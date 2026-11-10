#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspacePath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Z][A-Za-z0-9]+$')][string]$Feature,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$')][string]$Id,
    [Parameter(Mandatory)][ValidateSet('Create','Update','Close','Dismiss','Reopen')][string]$Operation,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
    [string]$DraftPath,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSha256,
    [ValidatePattern('^[A-Z][A-Za-z0-9]+$')][string]$RepairFeature,
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,79}$')][string]$RepairTaskId,
    [string[]]$RegressionRunIds=@(),
    [string[]]$Commits=@()
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'task-context.ps1')
. (Join-Path $PSScriptRoot 'review-paths.ps1')
$WorkspacePath=Resolve-PhysicalPathIdentity $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkspacePath)
$relative=".ai-workspace/specs/features/$Feature/findings/$Id.json"
$path=Resolve-AiSopReviewChild $WorkspacePath $relative
# 恢复先于读取；后续事务在同一记录锁下比较完整旧内容，拒绝丢失更新。
Invoke-AiSopWorkflowTransactionRecovery -WorkspacePath $WorkspacePath|Out-Null
$exists=[IO.File]::Exists($path)
$before=$null
if($Operation -eq 'Create'){
    if($exists){throw 'FINDING_ALREADY_EXISTS'}
    $record=@{schemaVersion='1.0';id=$Id;status='OPEN';history=@()}
}else{
    if(-not $exists){throw 'FINDING_NOT_FOUND'}
    $bytes=[IO.File]::ReadAllBytes($path)
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if(-not $ExpectedSha256 -or $hash -cne $ExpectedSha256.ToLowerInvariant()){throw 'FINDING_EXPECTED_HASH_MISMATCH'}
    $before=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)
    Assert-AiSopWorkflowJsonSchema -Json $before -SchemaId FINDING
    $record=ConvertFrom-AiSopWorkflowJson $before -AsHashtable
    if($record.id -cne $Id){throw 'FINDING_ID_MISMATCH'}
    if($Operation -ne 'Reopen' -and $record.status -in @('CLOSED','DISMISSED')){throw 'FINDING_REOPEN_REQUIRED'}
}
if($DraftPath){
    $draftRaw=[IO.File]::ReadAllText((Resolve-AiSopReviewChild $WorkspacePath $DraftPath))
    $draft=ConvertFrom-Json -InputObject $draftRaw -AsHashtable -NoEnumerate
    if($draft -isnot [Collections.IDictionary]){throw 'FINDING_DRAFT_OBJECT_REQUIRED'}
    foreach($key in $draft.Keys){
        if($key -cnotin @('severity','title','scope','trigger','impact','source','closure','status')){throw "FINDING_DRAFT_FIELD_UNSUPPORTED:$key"}
        if($key -ceq 'status' -and ($Operation -ne 'Update' -or $draft.status -cnotin @('OPEN','IN_REVIEW'))){throw 'FINDING_EXPLICIT_OPERATION_REQUIRED'}
        if($key -ceq 'closure' -and $Operation -notin @('Close','Dismiss')){throw 'FINDING_EXPLICIT_OPERATION_REQUIRED'}
        $record[$key]=$draft[$key]
    }
}
$record.status=switch($Operation){Create {'OPEN'} Close {'CLOSED'} Dismiss {'DISMISSED'} Reopen {'OPEN'} default {$record.status}}
if($Operation -in @('Close','Dismiss') -and (-not $DraftPath -or -not $draft.Contains('closure'))){throw 'FINDING_EXPLICIT_CLOSURE_REQUIRED'}
if($Operation -eq 'Close' -or $RepairTaskId -or $RepairFeature -or $RegressionRunIds.Count -or $Commits.Count){
    if(-not $RepairFeature -or -not $RepairTaskId -or -not $RegressionRunIds.Count -or -not $Commits.Count){throw 'FINDING_REPAIR_SELECTION_REQUIRED'}
    $taskPath=Resolve-AiSopReviewChild $WorkspacePath ".ai-workspace/specs/features/$RepairFeature/tasks/$RepairTaskId/task.json"
    $taskRaw=[IO.File]::ReadAllText($taskPath)
    Assert-AiSopWorkflowJsonSchema -Json $taskRaw -SchemaId TASK
    $task=ConvertFrom-AiSopWorkflowJson $taskRaw -AsHashtable
    if($task.feature -cne $RepairFeature -or $task.taskId -cne $RepairTaskId){throw 'FINDING_REPAIR_TASK_MISMATCH'}
    foreach($runId in $RegressionRunIds){
        $matches=@($task.verifications|Where-Object {$_.runId -ceq $runId})
        if($matches.Count -ne 1 -or $matches[0].kind -ne 'test' -or $matches[0].outcome -ne 'PASSED' -or $matches[0].exitCode -ne 0 -or $matches[0].inputsStable -ne $true){throw 'FINDING_REGRESSION_REFERENCE_INVALID'}
    }
    $record.repair=@{feature=$task.feature;taskId=$task.taskId;commits=@($Commits);regressionRunIds=@($RegressionRunIds)}
}
foreach($scope in $record.scope){[void](ConvertTo-AiSopReviewScope $scope)}
$record.history=@($record.history)+@(@{status=$record.status;reason=$Reason;at=[DateTimeOffset]::UtcNow.ToString('o')})
$json=ConvertTo-AiSopWorkflowCanonicalJson $record
Assert-AiSopWorkflowJsonSchema -Json $json -SchemaId FINDING
$target=@{path=$path;kind='FINDING';schemaId='FINDING';afterJson=$json;expectedBeforeExists=$exists;expectedBeforeJson=$before}
$transaction=Invoke-AiSopWorkflowTransaction -Operation WRITE_FINDING -Feature $Feature -OwnerPath $path -Targets @($target) -TransactionId ('finding-'+[guid]::NewGuid().ToString('N')) -WorkspacePath $WorkspacePath
# 返回本次写入的精确 UTF-8 摘要，不能在释放锁后采纳他人刚写入的版本。
@{path=$relative;id=$Id;status=$record.status;sha256=(Get-AiSopWorkflowSha256 $json);transactionId=$transaction.TransactionId;result=$transaction.Result;limits=@('Schema and selected task references validated; repair correctness, commit contents and review approval remain declared.','No task state, completion rule or authorization is changed.')}|ConvertTo-Json -Depth 8
