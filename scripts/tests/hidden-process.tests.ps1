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

    # Fault injection: cancellation callbacks and Dispose can block in native
    # I/O. A cleanup budget must include them, not only Task.WaitAll afterward.
    $blockerSource=@'
using System;
using System.IO;
using System.Threading;
public class AiSopBlockingCleanupStream : MemoryStream {
    public readonly ManualResetEventSlim Entered = new ManualResetEventSlim(false);
    public readonly ManualResetEventSlim Release = new ManualResetEventSlim(false);
    public string FailurePath;
    public bool SawFailure;
    public void Block() {
        SawFailure = File.Exists(FailurePath) && File.ReadAllText(FailurePath).Contains("PROCESS_TIMED_OUT");
        Entered.Set(); Release.Wait();
    }
    public void BlockCancellation(CancellationTokenSource source) { source.Token.Register(Block); }
    protected override void Dispose(bool disposing) { Block(); base.Dispose(disposing); }
}
'@
    Add-Type -TypeDefinition $blockerSource
    foreach ($stage in @('dispose','cancel')) {
        $blocked=$null; $blocker=[AiSopBlockingCleanupStream]::new()
        $failureFile=Join-Path $TestRoot "$stage.failure.json"; $blocker.FailurePath=$failureFile
        try {
            $blocked=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep 60') -TimeoutSeconds 1 -CleanupTimeoutMilliseconds 200 -FailurePath $failureFile -PassThru
            if ($stage -eq 'dispose') { $blocked.Streams.Add($blocker) }
            else { $blocker.BlockCancellation($blocked.CopyCancellation) }
            $timer.Restart(); $blocked.WaitForExit()
            if ($timer.Elapsed.TotalSeconds -gt 6 -or $blocked.ExitCode -ne 124 -or $blocked.Diagnostic -notmatch 'PROCESS_CLEANUP_TIMED_OUT') { throw "Blocked $stage escaped cleanup budget or lost original failure" }
            if (-not $blocker.Entered.Wait(3000) -or -not $blocker.SawFailure) { throw 'Failure was not saved before entering blocking cleanup' }
            $savedFailure=Get-Content -LiteralPath $failureFile -Raw | ConvertFrom-Json
            if ($savedFailure.exitCode -ne 124 -or $savedFailure.diagnostic -notmatch 'PROCESS_CLEANUP_TIMED_OUT') { throw 'Cleanup timeout diagnosis was not retained' }
            $timer.Restart(); $blocked.Dispose(); $blocked.Dispose()
            if ($timer.Elapsed.TotalSeconds -gt 1) { throw 'Dispose retried an already timed out cleanup' }
        } finally {
            $blocker.Release.Set()
            if ($blocked) {
                $blocked.Dispose()
                if (-not $blocked.Cleanup.pending.Wait(5000)) { throw 'Fault fixture cleanup did not finish after release' }
            }
        }
    }

    # A permanently blocked BACKGROUND cleanup must not hold the CLI open.
    $fixtureType=Join-Path $TestRoot 'blocker.cs'; [IO.File]::WriteAllText($fixtureType,$blockerSource)
    $fixtureHost=Join-Path $TestRoot 'cleanup-host.ps1'
    [IO.File]::WriteAllText($fixtureHost,@'
param([string]$Helper,[string]$Fixture,[string]$Failure)
. $Helper
Add-Type -Path $Fixture
$blocker=[AiSopBlockingCleanupStream]::new(); $blocker.FailurePath=$Failure
$child=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep 60') -TimeoutSeconds 1 -CleanupTimeoutMilliseconds 200 -FailurePath $Failure -PassThru
$child.Streams.Add($blocker)
$child.WaitForExit(); $child.Dispose()
if ($child.Diagnostic -notmatch 'PROCESS_CLEANUP_TIMED_OUT') { exit 9 }
exit 7
'@)
    $hostProcess=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$fixtureHost,(Join-Path $ScriptsRoot 'hidden-process.ps1'),$fixtureType,(Join-Path $TestRoot 'host.failure.json')) -TimeoutSeconds 12 -PassThru
    try { $hostProcess.WaitForExit(); if ($hostProcess.ExitCode -ne 7) { throw 'Blocked background cleanup kept the CLI alive or hid failure' } }
    finally { $hostProcess.Dispose() }

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
