#requires -Version 7.0
param([string]$Legacy,[string]$Current,[ValidateSet('six','seven')][string]$Mode,[string]$ResultRoot)
$ErrorActionPreference='Stop'
[IO.Directory]::CreateDirectory($ResultRoot)|Out-Null
. (Join-Path $PSScriptRoot 'owned-process.ps1')
$owned=New-AiSopTestProcesses
$checks=[Collections.Generic.List[string]]::new()
$primary='';$cleanupErrors=[Collections.Generic.List[string]]::new()
function Assert($ok,[string]$message){if(-not $ok){throw $message}}
function Track($handle){ Register-AiSopTestProcess -Handle $handle -Owned $owned }
function Sleeper([string]$name){
    $handle=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep 120') -RedirectStandardOutput (Join-Path $ResultRoot "$name.out") -RedirectStandardError (Join-Path $ResultRoot "$name.err") -PassThru
    Track $handle
    return $handle
}
try{
    # Six is the exact 7dc0e9c script; seven also preloads the old public type
    # with its later optional argument. It is an ABI fixture, not a new engine.
    if($Mode -eq 'seven'){
        $text=[IO.File]::ReadAllText($Legacy)
        $anchor='IDisposable[] resources) {'
        Assert ($text.Split($anchor).Count -eq 2) 'Legacy ABI fixture anchor changed'
        $sevenPath=Join-Path $ResultRoot legacy-seven.ps1
        [IO.File]::WriteAllText($sevenPath,$text.Replace($anchor,'IDisposable[] resources, bool attached = false) {'))
        . $sevenPath
    }else{. $Legacy}
    $legacyType='AiSop.ProcessCleanup' -as [type]
    $legacyArity=if($Mode -eq 'six'){6}else{7}
    Assert ($legacyType.GetMethod('Begin').GetParameters().Count -eq $legacyArity) 'Expected legacy type was not loaded'
    $before=Sleeper before-upgrade
    . $Current
    . $Current
    Assert ([object]::ReferenceEquals($legacyType,('AiSop.ProcessCleanup' -as [type]))) 'Upgrade replaced the legacy type'
    $before.Dispose();$before.Dispose()
    Assert ($before.Cleanup.confirmed -and $before.Cleanup.exited -and $before.Disposed) 'Existing handle cleanup failed after upgrade'
    $checks.Add('existing-handle-dispose-after-repeated-load')
    $after=Sleeper after-upgrade
    $after.Dispose();$after.Dispose()
    Assert ($after.Cleanup.confirmed -and $after.Cleanup.exited -and $after.Disposed) 'New handle cleanup failed after upgrade'
    $checks.Add('new-handle-dispose')

    $normal=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Write-Output upgraded-output; Start-Sleep -Milliseconds 500; exit 7') -RedirectStandardOutput (Join-Path $ResultRoot normal.out) -PassThru
    Track $normal
    Assert ($normal.Inner.WaitForExit(5000)) 'Normal fixture did not exit'
    Track $normal # Deterministically cover exit before rescue registration.
    $normal.WaitForExit();$normal.Dispose()
    Assert ($normal.ExitCode -eq 7 -and $normal.Cleanup.confirmed -and [IO.File]::ReadAllText((Join-Path $ResultRoot normal.out)) -match 'upgraded-output') 'Normal nonzero exit or output changed after upgrade'
    $checks.Add('normal-exit-and-output')
    $timeout=Sleeper timeout
    $timeout.TimeoutSeconds=1
    $timeout.WaitForExit();$timeout.Dispose()
    Assert ($timeout.ExitCode -eq 124 -and $timeout.Cleanup.confirmed -and $timeout.Cleanup.exited) 'Timeout cleanup failed after upgrade'
    $checks.Add('timeout')

    $attachedOwner=Sleeper attached
    $attached=[Diagnostics.Process]::GetProcessById($attachedOwner.Id)
    [void]$attached.Handle
    $result=Invoke-AiSopProcessCleanup -Process $attached -Attached -Terminate $true
    Assert ($result.confirmed -and $result.exited) 'Attached cleanup used incompatible legacy type'
    $attachedOwner.WaitForExit();$attachedOwner.Dispose()
    Assert $attachedOwner.Cleanup.confirmed 'Attached owner output cleanup failed'
    $checks.Add('attached-handle')

    $failedStart=''
    try{Start-AiSopHiddenProcess -FilePath (Join-Path $ResultRoot absent-executable) -RedirectStandardOutput (Join-Path $ResultRoot absent.out)|Out-Null}catch{$failedStart=$_.Exception.Message}
    Assert ($failedStart -and $failedStart -notmatch 'Begin.*7|overload') 'Start failure was masked by cleanup ABI failure'
    $exclusive=[IO.File]::Open((Join-Path $ResultRoot absent.out),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$exclusive.Dispose()
    $checks.Add('failed-start-releases-output')

    $retry=Sleeper retry
    $realCleanup=(Get-Command Invoke-AiSopProcessCleanup).ScriptBlock
    try{
        function Invoke-AiSopProcessCleanup {throw 'INJECTED_PRE_CLEANUP_FAILURE'}
        $first='';try{$retry.Dispose()}catch{$first=$_.Exception.Message}
        Assert ($first -match 'INJECTED_PRE_CLEANUP_FAILURE' -and -not $retry.Disposed -and -not $retry.Inner.HasExited) 'Failed cleanup invocation poisoned retry state'
    }finally{Set-Item Function:\Invoke-AiSopProcessCleanup -Value $realCleanup}
    $retry.Dispose();$retry.Dispose()
    Assert ($retry.Disposed -and $retry.Cleanup.confirmed -and $retry.Cleanup.exited) 'Retry did not clean owned child'
    $checks.Add('pre-cleanup-failure-retry')
}catch{$primary=$_.ToString()+[Environment]::NewLine+$_.ScriptStackTrace;throw}
finally{
    # Separate real handles ensure a broken helper cannot leak probe children.
    $rescue=Close-AiSopTestProcesses -Owned $owned
    foreach($diagnostic in $rescue.diagnostics){$cleanupErrors.Add($diagnostic)}
    try{@{mode=$Mode;checks=@($checks.ToArray());failure=$primary;rescueConfirmed=($cleanupErrors.Count -eq 0);cleanupErrors=@($cleanupErrors.ToArray())}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $ResultRoot result.json)}
    catch{$cleanupErrors.Add('UPGRADE_REPORT_UNAVAILABLE: '+$_.ToString())}
    if($cleanupErrors.Count){Write-Warning ($cleanupErrors -join '; ');if(-not $primary){throw 'UPGRADE_FIXTURE_CLEANUP_FAILED'}}
}
Write-Output "PASS: same-process $Mode-argument legacy upgrade; seven lifecycle checks; repeated loading and cleanup"
