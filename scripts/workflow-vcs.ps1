#requires -Version 7.0
. (Join-Path $PSScriptRoot 'hidden-process.ps1')

# One context per workflow-state invocation. Time spent outside VCS is not charged.
function New-AiSopWorkflowVcsContext {
    param([ValidateRange(1,600)][int]$TimeoutSeconds=60, [ValidateRange(1,1800)][int]$BudgetSeconds=180)
    return @{timeoutSeconds=$TimeoutSeconds; budgetSeconds=$BudgetSeconds; elapsedMs=0.0; blocked=@{}}
}

function Invoke-AiSopWorkflowVcs {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][ValidateSet('git','svn')][string]$Tool,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowNonZero
    )
    if ($Context.blocked.ContainsKey($Tool)) {
        throw "VCS_PROBE_UNAVAILABLE: $Tool circuit open for this operation; $($Context.blocked[$Tool])"
    }
    $remaining=[math]::Floor($Context.budgetSeconds - $Context.elapsedMs/1000)
    if ($remaining -lt 1) { throw 'VCS_PROBE_UNAVAILABLE: total VCS time budget exhausted for this operation' }
    $timeout=[int][math]::Min($Context.timeoutSeconds,$remaining)
    # Tiny local identity queries have a tighter limit than diff/status scans.
    if (-not @($Arguments | Where-Object { $_ -in @('diff','status','ls-files') }).Count) { $timeout=[math]::Min($timeout,10) }
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        $executable=(Get-Command $Tool -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $result=Invoke-AiSopMetadataProbe -FilePath $executable -ArgumentList $Arguments -TimeoutSeconds $timeout -PreserveWhitespace
    } catch {
        $Context.blocked[$Tool]=$_.Exception.Message
        throw "VCS_PROBE_UNAVAILABLE: $Tool could not run; $($_.Exception.Message)"
    } finally { $Context.elapsedMs += $timer.Elapsed.TotalMilliseconds }
    if ($result.diagnostic) {
        $Context.blocked[$Tool]=$result.diagnostic
        throw "VCS_PROBE_UNAVAILABLE: $Tool ($($Arguments -join ' ')); $($result.diagnostic)"
    }
    if ($result.exitCode -ne 0 -and -not $AllowNonZero) {
        $detail=[string]$result.stderr
        if ($detail.Length -gt 1000) { $detail=$detail.Substring(0,1000) }
        throw "VCS_COMMAND_FAILED: $Tool ($($Arguments -join ' ')) exit=$($result.exitCode); $detail"
    }
    # Match native PowerShell line enumeration, preserving leading status/diff
    # whitespace and interior blank lines; never parse stderr as source changes.
    $lines=[Collections.Generic.List[string]]::new()
    $reader=[IO.StringReader]::new([string]$result.output)
    try { while ($null -ne ($line=$reader.ReadLine())) { $lines.Add($line) } } finally { $reader.Dispose() }
    return @{exitCode=$result.exitCode; output=$result.output; lines=$lines.ToArray(); stderr=$result.stderr}
}
