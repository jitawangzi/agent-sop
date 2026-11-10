#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'review-paths.ps1')
. (Join-Path $PSScriptRoot 'fixtures/boundary-cases.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('finding-writer-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
function Assert($ok,$message){if(-not $ok){throw $message}}
function JsonFile($path,$value){[void][IO.Directory]::CreateDirectory((Split-Path $path));[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 30))}
function Reject([scriptblock]$action,[string]$code){$caught='';try{& $action|Out-Null}catch{$caught=$_.Exception.Message};Assert ($caught -like "*$code*") "Expected $code; got $caught"}
$common=@{WorkspacePath=$root;Feature='Example';Id='CHECK-1';Reason='fixture';DraftPath='draft.json'}
$path=Join-Path $root '.ai-workspace/specs/features/Example/findings/CHECK-1.json'
$writer=Join-Path $scripts 'write-finding.ps1'
$success=$false
try{
    $draft=@{severity='P2';title='fixture finding';scope=@('src');trigger='failure';impact='loss';source=@{repository='fixture';revision='before';path='src/example'}}
    JsonFile (Join-Path $root draft.json) $draft
    $created=& $writer @common -Operation Create|ConvertFrom-Json
    Assert ($created.status -eq 'OPEN' -and $created.result -eq 'COMMITTED') 'Create failed'
    Reject {& $writer @common -Operation Create} 'FINDING_ALREADY_EXISTS'
    $original=(Get-FileHash $path).Hash
    foreach($case in @(Get-AiSopJsonBoundaryCases Object|Where-Object {-not $_.accepted})){
        [IO.File]::WriteAllText((Join-Path $root draft.json),$case.json)
        Reject {& $writer @common -Operation Update -ExpectedSha256 $original} 'FINDING_DRAFT_OBJECT_REQUIRED'
        Assert ((Get-FileHash $path).Hash -eq $original) 'Bad draft modified finding'
    }
    JsonFile (Join-Path $root draft.json) @{status='CLOSED'}
    Reject {& $writer @common -Operation Update -ExpectedSha256 $original} 'FINDING_EXPLICIT_OPERATION_REQUIRED'
    JsonFile (Join-Path $root draft.json) @{history=@()}
    Reject {& $writer @common -Operation Update -ExpectedSha256 $original} 'FINDING_DRAFT_FIELD_UNSUPPORTED'
    JsonFile (Join-Path $root draft.json) @{status='IN_REVIEW';title='updated'}
    $updated=& $writer @common -Operation Update -ExpectedSha256 $original|ConvertFrom-Json
    Reject {& $writer @common -Operation Update -ExpectedSha256 $original} 'FINDING_EXPECTED_HASH_MISMATCH'
    $record=Get-Content $path -Raw|ConvertFrom-Json
    Assert ($record.history.Count -eq 2 -and $record.history[0].status -eq 'OPEN') 'History overwritten'
    $taskPath=Join-Path $root '.ai-workspace/specs/features/Example/tasks/repair/task.json'
    $run=@{kind='test';batch='behavior';command='fixture';exitCode=0;executedAt='2026-01-01T00:00:00Z';inputDigest=('a'*64);inputsRef=('b'*64);inputsStable=$true;caseIds=@();runId=('1'*32);outcome='PASSED';context=@{}}
    $bad=$run.Clone();$bad.runId='2'*32;$bad.outcome='FAILED';$bad.exitCode=1
    $contradictory=$run.Clone();$contradictory.runId='3'*32;$contradictory.exitCode=1
    $task=@{schemaVersion='1.0';taskId='repair';feature='Example';ownerId='fixture';tier='T2';objective='fixture';status='DONE';nextAction='';notes='';createdAt='2026-01-01T00:00:00Z';updatedAt='2026-01-01T00:00:00Z';requiredCaseIds=@();verifications=@($run,$bad,$contradictory)}
    JsonFile $taskPath $task
    $taskHash=(Get-FileHash $taskPath).Hash
    JsonFile (Join-Path $root draft.json) @{closure=@{reason='reviewed repair';evidence='tasks/repair/validation.md';reviewers=@('fixture');limits='synthetic evidence'}}
    $repair=@{RepairFeature='Example';RepairTaskId='repair';Commits=@('a'*40)}
    Reject {& $writer @common -Operation Close -ExpectedSha256 $updated.sha256 @repair -RegressionRunIds @('missing')} 'FINDING_REGRESSION_REFERENCE_INVALID'
    Reject {& $writer @common -Operation Close -ExpectedSha256 $updated.sha256 @repair -RegressionRunIds @('2'*32)} 'FINDING_REGRESSION_REFERENCE_INVALID'
    Reject {& $writer @common -Operation Close -ExpectedSha256 $updated.sha256 @repair -RegressionRunIds @('3'*32)} 'FINDING_REGRESSION_REFERENCE_INVALID'
    Assert ((Get-FileHash $path).Hash.ToLowerInvariant() -eq $updated.sha256) 'Invalid close changed bytes'
    $closed=& $writer @common -Operation Close -ExpectedSha256 $updated.sha256 @repair -RegressionRunIds @('1'*32)|ConvertFrom-Json
    $record=Get-Content $path -Raw|ConvertFrom-Json
    Assert ($record.repair.feature -eq 'Example' -and $record.repair.regressionRunIds[0] -eq ('1'*32) -and $record.closure.reason -eq 'reviewed repair' -and $record.history.Count -eq 3) 'Closure structure incomplete'
    Assert (Test-Json -Json (Get-Content $path -Raw) -SchemaFile (Join-Path (Split-Path $scripts) 'schemas/finding.schema.json')) 'Writer emitted invalid schema'
    $export=& (Join-Path $scripts export-review.ps1) -WorkspacePath $root -Feature Example -TaskId repair -Scope src -RepositoryPaths @()|ConvertFrom-Json
    Assert ($export.findings.Count -eq 1 -and $export.findings[0].declaredStatus -eq 'CLOSED' -and $export.findingCoverage -eq 'DECLARED_PATH_SCOPE_ONLY') 'Actual export could not read closure'
    Assert ((Get-FileHash $taskPath).Hash -eq $taskHash) 'Writer modified task'
    foreach($operation in @('Update','Close','Dismiss')){Reject {& $writer @common -Operation $operation -ExpectedSha256 $closed.sha256} 'FINDING_REOPEN_REQUIRED'}
    $common.Remove('DraftPath')
    $reopened=& $writer @common -Operation Reopen -ExpectedSha256 $closed.sha256|ConvertFrom-Json
    Assert ((Get-Content $path -Raw|ConvertFrom-Json).history.Count -eq 4 -and $reopened.status -eq 'OPEN') 'Reopen lost history'
    # 已驳回同样必须先重开；两类终态的保护不依赖草稿内容。
    $dismissed=& $writer @common -DraftPath draft.json -Operation Dismiss -ExpectedSha256 $reopened.sha256|ConvertFrom-Json
    foreach($operation in @('Update','Close','Dismiss')){Reject {& $writer @common -Operation $operation -ExpectedSha256 $dismissed.sha256} 'FINDING_REOPEN_REQUIRED'}
    $reopened=& $writer @common -Operation Reopen -ExpectedSha256 $dismissed.sha256|ConvertFrom-Json
    # 在生产入口已释放锁、尚未返回响应的位置注入第二次真实事务写入。
    $responseLine=(@(Get-Content $writer)|Select-String '^@\{path=\$relative;').LineNumber
    $breakpoint=Set-PSBreakpoint -Script $writer -Line $responseLine -Action {
        $other=ConvertFrom-AiSopWorkflowJson $json -AsHashtable;$other.title='second writer after release'
        $otherTarget=@{path=$path;kind='FINDING';schemaId='FINDING';afterJson=$other;expectedBeforeExists=$true;expectedBeforeJson=$json}
        Invoke-AiSopWorkflowTransaction -Operation WRITE_FINDING -Feature Example -OwnerPath $path -Targets @($otherTarget) -TransactionId ('fixture-'+[guid]::NewGuid().ToString('N')) -WorkspacePath $WorkspacePath|Out-Null
    }
    try{$response=& $writer @common -Operation Update -ExpectedSha256 $reopened.sha256|ConvertFrom-Json}
    finally{Remove-PSBreakpoint -Breakpoint $breakpoint}
    Assert ((Get-Content $path -Raw|ConvertFrom-Json).title -eq 'second writer after release') 'Race injection did not run'
    Assert ($response.sha256 -ne (Get-FileHash $path).Hash.ToLowerInvariant()) 'Response adopted unseen concurrent version'
    Reject {& $writer @common -Operation Update -ExpectedSha256 $response.sha256} 'FINDING_EXPECTED_HASH_MISMATCH'
    # 事务锁内旧快照比较，模拟两个执行者读取相同版本后先后提交。
    $old=Get-Content $path -Raw
    $next=ConvertFrom-AiSopWorkflowJson $old -AsHashtable;$next.title='first writer'
    $target=@{path=$path;kind='FINDING';schemaId='FINDING';afterJson=$next;expectedBeforeExists=$true;expectedBeforeJson=$old}
    Invoke-AiSopWorkflowTransaction -Operation WRITE_FINDING -Feature Example -OwnerPath $path -Targets @($target) -TransactionId ('fixture-'+[guid]::NewGuid().ToString('N')) -WorkspacePath $root|Out-Null
    $next.title='stale writer'
    Reject {Invoke-AiSopWorkflowTransaction -Operation WRITE_FINDING -Feature Example -OwnerPath $path -Targets @($target) -TransactionId ('fixture-'+[guid]::NewGuid().ToString('N')) -WorkspacePath $root} 'WORKFLOW_TRANSACTION_PRECONDITION_FAILED'
    Assert ((Get-Content $path -Raw|ConvertFrom-Json).title -eq 'first writer') 'Lost concurrent update'
    # 在实际事务落盘边界注入异常；再次进入恢复器必须回滚/前滚且可重复。
    $pauseDefinition=${function:Invoke-AiSopWorkflowPausePoint}
    try{
        foreach($point in @('AFTER_PREPARED','AFTER_TARGET_1','AFTER_COMMITTED')){
            $old=Get-Content $path -Raw
            $next=ConvertFrom-AiSopWorkflowJson $old -AsHashtable;$next.title=$point
            $target=@{path=$path;kind='FINDING';schemaId='FINDING';afterJson=$next;expectedBeforeExists=$true;expectedBeforeJson=$old}
            $script:fixturePause=$point
            function Invoke-AiSopWorkflowPausePoint($Point){if($Point -eq $script:fixturePause){throw 'FIXTURE_INTERRUPTED'}}
            Reject {Invoke-AiSopWorkflowTransaction -Operation WRITE_FINDING -Feature Example -OwnerPath $path -Targets @($target) -TransactionId ('fixture-'+[guid]::NewGuid().ToString('N')) -WorkspacePath $root} 'FIXTURE_INTERRUPTED'
            ${function:Invoke-AiSopWorkflowPausePoint}=$pauseDefinition
            $recovery=@(Invoke-AiSopWorkflowTransactionRecovery -WorkspacePath $root)
            Assert ($recovery.Count -eq 1) 'Pending finding journal not recovered'
            $expected=if($point -eq 'AFTER_PREPARED'){(ConvertFrom-Json $old).title}else{$point}
            Assert ((Get-Content $path -Raw|ConvertFrom-Json).title -eq $expected) 'Wrong finding recovered'
            Assert (@(Invoke-AiSopWorkflowTransactionRecovery -WorkspacePath $root).Count -eq 0) 'Recovery not idempotent'
        }
    }finally{${function:Invoke-AiSopWorkflowPausePoint}=$pauseDefinition}
    $success=$true
    Write-Host 'PASS finding writer: explicit lifecycle, schema, references, export, history, stale updates and read-only task'
}finally{
    if($success){Remove-Item -LiteralPath $root -Recurse -Force}else{Write-Host "Retained fixture: $root"}
}
