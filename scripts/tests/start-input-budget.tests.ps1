#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) task-context.ps1)
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('start-budget-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $root '.ai-workspace/context'))|Out-Null
[IO.File]::WriteAllBytes((Join-Path $root source.txt),[byte[]]::new(9MB))
$ok=$false;$failure='';$saved=@{}
function Capture { $t=@{tier='T2';taskId='example';feature='Example';createdAt=[DateTimeOffset]::UtcNow.ToString('o')};Initialize-AiSopTaskStart $t $root ('claim-'+[guid]::NewGuid().ToString('N')) -NewStart;return $t }
function Assert($value,$message){if(-not $value){throw $message}}
try {
    $t=Capture;Assert ($t.startInputs.status -eq 'UNAVAILABLE') 'Default budget unexpectedly accepted 9MiB'
    $config=Join-Path $root '.ai-workspace/context/start-inputs.json'
    '{"budgetMilliseconds":15000,"maxBytes":16777216}'|Set-Content $config
    $t=Capture;Assert ($t.startInputs.status -eq 'CAPTURED') 'Project budget failed'
    $digest=$t.startInputs.inputDigest
    $stream=[IO.File]::OpenWrite((Join-Path $root source.txt));try{$stream.WriteByte(1)}finally{$stream.Dispose()}
    $t=Capture;Assert ($t.startInputs.inputDigest -ne $digest) 'Content mutation lost'
    foreach($bad in @('null','[]','"text"','{"budgetMilliseconds":0,"maxBytes":1}','{"budgetMilliseconds":15000,"maxBytes":1}','{"budgetMilliseconds":1,"maxBytes":16777216}')){
        $bad|Set-Content $config;$t=Capture;Assert ($t.startInputs.status -eq 'UNAVAILABLE' -and -not $t.startInputs.inputsRef) 'Invalid or exhausted budget supplied partial baseline'
    }
    foreach($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')){
        $key='AI_SOP_'+$kind+'_REGISTRY';$saved[$key]=[Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key,(Join-Path $root $kind))
    }
    '{"budgetMilliseconds":15000,"maxBytes":16777216}'|Set-Content $config
    $entry=Join-Path (Split-Path $PSScriptRoot) workflow-task.ps1
    & $entry -Operation Start -WorkspacePath $root -Feature Example -TaskId persisted -Agent CODEX -NativeSessionId budget-fixture -Objective 'Budget integration'|Out-Null
    $path=Join-Path $root '.ai-workspace/specs/features/Example/tasks/persisted/task.json'
    $record=Get-Content $path -Raw|ConvertFrom-Json
    Assert ($record.startInputs.status -eq 'CAPTURED' -and $record.startInputs.budget.MaxBytes -eq 16777216) 'Real Start did not persist budget and baseline'
    $original=$record.startInputs.inputsRef
    'null'|Set-Content $config
    & $entry -Operation Resume -WorkspacePath $root -Feature Example -TaskId persisted -Agent CODEX -NativeSessionId budget-fixture|Out-Null
    $record=Get-Content $path -Raw|ConvertFrom-Json
    Assert ($record.startInputs.inputsRef -ceq $original) 'Resume recaptured origin'
    $ok=$true
}catch{$failure=$_.ToString();throw}finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])};Complete-AiSopTestFixture -Root $root -Prefix start-budget- -Succeeded $ok -Failure $failure}
Write-Output 'PASS: default, project budget, changed content, invalid config and exhaustion'
