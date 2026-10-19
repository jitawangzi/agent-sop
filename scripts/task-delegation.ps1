#requires -Version 7.0

# 委派只授予执行权；任务归属始终保留在父会话。
function Test-AiSopExecutionDelegate {
    param($Owner, $Session, [DateTimeOffset]$At = [DateTimeOffset]::UtcNow)
    if ($Session -isnot [Collections.IDictionary]) { $Session=ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $Session) -AsHashtable }
    $d = $Owner.executionDelegation
    return ($null -ne $d -and $d.status -ceq 'ACTIVE' -and $Owner.status -ceq 'ACTIVE' -and
        $d.taskId -ceq $Owner.taskId -and $d.parentSessionKey -ceq $Owner.sessionBinding.sessionKey -and
        $d.parentSessionEpochId -ceq $Owner.sessionBinding.sessionEpochId -and
        $d.sessionKey -ceq $Session.sessionKey -and $d.sessionEpochId -ceq $Session.sessionEpochId -and
        $At -lt [DateTimeOffset]::Parse($d.expiresAt) -and $Session.agent -ceq $Owner.agent -and
        $Session.boundFeature -ceq $Owner.feature -and $Session.boundOwnerId -ceq $Owner.ownerId -and
        $Session.boundWorkflow -ceq 'SUPERPOWERS' -and $Session.boundSessionEpochId -ceq $Session.sessionEpochId -and
        $Session.lifecycleProof -ceq 'CONFIRMED' -and
        (Get-AiSopWorkflowSessionEffectiveStatus $Session $At) -ceq 'ACTIVE')
}

function Assert-AiSopDelegationParent {
    param($Owner, $Parent, [DateTimeOffset]$At = [DateTimeOffset]::UtcNow)
    if ($Parent -isnot [Collections.IDictionary]) { $Parent=ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $Parent) -AsHashtable }
    if ($Parent.sessionKey -cne $Owner.sessionBinding.sessionKey -or
        $Parent.sessionEpochId -cne $Owner.sessionBinding.sessionEpochId -or
        $Parent.agent -cne $Owner.agent -or
        (Resolve-PhysicalPathIdentity $Parent.workspacePath) -cne (Resolve-PhysicalPathIdentity $Owner.workspacePath) -or
        $Parent.boundWorkflow -cne 'SUPERPOWERS' -or $Parent.endedAt -or
        $Parent.boundOwnerId -cne $Owner.ownerId -or $Parent.boundFeature -cne $Owner.feature -or
        $Parent.boundSessionEpochId -cne $Parent.sessionEpochId -or $Parent.lifecycleProof -cne 'CONFIRMED' -or
        $Parent.status -notin @('ACTIVE','IDLE')) {
        throw 'DELEGATION_PARENT_INACTIVE'
    }
}

function Get-AiSopExecutionBinding {
    param($Owner, $Session, [DateTimeOffset]$At = [DateTimeOffset]::UtcNow)
    if (Test-AiSopExecutionDelegate $Owner $Session $At) { return $Owner.executionDelegation }
    if ($Owner.sessionBinding.sessionKey -cne $Session.sessionKey -or
        $Owner.sessionBinding.sessionEpochId -cne $Session.sessionEpochId) { throw 'WORKFLOW_OWNER_SESSION_MISMATCH' }
    if ($Owner.executionDelegation.status -ceq 'ACTIVE') { throw 'TASK_EXECUTION_DELEGATED' }
    return $Owner.sessionBinding
}
