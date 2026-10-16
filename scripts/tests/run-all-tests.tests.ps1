#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$RunnerScript = Join-Path $ScriptsRoot "run-all-tests.ps1"
. (Join-Path $ScriptsRoot 'hidden-process.ps1')
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "runner-tests-" + [guid]::NewGuid().ToString("N")
)
$TestsDir = Join-Path $TestRoot "tests"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function New-FakeSuite {
    param([string]$Name, [string]$Body)

    $path = Join-Path $TestsDir "$Name.tests.ps1"
    [System.IO.File]::WriteAllText($path, $Body, $Utf8NoBom)
}

function Clear-FakeSuites {
    Get-ChildItem -LiteralPath $TestsDir -Filter *.tests.ps1 -File -ErrorAction SilentlyContinue |
        Remove-Item -Force
}

function Invoke-Runner {
    param(
        [string]$SuiteFilter = "",
        [switch]$Parallel
    )

    $argList = @("-NoProfile", "-File", $RunnerScript, "-TestsRoot", $TestsDir, "-Quiet")
    if ($SuiteFilter) {
        $argList += @("-Suite", $SuiteFilter)
    }
    if ($Parallel) {
        $argList += "-Parallel"
    }
    & {
        $ErrorActionPreference = 'Continue'
        & pwsh @argList *> $null
    }
    return $LASTEXITCODE
}

function Assert-ExitZero {
    param([string]$Message, [scriptblock]$Action)

    & $Action | Out-Null
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "Expected exit 0: $Message ; got exit $code"
    }
}

function Assert-ExitNonZero {
    param([string]$Message, [scriptblock]$Action)

    & $Action | Out-Null
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        throw "Expected non-zero exit: $Message ; got exit 0"
    }
}

function Invoke-ObservedRunner {
    param([string[]]$Extra=@(), [string]$Entry=$RunnerScript)
    $outFile=Join-Path $TestRoot 'observed.out'; $errFile=Join-Path $TestRoot 'observed.err'
    $child=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList (@('-NoProfile','-File',$Entry,'-TestsRoot',$TestsDir)+$Extra) -RedirectStandardOutput $outFile -RedirectStandardError $errFile -TimeoutSeconds 40 -PassThru
    try {
        $child.WaitForExit()
        if ($child.Diagnostic) { throw "Runner itself failed to finish: $($child.Diagnostic)" }
        $output=[IO.File]::ReadAllText($outFile) + [IO.File]::ReadAllText($errFile)
        if ($output -notmatch 'results: ([^\r\n]+results.json)') { throw "Runner did not expose its saved results: $output" }
        $report=$Matches[1]
        $records=@(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json)
        return @{exitCode=$child.ExitCode;output=$output;records=$records;report=$report}
    } finally { $child.Dispose() }
}

try {
    [System.IO.Directory]::CreateDirectory($TestsDir) | Out-Null

    # 1. 单个通过的 suite -> exit 0
    Clear-FakeSuites
    New-FakeSuite "aaa-pass" 'Write-Output "All aaa-pass tests passed."'
    Assert-ExitZero -Message "single passing suite exits 0" -Action {
        Invoke-Runner
    }

    # 2. 一个通过 + 一个失败 -> exit 非零
    New-FakeSuite "bbb-fail" 'throw "boom"'
    Assert-ExitNonZero -Message "mixed pass/fail suites exit non-zero" -Action {
        Invoke-Runner
    }

    # 3. -Suite 过滤到通过的 suite -> exit 0
    Assert-ExitZero -Message "Suite filter to passing suite exits 0" -Action {
        Invoke-Runner -SuiteFilter "aaa-pass"
    }

    # 4. -Suite 过滤到失败的 suite -> exit 非零
    Assert-ExitNonZero -Message "Suite filter to failing suite exits non-zero" -Action {
        Invoke-Runner -SuiteFilter "bbb-fail"
    }

    # 5. 空测试目录 -> exit 0
    Clear-FakeSuites
    Assert-ExitZero -Message "empty tests dir exits 0" -Action {
        Invoke-Runner
    }

    # 6. 不存在的 TestsRoot -> exit 0 (无可运行项)
    $missingDir = Join-Path $TestRoot "does-not-exist"
    $argList = @("-NoProfile", "-File", $RunnerScript, "-TestsRoot", $missingDir, "-Quiet")
    & {
        $ErrorActionPreference = 'Continue'
        & pwsh @argList *> $null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Expected exit 0 for missing tests root; got exit $LASTEXITCODE"
    }

    # 7. -Parallel with two passing suites -> exit 0
    Clear-FakeSuites
    New-FakeSuite "par-a" 'Write-Output "All par-a tests passed."'
    New-FakeSuite "par-b" 'Write-Output "All par-b tests passed."'
    Assert-ExitZero -Message "parallel passing suites exit 0" -Action {
        Invoke-Runner -Parallel
    }

    # A hung suite fails, retains both streams, emits progress and releases the
    # runner to execute the next suite. The outer process is itself bounded.
    Clear-FakeSuites
    New-FakeSuite 'aaa-hang' 'Write-Output "before-hang"; [Console]::Error.WriteLine("error-before-hang"); Start-Sleep 60'
    New-FakeSuite 'bbb-after' 'Write-Output "after-hang"'
    $observed=Invoke-ObservedRunner -Extra @('-SuiteTimeoutSeconds','3','-HeartbeatSeconds','1')
    $hung=$observed.records | Where-Object Name -eq 'aaa-hang.tests'
    $after=$observed.records | Where-Object Name -eq 'bbb-after.tests'
    if ($observed.exitCode -eq 0 -or $hung.Outcome -ne 'TIMED_OUT' -or $hung.ExitCode -ne 124 -or -not $after.Passed) { throw 'Serial timeout did not fail safely and continue' }
    if ($observed.output -notmatch 'WAIT aaa-hang.tests pid=\d+ elapsed=' -or $hung.DurationMs -gt 12000) { throw 'No bounded wait/progress for hung suite' }
    if ([IO.File]::ReadAllText($hung.OutFile) -notmatch 'before-hang' -or [IO.File]::ReadAllText($hung.ErrFile) -notmatch 'error-before-hang') { throw 'Timeout lost stdout/stderr logs' }

    Clear-FakeSuites
    New-FakeSuite 'aaa-hang' 'Start-Sleep 60'
    New-FakeSuite 'bbb-hang' 'Start-Sleep 60'
    New-FakeSuite 'ccc-after' 'exit 0'
    $observed=Invoke-ObservedRunner -Extra @('-Parallel','-MaxParallel','2','-SuiteTimeoutSeconds','3','-Quiet')
    $hung=@($observed.records | Where-Object Outcome -eq 'TIMED_OUT')
    if ($observed.exitCode -eq 0 -or $hung.Count -ne 2 -or @($observed.records | Where-Object Passed).Count -ne 1) { throw 'Parallel timeout was lost or stopped later suites' }
    if (@($hung | Where-Object DurationMs -gt 5500).Count) { throw 'Parallel deadline started at Wait, not at process launch' }
    if ($observed.output -notmatch 'PROCESS_TIMED_OUT' -or $observed.output -notmatch 'stderr=') { throw 'Quiet mode hid failure diagnosis/logs' }

    # MaxParallel=1 must serialize even when -Parallel was requested.
    Clear-FakeSuites
    $marker=Join-Path $TestRoot 'exclusive.marker'
    $body='$marker=' + "'" + $marker.Replace("'","''") + "'" + '; $stream=[IO.File]::Open($marker,[IO.FileMode]::CreateNew); try { Start-Sleep 1 } finally { $stream.Dispose(); Remove-Item -LiteralPath $marker }'
    New-FakeSuite 'capacity-a' $body; New-FakeSuite 'capacity-b' $body
    $observed=Invoke-ObservedRunner -Extra @('-Parallel','-MaxParallel','1','-SuiteTimeoutSeconds','10')
    if ($observed.exitCode -ne 0) { throw 'MaxParallel did not limit live suite processes' }

    if ([OperatingSystem]::IsWindows()) {
        # Installed-layout optional compile also needs a deadline, including
        # the batch launcher and its own pwsh grandchild.
        Clear-FakeSuites
        $hostRoot=Join-Path $TestRoot 'compile host'
        $installed=Join-Path $hostRoot '.ai-sop/scripts'
        [IO.Directory]::CreateDirectory($installed) | Out-Null
        Copy-Item -LiteralPath $RunnerScript,(Join-Path $ScriptsRoot 'hidden-process.ps1') -Destination $installed
        [IO.File]::WriteAllText((Join-Path $hostRoot 'gradlew.bat'), "@echo off`r`npwsh -NoProfile -Command `"Write-Output compile-start; Start-Sleep 60`"`r`nexit /b %ERRORLEVEL%`r`n")
        $observed=Invoke-ObservedRunner -Entry (Join-Path $installed 'run-all-tests.ps1') -Extra @('-IncludeCompile','-CompileTimeoutSeconds','3','-Quiet')
        if ($observed.exitCode -eq 0 -or $observed.records.Count -ne 1 -or $observed.records[0].Name -ne 'compileJava' -or $observed.records[0].Outcome -ne 'TIMED_OUT') { throw 'Optional compile escaped deadline/failure summary' }
    }

    Write-Output "All run-all-tests tests passed."
} finally {
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
