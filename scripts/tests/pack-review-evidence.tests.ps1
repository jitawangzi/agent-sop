#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path $PSScriptRoot
. (Join-Path $scripts task-context.ps1)
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('pack-evidence-'+[guid]::NewGuid().ToString('N'))
$ws=Join-Path $root workspace;$taskDir=Join-Path $ws '.ai-workspace/specs/features/Example/tasks/change'
[IO.Directory]::CreateDirectory($taskDir)|Out-Null
$ok=$false;$failure=''
function Assert($ok,$message){if(-not $ok){throw $message}}
try{
    $ref=Save-AiSopInputManifest (Get-AiSopInputSnapshot $ws) $ws
    $task=@{schemaVersion='1.0';taskId='change';feature='Example';ownerId='fixture';tier='T2';objective='Packaging';status='DONE';nextAction='';notes='';createdAt='2026-01-01T00:00:00Z';updatedAt='2026-01-01T00:00:00Z';requiredCaseIds=@();verifications=@();startInputs=@{status='CAPTURED';taskId='change';feature='Example';createdAt='2026-01-01T00:00:00Z';transactionId=('claim-'+('1'*32));mode='FULL';inputsRef=$ref;inputDigest=(Get-AiSopInputSnapshot $ws).digest}}
    foreach($size in @(0,1)){
        $relative="log-$size.log";[IO.File]::WriteAllBytes((Join-Path $ws $relative),[byte[]]::new($size))
        $task.verifications+=@{kind='test';batch="log-$size";command='fixture';exitCode=0;executedAt='2026-01-01T00:00:00Z';inputDigest=$task.startInputs.inputDigest;inputsRef=$ref;inputsStable=$true;caseIds=@();runId=([string]($size+1)*32);outcome='PASSED';context=@{logPath=$relative}}
    }
    $task|ConvertTo-Json -Depth 20|Set-Content (Join-Path $taskDir task.json)
    $before=(Get-FileHash (Join-Path $taskDir task.json)).Hash
    $output=Join-Path $root package
    & (Join-Path $scripts pack-review-evidence.ps1) -WorkspacePath $ws -Feature Example -TaskId change -OutputPath $output|Out-Null
    $index=Get-Content (Join-Path $output index.json) -Raw|ConvertFrom-Json
    foreach($size in @(0,1)){
        $entry=@($index.items|Where-Object source -eq "log-$size.log")[0]
        Assert ($entry.status -eq 'COPIED' -and (Get-Item (Join-Path $output $entry.path)).Length -eq $size) 'Empty or single-byte log lost array identity'
    }
    Assert (@($index.items|Where-Object source -like '*/inputs/*').Count -eq 1) 'Original baseline omitted'
    Assert (@($index.items|Where-Object {$_.source -like '*/evidence.json' -and $_.status -eq 'UNAVAILABLE'}).Count -eq 1) 'Missing supplement hidden'
    $manifest=Get-Content (Join-Path $output manifest.json) -Raw|ConvertFrom-Json
    Assert ('index.json' -in $manifest.path) 'Index absent from delivery manifest'
    foreach($entry in $manifest){Assert ((Get-FileHash (Join-Path $output $entry.path)).Hash.ToLowerInvariant() -ceq $entry.sha256) 'Packaged bytes differ'}
    Assert ((Get-FileHash (Join-Path $taskDir task.json)).Hash -eq $before) 'Task changed by packaging'
    $rejected=$false;try{& (Join-Path $scripts pack-review-evidence.ps1) -WorkspacePath $ws -Feature Example -TaskId change -OutputPath $output|Out-Null}catch{$rejected=$_.Exception.Message -eq 'EVIDENCE_OUTPUT_EXISTS'}
    Assert $rejected 'Existing output overwritten'
    # 在隔离脚本中确定性注入发布竞争及观察后变更，不依赖调度碰运气。
    $source=[IO.File]::ReadAllText((Join-Path $scripts pack-review-evidence.ps1)).Replace('$PSScriptRoot',("'"+$scripts.Replace("'","''")+"'"))
    $copy=Join-Path $root injected.ps1
    $anchor='[IO.Directory]::Move($output,$destination)'
    Assert ($source.Split($anchor).Count -eq 2) 'Publish anchor changed'
    [IO.File]::WriteAllText($copy,$source.Replace($anchor,'[IO.Directory]::CreateDirectory($destination)|Out-Null; [IO.File]::WriteAllText((Join-Path $destination marker),''winner''); '+$anchor))
    $race=Join-Path $root race;$failed=$false
    try{& $copy -WorkspacePath $ws -Feature Example -TaskId change -OutputPath $race|Out-Null}catch{$failed=$true}
    Assert ($failed -and (Get-Content (Join-Path $race marker) -Raw) -eq 'winner' -and -not (Test-Path (Join-Path $race index.json))) 'Concurrent winner was overwritten'
    $anchor='[IO.Directory]::CreateDirectory($output)|Out-Null'
    Assert ($source.Split($anchor).Count -eq 2) 'Copy anchor changed'
    $injection='foreach($item in $sources){if($item -like ''*/inputs/*''){[IO.File]::WriteAllText((Resolve-AiSopReviewChild $WorkspacePath $item),''{}'')}}; '
    [IO.File]::WriteAllText($copy,$source.Replace($anchor,$injection+$anchor))
    $drift=Join-Path $root drift
    & $copy -WorkspacePath $ws -Feature Example -TaskId change -OutputPath $drift|Out-Null
    $changed=Get-Content (Join-Path $drift index.json) -Raw|ConvertFrom-Json
    Assert (@($changed.items|Where-Object {$_.source -like '*/inputs/*' -and $_.observationMatch -eq 'CHANGED'}).Count -eq 1) 'Copied manifest drift hidden'
    $ok=$true
}catch{$failure=$_.ToString();throw}finally{Complete-AiSopTestFixture -Root $root -Prefix pack-evidence- -Succeeded $ok -Failure $failure}
Write-Output 'PASS: original baseline, missing references, index manifest, immutable task and existing-output rejection'
