#requires -Version 7.0
# Hidden, bounded subprocesses. Inherited output pipes also need a deadline.

function Close-AiSopHiddenProcessStreams {
    param($Handle)
    $Handle.CopyCancellation.Cancel()
    if ($Handle.Inner.StartInfo.RedirectStandardOutput) { $Handle.Inner.StandardOutput.Dispose() }
    if ($Handle.Inner.StartInfo.RedirectStandardError) { $Handle.Inner.StandardError.Dispose() }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$Handle.CopyTasks.ToArray(), 1000) } catch { }
    foreach ($stream in $Handle.Streams) { $stream.Dispose() }
    $Handle.Streams.Clear()
}

function Stop-AiSopHiddenProcess {
    param($Handle)
    if ($Handle.Completed) { return }
    try {
        if (-not $Handle.Inner.HasExited) {
            # Includes intermediary launchers (e.g. Git for Windows' cmd shim).
            $Handle.Inner.Kill($true)
            if (-not $Handle.Inner.WaitForExit(3000)) { throw 'process did not exit after tree termination' }
        }
    } catch { $Handle.Diagnostic += "; PROCESS_CLEANUP_FAILED: $($_.Exception.Message)" }
    if (-not $Handle.FailureCode) { $Handle.FailureCode=125; $Handle.Diagnostic='PROCESS_INTERRUPTED' + $Handle.Diagnostic }
    Close-AiSopHiddenProcessStreams $Handle
    $Handle.Completed=$true
}

function Update-AiSopHiddenProcess {
    param($Handle)
    if ($Handle.Completed) { return $true }
    $elapsed=$Handle.Clock.Elapsed.TotalSeconds
    if ($Handle.Inner.HasExited) {
        if ($null -eq $Handle.ExitObservedAt) { $Handle.ExitObservedAt=$elapsed }
        $pending=@($Handle.CopyTasks | Where-Object { -not $_.IsCompleted })
        if (-not $pending.Count) {
            try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$Handle.CopyTasks.ToArray(), 0) }
            catch { $Handle.FailureCode=125; $Handle.Diagnostic="OUTPUT_CAPTURE_FAILED: $($_.Exception.Message)" }
            Close-AiSopHiddenProcessStreams $Handle
            $Handle.Completed=$true
            return $true
        }
        if ($elapsed - $Handle.ExitObservedAt -ge $Handle.DrainTimeoutSeconds) {
            $Handle.FailureCode=125; $Handle.Diagnostic='OUTPUT_DRAIN_TIMED_OUT: child exited but inherited output pipes remained open; reparented descendant cleanup is unconfirmed'
            Stop-AiSopHiddenProcess $Handle
            return $true
        }
    } elseif ($elapsed -ge $Handle.TimeoutSeconds) {
        $Handle.FailureCode=124; $Handle.Diagnostic="PROCESS_TIMED_OUT: exceeded $($Handle.TimeoutSeconds)s; terminating child process tree"
        Stop-AiSopHiddenProcess $Handle
        return $true
    }
    if ($Handle.HeartbeatSeconds -gt 0 -and $elapsed -ge $Handle.NextHeartbeatAt) {
        Write-Host ("WAIT {0} pid={1} elapsed={2}s limit={3}s stdout={4} stderr={5}" -f $Handle.Label, $Handle.Id, [int]$elapsed, $Handle.TimeoutSeconds, $Handle.OutFile, $Handle.ErrFile)
        $Handle.NextHeartbeatAt=$elapsed + $Handle.HeartbeatSeconds
    }
    return $false
}

function Start-AiSopHiddenProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList=@(),
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError,
        [ValidateRange(1,86400)][int]$TimeoutSeconds=1800,
        [ValidateRange(1,60)][int]$DrainTimeoutSeconds=5,
        [ValidateRange(0,3600)][int]$HeartbeatSeconds=0,
        [string]$Label='process',
        [switch]$CloseStandardInput,
        [switch]$PassThru
    )
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$FilePath; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=[bool]$CloseStandardInput
    foreach ($arg in @($ArgumentList)) { if ($null -ne $arg) { $psi.ArgumentList.Add([string]$arg) } }
    $proc=[Diagnostics.Process]::new(); $proc.StartInfo=$psi
    $streams=[Collections.Generic.List[IO.Stream]]::new()
    $copies=[Collections.Generic.List[Threading.Tasks.Task]]::new()
    $cancellation=[Threading.CancellationTokenSource]::new()
    $started=$false
    try {
        $outStream=$null; $errStream=$null
        foreach ($entry in @(@{path=$RedirectStandardOutput;kind='out'}, @{path=$RedirectStandardError;kind='err'})) {
            if ([string]::IsNullOrWhiteSpace($entry.path)) { continue }
            $dir=Split-Path -Parent $entry.path
            if ($dir) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
            $stream=[IO.File]::Open($entry.path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $streams.Add($stream)
            if ($entry.kind -eq 'out') { $psi.RedirectStandardOutput=$true; $outStream=$stream }
            else { $psi.RedirectStandardError=$true; $errStream=$stream }
        }
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $started=$proc.Start()
        if (-not $started) { throw "Failed to start hidden process: $FilePath" }
        if ($CloseStandardInput) { $proc.StandardInput.Close() }
        if ($outStream) { $copies.Add($proc.StandardOutput.BaseStream.CopyToAsync($outStream, 81920, $cancellation.Token)) }
        if ($errStream) { $copies.Add($proc.StandardError.BaseStream.CopyToAsync($errStream, 81920, $cancellation.Token)) }
    } catch {
        try { if ($started -and -not $proc.HasExited) { $proc.Kill($true); [void]$proc.WaitForExit(3000) } }
        finally {
            $cancellation.Cancel()
            foreach ($stream in $streams) { $stream.Dispose() }
            $cancellation.Dispose(); $proc.Dispose()
        }
        throw
    }
    $handle=[pscustomobject]@{
        PSTypeName='AiSopHiddenProcess'; Inner=$proc; CopyTasks=$copies; Streams=$streams; CopyCancellation=$cancellation
        Clock=$clock; TimeoutSeconds=$TimeoutSeconds; DrainTimeoutSeconds=$DrainTimeoutSeconds
        HeartbeatSeconds=$HeartbeatSeconds; NextHeartbeatAt=$HeartbeatSeconds; Label=$Label
        OutFile=$RedirectStandardOutput; ErrFile=$RedirectStandardError
        ExitObservedAt=$null; Completed=$false; Disposed=$false; FailureCode=0; Diagnostic=''
    }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name Id -Value { $this.Inner.Id }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name ExitCode -Value { if ($this.FailureCode) { $this.FailureCode } else { $this.Inner.ExitCode } }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name HasExited -Value { $this.Inner.HasExited }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name StartInfo -Value { $this.Inner.StartInfo }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Refresh -Value { $this.Inner.Refresh() }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Poll -Value { Update-AiSopHiddenProcess $this }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name WaitForExit -Value {
        while (-not (Update-AiSopHiddenProcess $this)) { [Threading.Thread]::Sleep(50) }
    }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Dispose -Value {
        if ($this.Disposed) { return }
        try { if (-not $this.Completed) { Stop-AiSopHiddenProcess $this } }
        finally { $this.Inner.Dispose(); $this.CopyCancellation.Dispose(); $this.Disposed=$true }
    }
    if ($PassThru) { return $handle }
    try { $handle.WaitForExit(); return $handle.ExitCode } finally { $handle.Dispose() }
}

# Optional annotations only; never use a failed probe to satisfy a gate.
function Invoke-AiSopMetadataProbe {
    param([string]$FilePath, [string[]]$ArgumentList, [ValidateRange(1,60)][int]$TimeoutSeconds=10)
    $outFile=[IO.Path]::GetTempFileName(); $errFile=[IO.Path]::GetTempFileName(); $child=$null
    try {
        $child=Start-AiSopHiddenProcess -FilePath $FilePath -ArgumentList $ArgumentList -RedirectStandardOutput $outFile -RedirectStandardError $errFile -TimeoutSeconds $TimeoutSeconds -CloseStandardInput -PassThru
        $child.WaitForExit()
        return @{ exitCode=$child.ExitCode; output=[IO.File]::ReadAllText($outFile).Trim(); diagnostic=$child.Diagnostic }
    } catch { return @{exitCode=-1; output=''; diagnostic="METADATA_PROBE_FAILED: $($_.Exception.Message)"} }
    finally {
        if ($child) { $child.Dispose() }
        Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
    }
}
