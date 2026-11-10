#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts hidden-process.ps1)
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-cleanup-upgrade-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$worker=$null;$success=$false;$failure=''
try{
    $legacy=Join-Path $PSScriptRoot fixtures/hidden-process-legacy.ps1
    if((Get-FileHash -LiteralPath $legacy).Hash -ne '5C716F7E8B437ACDAD5BA001FF2E08AF295E6F53F2B32CED4D262E31D9CF5D79'){throw 'Frozen legacy fixture changed'}
    foreach($mode in @('six','seven')){
        $out=Join-Path $root "$mode.stdout.log";$err=Join-Path $root "$mode.stderr.log"
        $worker=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',(Join-Path $PSScriptRoot fixtures/hidden-process-upgrade-worker.ps1),'-Legacy',$legacy,'-Current',(Join-Path $scripts hidden-process.ps1),'-Mode',$mode,'-ResultRoot',(Join-Path $root $mode)) -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutSeconds 90 -PassThru
        $worker.WaitForExit()
        if($worker.ExitCode -ne 0 -or -not $worker.Cleanup.confirmed){throw "Upgrade worker $mode failed; exit=$($worker.ExitCode); stderr=$([IO.File]::ReadAllText($err))"}
        $report=Get-Content (Join-Path $root "$mode/result.json") -Raw|ConvertFrom-Json
        if(-not $report.rescueConfirmed -or $report.failure -or $report.checks.Count -ne 7){throw "Incomplete upgrade evidence: $mode"}
        $worker.Dispose();$worker=$null
        Write-Output "PASS: $mode-argument legacy type, seven lifecycle checks, all owned processes exited"
    }
    # Report failure must never replace an earlier fault, or create a PASS.
    $workerSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot fixtures/hidden-process-upgrade-worker.ps1))
    foreach($reportMode in @('primary','report-only')){
        $anchor=if($reportMode -eq 'primary'){'$before.Dispose();$before.Dispose()'}else{'$checks.Add(''pre-cleanup-failure-retry'')'}
        if($workerSource.Split($anchor).Count -ne 2){throw 'Report-fault injection anchor changed'}
        $fault='[IO.Directory]::CreateDirectory((Join-Path $ResultRoot result.json))|Out-Null; '
        if($reportMode -eq 'primary'){$fault+='@{id=$before.Id;ticks=$before.Inner.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json|Set-Content (Join-Path $ResultRoot rescue-id.json); throw ''INJECTED_PRIMARY_BEFORE_DISPOSE''; '}
        $copy=Join-Path $root "$reportMode.worker.ps1"
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot fixtures/owned-process.ps1) -Destination (Join-Path $root owned-process.ps1) -Force
        [IO.File]::WriteAllText($copy,$workerSource.Replace($anchor,$fault+$anchor))
        $out=Join-Path $root "$reportMode.stdout.log";$err=Join-Path $root "$reportMode.stderr.log"
        $worker=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$copy,'-Legacy',$legacy,'-Current',(Join-Path $scripts hidden-process.ps1),'-Mode','six','-ResultRoot',(Join-Path $root $reportMode)) -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutSeconds 90 -PassThru
        $worker.WaitForExit()
        if($worker.ExitCode -eq 0 -or $worker.FailureCode -ne 0 -or -not $worker.Cleanup.confirmed){throw 'Report-fault fixture passed or did not finish cleanup'}
        $errors=[IO.File]::ReadAllText($err);$output=[IO.File]::ReadAllText($out)
        $expected=if($reportMode -eq 'primary'){'INJECTED_PRIMARY_BEFORE_DISPOSE'}else{'UPGRADE_FIXTURE_CLEANUP_FAILED'}
        if($errors -notmatch $expected -or $output -notmatch 'UPGRADE_REPORT_UNAVAILABLE'){throw 'Primary/report fault classification lost'}
        if($reportMode -eq 'primary'){
            $identity=Get-Content (Join-Path $root "$reportMode/rescue-id.json") -Raw|ConvertFrom-Json
            $remaining=Get-Process -Id $identity.id -ErrorAction SilentlyContinue
            if($remaining){try{if(-not $remaining.HasExited -and $remaining.StartTime.ToUniversalTime().Ticks -eq $identity.ticks){throw 'Report failure leaked fixture child'}}finally{$remaining.Dispose()}}
        }
        $worker.Dispose();$worker=$null
        Write-Output "PASS: $reportMode report-write failure remains a failure, preserves primary cause and cleans owned child"
    }
    $success=$true
}catch{$failure=$_.ToString();throw}
finally{
    Complete-AiSopTestFixture -Root $root -Prefix sop-cleanup-upgrade- -Succeeded $success -Failure $failure -Cleanup @({if($worker){$worker.Dispose();if(-not $worker.Cleanup.confirmed){throw 'UPGRADE_WORKER_CLEANUP_UNCONFIRMED'}}})
}
