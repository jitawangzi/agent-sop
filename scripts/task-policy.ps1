#requires -Version 7.0
# Task policy metadata is changed by the owner Checkpoint transaction only.

function Assert-AiSopInitialTaskTier {
    param([string]$Tier, [string]$UserRequest)
    if ($Tier -notin @('T1','T2','T3')) { throw 'TASK_TIER_INVALID' }
    if ($Tier -ne 'T2' -and [string]::IsNullOrWhiteSpace($UserRequest)) {
        throw 'TASK_TIER_USER_REQUEST_REQUIRED: new T1/T3 tasks require -UserRequest with the human tier selection; omit Tier to use default T2'
    }
}

function New-AiSopTaskTierSelection {
    param([string]$Tier, [string]$UserRequest, [string]$At, [switch]$Legacy)
    # 原话由调用方记录，用于追溯选择依据，不代表独立的人类身份认证。
    if ($Legacy) { return @{ tier=$Tier; source='LEGACY_PRESERVED'; recordedAt=$At } }
    Assert-AiSopInitialTaskTier $Tier $UserRequest
    $selection=@{ tier=$Tier; source='DEFAULT'; recordedAt=$At }
    if (-not [string]::IsNullOrWhiteSpace($UserRequest)) {
        $selection.source='USER_REQUEST'; $selection.userRequest=$UserRequest
    }
    return $selection
}

function Update-AiSopTaskPolicy {
    param($Task, $Update, [string]$SpecDirectory, [string]$WorkspacePath, [string]$At)
    if ($Update.operation -in @('ChangeTier','SetApplicability','SetBaseline','SetCaseScope') -and @($Task.verifications | Where-Object { $_.outcome -eq 'RUNNING' }).Count) {
        throw 'RUN_UNFINISHED: finish or recover execution before changing verification requirements'
    }
    $allowed = switch ($Update.operation) {
        'SetCaseScope' { @('operation','caseIds','reason') }
        'SetBaseline' { @('operation','inputsRef','reason') }
        'ChangeTier' { @('operation','tier','reason','userRequest') }
        'RecordSync' { @('operation','documentation','tests','summary') }
        'SetApplicability' { @('operation','kind','status','reason') }
        'AddFollowUp' { @('operation','id','kind','summary','scope') }
        'CloseFollowUp' { @('operation','sourceTaskId','id','status','resolution','userRequest') }
        'ReopenFollowUp' { @('operation','sourceTaskId','id','reason') }
        default { throw 'TASK_UPDATE_OPERATION_INVALID' }
    }
    foreach ($key in $Update.Keys) { if ($key -notin $allowed) { throw "TASK_UPDATE_FIELD_INVALID:$key" } }
    function Require-Text([string]$Value, [string]$Name) {
        if ([string]::IsNullOrWhiteSpace($Value)) { throw "TASK_UPDATE_REQUIRED:$Name" }
    }
    switch ($Update.operation) {
        'SetCaseScope' { Set-AiSopTaskCaseScope $Task @($Update.caseIds) $Update.reason $SpecDirectory $At }
        'SetBaseline' {
            Require-Text $Update.reason 'reason'
            Set-AiSopTaskStartBaseline $Task $WorkspacePath $Update.inputsRef $Update.reason
        }
        'ChangeTier'  {
            if ($Update.tier -notin @('T1','T2','T3')) { throw 'TASK_TIER_INVALID' }
            Require-Text $Update.reason 'reason'
            Require-Text $Update.userRequest 'userRequest'
            if ($Task.tier -ceq $Update.tier) { return }
            if ($Update.tier -eq 'T3') {
                if (-not $Task.baseline.inputsRef) {
                    Set-AiSopTaskStartBaseline $Task $WorkspacePath $Task.startInputs.inputsRef 'Reuse the original task Start snapshot on explicit tier change'
                } else {
                    # Old manually adopted baselines must not move a light task
                    # into T3 only to fail provenance checks at completion.
                    Read-AiSopTaskBaselineInputs $Task $WorkspacePath | Out-Null
                }
            }
            $Task['tierHistory'] = @($Task.tierHistory | Where-Object { $null -ne $_ }) + @(@{
                from=$Task.tier; to=$Update.tier; reason=$Update.reason; userRequest=$Update.userRequest; changedAt=$At
            })
            $Task.tier = $Update.tier
            # Retain every run, review and follow-up. A tier change is not a pass.
        }
        'RecordSync' {
            if ($Update.documentation -notin @('UPDATED','UNCHANGED') -or $Update.tests -notin @('UPDATED','UNCHANGED','NOT_APPLICABLE')) { throw 'SYNC_REVIEW_INVALID' }
            Require-Text $Update.summary 'summary'
            $Task['syncReview'] = @{ documentation=$Update.documentation; tests=$Update.tests; summary=$Update.summary; recordedAt=$At }
        }
        'SetApplicability' {
            if ($Update.kind -notin @('compile','test') -or $Update.status -notin @('REQUIRED','NOT_APPLICABLE')) { throw 'APPLICABILITY_INVALID' }
            Require-Text $Update.reason 'reason'
            if ($Update.status -eq 'NOT_APPLICABLE') {
                if ($Task.tier -eq 'T3') { throw 'T3_VERIFICATION_REQUIRED' }
                $latest = @($Task.verifications | Where-Object { $_.kind -eq $Update.kind } | Group-Object batch | ForEach-Object { @($_.Group)[-1] })
                if (@($latest | Where-Object { $_.exitCode -ne 0 -or -not $_.inputsStable }).Count) { throw 'FAILED_VERIFICATION_NOT_INAPPLICABLE' }
                $snapshot=Assert-AiSopApplicabilityScope $Task $WorkspacePath
            } else {
                $snapshot=Get-AiSopInputSnapshot $WorkspacePath
            }
            if (-not $Task.applicability) { $Task['applicability'] = @{} }
            $Task.applicability[$Update.kind] = @{
                status=$Update.status; reason=$Update.reason; recordedAt=$At; inputDigest=$snapshot.digest
            }
            if ($Update.status -eq 'NOT_APPLICABLE') { $Task.applicability[$Update.kind].startInputsRef=$Task.startInputs.inputsRef }
        }
        'AddFollowUp' {
            Require-Text $Update.id 'id'
            Require-Text $Update.summary 'summary'
            if ($Update.kind -notin @('documentation','test-cases','verification')) { throw 'FOLLOW_UP_KIND_INVALID' }
            if (-not @($Update.scope).Count) { throw 'FOLLOW_UP_SCOPE_REQUIRED' }
            foreach ($scope in $Update.scope) { Require-Text $scope 'scope' }
            $existing = @($Task.followUps | Where-Object { $_.id -ceq $Update.id })
            if ($existing.Count) {
                if ($existing.Count -ne 1 -or $existing[0].kind -cne $Update.kind -or $existing[0].summary -cne $Update.summary -or
                    (ConvertTo-AiSopWorkflowCanonicalJson @($existing[0].scope)) -cne (ConvertTo-AiSopWorkflowCanonicalJson @($Update.scope))) { throw 'FOLLOW_UP_ID_CONFLICT' }
                return
            }
            $Task['followUps'] = @($Task.followUps | Where-Object { $null -ne $_ }) + @(@{
                id=$Update.id; kind=$Update.kind; summary=$Update.summary; scope=@($Update.scope); status='PENDING'; createdAt=$At
            })
        }
        { $_ -in @('CloseFollowUp','ReopenFollowUp') } {
            Require-Text $Update.id 'id'
            if ($Update.operation -eq 'ReopenFollowUp') { Require-Text $Update.reason 'reason' }
            else {
                Require-Text $Update.resolution 'resolution'
                if ($Update.status -notin @('RESOLVED','NOT_NEEDED')) { throw 'FOLLOW_UP_DISPOSITION_INVALID' }
                if ($Update.status -eq 'NOT_NEEDED') { Require-Text $Update.userRequest 'userRequest' }
            }
            $sourceId = if ($Update.sourceTaskId) { [string]$Update.sourceTaskId } else { [string]$Task.taskId }
            $sourceBefore = $null
            $source = $Task
            if ($sourceId -cne $Task.taskId) {
                $sourceBefore = Read-AiSopTask $SpecDirectory $sourceId
                if ($sourceBefore.status -eq 'ACTIVE') { throw 'FOLLOW_UP_SOURCE_ACTIVE' }
                $source = ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $sourceBefore) -AsHashtable
            }
            $items = @($source.followUps | Where-Object { $_.id -ceq $Update.id })
            if ($items.Count -ne 1) { throw 'FOLLOW_UP_NOT_FOUND' }
            $item = $items[0]
            if ($Update.operation -eq 'ReopenFollowUp') {
                if ($item.status -eq 'PENDING') { return }
                $history=@{status=$item.status;resolution=$item.resolution;resolvedAt=$item.resolvedAt;resolvedByTaskId=$item.resolvedByTaskId;reopenedAt=$At;reopenedByTaskId=$Task.taskId;reason=$Update.reason}
                if ($item.userRequest) { $history.userRequest=$item.userRequest }
                $item['resolutionHistory']=@($item.resolutionHistory | Where-Object { $null -ne $_ }) + @($history)
                $item.status='PENDING'
                foreach ($key in @('resolution','resolvedAt','resolvedByTaskId','userRequest')) { $item.Remove($key) }
            } else {
                if ($item.status -ne 'PENDING') {
                    if ($item.status -ceq $Update.status -and $item.resolution -ceq $Update.resolution) { return }
                    throw 'FOLLOW_UP_ALREADY_CLOSED'
                }
                $item.status=$Update.status; $item['resolution']=$Update.resolution; $item['resolvedAt']=$At; $item['resolvedByTaskId']=$Task.taskId
                if ($Update.userRequest) { $item['userRequest']=$Update.userRequest }
            }
            $source.updatedAt=$At
            if ($sourceBefore) {
                return @{ path=(Get-AiSopTaskPath $SpecDirectory $sourceId); before=$sourceBefore; after=$source }
            }
        }
    }
}

function Write-AiSopCancelledFollowUpReminder {
    param([string]$SpecDirectory, [string]$TaskId)
    # Cancellation releases ownership; it does not undo completed edits. This
    # advisory runs only after commit and must never turn Cancel into a failure.
    $count=0
    foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $SpecDirectory 'tasks') -Directory -ErrorAction SilentlyContinue)) {
        try {
            $source=Read-AiSopTask $SpecDirectory $entry.Name
            foreach ($item in @($source.followUps | Where-Object { $_.status -in @('RESOLVED','NOT_NEEDED') -and $_.resolvedByTaskId -ceq $TaskId })) {
                $count++
                Write-Output ("FOLLOW_UP_CANCEL_REVIEW: " + (@{sourceTaskId=$source.taskId;id=$item.id;status=$item.status;resolution=$item.resolution;resolvedByTaskId=$TaskId} | ConvertTo-Json -Compress))
            }
        } catch { Write-Warning "FOLLOW_UP_SCAN_UNAVAILABLE:$($entry.Name):$($_.Exception.Message)" -WarningAction Continue }
    }
    if ($count) { Write-Output 'FOLLOW_UP_NON_BLOCKING: Cancel preserved these resolutions. If the work was undone or incomplete, use ReopenFollowUp from a subsequent active task with SourceTaskId, FollowUpId and Reason.' }
}

function Get-AiSopPendingFollowUps {
    param([string]$WorkspacePath)
    $root = Resolve-PhysicalPathIdentity (Join-Path $WorkspacePath '.ai-workspace/specs/features')
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $dir.FullName 'tasks') -Directory -ErrorAction SilentlyContinue)) {
            try {
                # Physical containment is also checked by Read-AiSopTask.
                $physical = Resolve-PhysicalPathIdentity $dir.FullName
                if ((Split-Path -Parent $physical) -cne $root) { throw 'FEATURE_PATH_ESCAPE' }
                $task = Read-AiSopTask $physical $entry.Name
                foreach ($item in @($task.followUps | Where-Object { $_.status -eq 'PENDING' })) {
                    [ordered]@{ feature=$task.feature; taskId=$task.taskId; taskStatus=$task.status; id=$item.id; kind=$item.kind; summary=$item.summary; scope=$item.scope; createdAt=$item.createdAt }
                }
            } catch {
                # Reminder failure must never prevent an unrelated task starting.
                Write-Warning "FOLLOW_UP_SCAN_UNAVAILABLE:$($dir.Name)/$($entry.Name):$($_.Exception.Message)" -WarningAction Continue
            }
        }
    }
}

function Write-AiSopFollowUpReminder {
    param([string]$WorkspacePath, [string]$Feature)
    try {
        $items = @(Get-AiSopPendingFollowUps $WorkspacePath)
        foreach ($item in @($items | Where-Object { $_.feature -ceq $Feature })) {
            Write-Output ("FOLLOW_UP_REMINDER: " + ($item | ConvertTo-Json -Depth 6 -Compress))
        }
        $others = @($items | Where-Object { $_.feature -cne $Feature })
        if ($others.Count) { Write-Output "FOLLOW_UP_OTHER_FEATURES: $($others.Count) pending item(s) in this workspace; use Task FollowUps for details." }
        if ($items.Count) { Write-Output 'FOLLOW_UP_NON_BLOCKING: continue this task; do not add work or request acknowledgement solely for this reminder.' }
    } catch { Write-Warning "FOLLOW_UP_SCAN_UNAVAILABLE:$($_.Exception.Message)" -WarningAction Continue }
}
