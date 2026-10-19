#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'workflow-session.ps1')
. (Join-Path $scripts 'guard-production-edit.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-delegation-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'
$spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
$saved=@{}
function Assert($ok,$message) { if (-not $ok) { throw $message } }
function Task($op,$native='parent',$extra=@{}) {
    & (Join-Path $scripts 'workflow-task.ps1') -Operation $op -WorkspacePath $workspace -Feature Example -TaskId delegated -Agent CURSOR -NativeSessionId $native @extra
    if ($LASTEXITCODE -ne 0) { throw "TASK_FAILED:$op" }
}
function Denied([scriptblock]$action,$code) {
    $failure=''
    try { & $action | Out-Null } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $code) "Expected $code; received $failure; action=$action"
}
function Owner { Get-Content -LiteralPath (Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json') -Raw | ConvertFrom-Json -AsHashtable }
function Guard($native,$name='Write') {
    $event=@{agent='CURSOR';nativeSessionId=$native;workspacePath=$workspace;toolName=$name;toolClass=$(if($name -eq 'Write'){'FILE_EDIT'}else{'OWNER_REQUIRED'})}
    Get-AiSopExactOwnerDecision -HookEvent $event -AcceptedAt ([DateTimeOffset]::UtcNow) -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(10))
}
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) {
        $name="AI_SOP_${kind}_REGISTRY"; $saved[$name]=[Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name,(Join-Path $root $kind))
    }
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'src')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'src/input.txt'),'original')
    Task Start parent @{Objective='单个子会话实现测试';Tier='T3';UserRequest='此回归明确使用 T3'} | Out-Null
    $original=Owner
    Task Join child | Out-Null
    Task Join other | Out-Null
    Assert ((Guard child).Decision -eq 'DENY') 'Join 不得自动授权'
    Denied { Task Delegate child @{ChildNativeSessionId='other';Reason='越权'} } 'WORKFLOW_OWNER_SESSION_MISMATCH'
    Task Delegate parent @{ChildNativeSessionId='child';Reason='显式委派实现'} | Out-Null
    $delegated=Owner
    Assert ((ConvertTo-AiSopWorkflowCanonicalJson $original.sessionBinding) -ceq (ConvertTo-AiSopWorkflowCanonicalJson $delegated.sessionBinding)) '委派改变父归属'
    Assert ((Guard child).Decision -eq 'ALLOW') '授权子会话不能编辑'
    Assert ((Guard parent).ReasonCode -eq 'TASK_EXECUTION_DELEGATED') '父会话未停止编辑'
    Assert ((Guard parent Task).Decision -eq 'ALLOW') '父会话不能派发'
    Assert ((Guard child Task).Decision -eq 'DENY') '子会话不能继续委派'
    Assert ((Guard other).Decision -eq 'DENY') '其他子会话得到写权限'
    Denied { Task Delegate parent @{ChildNativeSessionId='other';Reason='替换'} } 'DELEGATION_ALREADY_ACTIVE'
    Denied { Task Run parent @{Kind='compile';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0')} } 'TASK_EXECUTION_DELEGATED'
    Denied { Task Cancel child } 'WORKFLOW_OWNER_SESSION_MISMATCH|DELEGATE_CONTROL_DENIED'
    Denied { Task Resume child @{ConfirmTakeover=$true} } 'DELEGATE_CONTROL_DENIED'
    Denied { Task Recover child @{ForceRecovery=$true} } 'DELEGATE_CONTROL_DENIED'
    Denied { Task ChangeTier child @{Tier='T1';UserRequest='越权降档';Reason='越权'} } 'WORKFLOW_OWNER_SESSION_MISMATCH|DELEGATE_CONTROL_DENIED'
    Task Run child @{Kind='compile';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0');TimeoutSeconds=30} | Out-Null
    $evidence=(Read-AiSopTask $spec delegated).verifications[-1]
    Assert ($evidence.outcome -eq 'PASSED' -and $evidence.context.sessionKey -ceq $delegated.executionDelegation.sessionKey -and $evidence.context.delegationId -ceq $delegated.executionDelegation.id) '验证没有绑定真实子会话'
    Assert ((Owner).sessionBinding.sessionKey -ceq $original.sessionBinding.sessionKey) '验证抢占父归属'
    $pendingPath=Get-AiSopRunEvidencePath $spec delegated $evidence.runId
    $validEvidence=ConvertTo-AiSopWorkflowCanonicalJson $evidence
    $evidence.context.delegationId=[guid]::NewGuid().ToString('N')
    Write-AiSopWorkflowTextAtomic $pendingPath (ConvertTo-AiSopWorkflowCanonicalJson $evidence)
    Denied { Task RetryEvidence child @{RunId=$evidence.runId} } 'RUN_DELEGATION_MISMATCH'
    Write-AiSopWorkflowTextAtomic $pendingPath $validEvidence
    Denied { Task RetryEvidence parent @{RunId=$evidence.runId} } 'TASK_EXECUTION_DELEGATED'
    Task RetryEvidence child @{RunId=$evidence.runId} | Out-Null
    Assert (-not [IO.File]::Exists($pendingPath)) '原子会话重试成功后未清除 pending'
    # 真实后台验证运行中，拒绝撤销、替换和第二次运行。
    $fixture=Join-Path $root 'run.ps1'
    [IO.File]::WriteAllText($fixture, @'
param($Entry,$Workspace)
& $Entry -Operation Run -WorkspacePath $Workspace -Feature Example -TaskId delegated -Agent CURSOR -NativeSessionId child -Kind compile -Batch slow -Executable pwsh -Arguments @('-NoProfile','-Command','Start-Sleep -Seconds 25; exit 0') -TimeoutSeconds 40
exit $LASTEXITCODE
'@)
    $runner=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$fixture,'-Entry',(Join-Path $scripts 'workflow-task.ps1'),'-Workspace',$workspace) -RedirectStandardOutput (Join-Path $root 'run.out') -RedirectStandardError (Join-Path $root 'run.err') -TimeoutSeconds 55 -CloseStandardInput -PassThru
    $limit=[DateTimeOffset]::UtcNow.AddSeconds(15)
    while (-not @((Read-AiSopTask $spec delegated).verifications | Where-Object outcome -eq 'RUNNING').Count -and [DateTimeOffset]::UtcNow -lt $limit -and -not $runner.HasExited) { Start-Sleep -Milliseconds 100 }
    Assert (@((Read-AiSopTask $spec delegated).verifications | Where-Object outcome -eq 'RUNNING').Count -eq 1) "后台验证未启动: $(Get-Content (Join-Path $root 'run.err') -Raw)"
    Denied { Task RevokeDelegation parent @{Reason='运行期间禁止撤销'} } 'RUN_UNFINISHED'
    Denied { Task Delegate parent @{ChildNativeSessionId='other';Reason='运行期间禁止替换'} } 'RUN_UNFINISHED'
    Denied { Task Suspend parent } 'RUN_UNFINISHED'
    Denied { Task Run child @{Kind='compile';Batch='competing';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0')} } 'RUN_UNFINISHED'
    $runner.WaitForExit()
    Assert ($runner.ExitCode -eq 0) "后台验证失败: exit=$($runner.ExitCode); diagnostic=$($runner.Diagnostic); stdout=$(Get-Content (Join-Path $root 'run.out') -Raw); stderr=$(Get-Content (Join-Path $root 'run.err') -Raw)"
    $runner.Dispose(); $runner=$null
    Task RevokeDelegation parent @{Reason='实现结束'} | Out-Null
    Assert ((Guard child).Decision -eq 'DENY' -and (Guard parent).Decision -eq 'ALLOW') '撤销未恢复唯一执行者'
    Denied { Task RetryEvidence child @{RunId=$evidence.runId} } 'RUN_PENDING_RESULT_NOT_FOUND|EVIDENCE|WORKFLOW_OWNER_SESSION_MISMATCH'
    Task Delegate parent @{ChildNativeSessionId='other';Reason='下一位执行者'} | Out-Null
    Task Suspend parent | Out-Null
    Assert ((Owner).executionDelegation.status -eq 'REVOKED' -and (Guard other).Decision -eq 'DENY') '暂停没有撤销'
    Task Resume parent | Out-Null
    Assert ((Guard other).Decision -eq 'DENY') '恢复重新激活旧委派'
    Task Delegate parent @{ChildNativeSessionId='child';Reason='过期验证'} | Out-Null
    $expired=Owner; $expired.executionDelegation.expiresAt=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
    Write-AiSopWorkflowTextAtomic (Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json') (ConvertTo-AiSopWorkflowCanonicalJson $expired)
    Assert ((Guard child).Decision -eq 'DENY') '过期委派仍可编辑'
    Denied { Task Run child @{Kind='compile';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0')} } 'WORKFLOW_OWNER_SESSION_MISMATCH'
    Task RevokeDelegation parent @{Reason='显式回收过期授权'} | Out-Null
    Task Delegate parent @{ChildNativeSessionId='child';Reason='真正接管验证'} | Out-Null
    Task Resume replacement @{ConfirmTakeover=$true} | Out-Null
    Assert ((Owner).executionDelegation.status -eq 'REVOKED' -and (Guard child).Decision -eq 'DENY') '真正接管没有撤销旧执行者'
    Task Resume parent @{ConfirmTakeover=$true} | Out-Null
    Task Delegate parent @{ChildNativeSessionId='child';Reason='父会话结束验证'} | Out-Null
    $parentPath=Get-AiSopWorkflowSessionPath -SessionKey (Owner).sessionBinding.sessionKey -WorkspacePath $workspace
    $idleParent=Read-AiSopWorkflowSessionRecord -SessionPath $parentPath
    $idleParent.expiresAt=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
    Write-AiSopWorkflowTextAtomic $parentPath (ConvertTo-AiSopWorkflowCanonicalJson $idleParent)
    Assert ((Guard child).Decision -eq 'ALLOW') '等待导致的父空闲租约到期不应提前截断显式委派'
    Invoke-AiSopWorkflowSession -Operation End -Agent CURSOR -NativeSessionId parent -WorkspacePath $workspace -AcceptedAt ([DateTimeOffset]::UtcNow) | Out-Null
    Assert ((Guard child).ReasonCode -eq 'DELEGATION_PARENT_INACTIVE') '父会话结束后仍可执行'
    Task Resume parent | Out-Null
    Assert ((Owner).executionDelegation.status -eq 'REVOKED' -and (Guard child).Decision -eq 'DENY') '父会话重绑恢复了旧委派'
    Task Delegate parent @{ChildNativeSessionId='child';Reason='恢复验证'} | Out-Null
    Task Recover parent @{ForceRecovery=$true} | Out-Null
    Assert ((Owner).executionDelegation.status -eq 'REVOKED' -and (Guard child).Decision -eq 'DENY') '恢复没有撤销执行者'
    Task Resume parent | Out-Null
    Task Delegate parent @{ChildNativeSessionId='child';Reason='取消验证'} | Out-Null
    Task Cancel parent | Out-Null
    Assert ((Owner).executionDelegation.status -eq 'REVOKED' -and (Guard child).Decision -eq 'DENY') '取消没有撤销'
    Write-Host 'PASS: 显式委派、唯一执行者、父归属、真实验证证据、撤销/暂停/取消'
} finally {
    if ($runner) { $runner.Dispose() }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
    $physical=Resolve-PhysicalPathIdentity $root
    if ((Split-Path -Parent $physical) -cne (Resolve-PhysicalPathIdentity ([IO.Path]::GetTempPath())) -or (Split-Path -Leaf $physical) -notlike 'sop-delegation-*') { throw 'TEST_CLEANUP_PATH_INVALID' }
    Remove-Item -LiteralPath $physical -Recurse -Force
}
