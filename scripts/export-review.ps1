#requires -Version 7.0
<# Read-only navigation derived from existing records; never completes tasks or approves code. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspacePath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')][string]$Feature,
    [Parameter(Mandatory)][string]$TaskId,
    [string[]]$Scope=@(),
    [string[]]$RepositoryPaths=@('.','.ai-workspace','.ai-workspace/specs'),
    [string]$DeliveryManifest='',
    [switch]$CheckCurrent
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'task-context.ps1')
. (Join-Path $PSScriptRoot 'review-paths.ps1')
. (Join-Path $PSScriptRoot 'review-delivery.ps1')
$WorkspacePath=Resolve-PhysicalPathIdentity $WorkspacePath
$spec=Resolve-AiSopReviewChild $WorkspacePath ".ai-workspace/specs/features/$Feature"
$null=Resolve-AiSopReviewChild $WorkspacePath ".ai-workspace/specs/features/$Feature/tasks/$TaskId/task.json"
$task=Read-AiSopTask $spec $TaskId
$context=New-AiSopValidationContext
$diagnostics=[Collections.Generic.List[string]]::new()
$scopeComparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
try {$Scope=@($Scope|ForEach-Object {ConvertTo-AiSopReviewScope $_})}
catch {$diagnostics.Add('SCOPE_UNRESOLVED: findings are not filtered');$Scope=@()}
$current=$null
if($CheckCurrent){
    try {$current=Get-AiSopValidationSnapshot $WorkspacePath $context}
    catch {$diagnostics.Add('CURRENT_INPUTS_UNAVAILABLE: '+$_.Exception.Message)}
}
function FileReference([string]$RelativePath,[string]$ExpectedHash='') {
    $result=[ordered]@{path=$RelativePath;status='UNAVAILABLE';sha256=$null}
    try {
        $path=Resolve-AiSopReviewChild $WorkspacePath $RelativePath
        if([IO.File]::Exists($path)){
            $result.sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $result.status=if($ExpectedHash){if($result.sha256 -ceq $ExpectedHash){'MATCH'}else{'CHANGED'}}else{'PRESENT_UNBOUND'}
        } else {$result.status='MISSING'}
    } catch {$result.status='UNAVAILABLE'}
    return $result
}
$runs=@(foreach($run in $task.verifications){
    $integrity='UNAVAILABLE';$match=if($CheckCurrent){'UNAVAILABLE'}else{'NOT_CHECKED'}
    try {
        if($run.inputsRef){$null=Resolve-AiSopReviewChild $WorkspacePath ('.ai-workspace/specs/.artifacts/inputs/'+$run.inputsRef+'.json')}
        $input=Read-AiSopVerificationInputs $run $WorkspacePath $context
        if($input.digest){$integrity='VALID'}else{$integrity='LEGACY_UNBOUND'}
        if($current -and $input.digest){$match=if($input.digest -ceq $current.digest){'MATCH'}else{'STALE'}}
    } catch {$diagnostics.Add('INPUTS_UNAVAILABLE: '+$run.runId)}
    $log=$null
    try {$logPath=Get-AiSopRunLogPath $run $WorkspacePath $spec $TaskId;if($logPath){$log=FileReference ([IO.Path]::GetRelativePath($WorkspacePath,$logPath))}}
    catch {$diagnostics.Add('LOG_REFERENCE_UNAVAILABLE: '+$run.runId)}
    $reports=@(foreach($report in $run.reportEvidence.reports){FileReference $report.path $report.sha256})
    [pscustomobject][ordered]@{runId=$run.runId;kind=$run.kind;batch=$run.batch;outcome=$run.outcome;exitCode=$run.exitCode;executedAt=$run.executedAt;
        executable=$run.context.executable;profile=$run.context.profile;caseIds=$run.caseIds;inputsRef=$run.inputsRef;inputDigest=$run.inputDigest;
        inputsStable=$run.inputsStable;inputIntegrity=$integrity;currentInputs=$match;log=$log;reports=$reports;
        reportCoverage=if($reports.Count){'RECORDED_REPORT_REFERENCES'}else{'NOT_RECORDED'};
        recordedVersions=@{code=$run.context.codeGitRevision;context=$run.context.contextGitRevision;specs=$run.context.specGitRevision}}
})
$latest=@($runs|Group-Object kind,batch|ForEach-Object {$_.Group[-1]})
$repositories=@(foreach($relative in $RepositoryPaths){
    try {
        $path=if($relative -eq '.'){$WorkspacePath}else{Resolve-AiSopReviewChild $WorkspacePath $relative}
        $top=(Get-AiSopDeliveryText $path @('rev-parse','--show-toplevel')).Trim()
        if((Resolve-PhysicalPathIdentity $top) -cne $path){throw 'NOT_A_REPOSITORY_ROOT'}
        $head=(Get-AiSopDeliveryText $path @('rev-parse','--verify','HEAD^{commit}')).Trim()
        $changes=@(Get-AiSopReadOnlyWorkingChanges $path)
        $base=if($relative -eq '.'){$task.baseline.revision}elseif($task.verifications.Count -and $relative -eq '.ai-workspace'){$task.verifications[0].context.contextGitRevision}elseif($task.verifications.Count -and $relative -eq '.ai-workspace/specs'){$task.verifications[0].context.specGitRevision}else{$null}
        $delta=@();$deltaState='BASELINE_UNAVAILABLE'
        if($base -match '^[0-9a-f]{40,64}$'){
            try{
                $delta=@((Get-AiSopDeliveryText $path @('diff','--no-ext-diff','--no-textconv','--name-status',$base,$head,'--')) -split '\r?\n'|Where-Object {$_})
                $deltaState='TRACKED_COMMIT_DIFF_INDEX'
            }catch{$deltaState='BASELINE_UNAVAILABLE'}
        }
        @{path=$relative;revision=$head;baseline=$base;baselineBasis=if($relative -eq '.'){'TASK_BASELINE'}else{'FIRST_RUN_RECORDED_REVISION_NOT_TASK_START'};committedDifference=$delta;differenceStatus=$deltaState;workingChanges=$changes;workingChangesBasis='EXTERNAL_FILTERS_DISABLED_SUBMODULE_WORKTREES_OMITTED';status='AVAILABLE'}
    } catch {@{path=$relative;status='UNAVAILABLE'}}
})
$findings=@()
$features=Resolve-AiSopReviewChild $WorkspacePath '.ai-workspace/specs/features'
foreach($featureDir in Get-ChildItem -LiteralPath $features -Directory){
    $relative='.ai-workspace/specs/features/'+$featureDir.Name+'/findings'
    $directory=Resolve-AiSopReviewChild $WorkspacePath $relative
    if(-not(Test-Path -LiteralPath $directory)){continue}
    foreach($file in Get-ChildItem -LiteralPath $directory -File -Filter '*.json'){
        $path=Resolve-AiSopReviewChild $WorkspacePath ($relative+'/'+$file.Name)
        try {
            $raw=[IO.File]::ReadAllText($path)
            if(-not(Test-Json -Json $raw -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/finding.schema.json') -ErrorAction Stop)){throw 'INVALID_FINDING'}
            $finding=ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
            $related=-not $Scope.Count
            foreach($changed in $Scope){foreach($affectedPath in $finding.scope){$affected=ConvertTo-AiSopReviewScope $affectedPath;if($changed -eq '.' -or $affected -eq '.' -or $changed.Equals($affected,$scopeComparison) -or $changed.StartsWith($affected+'/', $scopeComparison) -or $affected.StartsWith($changed+'/', $scopeComparison)){$related=$true}}}
            if($related){$findings+=@{record=$relative+'/'+$file.Name;id=$finding.id;title=$finding.title;severity=$finding.severity;declaredStatus=$finding.status;scope=$finding.scope;relevance=if($Scope.Count){'PATH_OVERLAP'}else{'SCOPE_NOT_SPECIFIED'};repair=@{feature=$finding.repair.feature;taskId=$finding.repair.taskId;commits=$finding.repair.commits;regressionRunIds=$finding.repair.regressionRunIds};closure=@{result=$finding.closure.result;evidence=$finding.closure.evidence}}}
        } catch {$diagnostics.Add('FINDING_UNREADABLE: '+$relative+'/'+$file.Name)}
    }
}
# Supplemental facts remain references to the task's maintained evidence; absence is explicit.
$evidence=FileReference ".ai-workspace/specs/features/$Feature/tasks/$TaskId/evidence.json"
$supplement=@{}
if($evidence.status -eq 'PRESENT_UNBOUND'){
    try {
        $raw=[IO.File]::ReadAllText((Resolve-AiSopReviewChild $WorkspacePath $evidence.path))
        $parsed=ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
        # PowerShell 会展开单元素数组，保留顶层对象判断，避免把对象数组当成对象。
        if(-not $raw.TrimStart().StartsWith('{') -or $parsed -isnot [System.Collections.IDictionary]){throw 'SUPPLEMENTAL_EVIDENCE_OBJECT_REQUIRED'}
        $supplement=$parsed
    }
    catch {
        # 补充材料不可读时保留其他审查事实，不把结构异常解释为清理或验证成功。
        $evidence.status='UNAVAILABLE'
        $diagnostics.Add('SUPPLEMENTAL_EVIDENCE_UNREADABLE')
    }
}
$cleanupSummary=@{}
if($supplement.cleanup.outcome -in @('PASSED','FAILED','UNKNOWN','NOT_RUN')){$cleanupSummary.outcome=$supplement.cleanup.outcome}
$delivery=@{status='UNAVAILABLE';blocking=$false;coverage='INCOMPLETE';items=@();diagnostics=@('DELIVERY_CHECK_UNAVAILABLE')}
try{$delivery=Get-AiSopDeliveryReview $WorkspacePath $DeliveryManifest}catch{$diagnostics.Add('DELIVERY_CHECK_UNAVAILABLE')}
$result=[ordered]@{schemaVersion='1.0';derived=$true;blocking=$false;feature=$Feature;taskId=$TaskId;objective=$task.objective;tier=$task.tier;taskStatus=$task.status;
    delivery=$delivery;
    currentInputCheck=if($CheckCurrent){if($current){'PERFORMED'}else{'UNAVAILABLE'}}else{'NOT_REQUESTED'};
    repositories=$repositories;latest=$latest;history=$runs;findings=$findings;findingCoverage=if(@($diagnostics|Where-Object {$_ -like 'FINDING_*' -or $_ -like 'SCOPE_*'}).Count){'INCOMPLETE'}else{'DECLARED_PATH_SCOPE_ONLY'};unverifiedScope=@{status=if($supplement.ContainsKey('limitations')){'CONSULT_SOURCE'}else{'NOT_RECORDED'};source=$evidence};cleanup=@{status=if($supplement.ContainsKey('cleanup')){'RECORDED_NOT_REVIEWED'}else{'NOT_RECORDED'};value=$cleanupSummary;source=$evidence};
    diagnostics=$diagnostics.ToArray();limits=@('No task, owner, finding or evidence state is changed.','Digest equality does not prove test semantics or review approval.','Commands, environment values and raw logs are not copied.','Nested repositories without a recorded baseline are not presented as a complete task diff.','Missing supplementary cleanup/scope facts remain unknown; inspect the source evidence.')}
$hints=[Collections.Generic.List[string]]::new()
if(-not $CheckCurrent){$hints.Add('CHECK_CURRENT_INPUTS_BEFORE_SELECTING_VERIFICATION')}
elseif(-not $current){$hints.Add('CURRENT_INPUTS_UNAVAILABLE')}
if(@($latest|Where-Object currentInputs -eq 'STALE').Count){$hints.Add('STALE_BATCHES_REQUIRE_REVIEW')}
if(@($latest|Where-Object {$_.outcome -ne 'PASSED' -or -not $_.inputsStable}).Count){$hints.Add('LATEST_FAILED_OR_UNSTABLE_BATCHES_REMAIN_VISIBLE')}
if(-not $task.syncReview){$hints.Add('RECORD_DOCUMENTATION_AND_TEST_SYNC_BEFORE_COMPLETE')}
if($task.status -eq 'ACTIVE'){$hints.Add('FINISH_DOCUMENTATION_FINDINGS_AND_REVIEW_RECORDS_BEFORE_COMPLETE')}
if(@($repositories|Where-Object status -ne 'AVAILABLE').Count){$hints.Add('REPOSITORY_INVENTORY_INCOMPLETE')}
$result.preparation=[ordered]@{
    derived=$true;blocking=$false;observedAt=[DateTimeOffset]::UtcNow.ToString('o');
    observedInputDigest=if($current){$current.digest}else{$null};
    latestRunIds=@($latest.runId);hints=$hints.ToArray();
    sequence=@('Finish targeted regressions, static review and documentation before full verification.','Observe the final inputs and repository differences; any later input change must remain visible.','Record findings, review and evidence references before Complete.','After Complete, use the task record, Git commits and read-only delivery checks; do not rewrite historical evidence.');
    limits=@('An observed digest is not a filesystem lock.','This section neither authorizes reruns nor reuses old results.','Input equality does not check command definitions, case scope or test semantics.','Repository changes include unrelated work; this is not an automatic staging list.')
}
$result|ConvertTo-Json -Depth 24
