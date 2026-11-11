#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) hidden-process.ps1)
. (Join-Path $PSScriptRoot fixtures/boundary-cases.ps1)
foreach($case in Get-AiSopProcessContractCases){
    $pending=if($case.pending){[Threading.Tasks.TaskCompletionSource[object]]::new().Task}else{$null}
    $handle=[pscustomobject]@{ExitCode=$case.code;RawExitCode=0;Diagnostic=$case.diagnostic;Completed=$case.completed;Disposed=$case.disposed;Cleanup=@{confirmed=$case.confirmed;diagnostic='';pending=$pending}}
    $facts=Get-AiSopProcessFacts $handle
    if($facts.cleanupConfirmed -ne $case.expected -or $facts.exitCode -ne $case.code -or $facts.pendingIncomplete -ne $case.pending){throw "Contract failed: $($case.id)"}
    if($handle.Disposed -ne $case.disposed -or $handle.Completed -ne $case.completed){throw 'Observation mutated handle'}
    $json=$facts|ConvertTo-Json -Depth 5
    if(@($facts.Values|Where-Object {$_ -is [Threading.Tasks.Task]}).Count){throw 'Snapshot exposed live asynchronous resources'}
}
$handle=[pscustomobject]@{ExitCode=0;RawExitCode=0;Diagnostic='';Completed=$true;Disposed=$true;Cleanup=@{confirmed=$true;diagnostic='';pending=$null}}
if((Get-AiSopProcessFacts $handle -DisposeError 'injected disposal exception').cleanupConfirmed){throw 'Dispose exception erased'}
Write-Output 'PASS: seven shared lifecycle contracts, pending serialization, pure observation and disposal exception'


. (Join-Path (Split-Path $PSScriptRoot) test-execution-environment.ps1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('process-contract-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$start=(Get-Item Function:\Start-AiSopHiddenProcess).ScriptBlock
try{
    function Start-AiSopHiddenProcess {
        param($FilePath,$ArgumentList,$Environment,$TimeoutSeconds,$RedirectStandardOutput,$RedirectStandardError,$FailurePath,[switch]$CloseStandardInput,[switch]$PassThru)
        [IO.File]::WriteAllText($RedirectStandardOutput,'contract-version')
        $pending=if($case.pending){[Threading.Tasks.TaskCompletionSource[object]]::new().Task}else{$null}
        $h=[pscustomobject]@{Id=123;Inner=@{StartTime=[DateTime]::UtcNow};ExitCode=$case.code;RawExitCode=0;Diagnostic=$case.diagnostic;Completed=$case.completed;Disposed=$case.disposed;Cleanup=@{confirmed=$case.confirmed;diagnostic='';pending=$pending}}
        $h|Add-Member ScriptMethod WaitForExit {}
        $h|Add-Member ScriptMethod Dispose {}
        return $h
    }
    foreach($case in Get-AiSopProcessContractCases){
        $environment=Get-AiSopTestEnvironment -ReportDirectory $root -ReadVersions
        $probed=@($environment.tools|Where-Object probe)
        if(-not $probed.Count){throw 'No contract consumer executed'}
        foreach($record in $probed){
            if(($record.probe.cleanupStatus -eq 'CONFIRMED') -ne $case.expected){throw "Consumer cleanup contract failed: $($case.id)"}
            $observed=($case.expected -and $case.code -eq 0 -and -not $case.diagnostic)
            if(($record.versionStatus -eq 'OBSERVED') -ne $observed){throw "Consumer version policy failed: $($case.id)"}
        }
    }
}finally{Set-Item Function:\Start-AiSopHiddenProcess -Value $start;[IO.Directory]::Delete($root,$true)}
Write-Output 'PASS: shared declared contracts exercised through actual version consumer, independent of fact-reader expectations'
