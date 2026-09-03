#requires -Version 7.0

# Aggregates and runs all workflow test suites under the tests directory.
# Each suite runs in its own pwsh subprocess so per-suite environment overrides
# cannot leak into siblings. Suites are parallel by default (each uses a unique
# guid-based temp registry and independent env, so they are isolated); pass
# -Serial for sequential execution. Exit code is 0 only when every suite (and,
# when requested, gradlew compileJava) passes; used as the pre-completion gate
# and the CI entry point.
#
# Usage:
#   pwsh -NoProfile -File .\.ai-sop\scripts\run-all-tests.ps1
#   pwsh -NoProfile -File .\.ai-sop\scripts\run-all-tests.ps1 -Serial
#   pwsh -NoProfile -File .\.ai-sop\scripts\run-all-tests.ps1 -Suite workflow-owner
#   pwsh -NoProfile -File .\.ai-sop\scripts\run-all-tests.ps1 -IncludeCompile

[CmdletBinding()]
param(
    [string]$TestsRoot = (Join-Path $PSScriptRoot "tests"),

    [string]$Suite = "",

    [switch]$IncludeCompile,

    [switch]$Quiet,

    [switch]$Serial,

    [int]$MaxParallel = 0
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hidden-process.ps1")

function Invoke-TestSuiteSerial {
    param([string]$File)

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-AiSopHiddenProcess `
            -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList @("-NoProfile", "-File", $File) `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -PassThru
        $proc.WaitForExit()
        $stdout = @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue)
        $stderr = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)
        $output = @($stdout + $stderr)
        return [pscustomobject]@{
            Name     = [System.IO.Path]::GetFileNameWithoutExtension($File)
            File     = $File
            ExitCode = $proc.ExitCode
            Passed   = ($proc.ExitCode -eq 0)
            Output   = $output
        }
    } finally {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-TestSuiteParallel {
    # Launches one hidden pwsh subprocess per suite, writing combined output
    # to a temp file; returns jobs to await. CreateNoWindow (not WindowStyle)
    # is what actually suppresses the Windows console when stdout is redirected.
    param(
        [string]$File,
        [string]$OutFile
    )
    $errFile = [System.IO.Path]::ChangeExtension($OutFile, ".err")
    $p = Start-AiSopHiddenProcess `
        -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @("-NoProfile", "-File", $File) `
        -RedirectStandardOutput $OutFile `
        -RedirectStandardError $errFile `
        -PassThru
    return [pscustomobject]@{
        Name    = [System.IO.Path]::GetFileNameWithoutExtension($File)
        File    = $File
        Process = $p
        OutFile = $OutFile
    }
}

function Invoke-Compile {
    $sopParent = Split-Path -Parent $PSScriptRoot
    $projectRoot = if (-not [string]::IsNullOrWhiteSpace($sopParent)) {
        Split-Path -Parent $sopParent
    } else {
        ""
    }
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        $projectRoot = $sopParent
    }
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        Write-Host "gradlew not found; skipping compile." -ForegroundColor Yellow
        return $true
    }
    $gradlew = Join-Path $projectRoot "gradlew.bat"
    if (-not (Test-Path -LiteralPath $gradlew)) {
        $gradlew = Join-Path $projectRoot "gradlew"
    }
    if (-not (Test-Path -LiteralPath $gradlew)) {
        Write-Host "gradlew not found under $projectRoot; skipping compile." -ForegroundColor Yellow
        return $true
    }
    & {
        $ErrorActionPreference = 'Continue'
        & $gradlew compileJava 2>&1
    }
    return ($LASTEXITCODE -eq 0)
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

if (-not $Quiet) {
    $mode = if ($Parallel) { "parallel" } else { "serial" }
    Write-Host "Running $($allFiles.Count) test suite(s) from $TestsRoot ($mode)" -ForegroundColor Cyan
}

$results = @()

if (-not $Parallel) {
    foreach ($file in $allFiles) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-TestSuiteSerial -File $file.FullName
        $stopwatch.Stop()
        $result |
            Add-Member -NotePropertyName DurationMs -NotePropertyValue $stopwatch.ElapsedMilliseconds
        $results += $result
        if (-not $Quiet) {
            $status = if ($result.Passed) { "PASS" } else { "FAIL" }
            $color = if ($result.Passed) { 'Green' } else { 'Red' }
            Write-Host ("{0,-42} {1}  {2} ms" -f $result.Name, $status, $result.DurationMs) -ForegroundColor $color
            if (-not $result.Passed -and $result.Output) {
                $result.Output | Select-Object -Last 10 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
            }
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
} else {
    # Parallel: launch all, then await.
    $jobs = @()
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-sop-run-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        $idx = 0
        foreach ($file in $allFiles) {
            $outFile = Join-Path $tempDir ("suite-$idx.out")
            $jobs += Invoke-TestSuiteParallel -File $file.FullName -OutFile $outFile
            $idx++
        }

        # Await all processes.
        foreach ($job in $jobs) {
            $job.Process.WaitForExit()
        }

        # Collect results in discovery order.
        $rIdx = 0
        foreach ($job in $jobs) {
            $tail = ""
            $outFile = Join-Path $tempDir ("suite-$rIdx.out")
            if (Test-Path -LiteralPath $outFile) {
                $tail = ([string]((@(Get-Content -LiteralPath $outFile) | Select-Object -Last 1)))
            }
            $results += [pscustomobject]@{
                Name       = $job.Name
                File       = $job.File
                ExitCode   = $job.Process.ExitCode
                Passed     = ($job.Process.ExitCode -eq 0)
                Tail       = $tail
                DurationMs = 0
                OutFile    = $outFile
            }
            $rIdx++
        }

        if (-not $Quiet) {
            foreach ($r in $results) {
                $status = if ($r.Passed) { "PASS" } else { "FAIL" }
                $color = if ($r.Passed) { 'Green' } else { 'Red' }
                Write-Host ("{0,-42} {1}" -f $r.Name, $status) -ForegroundColor $color
                if (-not $r.Passed -and $r.OutFile -and (Test-Path -LiteralPath $r.OutFile)) {
                    Get-Content -LiteralPath $r.OutFile -Tail 10 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
                }
            }
        }
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $tempDir -ErrorAction SilentlyContinue
    }
}

$passedCount = @($results | Where-Object { $_.Passed }).Count
$failedCount = @($results | Where-Object { -not $_.Passed }).Count

$compilePassed = $true
if ($IncludeCompile) {
    if (-not $Quiet) { Write-Host "---- gradlew compileJava ----" -ForegroundColor Cyan }
    $compilePassed = Invoke-Compile
    if (-not $Quiet) {
        $cStatus = if ($compilePassed) { "PASS" } else { "FAIL" }
        $cColor = if ($compilePassed) { 'Green' } else { 'Red' }
        Write-Host ("{0,-42} {1}" -f "compileJava", $cStatus) -ForegroundColor $cColor
    }
}

$overallOk = ($failedCount -eq 0) -and $compilePassed
$compileNote = if (-not $compilePassed) { " (compile FAILED)" } else { "" }

if (-not $Quiet) {
    $summaryColor = if ($overallOk) { 'Green' } else { 'Red' }
    Write-Host ("{0}/{1} test suites passed{2}" -f $passedCount, $results.Count, $compileNote) -ForegroundColor $summaryColor
} else {
    if (-not $overallOk) {
        Write-Host ("{0}/{1} test suites passed{2}" -f $passedCount, $results.Count, $compileNote)
    }
}

if ($overallOk) { exit 0 } else { exit 1 }
