#requires -Version 7.0
# Each suite has its own process, deadline and retained output. Serial by default.
[CmdletBinding()]
param(
    [string]$TestsRoot=(Join-Path $PSScriptRoot 'tests'),
    [string]$Suite='',
    [switch]$IncludeCompile,
    [switch]$Quiet,
    [switch]$Serial,
    [switch]$Parallel,
    [ValidateRange(0,64)][int]$MaxParallel=0,
    [ValidateRange(1,86400)][int]$SuiteTimeoutSeconds=900,
    [ValidateRange(1,86400)][int]$CompileTimeoutSeconds=1800,
    [ValidateRange(1,3600)][int]$HeartbeatSeconds=30
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'hidden-process.ps1')
if ($Serial -and $Parallel) { throw 'Specify either -Serial or -Parallel, not both.' }

function Start-Suite {
    param([string]$File, [string]$Name, [string[]]$ExtraArguments=@(), [int]$Limit=$SuiteTimeoutSeconds)
    $index=$script:NextIndex; $script:NextIndex++
    $outFile=Join-Path $script:LogRoot "$index.stdout.log"
    $errFile=Join-Path $script:LogRoot "$index.stderr.log"
    $job=[pscustomobject]@{name=$Name;file=$File;process=$null;outFile=$outFile;errFile=$errFile;diagnostic='';limit=$Limit}
    try {
        $heartbeat=if ($Quiet) { 0 } else { $HeartbeatSeconds }
        $job.process=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList (@('-NoProfile','-File',$File)+$ExtraArguments) -RedirectStandardOutput $outFile -RedirectStandardError $errFile -TimeoutSeconds $Limit -HeartbeatSeconds $heartbeat -Label $Name -CloseStandardInput -PassThru
        if (-not $Quiet) { Write-Host "START $Name pid=$($job.process.Id) limit=$($Limit)s" -ForegroundColor Cyan }
    } catch { $job.diagnostic="PROCESS_START_FAILED: $($_.Exception.Message)" }
    return $job
}

function Complete-Suite {
    param($Job)
    $code=-1; $duration=0; $diagnostic=$Job.diagnostic
    if ($Job.process) {
        $code=$Job.process.ExitCode; $duration=$Job.process.Clock.ElapsedMilliseconds
        $diagnostic=$Job.process.Diagnostic
    }
    $outcome=if ($code -eq 0) { 'PASSED' } elseif ($code -eq 124 -and $diagnostic -like 'PROCESS_TIMED_OUT:*') { 'TIMED_OUT' } else { 'FAILED' }
    $result=[pscustomobject]@{
        Name=$Job.name; File=$Job.file; ExitCode=$code; Passed=($code -eq 0); Outcome=$outcome
        DurationMs=$duration; TimeoutSeconds=$Job.limit; Diagnostic=$diagnostic; OutFile=$Job.outFile; ErrFile=$Job.errFile
    }
    if ($Job.process) { $Job.process.Dispose() }
    $script:Results.Add($result)
    # Incremental diagnostic report, not workflow evidence. Preserve on failure.
    [IO.File]::WriteAllText((Join-Path $script:LogRoot 'results.json'), (ConvertTo-Json -InputObject @($script:Results.ToArray()) -Depth 5))
    if (-not $Quiet -or -not $result.Passed) {
        $color=if ($result.Passed) { 'Green' } else { 'Red' }
        Write-Host ("{0,-42} {1}  {2} ms" -f $result.Name,$outcome,$duration) -ForegroundColor $color
        if (-not $result.Passed) {
            if ($diagnostic) { Write-Host $diagnostic -ForegroundColor Red }
            foreach ($path in @($Job.outFile,$Job.errFile)) {
                if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Tail 10 | ForEach-Object { Write-Host "        $_" } }
            }
            Write-Host "Logs: stdout=$($Job.outFile) stderr=$($Job.errFile)"
        }
    }
}

# Discover test files. Auto-includes any future *.tests.ps1 with no list
# maintenance. Standard-flow suites live in .ai-sop/scripts/tests; project-
# domain suites (e.g. feature-runtime / tomcat) live in .ai-workspace/scripts/tests.
# The project test root is only appended when TestsRoot is the default
# (.ai-sop/scripts/tests), so explicit -TestsRoot overrides (used by the
# run-all-tests self-test with a temp dir) stay isolated.
$defaultTestRoot = Join-Path $PSScriptRoot "tests"
$testRoots = @($TestsRoot)
if ($TestsRoot -eq $defaultTestRoot) {
    # Installed layout: <workspace>/.ai-sop/scripts  -> parent/parent is workspace.
    # This repo layout: <workspace>/scripts -> parent/parent can be empty on some hosts.
    $sopParent = Split-Path -Parent $PSScriptRoot
    $projectRoot = if (-not [string]::IsNullOrWhiteSpace($sopParent)) {
        Split-Path -Parent $sopParent
    } else {
        ""
    }
    if (-not [string]::IsNullOrWhiteSpace($projectRoot)) {
        $projectTestRoot = Join-Path $projectRoot ".ai-workspace/scripts/tests"
        if (Test-Path -LiteralPath $projectTestRoot) { $testRoots += $projectTestRoot }
    }
}
$allFiles = @(
    foreach ($tr in $testRoots) {
        Get-ChildItem -LiteralPath $tr -Filter *.tests.ps1 -File -ErrorAction SilentlyContinue
    }
) | Sort-Object Name
if ($Suite) {
    $allFiles = @($allFiles | Where-Object {
        $_.BaseName -like "*$Suite*" -or $_.Name -like "*$Suite*"
    })
}


$script:LogRoot=Join-Path ([IO.Path]::GetTempPath()) ('ai-sop-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($script:LogRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $script:LogRoot 'results.json'), '[]')
$script:NextIndex=0
$script:Results=[Collections.Generic.List[object]]::new()
$jobs=[Collections.Generic.List[object]]::new()
$queue=[Collections.Generic.Queue[object]]::new()
foreach ($file in $allFiles) { $queue.Enqueue($file) }
$capacity=if (-not $Parallel) { 1 } elseif ($MaxParallel -gt 0) { $MaxParallel } else { 4 }
if (-not $Quiet) {
    Write-Host "Running $($allFiles.Count) test suite(s), max concurrent=$capacity; per-suite limit=$($SuiteTimeoutSeconds)s" -ForegroundColor Cyan
    Write-Host "Test logs: $script:LogRoot"
}
try {
    while ($queue.Count -or $jobs.Count) {
        while ($queue.Count -and $jobs.Count -lt $capacity) {
            $file=$queue.Dequeue()
            $jobs.Add((Start-Suite -File $file.FullName -Name $file.BaseName))
        }
        # Poll every active suite, so parallel deadlines run from launch time,
        # even when an earlier suite hangs.
        foreach ($job in @($jobs.ToArray())) {
            if (-not $job.process -or $job.process.Poll()) {
                Complete-Suite $job
                [void]$jobs.Remove($job)
            }
        }
        if ($jobs.Count) { [Threading.Thread]::Sleep(100) }
    }
    if ($IncludeCompile) {
        $projectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $gradlew=Join-Path $projectRoot 'gradlew.bat'
        if (-not (Test-Path -LiteralPath $gradlew)) { $gradlew=Join-Path $projectRoot 'gradlew' }
        if (Test-Path -LiteralPath $gradlew) {
            # Use a script with argument arrays, never interpolate a shell command.
            $worker=Join-Path $script:LogRoot 'compile.ps1'
            [IO.File]::WriteAllText($worker, 'param([string]$Wrapper,[string]$Root) $ErrorActionPreference="Stop"; Set-Location -LiteralPath $Root; & $Wrapper compileJava; exit $LASTEXITCODE')
            $job=Start-Suite -File $worker -Name 'compileJava' -ExtraArguments @($gradlew,$projectRoot) -Limit $CompileTimeoutSeconds
            $jobs.Add($job)
            if ($job.process) { $job.process.WaitForExit() }
            Complete-Suite $job
            [void]$jobs.Remove($job)
        } else { Write-Host "gradlew not found under $projectRoot; skipping compile." -ForegroundColor Yellow }
    }
} finally {
    # Also runs on interruption/runner error; Dispose never waits indefinitely.
    foreach ($job in $jobs) { if ($job.process) { $job.process.Dispose() } }
}
$failed=@($script:Results | Where-Object { -not $_.Passed }).Count
$passed=$script:Results.Count - $failed
if (-not $Quiet -or $failed) {
    Write-Host "$passed/$($script:Results.Count) checks passed; results: $(Join-Path $script:LogRoot 'results.json')"
}
if ($failed) { exit 1 } else { exit 0 }
