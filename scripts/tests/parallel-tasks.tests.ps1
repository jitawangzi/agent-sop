#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
$entry=Join-Path $scripts 'workflow-task.ps1'
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'guard-production-edit.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-parallel-'+[guid]::NewGuid().ToString('N'))
$saved=@{}
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS','AI_SOP_SKIP_OWNER_GUARD','SERVER_NEW_SKIP_OWNER_GUARD','AI_SOP_GUARD_ROOT')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function Fails([scriptblock]$action,[string]$pattern) {
    $failure=''
    try { & $action | Out-Null; if ($LASTEXITCODE -ne 0) { $failure="exit=$LASTEXITCODE" } } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $pattern) "Expected $pattern; got $failure"
}
function New-Workspace([string]$name) {
    $ws=Join-Path $root $name
    [IO.Directory]::CreateDirectory((Join-Path $ws '.ai-workspace/specs/features/Example')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $ws 'src')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $ws 'src/input.txt'),'initial')
    return $ws
}
function Use-Workspace([string]$ws) {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY",(Join-Path $root "registries/$(Split-Path -Leaf $ws)/$kind")) }
    $env:AI_SOP_GUARD_ROOT=Join-Path $ws '.ai-sop'
}
function Spec([string]$ws) { Join-Path $ws '.ai-workspace/specs/features/Example' }
function Task([string]$ws,[string]$op,[string]$id,[hashtable]$extra=@{}) {
    Use-Workspace $ws
    & $entry -Operation $op -WorkspacePath $ws -Feature Example -TaskId $id -Agent CODEX -NativeSessionId ('parallel-'+(Split-Path -Leaf $ws)) @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
function Start-Task([string]$ws,[string]$id,[string]$tier) {
    $args=@{Tier=$tier;Objective="Parallel fixture $id"}
    if ($tier -ne 'T2') { $args.UserRequest="本测试明确选择 $tier" }
    Task $ws Start $id $args | Out-Null
}
function Sync-Task([string]$from,[string]$to,[string]$id) {
    $destination=Get-AiSopTaskPath (Spec $to) $id
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    Copy-Item -LiteralPath (Get-AiSopTaskPath (Spec $from) $id) -Destination $destination
}
function Guard([string]$ws) {
    Use-Workspace $ws
    Get-AiSopGuardDecision -AcceptedAt ([DateTimeOffset]::UtcNow) -HookEvent @{
        event='PRE_TOOL_USE';agent='CODEX';nativeSessionId=('parallel-'+(Split-Path -Leaf $ws));workspacePath=$ws
        toolName='Edit';toolClass='FILE_EDIT';targetPaths=@((Join-Path $ws 'src/input.txt'))
    }
}
try {
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'; $env:AI_SOP_SKIP_OWNER_GUARD='0'; $env:SERVER_NEW_SKIP_OWNER_GUARD='0'
    # 两个方向都要检查，不能只允许轻档在 T3 之后启动。
    foreach ($pair in @('T1,T1','T1,T2','T2,T1','T2,T2','T3,T1','T3,T2','T1,T3','T2,T3')) {
        $tiers=$pair.Split(','); $a=New-Workspace ($pair.Replace(',','-')+'-a'); $b=New-Workspace ($pair.Replace(',','-')+'-b')
        Start-Task $a one $tiers[0]; Sync-Task $a $b one
        $foreign=[IO.File]::ReadAllText((Get-AiSopTaskPath (Spec $b) one))
        Start-Task $b two $tiers[1]; Sync-Task $b $a two
        Assert ($foreign -ceq [IO.File]::ReadAllText((Get-AiSopTaskPath (Spec $b) one))) 'Start rewrote foreign task'
        foreach ($item in @(@{ws=$a;id='one'},@{ws=$b;id='two'})) {
            $local=Read-AiSopTask (Spec $item.ws) $item.id
            Assert ($local.schemaVersion -eq '1.1' -and (Get-AiSopTaskExecutionLocality $local $item.ws) -eq 'LOCAL') 'Local origin was not recorded'
            Task $item.ws Resume $item.id | Out-Null
            $decision=Guard $item.ws
            Assert ($decision.Decision -eq 'ALLOW') "Supported $pair write denied"
            Fails { Start-Task $item.ws forbidden T2 } 'WORKFLOW_OWNER_ALREADY_ACTIVE|COMMAND_GRANT_OWNER_STATE_INVALID'
            Assert ((Guard $item.ws).Decision -eq 'ALLOW') 'Rejected Start grant invalidated the existing owner'
        }
        $external=Task $b Status one @{OutputFormat='JsonLines'} | ConvertFrom-Json
        Assert ($external.executionLocality -eq 'EXTERNAL' -and $external.verificationScope -eq 'NOT_CHECKED' -and $external.diagnostics.Count -eq 0 -and $external.suggestedActionCode -eq 'EXTERNAL_TASK') 'Synced task was treated as a local orphan/stale input'
        Task $a Suspend one | Out-Null; Task $b Cancel two | Out-Null
    }
    # 可见冲突：Start 和升档均拒绝，既有轻档不被改写。
    $a=New-Workspace 'visible-a'; $b=New-Workspace 'visible-b'
    Start-Task $a one T3; Sync-Task $a $b one
    Fails { Start-Task $b denied T3 } 'TASK_PARALLEL_T3_UNSUPPORTED:one'
    Assert (-not (Test-Path -LiteralPath (Get-AiSopTaskPath (Spec $b) denied))) 'Rejected Start created a task'
    Start-Task $b two T2
    $before=[IO.File]::ReadAllText((Get-AiSopTaskPath (Spec $b) two))
    Fails { Task $b ChangeTier two @{Tier='T3';Reason='复杂度增加';UserRequest='本测试请求 T3'} } 'TASK_PARALLEL_T3_UNSUPPORTED:one'
    Assert ($before -ceq [IO.File]::ReadAllText((Get-AiSopTaskPath (Spec $b) two))) 'Rejected tier change changed task'
    Task $b Cancel two | Out-Null; Task $a Suspend one | Out-Null
    # 未同步时无法探测远端活动；同步后在续接、写前和完成校验时拦截。
    $a=New-Workspace 'collision-a'; $b=New-Workspace 'collision-b'
    Start-Task $a one T3; Start-Task $b two T3
    [IO.File]::WriteAllText((Join-Path $a 'src/input.txt'),'a-work')
    [IO.File]::WriteAllText((Join-Path $b 'src/input.txt'),'b-work')
    $baseline=(Read-AiSopTask (Spec $a) one).baseline.inputDigest
    Sync-Task $a $b one; Sync-Task $b $a two
    Fails { Task $a Resume one } 'TASK_PARALLEL_T3_UNSUPPORTED:two'
    Assert ((Guard $a).ReasonCode -eq 'TASK_PARALLEL_T3_UNSUPPORTED') 'Write guard missed T3 collision'
    $problems=@(Get-AiSopTaskProblems (Read-AiSopTask (Spec $a) one) $a (Spec $a))
    Assert ($problems -match '^TASK_PARALLEL_T3_UNSUPPORTED:two') 'Completion diagnostics missed T3 collision'
    $inspection=Task $a InspectRecovery one | ConvertFrom-Json
    Assert ($inspection.suggestedActionCode -eq 'RESOLVE_PARALLEL_T3') 'Recovery did not explain collision'
    Task $b Suspend two | Out-Null
    Sync-Task $b $a two
    Task $a Resume one | Out-Null
    Assert ((Guard $a).Decision -eq 'ALLOW') 'Pausing at origin and syncing did not restore allowed execution'
    Assert ((Read-AiSopTask (Spec $a) one).baseline.inputDigest -ceq $baseline) 'Recovery recaptured baseline'
    Assert ([IO.File]::ReadAllText((Join-Path $a 'src/input.txt')) -ceq 'a-work' -and [IO.File]::ReadAllText((Join-Path $b 'src/input.txt')) -ceq 'b-work') 'Recovery lost either workspace edits'
    Task $a Cancel one | Out-Null
    # 来源丢失与本地孤儿不能冒充外部任务。
    $a=New-Workspace 'orphan-a'; $b=New-Workspace 'orphan-b'
    Start-Task $a one T2; Sync-Task $a $b one
    Fails { Task $b Recover one } 'EXTERNAL_TASK_CONFIRM_STOPPED'
    Fails { Task $b Resume one } 'TASK_NOT_RESUMABLE'
    $legacy=Read-AiSopTask (Spec $b) one; $legacy.schemaVersion='1.0'; $legacy.Remove('executionLocation')
    [IO.File]::WriteAllText((Get-AiSopTaskPath (Spec $b) one),(ConvertTo-AiSopWorkflowCanonicalJson $legacy))
    Fails { Start-Task $b two T2 } 'TASK_ACTIVE_CONFLICT:one'
    Use-Workspace $a
    $ownerPath=Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json'; $ownerRaw=[IO.File]::ReadAllText($ownerPath)
    Remove-Item -LiteralPath $ownerPath
    try {
        Fails { Assert-AiSopNoOtherActiveTask (Spec $a) two $a T2 } 'TASK_ACTIVE_CONFLICT:one'
        Fails { Start-Task $a two T2 } 'TASK_ACTIVE_CONFLICT:one|COMMAND_GRANT_OWNER_STATE_INVALID'
    }
    finally { [IO.File]::WriteAllText($ownerPath,$ownerRaw) }
    # 正常跨工作区接管必须先在原地暂停；不会重拍启动清单。
    $startDigest=(Read-AiSopTask (Spec $a) one).startInputs.inputDigest
    Task $a Suspend one | Out-Null; Sync-Task $a $b one
    Task $b Resume one | Out-Null
    Assert ((Get-AiSopTaskExecutionLocality (Read-AiSopTask (Spec $b) one) $b) -eq 'LOCAL') 'Handoff retained foreign location'
    Assert ((Read-AiSopTask (Spec $b) one).startInputs.inputDigest -ceq $startDigest) 'Handoff replaced Start inputs'
    Task $b Cancel one | Out-Null
    # 来源确认后可恢复外部孤儿；只影响接收副本，不改变原工作区。
    $c=New-Workspace 'recovery-c'
    $snapshot=Read-AiSopTask (Spec $a) one; $snapshot.status='ACTIVE'
    $snapshotPath=Get-AiSopTaskPath (Spec $c) one
    [IO.Directory]::CreateDirectory((Split-Path -Parent $snapshotPath)) | Out-Null
    [IO.File]::WriteAllText($snapshotPath,(ConvertTo-AiSopWorkflowCanonicalJson $snapshot))
    Task $c Recover one @{ForceRecovery=$true;Reason='原工作区已经暂停，当前接收副本是滞后的 ACTIVE 记录'} | Out-Null
    Assert ((Read-AiSopTask (Spec $c) one).status -eq 'PAUSED' -and (Read-AiSopTask (Spec $a) one).status -eq 'PAUSED') 'Confirmed recovery changed the source or failed to pause'
    # 异地同名路径仍是外部来源；新版本记录缺少位置会被 Schema 拒绝。
    $record=Read-AiSopTask (Spec $a) one
    $record.executionLocation.machine='different-test-machine'
    Assert ((Get-AiSopTaskExecutionLocality $record $a) -eq 'EXTERNAL') 'Remote path collision became local'
    $record.Remove('executionLocation')
    Fails { Assert-AiSopWorkflowJsonSchema -Json (ConvertTo-AiSopWorkflowCanonicalJson $record) -SchemaId TASK } 'SCHEMA|schema'
    # 两边验证独立完成；合入代码会让接收方当前证据过期，不能沿用绿色结果。
    $a=New-Workspace 'delivery-a'; $b=New-Workspace 'delivery-b'
    Start-Task $a one T2; Sync-Task $a $b one; Start-Task $b two T2; Sync-Task $b $a two
    foreach ($item in @(@{ws=$a;id='one'},@{ws=$b;id='two'})) {
        Task $item.ws RecordSync $item.id @{Documentation='UNCHANGED';Tests='UNCHANGED';Summary='使用现有输入检查，无设计规则变化'} | Out-Null
        foreach ($kind in @('compile','test')) { Task $item.ws Run $item.id @{Kind=$kind;Executable='pwsh';Arguments=@('-NoProfile','-Command',"if ([IO.File]::ReadAllText('src/input.txt') -cne 'initial') { throw 'unexpected input' }")} | Out-Null }
    }
    Task $a Complete one | Out-Null
    [IO.File]::WriteAllText((Join-Path $b 'src/input.txt'),'merged')
    Fails { Task $b Complete two } 'WORKFLOW_COMPLETION_VERIFICATION_FAILED'
    foreach ($kind in @('compile','test')) { Task $b Run two @{Kind=$kind;Executable='pwsh';Reason='合并后的输入重新验证';Arguments=@('-NoProfile','-Command',"if ([IO.File]::ReadAllText('src/input.txt') -cne 'merged') { throw 'unexpected merged input' }")} | Out-Null }
    Task $b Complete two | Out-Null
    Assert ((Read-AiSopTask (Spec $a) one).status -eq 'DONE' -and (Read-AiSopTask (Spec $b) two).status -eq 'DONE') 'Independent completion failed'
    Start-Task $a later T2
    $historical=Task $a Status one @{OutputFormat='JsonLines';RecheckHistory=$true} | ConvertFrom-Json
    Assert (-not ($historical.diagnostics -match 'TASK_ACTIVE_CONFLICT')) 'Historical input recheck treated the later task as concurrent execution'
    Task $a Cancel later | Out-Null
    # 已有本地归属不能静默吞入同 ID 的外部 ACTIVE 版本。
    $a=New-Workspace 'identity-a'; $b=New-Workspace 'identity-b'
    Start-Task $a one T2
    $identityPath=Get-AiSopTaskPath (Spec $a) one; $identityRaw=[IO.File]::ReadAllText($identityPath)
    $record=Read-AiSopTask (Spec $a) one; $record.executionLocation.workspace=$b
    [IO.File]::WriteAllText($identityPath,(ConvertTo-AiSopWorkflowCanonicalJson $record))
    Fails { Task $a Resume one } 'TASK_EXECUTION_LOCATION_MISMATCH'
    Assert ((Guard $a).ReasonCode -eq 'TASK_EXECUTION_LOCATION_MISMATCH') 'Foreign same-ID task inherited local write permission'
    [IO.File]::WriteAllText($identityPath,$identityRaw)
    Task $a Cancel one | Out-Null
    Write-Host 'PASS: parallel tier matrix, local exclusivity, legacy safety, conflict recovery, handoff, evidence invalidation'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $cleanup=Resolve-PhysicalPathIdentity $root
    $tempPrefix=(Resolve-PhysicalPathIdentity ([IO.Path]::GetTempPath())).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if (-not $cleanup.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $cleanup) -notlike 'sop-parallel-*') { throw 'CLEANUP_PATH_INVALID' }
    if ([IO.Directory]::Exists($cleanup)) { Remove-Item -LiteralPath $cleanup -Recurse -Force }
}
