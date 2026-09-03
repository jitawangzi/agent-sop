#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ScriptsRoot "hidden-process.ps1")
$RunnerScript = Join-Path $ScriptsRoot "run-all-tests.ps1"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "hidden-process-tests-" + [guid]::NewGuid().ToString("N")
)

try {
    [System.IO.Directory]::CreateDirectory($TestRoot) | Out-Null

    $outFile = Join-Path $TestRoot "child.out"
    $errFile = Join-Path $TestRoot "child.err"
    $worker = Join-Path $TestRoot "child.ps1"
    [System.IO.File]::WriteAllText(
        $worker,
        'Write-Output "hidden-ok"; Write-Error "hidden-err" -ErrorAction Continue; exit 0',
        $Utf8NoBom
    )

    $proc = Start-AiSopHiddenProcess `
        -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @("-NoProfile", "-File", $worker) `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError $errFile `
        -PassThru
    if (-not $proc.StartInfo.CreateNoWindow) {
        throw "Start-AiSopHiddenProcess must set CreateNoWindow; WindowStyle Hidden is ignored with redirects."
    }
    if ($proc.StartInfo.UseShellExecute) {
        throw "Start-AiSopHiddenProcess must set UseShellExecute=false so CreateNoWindow is honored."
    }
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        throw "Hidden child exited $($proc.ExitCode)"
    }
    $outText = [System.IO.File]::ReadAllText($outFile)
    if ($outText -notmatch "hidden-ok") {
        throw "Hidden child stdout was not captured. Content: $outText"
    }

    # Regression lock: suite runners and tests must not call Start-Process.
    # That cmdlet opens a console when combined with stdout redirect.
    $scanRoots = @(
        $ScriptsRoot,
        (Join-Path $ScriptsRoot "tests")
    )
    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $scanRoots) {
        Get-ChildItem -LiteralPath $root -Filter *.ps1 -File | ForEach-Object {
            if ($_.Name -like "hidden-process*.ps1") { return }
            $lines = Get-Content -LiteralPath $_.FullName
            $i = 0
            foreach ($line in $lines) {
                $i++
                $code = $line -replace '#.*$', ''
                if ($code -match '\bStart-Process\b') {
                    $rel = $_.FullName.Substring($ScriptsRoot.Length).TrimStart('\', '/')
                    $hits.Add("${rel}:$i")
                }
            }
        }
    }
    if ($hits.Count -gt 0) {
        throw "Start-Process reintroduced (visible pwsh windows on Windows). Use Start-AiSopHiddenProcess. Hits: $($hits -join ', ')"
    }

    $runner = Get-Content -LiteralPath $RunnerScript -Raw
    if ($runner -notmatch 'Start-AiSopHiddenProcess') {
        throw "run-all-tests.ps1 must launch suites via Start-AiSopHiddenProcess so serial runs do not pop consoles."
    }
    if ($runner -match '(?m)function Invoke-TestSuiteSerial[\s\S]{0,400}?pwsh -NoProfile -File \$File') {
        throw "Invoke-TestSuiteSerial must not invoke a visible pwsh console via 'pwsh -File'."
    }

    Write-Output "All hidden-process tests passed."
} finally {
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
