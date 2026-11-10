#requires -Version 7.0
<# 从现有任务记录复制明确引用的报告；输出仅是派生交付材料，不修改任务或 Git。 #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkspacePath,[Parameter(Mandatory)][string]$Feature,
    [Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot task-context.ps1)
. (Join-Path $PSScriptRoot review-paths.ps1)
$WorkspacePath=Resolve-PhysicalPathIdentity $WorkspacePath
$output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if(Test-Path -LiteralPath $output){throw 'EVIDENCE_OUTPUT_EXISTS'}
$destination=$output
$output=Join-Path (Split-Path -Parent $destination) ('.evidence-pack-'+[guid]::NewGuid().ToString('N'))
$sources=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
$expected=@{}
$taskRelative=".ai-workspace/specs/features/$Feature/tasks/$TaskId/task.json"
[void]$sources.Add($taskRelative)
$taskPath=Resolve-AiSopReviewChild $WorkspacePath $taskRelative
$taskBytes=[IO.File]::ReadAllBytes($taskPath)
$expected[$taskRelative]=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($taskBytes)).ToLowerInvariant()
$task=[Text.Encoding]::UTF8.GetString($taskBytes).TrimStart([char]0xFEFF)|ConvertFrom-Json -AsHashtable
$supplement=".ai-workspace/specs/features/$Feature/tasks/$TaskId/evidence.json"
[void]$sources.Add($supplement)
if($task.startInputs.inputsRef){[void]$sources.Add('.ai-workspace/specs/.artifacts/inputs/'+$task.startInputs.inputsRef+'.json')}
foreach($run in $task.verifications){
    if($run.context.logPath){[void]$sources.Add($run.context.logPath)}
    foreach($report in $run.reportEvidence.reports){if($report.path){[void]$sources.Add($report.path)}}
    if($run.inputsRef){[void]$sources.Add('.ai-workspace/specs/.artifacts/inputs/'+$run.inputsRef+'.json')}
}
foreach($source in $sources){
    if($expected.ContainsKey($source)){continue}
    try{$expected[$source]=(Get-FileHash -LiteralPath (Resolve-AiSopReviewChild $WorkspacePath $source)).Hash.ToLowerInvariant()}catch{}
}
$review=(& (Join-Path $PSScriptRoot export-review.ps1) -WorkspacePath $WorkspacePath -Feature $Feature -TaskId $TaskId)|ConvertFrom-Json -AsHashtable
[IO.Directory]::CreateDirectory($output)|Out-Null
$items=[Collections.Generic.List[object]]::new();$declarations=[Collections.Generic.List[object]]::new()
foreach($source in $sources){
    $entry=[ordered]@{source=$source;status='UNAVAILABLE';path=$null;sha256=$null;observationMatch='UNBOUND';diagnostic=$null}
    try {
        $path=Resolve-AiSopReviewChild $WorkspacePath $source
        $bytes=if($source -ceq $taskRelative){$taskBytes}else{[IO.File]::ReadAllBytes($path)}
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $name='objects/'+$hash
        [IO.Directory]::CreateDirectory((Join-Path $output objects))|Out-Null
        [IO.File]::WriteAllBytes((Join-Path $output $name),$bytes)
        $entry.path=$name;$entry.sha256=$hash;$entry.status='COPIED'
        if($expected.ContainsKey($source)){$entry.observationMatch=if($expected[$source] -ceq $hash){'MATCH'}else{'CHANGED'}}
        if($name -notin $declarations.path){$declarations.Add(@{path=$name;sha256=$hash})}
    }catch{$entry.diagnostic=$_.Exception.Message}
    $items.Add($entry)
}
if((Get-FileHash -LiteralPath $taskPath).Hash.ToLowerInvariant() -cne $expected[$taskRelative]){throw 'EVIDENCE_TASK_CHANGED_DURING_PACK'}
@{schemaVersion='1';authoritative=$false;items=@($items.ToArray());review=$review;limits=@('Only task record references are copied; supplemental attachments require separate explicit packaging.','Hashes prove copied bytes, not test correctness or remote delivery.','ObservationMatch compares export-time bytes; report validity remains in review.history.reports.')}|
    ConvertTo-Json -Depth 60|Set-Content -LiteralPath (Join-Path $output index.json)
$declarations.Add(@{path='index.json';sha256=(Get-FileHash -LiteralPath (Join-Path $output index.json)).Hash.ToLowerInvariant()})
ConvertTo-Json -InputObject @($declarations.ToArray()) -Depth 5|Set-Content -LiteralPath (Join-Path $output manifest.json)
# 同目录原子发布；另一调用抢先发布时保留此临时包，不覆盖对方材料。
[IO.Directory]::Move($output,$destination)
$output=$destination
@{output=$output;copied=@($items|Where-Object status -eq COPIED).Count;unavailable=@($items|Where-Object status -ne COPIED).Count;blocking=$false}|ConvertTo-Json
