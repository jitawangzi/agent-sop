#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path $PSScriptRoot
. (Join-Path $scripts task-context.ps1)
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
. (Join-Path $PSScriptRoot fixtures/boundary-cases.ps1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('pack-evidence-'+[guid]::NewGuid().ToString('N'))
$ws=Join-Path $root workspace;$taskDir=Join-Path $ws '.ai-workspace/specs/features/Example/tasks/change'
[IO.Directory]::CreateDirectory($taskDir)|Out-Null
$ok=$false;$failure=''
function Assert($ok,$message){if(-not $ok){throw $message}}
$gitWorker=Join-Path $root git-worker.ps1
@'
param([string]$Repository,[string]$Encoded)
$ErrorActionPreference='Stop'
foreach($key in @(Get-ChildItem Env:|Where-Object Name -like 'GIT_*')){Remove-Item -LiteralPath ('Env:'+$key.Name)}
$env:GIT_CONFIG_NOSYSTEM='1';$env:GIT_CONFIG_GLOBAL=if([OperatingSystem]::IsWindows()){'NUL'}else{'/dev/null'}
$env:GIT_TERMINAL_PROMPT='0'
$empty=Join-Path $PSScriptRoot empty-git-policy;[IO.Directory]::CreateDirectory($empty)|Out-Null
$arguments=@(ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded))))
$options=@('-c',('core.hooksPath='+$empty),'-c',('init.templateDir='+$empty),'-c','commit.gpgsign=false','-c','core.fsmonitor=false','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-C',$Repository)
if($arguments[0] -ne 'init'){
    $actual=& git @options rev-parse --show-toplevel
    $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if($LASTEXITCODE -ne 0 -or -not [IO.Path]::GetFullPath($actual).Equals($Repository,$comparison)){throw 'FIXTURE_REPOSITORY_MISMATCH'}
}
& git @options @arguments
exit $LASTEXITCODE
'@|Set-Content $gitWorker
function FixtureGit([string]$Repository,[string[]]$Arguments){
    $full=[IO.Path]::GetFullPath($Repository);$physical=[IO.Path]::GetPathRoot($full)
    foreach($segment in [IO.Path]::GetRelativePath($physical,$full).Split([IO.Path]::DirectorySeparatorChar,[StringSplitOptions]::RemoveEmptyEntries)){$physical=Resolve-PhysicalPathIdentity (Join-Path $physical $segment)}
    $Repository=$physical
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Arguments -Compress)))
    $out=Join-Path $root ([guid]::NewGuid().ToString('N')+'.git.out');$err=$out+'.err'
    $child=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$gitWorker,$Repository,$encoded) -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutSeconds 30 -PassThru
    try{$child.WaitForExit();$child.Dispose();if($child.ExitCode -ne 0 -or $child.Diagnostic){throw ('FIXTURE_GIT_FAILED: '+[IO.File]::ReadAllText($err))}}finally{$child.Dispose()}
}
function ForeignBytes([string]$Path){return (@(Get-ChildItem -LiteralPath $Path -Force -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join ';')}
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
    $attachmentList=Join-Path $ws attachments.json
    [IO.File]::WriteAllText((Join-Path $ws extra.log),'attachment')
    '["extra.log","./extra.log","missing.log","log-0.log","log-1.log"]'|Set-Content $attachmentList
    $attachedOutput=Join-Path $root attached
    & (Join-Path $scripts pack-review-evidence.ps1) -WorkspacePath $ws -Feature Example -TaskId change -OutputPath $attachedOutput -AttachmentsManifest attachments.json|Out-Null
    $attached=Get-Content (Join-Path $attachedOutput index.json) -Raw|ConvertFrom-Json
    Assert (@($attached.items|Where-Object source -eq extra.log).Count -eq 1) 'Duplicate attachment not deduplicated'
    $extra=$attached.items|Where-Object source -eq extra.log
    Assert ($extra.status -eq 'COPIED' -and $extra.observationMatch -eq 'MATCH' -and (Get-Content (Join-Path $attachedOutput $extra.path) -Raw) -eq 'attachment') 'Explicit attachment missing or changed'
    Assert (($attached.items|Where-Object source -eq missing.log).status -eq 'UNAVAILABLE') 'Missing attachment hidden'
    Assert (($attached.items|Where-Object source -eq attachments.json).status -eq 'COPIED') 'Attachment declaration omitted'
    $invalidPaths=@(Get-AiSopInvalidPathDeclarations $root)
    foreach($invalid in (@('null','{}','"extra.log"','[null]')+@($invalidPaths.json))){
        $invalid|Set-Content $attachmentList
        $badOutput=Join-Path $root ([guid]::NewGuid().ToString('N'));$rejected=$false
        try{& (Join-Path $scripts pack-review-evidence.ps1) -WorkspacePath $ws -Feature Example -TaskId change -OutputPath $badOutput -AttachmentsManifest attachments.json|Out-Null}catch{$rejected=$true}
        Assert ($rejected -and -not(Test-Path $badOutput)) 'Invalid attachment declaration published output'
    }
    foreach($valid in @('[]','["extra.log"]')){
        $valid|Set-Content $attachmentList
        & (Join-Path $scripts pack-review-evidence.ps1) -WorkspacePath $ws -Feature Example -TaskId change -OutputPath (Join-Path $root ([guid]::NewGuid().ToString('N'))) -AttachmentsManifest attachments.json|Out-Null
    }
    # 直接提取文档中的输出位置，防止示例悄悄回到会污染验证输入的目录。
    $guide=Get-Content (Join-Path (Split-Path $scripts) docs/BASELINE_AND_DELIVERY.md) -Raw
    Assert ($guide -match '(?m)^& .*pack-review-evidence\.ps1 .* -OutputPath (\S+)') 'Documented package command missing'
    $documentedOutput=Join-Path $ws $Matches[1]
    $beforePackage=(Get-AiSopInputSnapshot $ws).digest
    $bridge=(& (Join-Path $scripts pack-review-evidence.ps1) -WorkspacePath $ws -Feature Example -TaskId change -OutputPath $documentedOutput)|ConvertFrom-Json -AsHashtable
    Assert ((Get-AiSopInputSnapshot $ws).digest -ceq $beforePackage) 'Documented packaging invalidated verification inputs'
    Assert ($bridge.deliveryCheck.available -and $bridge.deliveryCheck.pathBase -eq 'manifest-directory') 'Package did not expose usable byte-check arguments'
    $foreign=Join-Path $root foreign;[IO.Directory]::CreateDirectory($foreign)|Out-Null
    FixtureGit $foreign @('init','-q')
    'original'|Set-Content (Join-Path $foreign original.txt)
    FixtureGit $foreign @('add','.')
    FixtureGit $foreign @('commit','-qm','original')
    'uncommitted'|Set-Content (Join-Path $foreign staged.txt)
    FixtureGit $foreign @('add','staged.txt')
    $foreignBefore=ForeignBytes $foreign
    $poison=@{GIT_DIR=(Join-Path $foreign .git);GIT_WORK_TREE=$foreign;GIT_INDEX_FILE=(Join-Path $foreign '.git/index');GIT_CONFIG_COUNT='1';GIT_CONFIG_KEY_0='core.hooksPath';GIT_CONFIG_VALUE_0=(Join-Path $foreign hooks);GIT_TEMPLATE_DIR=$foreign}
    $savedGit=@{}
    try{
        foreach($key in $poison.Keys){$savedGit[$key]=@{present=(Test-Path ("Env:"+$key));value=[Environment]::GetEnvironmentVariable($key)};[Environment]::SetEnvironmentVariable($key,$poison[$key])}
        FixtureGit $ws @('init','-q')
        '* -text'|Set-Content (Join-Path $ws .gitattributes)
        $alias=Join-Path $root 'linked workspace'
        if([OperatingSystem]::IsWindows()){New-Item -ItemType Junction -Path $alias -Value $root|Out-Null}
        else{[IO.Directory]::CreateSymbolicLink($alias,$root)|Out-Null}
        try{FixtureGit (Join-Path $alias workspace) @('add','.')}
        finally{Remove-Item -LiteralPath $alias -Force}
        FixtureGit $ws @('commit','-qm','fixture')
        $checkArgs=$bridge.deliveryCheck.arguments
        $checked=(& (Join-Path $scripts export-review.ps1) @checkArgs)|ConvertFrom-Json
        Assert ($checked.delivery.coverage -eq 'COMPLETE' -and @($checked.delivery.items).Count -gt 0 -and @($checked.delivery.items|Where-Object status -ne COMMITTED).Count -eq 0) 'Returned arguments did not verify real committed bytes'
        Assert ((ForeignBytes $foreign) -ceq $foreignBefore) 'Fixture Git changed external HEAD/index/config/worktree'
        foreach($key in $poison.Keys){Assert ([Environment]::GetEnvironmentVariable($key) -ceq $poison[$key]) 'Child Git changed caller environment'}
    }finally{foreach($key in $savedGit.Keys){if($savedGit[$key].present){[Environment]::SetEnvironmentVariable($key,$savedGit[$key].value)}else{Remove-Item -LiteralPath ('Env:'+$key) -ErrorAction SilentlyContinue}}}
    Write-Output 'PASS: real package byte-check bridge under redirected Git environment; external repository and caller preserved'
    & (Join-Path $scripts pack-review-evidence.ps1) -WorkspacePath $ws -Feature Example -TaskId change -OutputPath (Join-Path $ws unsafe-root-package)|Out-Null
    Assert ((Get-AiSopInputSnapshot $ws).digest -cne $beforePackage) 'Negative control did not detect root package contamination'
    # 在隔离脚本中确定性注入发布竞争及观察后变更，不依赖调度碰运气。
    $source=[IO.File]::ReadAllText((Join-Path $scripts pack-review-evidence.ps1)).Replace('$PSScriptRoot',("'"+$scripts.Replace("'","''")+"'"))
    $copy=Join-Path $root injected.ps1
    '["./attachments.json","extra.log"]'|Set-Content $attachmentList
    $declarationHash=(Get-FileHash $attachmentList).Hash.ToLowerInvariant()
    $snapshotAnchor='foreach($source in $sources){'
    Assert ($source.Split($snapshotAnchor).Count -eq 3) 'Manifest mutation anchor changed'
    $mutation='[IO.File]::WriteAllText((Join-Path $WorkspacePath attachments.json),''["missing.log"]''); '
    [IO.File]::WriteAllText($copy,$source.Replace($snapshotAnchor,$mutation+$snapshotAnchor))
    $selfOutput=Join-Path $root self-reference
    & $copy -WorkspacePath $ws -Feature Example -TaskId change -OutputPath $selfOutput -AttachmentsManifest ./attachments.json|Out-Null
    $self=(Get-Content (Join-Path $selfOutput index.json) -Raw|ConvertFrom-Json).items
    $declaration=@($self|Where-Object source -eq attachments.json)
    Assert ($declaration.Count -eq 1 -and $declaration[0].sha256 -ceq $declarationHash -and 'extra.log' -in $self.source -and 'missing.log' -notin $self.source) 'Self-reference re-read changed declaration or duplicated alias'
    # Windows通过精确路径映射模拟大小写敏感文件系统，执行实际打包器两次观察。
    foreach($name in @('Case.log','case.log')){
        $task.verifications+=@{kind='test';batch=$name;command='fixture';exitCode=0;executedAt='2026-01-01T00:00:00Z';inputDigest=$task.startInputs.inputDigest;inputsRef=$ref;inputsStable=$true;caseIds=@();runId=([guid]::NewGuid().ToString('N'));outcome='PASSED';context=@{logPath=$name}}
    }
    $task|ConvertTo-Json -Depth 20|Set-Content (Join-Path $taskDir task.json)
    [IO.File]::WriteAllText((Join-Path $ws upper.txt),'upper');[IO.File]::WriteAllText((Join-Path $ws lower.txt),'lower')
    $mapping=@'
function Resolve-AiSopReviewChild([string]$Root,[string]$RelativePath){
    if($RelativePath -ceq 'Case.log'){return Join-Path $Root upper.txt}
    if($RelativePath -ceq 'case.log'){return Join-Path $Root lower.txt}
    return Resolve-AiSopWorkspaceChild $Root $RelativePath
}
'@
    $mapped=$source.Replace('$expected=', $mapping+"`n"+'$expected=')
    $mapped=$mapped.Replace('$review=(& (Join-Path', $mapping+"`n"+'$review=(& (Join-Path')
    # export-review的点加载可能覆盖路径函数，因此在复制前再次装入同一映射。
    $mapped=$mapped.Replace('[IO.Directory]::CreateDirectory($output)|Out-Null',$mapping+"`n"+'[IO.Directory]::CreateDirectory($output)|Out-Null')
    [IO.File]::WriteAllText($copy,$mapped)
    $caseOutput=Join-Path $root case-map
    & $copy -WorkspacePath $ws -Feature Example -TaskId change -OutputPath $caseOutput|Out-Null
    $cases=(Get-Content (Join-Path $caseOutput index.json) -Raw|ConvertFrom-Json).items|Where-Object {$_.source -cin @('Case.log','case.log')}
    Assert (@($cases).Count -eq 2 -and @($cases|Where-Object observationMatch -ne MATCH).Count -eq 0 -and @($cases.sha256|Sort-Object -Unique).Count -eq 2) 'Case-sensitive source observations collided'
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
