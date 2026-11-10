#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot fixtures/owned-process.ps1)
. (Join-Path (Split-Path $PSScriptRoot) hidden-process.ps1)
function Assert($ok,$message){if(-not $ok){throw $message}}
$owned=New-AiSopTestProcesses
$child=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep 120') -PassThru
try{
    Register-AiSopTestProcess $child $owned
    Register-AiSopTestProcess $child $owned
    Assert ($owned.entries.Count -eq 1) 'Duplicate registration'
    $result=Close-AiSopTestProcesses $owned
    Assert ($result.confirmed -and $owned.entries.Count -eq 0) 'Live child rescue failed'
    Assert (Close-AiSopTestProcesses $owned).confirmed 'Repeated cleanup failed'
}finally{$child.Dispose()}
$log=Join-Path ([IO.Path]::GetTempPath()) ('owned-output-'+[guid]::NewGuid().ToString('N'))
$child=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Write-Output done') -RedirectStandardOutput $log -PassThru
try{
    Assert ($child.Inner.WaitForExit(10000)) 'Fast child did not exit'
    $owned=New-AiSopTestProcesses;Register-AiSopTestProcess $child $owned
    Assert (Close-AiSopTestProcesses $owned).confirmed 'Fast exit output cleanup failed'
    $stream=[IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$stream.Dispose()
    Assert ($child.Disposed -and (Get-Content $log -Raw) -match 'done') 'Fast exit output was lost'
}finally{$child.Dispose()}
# 使用替身验证连续失败；当前 PID 只供身份比较，不允许对真实当前进程 Kill。
$fake=[pscustomobject]@{HasExited=$false;StartTime=[datetime]::MinValue;Denied=$true}
$fake|Add-Member ScriptMethod Kill {param($tree) if($this.Denied){throw 'INJECTED_RESCUE_DENIED'};$this.HasExited=$true}
$fake|Add-Member ScriptMethod WaitForExit {param($timeout) return $this.HasExited}
$fake|Add-Member ScriptMethod Dispose {}
$handle=[pscustomobject]@{Inner=$fake;Id=$PID;Cleanup=@{confirmed=$false}}
$handle|Add-Member ScriptMethod Dispose {$this.Cleanup.confirmed=$true}
$handle|Add-Member ScriptMethod WaitForExit {}
$owned=New-AiSopTestProcesses
$failure='';try{Register-AiSopTestProcess $handle $owned}catch{$failure=$_.Exception.Message}
Assert ($failure -match 'TEST_PROCESS_IDENTITY_MISMATCH' -and $owned.entries.Count -eq 1) 'Registration failure lost original process'
$first=Close-AiSopTestProcesses $owned
Assert (-not $first.confirmed -and $owned.entries.Count -eq 1) 'Failed rescue incorrectly confirmed'
$fake.Denied=$false
Assert (Close-AiSopTestProcesses $owned).confirmed 'Rescue retry failed'
Assert (Close-AiSopTestProcesses $owned).confirmed 'Repeated successful rescue failed'
Write-Output 'PASS: real child rescue, duplicate registration, registration failure, failed rescue and retry'

# 真实后代夹具在主断言和补救再次失败时，仍尝试其他释放并保留两类失败。
$faultRoot=Join-Path ([IO.Path]::GetTempPath()) ('owned-drain-fault-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($faultRoot)|Out-Null
$workerSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot owned-process-drain.tests.ps1))
$workerSource=$workerSource.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))
Assert ($workerSource.Split('$success=$true').Count -eq 2 -and $workerSource.Split('$rescue.Dispose()').Count -eq 2) 'Fault fixture anchors changed'
$workerSource=$workerSource.Replace('$success=$true',"throw 'INJECTED_PRIMARY';"+'$success=$true').Replace('$rescue.Dispose()',"`$rescue.Dispose();throw 'INJECTED_RESCUE_FAILURE'")
$copy=Join-Path $faultRoot worker.ps1;[IO.File]::WriteAllText($copy,$workerSource)
$stdout=Join-Path $faultRoot out.log;$stderr=Join-Path $faultRoot err.log
$probe=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$copy) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -TimeoutSeconds 60 -PassThru
try{
    $probe.WaitForExit()
    Assert ($probe.ExitCode -ne 0 -and $probe.Cleanup.confirmed) 'Fault probe did not exit with failure'
    $out=[IO.File]::ReadAllText($stdout);$err=[IO.File]::ReadAllText($stderr)
    Assert ($err -match 'INJECTED_PRIMARY' -and $out -match 'RETAINED_FIXTURE:([^\r\n]+)') 'Primary failure or retained path lost'
    $retained=$Matches[1].Trim()
    $report=Get-Content (Join-Path $retained failure.json) -Raw|ConvertFrom-Json
    Assert (-not $report.cleanupConfirmed -and $report.failure -match 'INJECTED_PRIMARY' -and ($report.diagnostics -join ' ') -match 'INJECTED_RESCUE_FAILURE' -and (Test-Path (Join-Path $retained handles-cleanup-attempted.txt))) 'Combined failure was hidden or later cleanup skipped'
}finally{$probe.Dispose()}
Write-Output 'PASS: primary failure plus rescue failure retains both and continues output-handle cleanup'
