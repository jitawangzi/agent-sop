#requires -Version 7.0
param([string]$OwnedHelper=(Join-Path $PSScriptRoot fixtures/owned-process.ps1))
$ErrorActionPreference='Stop'
. $OwnedHelper
. (Join-Path (Split-Path $PSScriptRoot) hidden-process.ps1)
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
function Assert($ok,$message){if(-not $ok){throw $message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('owned-drain-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$success=$false;$primary=''
$allHandles=[Collections.Generic.List[object]]::new();$allRescues=[Collections.Generic.List[object]]::new();$allOwned=[Collections.Generic.List[object]]::new()
try{
    $worker=Join-Path $root worker.ps1
    @'
param($Identity,$Release)
$info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$info.UseShellExecute=$false;$info.CreateNoWindow=$true
foreach($arg in @('-NoProfile','-Command','Write-Output child; Start-Sleep 120')){[void]$info.ArgumentList.Add($arg)}
$child=[Diagnostics.Process]::Start($info)
@{id=$child.Id;ticks=$child.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json|Set-Content ($Identity+'.tmp')
[IO.File]::Move(($Identity+'.tmp'),$Identity)
while(-not (Test-Path $Release)){Start-Sleep -Milliseconds 20}
exit 0
'@|Set-Content $worker
    foreach($prePoll in @($true,$false)){
        $identity=Join-Path $root "$prePoll.identity";$release=Join-Path $root "$prePoll.release"
        $handle=$null;$rescue=$null;$owned=New-AiSopTestProcesses;$allOwned.Add($owned)
        try{
            $handle=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$worker,$identity,$release) -RedirectStandardOutput (Join-Path $root "$prePoll.log") -DrainTimeoutSeconds 1 -TimeoutSeconds 30 -PassThru
            $allHandles.Add($handle)
            Register-AiSopTestProcess $handle $owned
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while(-not(Test-Path $identity)){if([DateTime]::UtcNow -gt $deadline){throw 'IDENTITY_TIMEOUT'};Start-Sleep -Milliseconds 20}
            $id=Get-Content $identity -Raw|ConvertFrom-Json
            $candidate=[Diagnostics.Process]::GetProcessById($id.id)
            try{[void]$candidate.Handle;Assert ($candidate.StartTime.ToUniversalTime().Ticks -eq $id.ticks) 'Grandchild identity mismatch';$rescue=$candidate;$allRescues.Add($rescue);$candidate=$null}
            finally{if($candidate){$candidate.Dispose()}}
            [IO.File]::WriteAllText($release,'release')
            Assert ($handle.Inner.WaitForExit(10000)) 'Launcher did not exit'
            if($prePoll){$handle.WaitForExit()}
            $result=Close-AiSopTestProcesses $owned
            Assert (-not $rescue.HasExited -and $handle.Cleanup.confirmed) 'Fixture did not reach live-grandchild/local-cleanup combination'
            Assert (-not $result.confirmed -and $owned.entries.Count -eq 1 -and ($result.diagnostics -join ' ') -match 'OUTPUT_DRAIN_TIMED_OUT') 'Live descendant incorrectly confirmed or registration discarded'
            $again=Close-AiSopTestProcesses $owned
            Assert (-not $again.confirmed -and ($again.diagnostics -join ' ') -match 'OUTPUT_DRAIN_TIMED_OUT') 'Repeated cleanup lost uncertainty'
        }finally{}
    }
    $success=$true
}catch{$primary=$_.ToString();throw}finally{
    Complete-AiSopTestFixture -Root $root -Prefix owned-drain- -Succeeded $success -Failure $primary -Cleanup @(
        {
            $errors=[Collections.Generic.List[string]]::new()
            foreach($rescue in $allRescues){
                try{if(-not $rescue.HasExited){$rescue.Kill($true);Assert ($rescue.WaitForExit(3000)) 'Independent rescue failed'}}catch{$errors.Add($_.ToString())}
                try{$rescue.Dispose()}catch{$errors.Add($_.ToString())}
            }
            if($errors.Count){throw ($errors -join '; ')}
        },
        {
            $errors=[Collections.Generic.List[string]]::new()
            foreach($handle in $allHandles){try{$handle.Dispose();if(-not $handle.Cleanup.confirmed){throw 'LOCAL_HANDLE_CLEANUP_UNCONFIRMED'}}catch{$errors.Add($_.ToString())}}
            [IO.File]::WriteAllText((Join-Path $root handles-cleanup-attempted.txt),'attempted')
            if($errors.Count){throw ($errors -join '; ')}
        },
        {
            $errors=[Collections.Generic.List[string]]::new()
            foreach($owned in $allOwned){foreach($entry in $owned.entries){try{$entry.process.Dispose()}catch{$errors.Add($_.ToString())}}}
            if($errors.Count){throw ($errors -join '; ')}
        }
    )
}
Write-Output 'PASS: live descendant with local cleanup confirmed remains unknown, before/after Poll and repeated cleanup; independently rescued'
