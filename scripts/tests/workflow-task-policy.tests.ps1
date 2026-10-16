#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
$entry=Join-Path $scripts 'workflow-task.ps1'
. (Join-Path $scripts 'task-context.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-task-policy-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'
$spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
$saved=@{}
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS','CODEX_SESSION_ID','AI_SESSION_ID')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Assert($value, $message) { if (-not $value) { throw $message } }
function Task([string]$op, [string]$id, [hashtable]$extra=@{}) {
    & $entry -Operation $op -WorkspacePath $workspace -Feature Example -TaskId $id -Agent CODEX @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
function Fails([scriptblock]$action, [string]$pattern) {
    $failure=''
    try { & $action | Out-Null; if ($LASTEXITCODE -ne 0) { $failure="exit=$LASTEXITCODE" } } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $pattern) "Expected $pattern, received '$failure'"
}
$check=@{ Executable='pwsh'; Arguments=@('-NoProfile','-Command', "if ([IO.File]::ReadAllText('input.txt') -ne 'valid') { throw 'Invalid fixture input' }") }
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY", (Join-Path $root $kind)) }
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'; $env:CODEX_SESSION_ID='policy-original'
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'input.txt'), 'valid')
    [IO.File]::WriteAllText((Join-Path $spec '06_design_contract.md'), 'Historical contract')
    Task Start urgent @{ Tier='T1'; Objective='Urgent behavior adjustment' } | Out-Null
    Assert (-not (Read-AiSopTask $spec urgent).followUps) 'T1 automatically created debt'
    $follow=@{ FollowUpId='field-doc'; FollowUpKind='documentation'; Summary='Update field meaning'; Scope=@('06_design_contract.md#response','Decoder#read') }
    Task AddFollowUp urgent $follow | Out-Null
    Task AddFollowUp urgent $follow | Out-Null
    Assert ((Read-AiSopTask $spec urgent).followUps.Count -eq 1) 'Retry duplicated a follow-up'
    Fails { Task AddFollowUp urgent @{ FollowUpId='field-doc'; FollowUpKind='test-cases'; Summary='Different item'; Scope=@('tests') } } 'FOLLOW_UP_ID_CONFLICT'
    Task AddFollowUp urgent @{ FollowUpId='field-test'; FollowUpKind='test-cases'; Summary='Add old payload regression'; Scope=@('DecoderTests') } | Out-Null
    Task Run urgent (@{Kind='compile'} + $check) | Out-Null
    Task Complete urgent | Out-Null
    Assert ((Read-AiSopTask $spec urgent).status -eq 'DONE') 'Pending follow-ups blocked T1 completion'
    $discovery=& $entry -Operation Discover -OutputFormat JsonLines -WorkspacePath $workspace -Feature Example | ConvertFrom-Json
    Assert ($discovery.pendingFollowUps.Count -eq 2) 'Completed task pending items disappeared from discovery'

    # Another feature gets only a summary; startup does not request acknowledgement.
    $other=& $entry -Operation Start -WorkspacePath $workspace -Feature Other -TaskId other -Objective 'Independent work' -Agent CODEX | Out-String
    Assert ($other -match 'FOLLOW_UP_OTHER_FEATURES: 2' -and $other -notmatch 'Update field meaning') 'Cross-feature reminder leaked full checklist or was missing'
    & $entry -Operation Cancel -WorkspacePath $workspace -Feature Other -TaskId other -Agent CODEX | Out-Null
    $started=Task Start next @{ Objective='Independent small task' } | Out-String
    Assert ((Read-AiSopTask $spec next).tier -eq 'T2') 'Unspecified task did not default to T2'
    Assert ($started -match 'field-doc' -and $started -match 'FOLLOW_UP_NON_BLOCKING') 'Same-feature startup did not show pending details'
    Assert (-not (Read-AiSopTask $spec next).followUps) 'New task inherited old follow-ups as its own work'
    $env:CODEX_SESSION_ID='policy-handoff'
    $resumed=Task Resume next @{ConfirmTakeover=$true} | Out-String
    Assert ($resumed -match 'field-doc' -and (Read-AiSopTask $spec next).tier -eq 'T2') 'Handoff omitted earlier deferred work or changed tier'
    Task Run next (@{Kind='compile'} + $check) | Out-Null
    Task Run next (@{Kind='test'} + $check) | Out-Null
    Fails { Task Complete next } 'MISSING_SYNC_REVIEW'
    Task RecordSync next @{ Documentation='UNCHANGED'; Tests='UNCHANGED'; Summary='Independent fix restores specified behavior; existing regression covers it.' } | Out-Null
    Task Complete next | Out-Null
    Assert ((Read-AiSopTask $spec urgent).followUps[0].status -eq 'PENDING') 'T2 completion silently cleared historical follow-ups'

    # Close historical items through the current owner, preserving source task completion.
    Task Start sync @{ Tier='T1'; Objective='Synchronize earlier documentation and tests' } | Out-Null
    Task CloseFollowUp sync @{ SourceTaskId='urgent'; FollowUpId='field-doc'; Resolution='Updated the response section in 06_design_contract.md.' } | Out-Null
    Fails { Task CloseFollowUp sync @{ SourceTaskId='urgent'; FollowUpId='field-test'; Disposition='NOT_NEEDED'; Resolution='Already covered' } } 'userRequest'
    Fails { Task CloseFollowUp sync @{ SourceTaskId='../escape'; FollowUpId='field-test'; Resolution='Wrong path' } } 'TASK_ID_INVALID'
    Task CloseFollowUp sync @{ SourceTaskId='urgent'; FollowUpId='field-test'; Disposition='NOT_NEEDED'; Resolution='Existing test already covers both payload versions.'; UserRequest='This existing test is sufficient; no additional test is needed.' } | Out-Null
    $source=Read-AiSopTask $spec urgent
    Assert ($source.status -eq 'DONE' -and $source.ownerId -eq 'task-urgent') 'Resolving follow-up reopened or reassigned source task'
    Assert ($source.followUps[0].resolvedByTaskId -eq 'sync' -and $source.followUps[1].status -eq 'NOT_NEEDED') 'Resolution audit missing'
    $pending=& $entry -Operation FollowUps -WorkspacePath $workspace | ConvertFrom-Json
    Assert ($pending.count -eq 0 -and -not $pending.blocking) 'Resolved follow-ups still pending'
    Assert ($source.updatedAt -ceq (Read-AiSopTask $spec sync).updatedAt) 'Source resolution and current task checkpoint have different transaction timestamps'
    $cancelled=Task Cancel sync | Out-String
    Assert ($cancelled -match 'FOLLOW_UP_CANCEL_REVIEW' -and $cancelled -match 'field-doc' -and $cancelled -match 'field-test' -and $cancelled -match 'FOLLOW_UP_NON_BLOCKING') 'Cancel hid resolutions made by this task'
    Assert ((Read-AiSopTask $spec sync).status -eq 'CANCELLED' -and (Read-AiSopTask $spec urgent).followUps[0].status -eq 'RESOLVED') 'Cancel blocked or automatically rolled back resolved work'
    Task Start reopen @{Tier='T1';Objective='Reassess the cancelled synchronization'} | Out-Null
    Fails { Task ReopenFollowUp reopen @{SourceTaskId='urgent';FollowUpId='field-doc'} } 'reason'
    Fails { Task ReopenFollowUp reopen @{SourceTaskId='../escape';FollowUpId='field-doc';Reason='Invalid source'} } 'TASK_ID_INVALID'
    Task ReopenFollowUp reopen @{SourceTaskId='urgent';FollowUpId='field-doc';Reason='Documentation edit was reverted after cancellation.'} | Out-Null
    $reopened=Read-AiSopTask $spec urgent
    $item=$reopened.followUps[0]
    Assert ($reopened.status -eq 'DONE' -and $item.status -eq 'PENDING' -and -not $item.resolvedByTaskId -and $item.resolutionHistory[0].resolvedByTaskId -eq 'sync' -and $item.resolutionHistory[0].reopenedByTaskId -eq 'reopen') 'Reopen lost resolution audit or changed source task lifecycle'
    Assert ($reopened.updatedAt -ceq (Read-AiSopTask $spec reopen).updatedAt) 'Reopen did not checkpoint both tasks atomically'
    Task ReopenFollowUp reopen @{SourceTaskId='urgent';FollowUpId='field-doc';Reason='Retry reopening'} | Out-Null
    Assert ((Read-AiSopTask $spec urgent).followUps[0].resolutionHistory.Count -eq 1) 'Retry duplicated reopen history'
    $pending=& $entry -Operation FollowUps -WorkspacePath $workspace | ConvertFrom-Json
    Assert ($pending.count -eq 1 -and -not $pending.blocking) 'Reopened follow-up not visible as non-blocking work'
    Task CloseFollowUp reopen @{SourceTaskId='urgent';FollowUpId='field-doc';Resolution='Restored the documentation edit.'} | Out-Null
    Task ReopenFollowUp reopen @{SourceTaskId='urgent';FollowUpId='field-test';Reason='The existing case omitted an affected behavior.'} | Out-Null
    Assert ((Read-AiSopTask $spec urgent).followUps[1].resolutionHistory[0].userRequest -eq $source.followUps[1].userRequest) 'Reopen discarded NOT_NEEDED authorization'
    Task CloseFollowUp reopen @{SourceTaskId='urgent';FollowUpId='field-test';Resolution='Added the missing regression.'} | Out-Null
    Task Cancel reopen | Out-Null

    # Changing tiers requires explicit authorization text and keeps failed evidence.
    Task Start change @{ Objective='Task with a failing test' } | Out-Null
    Task Run change (@{Kind='compile'} + $check) | Out-Null
    Fails { Task Run change @{Kind='test'; Executable='pwsh'; Arguments=@('-NoProfile','-Command','exit 2')} } 'Task Run failed'
    Fails { Task ChangeTier change @{Tier='T1'; Reason='Urgent'} } 'userRequest'
    Fails { Task SetApplicability change @{Kind='test'; Applicability='NOT_APPLICABLE'; Reason='Environment unavailable'} } 'FAILED_VERIFICATION_NOT_INAPPLICABLE'
    Task ChangeTier change @{Tier='T1'; Reason='User requests a compile-only handoff'; UserRequest='Use T1 now; I will handle the tests separately.'} | Out-Null
    $changed=Read-AiSopTask $spec change
    Assert ($changed.tier -eq 'T1' -and $changed.tierHistory.Count -eq 1 -and $changed.verifications[-1].exitCode -eq 2) 'Tier change erased evidence or lacked audit'
    Task Suspend change | Out-Null
    Fails { Task Resume change @{Tier='T2'} } 'TASK_TIER_CHANGE_REQUIRES_EXPLICIT_OPERATION'
    $env:AI_SESSION_ID='policy-cursor'
    & $entry -Operation Resume -WorkspacePath $workspace -Feature Example -TaskId change -Agent CURSOR -ConfirmTakeover | Out-Null
    $env:CODEX_SESSION_ID='policy-new'
    Task Resume change @{ConfirmTakeover=$true} | Out-Null
    $status=& $entry -Operation Status -OutputFormat JsonLines -WorkspacePath $workspace -Feature Example -TaskId change | ConvertFrom-Json
    Assert ($status.tier -eq 'T1' -and $status.failedVerifications.Count -eq 1) 'Cross-agent handoff lost tier or concealed optional failed tests'
    $verification=Task Verify change | Out-String
    Assert ($verification -match 'UNRESOLVED_OPTIONAL_TEST' -and $verification -match 'VERIFY_COMPLETION_PASS') 'T1 must report unresolved optional tests without pretending they passed'
    Task SetApplicability change @{Kind='test';Applicability='REQUIRED';Reason='User includes this regression in the delivery scope.'} | Out-Null
    Fails { Task Verify change } 'Task Verify failed'
    Task ChangeTier change @{Tier='T2'; Reason='User resumes normal validation'; UserRequest='Return to T2 and finish the related test.'} | Out-Null
    Fails { Task Complete change } 'EXECUTION_FAILED'
    Task Run change (@{Kind='test';Reason='Restore successful fixture command after exercising tier policy with a failure'} + $check) | Out-Null
    Task RecordSync change @{ Documentation='UNCHANGED'; Tests='UNCHANGED'; Summary='Behavior unchanged; regression now passes.' } | Out-Null
    Task Complete change | Out-Null

    # Pure documentation uses explicit applicability, never a fabricated green command.
    Task Start docs @{ Objective='Correct prose' } | Out-Null
    Task SetApplicability docs @{Kind='compile'; Applicability='NOT_APPLICABLE'; Reason='Only prose changed; no build inputs affected.'} | Out-Null
    Task SetApplicability docs @{Kind='test'; Applicability='NOT_APPLICABLE'; Reason='Only spelling changed; no executable behavior affected.'} | Out-Null
    Task RecordSync docs @{Documentation='UPDATED'; Tests='NOT_APPLICABLE'; Summary='Corrected spelling only; no behavior or test definition changes.'} | Out-Null
    Task Verify docs | Out-Null
    $docStatus=& $entry -Operation Status -OutputFormat JsonLines -WorkspacePath $workspace -Feature Example -TaskId docs | ConvertFrom-Json
    Assert ($docStatus.verification -eq 'APPLICABILITY_RECORDED') 'Inapplicable checks were presented as executed evidence'
    [IO.File]::WriteAllText((Join-Path $workspace 'input.txt'), 'changed')
    Fails { Task Verify docs } 'Task Verify failed'
    [IO.File]::WriteAllText((Join-Path $workspace 'input.txt'), 'valid')
    Task ChangeTier docs @{Tier='T3'; Reason='User requests full process'; UserRequest='Use T3 for this task.'} | Out-Null
    Assert (@(Get-AiSopTaskProblems (Read-AiSopTask $spec docs) $workspace $spec) -match 'MISSING_EVIDENCE') 'T3 accepted lightweight applicability exemption'
    Fails { Task SetApplicability docs @{Kind='test'; Applicability='NOT_APPLICABLE'; Reason='No tests'} } 'T3_VERIFICATION_REQUIRED'
    Task Cancel docs | Out-Null

    # Unreadable unrelated reminders are diagnostic, never a startup gate.
    $broken=Join-Path $workspace '.ai-workspace/specs/features/Broken/tasks/old'
    [IO.Directory]::CreateDirectory($broken) | Out-Null
    [IO.File]::WriteAllText((Join-Path $broken 'task.json'), '{broken')
    $warned=Task Start scan @{ Tier='T1'; Objective='Independent task despite an old corrupt reminder' } 3>&1 | Out-String
    Assert ($warned -match 'FOLLOW_UP_SCAN_UNAVAILABLE' -and (Read-AiSopTask $spec scan).status -eq 'ACTIVE') 'Unrelated reminder corruption prevented startup'
    Task Cancel scan | Out-Null
    Remove-Item -LiteralPath (Join-Path $broken 'task.json')
    [IO.Directory]::Delete($broken, $false)

    # The installed root entry forwards policy arguments without changing the default tier.
    $sopRoot=Join-Path $workspace '.ai-sop'
    [IO.Directory]::CreateDirectory($sopRoot) | Out-Null
    Copy-Item -LiteralPath $scripts -Destination $sopRoot -Recurse
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'schemas') -Destination $sopRoot -Recurse
    $rootEntry=Join-Path $workspace 'ai-sop.ps1'
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'distribution/templates/root/ai-sop.ps1') -Destination $rootEntry
    & $rootEntry Task -Operation Start -Feature Example -TaskId root-entry -Objective 'Root CLI forwarding' -Agent CODEX | Out-Null
    Assert ((Read-AiSopTask $spec root-entry).tier -eq 'T2') 'Root entry did not preserve default tier'
    & $rootEntry Task -Operation RecordSync -Feature Example -TaskId root-entry -Agent CODEX -Documentation UNCHANGED -Tests UNCHANGED -Summary 'Existing documents and tests remain correct.' | Out-Null
    & $rootEntry Task -Operation ChangeTier -Feature Example -TaskId root-entry -Agent CODEX -Tier T1 -Reason 'User chooses rapid delivery' -UserRequest 'Use T1' | Out-Null
    & $rootEntry Task -Operation AddFollowUp -Feature Example -TaskId root-entry -Agent CODEX -FollowUpId docs -FollowUpKind documentation -Summary 'Deferred explanation' -Scope @('06#details') | Out-Null
    $rootPending=& $rootEntry Task -Operation FollowUps -Feature Example | ConvertFrom-Json
    Assert ($rootPending.count -eq 1 -and $rootPending.pendingFollowUps[0].id -eq 'docs') 'Root entry lost follow-up arguments'
    & $rootEntry Task -Operation CloseFollowUp -Feature Example -TaskId root-entry -Agent CODEX -FollowUpId docs -Resolution 'Explanation now written in 06#details.' | Out-Null
    & $rootEntry Task -Operation SetApplicability -Feature Example -TaskId root-entry -Agent CODEX -Kind compile -Applicability NOT_APPLICABLE -Reason 'Only explanatory prose changed.' | Out-Null
    & $rootEntry Task -Operation Complete -Feature Example -TaskId root-entry -Agent CODEX | Out-Null
    Assert ((Read-AiSopTask $spec root-entry).status -eq 'DONE') 'Root policy workflow failed'

    # Recovery of a partial multi-task checkpoint preserves both sides of a resolution.
    $sourcePath=Get-AiSopTaskPath $spec urgent
    $currentPath=Get-AiSopTaskPath $spec root-entry
    foreach ($phase in @('PREPARED','COMMITTED')) {
        $sourceBefore=Read-AiSopWorkflowCanonicalState $sourcePath TASK
        $currentBefore=Read-AiSopWorkflowCanonicalState $currentPath TASK
        $sourceAfter=ConvertFrom-AiSopWorkflowJson $sourceBefore -AsHashtable
        $sourceAfter.followUps[0].resolution="Resolution recovered from $phase"
        $currentAfter=ConvertFrom-AiSopWorkflowJson $currentBefore -AsHashtable
        $currentAfter.notes="Resolving task checkpoint $phase"
        $sourceAfterJson=ConvertTo-AiSopWorkflowCanonicalJson $sourceAfter
        $currentAfterJson=ConvertTo-AiSopWorkflowCanonicalJson $currentAfter
        $journal=@{
            schemaVersion='1.0';transactionId="policy-$phase";operation='CHECKPOINT';phase=$phase;feature='Example'
            ownerPath=(Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json');sessionKeys=@();createdAt=[DateTimeOffset]::UtcNow.ToString('o')
            committedAt=$(if ($phase -eq 'COMMITTED') { [DateTimeOffset]::UtcNow.ToString('o') } else { '' })
            targets=@(
                @{path=$sourcePath;kind='TASK';schemaId='TASK';before=(New-AiSopWorkflowSnapshot $true $sourceBefore);after=(New-AiSopWorkflowSnapshot $true $sourceAfterJson)},
                @{path=$currentPath;kind='TASK';schemaId='TASK';before=(New-AiSopWorkflowSnapshot $true $currentBefore);after=(New-AiSopWorkflowSnapshot $true $currentAfterJson)}
            )
        }
        Write-AiSopWorkflowTransactionJournal -JournalPath (Join-Path $env:AI_SOP_TRANSACTION_REGISTRY "policy-$phase.json") -Journal $journal
        [IO.File]::WriteAllText($sourcePath,$sourceAfterJson)
        Invoke-AiSopWorkflowTransactionRecovery -WorkspacePath $workspace | Out-Null
        Assert ((Read-AiSopWorkflowCanonicalState $sourcePath TASK) -ceq $(if ($phase -eq 'COMMITTED') { $sourceAfterJson } else { $sourceBefore })) 'Source follow-up recovery diverged'
        Assert ((Read-AiSopWorkflowCanonicalState $currentPath TASK) -ceq $(if ($phase -eq 'COMMITTED') { $currentAfterJson } else { $currentBefore })) 'Resolving task recovery diverged'
    }
    Write-Output 'PASS: task tiers, synchronization, non-blocking follow-ups, cross-agent continuity, and applicability'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
