#requires -Version 7.0
# Cleanup can itself block in native I/O. Run it without a PowerShell runspace
# on a background thread, and never synchronously dispose it again on timeout.
if (-not ('AiSop.ProcessCleanup' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
namespace AiSop {
    public sealed class CleanupResult {
        public bool Exited;
        public int? ExitCode;
        public string Diagnostic = "";
    }
    public static class ProcessCleanup {
        public static Task<CleanupResult> Begin(Process process, bool started, bool terminate,
            CancellationTokenSource cancellation, Task[] copies, IDisposable[] resources) {
            var completion = new TaskCompletionSource<CleanupResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            var thread = new Thread(() => {
                var result = new CleanupResult();
                var errors = new List<string>();
                Action<Action> attempt = action => {
                    try { action(); } catch (Exception ex) { errors.Add(ex.Message); }
                };
                if (started) attempt(() => {
                    if (terminate && !process.HasExited) {
                        process.Kill(true);
                        if (!process.WaitForExit(3000)) throw new InvalidOperationException("process did not exit after tree termination");
                    }
                    result.Exited = process.HasExited;
                    if (result.Exited) result.ExitCode = process.ExitCode;
                });
                if (cancellation != null) attempt(() => cancellation.Cancel());
                // Pending readers and Process.Dispose are also inside this boundary.
                if (started) {
                    attempt(() => { if (process.StartInfo.RedirectStandardOutput) process.StandardOutput.Dispose(); });
                    attempt(() => { if (process.StartInfo.RedirectStandardError) process.StandardError.Dispose(); });
                }
                if (copies != null && copies.Length > 0) attempt(() => {
                    try { if (!Task.WaitAll(copies, 1000)) errors.Add("output copy cancellation unconfirmed"); }
                    catch (AggregateException ex) {
                        foreach (var inner in ex.Flatten().InnerExceptions)
                            if (!(inner is OperationCanceledException) && !(inner is ObjectDisposedException)) errors.Add(inner.Message);
                    }
                });
                if (resources != null) foreach (var resource in resources)
                    if (resource != null) attempt(() => resource.Dispose());
                if (cancellation != null) attempt(() => cancellation.Dispose());
                if (process != null) attempt(() => process.Dispose());
                result.Diagnostic = errors.Count == 0 ? "" : "PROCESS_CLEANUP_FAILED: " + string.Join("; ", errors);
                completion.TrySetResult(result);
            });
            thread.IsBackground = true;
            thread.Name = "ai-sop-process-cleanup";
            thread.Start();
            return completion.Task;
        }
    }
}
'@
}

function Invoke-AiSopProcessCleanup {
    param(
        [Diagnostics.Process]$Process, [bool]$Started=$true, [bool]$Terminate=$true,
        [Threading.CancellationTokenSource]$Cancellation,
        [Threading.Tasks.Task[]]$Copies=@(), [IDisposable[]]$Resources=@(),
        [ValidateRange(1,10000)][int]$BudgetMilliseconds=5000
    )
    $pending=[AiSop.ProcessCleanup]::Begin($Process,$Started,$Terminate,$Cancellation,$Copies,$Resources)
    if (-not $pending.Wait($BudgetMilliseconds)) {
        return @{confirmed=$false;exited=$false;exitCode=$null;diagnostic="PROCESS_CLEANUP_TIMED_OUT: exceeded $($BudgetMilliseconds)ms; background cleanup and descendant exit unconfirmed";pending=$pending}
    }
    $result=$pending.GetAwaiter().GetResult()
    return @{confirmed=([string]::IsNullOrEmpty($result.Diagnostic));exited=$result.Exited;exitCode=$result.ExitCode;diagnostic=$result.Diagnostic;pending=$pending}
}

function Write-AiSopHiddenProcessFailure {
    param($Handle)
    if ($Handle.FailurePath -and $Handle.FailureCode) {
        try {
            [IO.File]::WriteAllText($Handle.FailurePath, (ConvertTo-Json -InputObject @{
                pid=$Handle.ProcessId;exitCode=$Handle.FailureCode;diagnostic=$Handle.Diagnostic
                recordedAt=[DateTimeOffset]::UtcNow.ToString('o')
            }))
        } catch { $Handle.Diagnostic += "; FAILURE_LOG_UNAVAILABLE: $($_.Exception.Message)" }
    }
}

function Close-AiSopHiddenProcessStreams {
    param($Handle, [bool]$Terminate=$false)
    if ($Handle.Cleanup) { return } # A timeout consumes the budget; never retry Dispose.
    Write-AiSopHiddenProcessFailure $Handle
    $Handle.Cleanup=Invoke-AiSopProcessCleanup -Process $Handle.Inner -Terminate $Terminate -Cancellation $Handle.CopyCancellation -Copies $Handle.CopyTasks.ToArray() -Resources $Handle.Streams.ToArray() -BudgetMilliseconds $Handle.CleanupTimeoutMilliseconds
    if ($Handle.Cleanup.exited) {
        $Handle.ExitKnown=$true; $Handle.RawExitCode=$Handle.Cleanup.exitCode
    }
    if ($Handle.Cleanup.diagnostic) {
        if (-not $Handle.FailureCode) { $Handle.FailureCode=125 }
        $Handle.Diagnostic=(@($Handle.Diagnostic,$Handle.Cleanup.diagnostic) | Where-Object { $_ }) -join '; '
        Write-AiSopHiddenProcessFailure $Handle
    }
    $Handle.Streams.Clear()
}

function Stop-AiSopHiddenProcess {
    param($Handle)
    if ($Handle.Completed) { return }
    if (-not $Handle.FailureCode) { $Handle.FailureCode=125; $Handle.Diagnostic='PROCESS_INTERRUPTED' }
    # Close preserves the failure before native termination or stream disposal.
    Close-AiSopHiddenProcessStreams $Handle -Terminate $true
    $Handle.Completed=$true
}

function Update-AiSopHiddenProcess {
    param($Handle)
    if ($Handle.Completed) { return $true }
    $elapsed=$Handle.Clock.Elapsed.TotalSeconds
    if ($Handle.Inner.HasExited) {
        $Handle.ExitKnown=$true; $Handle.RawExitCode=$Handle.Inner.ExitCode
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
        [ValidateRange(1,10000)][int]$CleanupTimeoutMilliseconds=5000,
        [string]$FailurePath,
        [hashtable]$Environment=@{},
        [string]$Label='process',
        [switch]$CloseStandardInput,
        [switch]$PassThru
    )
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$FilePath; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=[bool]$CloseStandardInput
    foreach ($key in $Environment.Keys) { $psi.Environment[$key]=[string]$Environment[$key] }
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
        $cleanup=Invoke-AiSopProcessCleanup -Process $proc -Started $started -Cancellation $cancellation -Copies $copies.ToArray() -Resources $streams.ToArray() -BudgetMilliseconds $CleanupTimeoutMilliseconds
        if ($cleanup.diagnostic) { Write-Warning $cleanup.diagnostic }
        throw
    }
    $handle=[pscustomobject]@{
        PSTypeName='AiSopHiddenProcess'; Inner=$proc; CopyTasks=$copies; Streams=$streams; CopyCancellation=$cancellation
        Clock=$clock; TimeoutSeconds=$TimeoutSeconds; DrainTimeoutSeconds=$DrainTimeoutSeconds
        HeartbeatSeconds=$HeartbeatSeconds; NextHeartbeatAt=$HeartbeatSeconds; Label=$Label
        OutFile=$RedirectStandardOutput; ErrFile=$RedirectStandardError
        ExitObservedAt=$null; Completed=$false; Disposed=$false; FailureCode=0; Diagnostic=''
        Cleanup=$null; CleanupTimeoutMilliseconds=$CleanupTimeoutMilliseconds; FailurePath=$FailurePath
        ProcessId=$proc.Id; ProcessStartInfo=$psi; ExitKnown=$false; RawExitCode=$null
    }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name Id -Value { $this.ProcessId }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name ExitCode -Value { if ($this.FailureCode) { $this.FailureCode } elseif ($this.ExitKnown) { $this.RawExitCode } else { $this.Inner.ExitCode } }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name HasExited -Value { if ($this.ExitKnown) { $true } elseif ($this.Cleanup) { $false } else { $this.Inner.HasExited } }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name StartInfo -Value { $this.ProcessStartInfo }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Refresh -Value { if (-not $this.Cleanup) { $this.Inner.Refresh() } }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Poll -Value { Update-AiSopHiddenProcess $this }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name WaitForExit -Value {
        while (-not (Update-AiSopHiddenProcess $this)) { [Threading.Thread]::Sleep(50) }
    }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Dispose -Value {
        if ($this.Disposed) { return }
        try { if (-not $this.Completed) { Stop-AiSopHiddenProcess $this } }
        finally { $this.Disposed=$true }
    }
    if ($PassThru) { return $handle }
    try { $handle.WaitForExit(); return $handle.ExitCode } finally { $handle.Dispose() }
}

# Bounded observation; each caller decides whether unknown metadata is fatal.
# Never use a failed probe to satisfy a gate.
function Invoke-AiSopMetadataProbe {
    param([string]$FilePath, [string[]]$ArgumentList, [ValidateRange(1,60)][int]$TimeoutSeconds=10)
    $outFile=[IO.Path]::GetTempFileName(); $errFile=[IO.Path]::GetTempFileName(); $child=$null
    try {
        $child=Start-AiSopHiddenProcess -FilePath $FilePath -ArgumentList $ArgumentList -RedirectStandardOutput $outFile -RedirectStandardError $errFile -TimeoutSeconds $TimeoutSeconds -CloseStandardInput -Environment @{LC_ALL='C';GIT_TERMINAL_PROMPT='0'} -PassThru
        $child.WaitForExit()
        $output=''; $errorOutput=''
        if ($child.Cleanup.confirmed) { $output=[IO.File]::ReadAllText($outFile).Trim(); $errorOutput=[IO.File]::ReadAllText($errFile).Trim() }
        return @{ exitCode=$child.ExitCode; output=$output; stderr=$errorOutput; diagnostic=$child.Diagnostic }
    } catch { return @{exitCode=-1; output=''; stderr=''; diagnostic="METADATA_PROBE_FAILED: $($_.Exception.Message)"} }
    finally {
        if ($child) { $child.Dispose() }
        Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
    }
}
