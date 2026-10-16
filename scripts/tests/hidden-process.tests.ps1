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
    if ([IO.File]::ReadAllText($errFile) -notmatch 'hidden-err') { throw 'stderr was lost' }
    $proc.Dispose()

    # Probe timeouts cannot turn missing metadata into an exit-zero result.
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $probe=Invoke-AiSopMetadataProbe (Get-Process -Id $PID).Path @('-NoProfile','-Command','Start-Sleep 60') -TimeoutSeconds 1
    if ($probe.exitCode -ne 124 -or $probe.diagnostic -notmatch 'PROCESS_TIMED_OUT' -or $timer.Elapsed.TotalSeconds -gt 10) { throw 'Metadata probe did not time out promptly and explicitly' }
    $probe=Invoke-AiSopMetadataProbe (Get-Process -Id $PID).Path @('-NoProfile','-Command','[Console]::ReadLine(); Write-Output "stdin-closed"; exit 7')
    if ($probe.exitCode -ne 7 -or $probe.output -notmatch 'stdin-closed') { throw 'Probe did not close stdin or preserve nonzero exit' }

    # The direct child is a launcher. The grandchild must also die on timeout.
    $treeWorker=Join-Path $TestRoot 'tree.ps1'
    $identityFile=Join-Path $TestRoot 'descendant.json'
    [IO.File]::WriteAllText($treeWorker, @'
param([string]$IdentityFile, [switch]$ExitParent)
$info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$info.UseShellExecute=$false; $info.CreateNoWindow=$true
foreach ($arg in @('-NoProfile','-Command','Write-Output "descendant-output"; Start-Sleep 60')) { $info.ArgumentList.Add($arg) }
$child=[Diagnostics.Process]::Start($info)
@{id=$child.Id;startedTicks=$child.StartTime.ToUniversalTime().Ticks} | ConvertTo-Json | Set-Content -LiteralPath $IdentityFile
Write-Output 'parent-output'
if ($ExitParent) { exit 0 }
Start-Sleep 60
'@)
    foreach ($exitParent in @($false,$true)) {
        $tree=$null; $identity=$null
        try {
            $treeArgs=@('-NoProfile','-File',$treeWorker,$identityFile)
            if ($exitParent) { $treeArgs+='-ExitParent' }
            $tree=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList $treeArgs -RedirectStandardOutput $outFile -RedirectStandardError $errFile -TimeoutSeconds 5 -DrainTimeoutSeconds 1 -PassThru
            $tree.WaitForExit()
            $identity=Get-Content -LiteralPath $identityFile -Raw | ConvertFrom-Json
            if ($exitParent) {
                if ($tree.ExitCode -ne 125 -or $tree.Diagnostic -notmatch 'OUTPUT_DRAIN_TIMED_OUT') { throw "Inherited pipes were treated as success: $($tree.Diagnostic) / $($tree.ExitCode)" }
            } else {
                if ($tree.ExitCode -ne 124 -or -not $tree.HasExited) { throw 'Launcher was not terminated on timeout' }
                $remaining=Get-Process -Id $identity.id -ErrorAction SilentlyContinue
                if ($remaining) {
                    try {
                        if (-not $remaining.HasExited -and $remaining.StartTime.ToUniversalTime().Ticks -eq $identity.startedTicks) { throw 'Timeout left the launcher grandchild running' }
                    } finally { $remaining.Dispose() }
                }
            }
            if ([IO.File]::ReadAllText($outFile) -notmatch 'parent-output') { throw 'Output before timeout was discarded' }
        } finally {
            if ($tree) { $tree.Dispose() }
            # When a parent has already exited, .NET tree termination cannot
            # identify reparented descendants. Clean up only our fixture by ID
            # AND start time, never by executable name.
            if ($identity) {
                $remaining=Get-Process -Id $identity.id -ErrorAction SilentlyContinue
                if ($remaining) {
                    try {
                        if (-not $remaining.HasExited -and $remaining.StartTime.ToUniversalTime().Ticks -eq $identity.startedTicks) { $remaining.Kill($true); [void]$remaining.WaitForExit(3000) }
                    } finally { $remaining.Dispose() }
                }
            }
        }
    }

    $proc=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep 60') -PassThru
    $ownedId=$proc.Id; $ownedStart=$proc.Inner.StartTime
    $timer.Restart(); $proc.Dispose(); $proc.Dispose()
    if ($timer.Elapsed.TotalSeconds -gt 10) { throw 'Dispose waited for a sleeping process' }
    $remaining=Get-Process -Id $ownedId -ErrorAction SilentlyContinue
    if ($remaining) {
        try { if ($remaining.StartTime -eq $ownedStart -and -not $remaining.HasExited) { throw 'Dispose left its owned process running' } }
        finally { $remaining.Dispose() }
    }
    $launchFailure=''
    try { Start-AiSopHiddenProcess -FilePath (Join-Path $TestRoot 'missing-executable') -RedirectStandardOutput $outFile -PassThru | Out-Null }
    catch { $launchFailure=$_.Exception.Message }
    if (-not $launchFailure) { throw 'Missing executable did not fail' }
    $exclusive=[IO.File]::Open($outFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $exclusive.Dispose()

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
