[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "workflow-state.ps1"
$OwnerScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "workflow-owner.ps1"
$SessionScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "workflow-session.ps1"
$GrantScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "workflow-command-grant.ps1"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("workflow-state-tests-" + [guid]::NewGuid().ToString("N"))
$FeatureRoot = Join-Path $TestRoot ".ai-workspace\specs\features\Example"
$ApprovalPath = Join-Path $FeatureRoot "00_workflow_state.json"
$RuntimePath = Join-Path $TestRoot "runtime.json"
$HandoffPath = Join-Path $TestRoot "handoff.json"
$RequirementPath = Join-Path $FeatureRoot "01_server_rules.md"
$DesignPath = Join-Path $FeatureRoot "06_design_contract.md"
$TestPlanPath = Join-Path $FeatureRoot "05_test_plan.md"
$CoveragePath = Join-Path $FeatureRoot "05_test_coverage.json"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$env:SERVER_NEW_WORKFLOW_REGISTRY = Join-Path $TestRoot "owner-registry"
[System.IO.Directory]::CreateDirectory((Join-Path $TestRoot "build/classes")) | Out-Null
$env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = Join-Path $TestRoot "session-registry"
$env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY = Join-Path $TestRoot "grant-registry"
$env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY = Join-Path $TestRoot "transaction-registry"
$env:SERVER_NEW_WORKFLOW_OWNER_WORKFLOW = "CUSTOM_SKILLS"
$env:SERVER_NEW_WORKFLOW_OWNER_AGENT = "COPILOT"
$env:SERVER_NEW_WORKFLOW_OWNER_ID = "feature-run"
$env:AI_SOP_WORKFLOW_DEADLINE_MS = "10000"
$env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS = "10000"
$env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS = "10000"
. $SessionScriptPath
. $GrantScriptPath

function Get-TestArtifactHash {
    # Mirror of Get-AiSopArtifactHash in workflow-state.ps1: normalize CRLF->LF,
    # strip trailing whitespace per line, ensure single final newline.
    # JSON files keep raw-byte hashing.
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    if ($ext -ieq ".json") {
        return (Get-TestArtifactHash -Path $Path)
    }
    $raw = [System.IO.File]::ReadAllText($Path)
    $normalized = $raw -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    $normalized = $normalized -replace "[ \t]+`n", "`n"
    $normalized = $normalized.TrimEnd() + "`n"
    $enc = [System.Text.UTF8Encoding]::new($false)
    $bytes = $enc.GetBytes($normalized)
    return (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($bytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TestStringSha256 {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $hasher.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant())
    } finally {
        $hasher.Dispose()
    }
}

function Write-TestJson {
    param(
        [string]$Path,
        [object]$Value
    )

    [System.IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        $Utf8NoBom
    )
}

function New-TestOwnerCommand {
    param(
        [string]$Operation,
        [string]$Feature,
        [string]$Agent,
        [string]$OwnerId
    )

    return (
        "pwsh -NoProfile -File '.\.ai-sop\scripts\workflow-owner.ps1' " +
        "-Operation '$Operation' " +
        "-SpecDirectory '.ai-workspace\specs\features\$Feature' " +
        "-Feature '$Feature' -Workflow 'SUPERPOWERS' " +
        "-Agent '$Agent' -OwnerId '$OwnerId'"
    )
}

function New-TestSuperpowersOwner {
    param(
        [string]$Feature,
        [string]$SpecDirectory,
        [string]$Agent,
        [string]$OwnerId
    )

    $workspace = Split-Path -Parent (
        Split-Path -Parent (
            Split-Path -Parent (
                Split-Path -Parent $SpecDirectory
            )
        )
    )
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $workspace ".ai-sop\scripts")
    ) | Out-Null
    $sessionAcceptedAt = [DateTimeOffset]::UtcNow
    $session = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent $Agent `
        -NativeSessionId "workflow-state-$Feature-$Agent" `
        -WorkspacePath $workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $sessionAcceptedAt
    if (
        [string]$session.Record.stateChangedAt -cne
        $sessionAcceptedAt.ToUniversalTime().ToString("o")
    ) {
        throw "Workflow-state session fixture did not initialize stateChangedAt."
    }
    Invoke-AiSopWorkflowCommandGrant `
        -Operation Issue `
        -CommandText (New-TestOwnerCommand `
            -Operation Claim `
            -Feature $Feature `
            -Agent $Agent `
            -OwnerId $OwnerId) `
        -SessionKey $session.Record.sessionKey `
        -SessionEpochId $session.Record.sessionEpochId `
        -DedupKey (Get-AiSopWorkflowSha256 "state-$Feature-$Agent-claim") `
        -AcceptedAt ([DateTimeOffset]::UtcNow) `
        -TransactionId "state-$Feature-$Agent-claim" |
        Out-Null
    & $OwnerScriptPath -Operation Claim -SpecDirectory $SpecDirectory `
        -Feature $Feature -Workflow SUPERPOWERS -Agent $Agent `
        -OwnerId $OwnerId |
        Out-Null
    return $session
}

function Complete-TestSuperpowersOwner {
    param(
        [string]$Feature,
        [string]$SpecDirectory,
        [string]$Agent,
        [string]$OwnerId,
        [object]$Session
    )

    $currentSession = Get-AiSopWorkflowSession `
        -SessionKey $Session.Record.sessionKey
    Invoke-AiSopWorkflowCommandGrant `
        -Operation Issue `
        -CommandText (New-TestOwnerCommand `
            -Operation Complete `
            -Feature $Feature `
            -Agent $Agent `
            -OwnerId $OwnerId) `
        -SessionKey $currentSession.Record.sessionKey `
        -SessionEpochId $currentSession.Record.sessionEpochId `
        -DedupKey (Get-AiSopWorkflowSha256 "state-$Feature-$Agent-complete") `
        -AcceptedAt ([DateTimeOffset]::UtcNow) `
        -TransactionId "state-$Feature-$Agent-complete" |
        Out-Null
    try {
        $env:AI_SOP_SKIP_COMPLETION_VERIFY = "1"
        & $OwnerScriptPath -Operation Complete -SpecDirectory $SpecDirectory `
            -Feature $Feature -Workflow SUPERPOWERS -Agent $Agent `
            -OwnerId $OwnerId |
            Out-Null
    } finally {
        Remove-Item Env:AI_SOP_SKIP_COMPLETION_VERIFY -ErrorAction SilentlyContinue
    }
}

function Write-TestLegacyOwner {
    param(
        [string]$Feature,
        [string]$SpecDirectory,
        [string]$Workflow,
        [string]$Agent,
        [string]$OwnerId
    )

    [System.IO.Directory]::CreateDirectory($SpecDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($env:SERVER_NEW_WORKFLOW_REGISTRY) |
        Out-Null
    Write-TestJson `
        -Path (Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY (
            $Feature.ToLowerInvariant() + ".json"
        )) `
        -Value ([ordered]@{
            schemaVersion = "1.0"
            feature = $Feature
            workflow = $Workflow
            agent = $Agent
            ownerId = $OwnerId
            specDirectory = [System.IO.Path]::GetFullPath($SpecDirectory)
            baseline = "0"
            status = "ACTIVE"
            startedAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString("o")
            completedAt = ""
        })
}

function Assert-Fails {
    param(
        [scriptblock]$Action,
        [string]$Message
    )

    $failed = $false
    try {
        & $Action | Out-Null
    } catch {
        $failed = $true
    }
    if (-not $failed) {
        throw "Expected failure: $Message"
    }
}

function Assert-FailsWithMessageAndState {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage,
        [string]$StatePath,
        [string]$Message,
        [string[]]$AbsentPaths = @()
    )

    $beforeState = [System.IO.File]::ReadAllText($StatePath)
    $failed = $false
    try {
        & $Action | Out-Null
    } catch {
        $failed = $true
        if (-not $_.Exception.Message.Contains($ExpectedMessage, [System.StringComparison]::Ordinal)) {
            throw "Expected error containing '$ExpectedMessage' for '$Message', actual: $($_.Exception.Message)"
        }
    }
    if (-not $failed) {
        throw "Expected failure: $Message"
    }

    $afterState = [System.IO.File]::ReadAllText($StatePath)
    if ($afterState -cne $beforeState) {
        throw "Failure changed approval state: $Message"
    }
    foreach ($absentPath in $AbsentPaths) {
        if (Test-Path -LiteralPath $absentPath) {
            throw "Failure created an unexpected side-effect file '$absentPath': $Message"
        }
    }
}

function Assert-ApprovalGateFields {
    param(
        [string]$StatePath,
        [ValidateSet("requirement", "design")]
        [string]$GateName,
        [string]$Status,
        [string]$Sha256,
        [object]$ApprovedAt,
        [string]$ApprovedBy
    )

    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $gate = $state.$GateName
    if (
        $gate.status -cne $Status -or
        $gate.sha256 -cne $Sha256 -or
        $gate.approvedAt -cne $ApprovedAt -or
        $gate.approvedBy -cne $ApprovedBy
    ) {
        throw (
            "Unexpected $GateName approval fields. " +
            "Expected=[$Status,$Sha256,$ApprovedAt,$ApprovedBy]; " +
            "Actual=[$($gate.status),$($gate.sha256),$($gate.approvedAt),$($gate.approvedBy)]"
        )
    }
}

function Assert-SuperpowersMutationAccepted {
    param(
        [string]$Agent
    )

    $feature = "Mutation" + ($Agent -replace "_", "")
    $specDirectory = Join-Path $TestRoot ".ai-workspace\specs\features\$feature"
    $approvalPath = Join-Path $specDirectory "00_workflow_state.json"
    $ownerId = "mutation-$($Agent.ToLowerInvariant())"
    $session = New-TestSuperpowersOwner `
        -Feature $feature `
        -SpecDirectory $specDirectory `
        -Agent $Agent `
        -OwnerId $ownerId
    try {
        & $ScriptPath -Operation InitApproval -Path $approvalPath -Feature $feature `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId | Out-Null
        & $ScriptPath -Operation ValidateApproval -Path $approvalPath | Out-Null
    } finally {
        Complete-TestSuperpowersOwner `
            -Feature $feature `
            -SpecDirectory $specDirectory `
            -Agent $Agent `
            -OwnerId $ownerId `
            -Session $session
    }
}

function Assert-NoRuntimeApprovalAccepted {
    param(
        [string]$Agent
    )

    $feature = "NoRuntimeApproval" + ($Agent -replace "_", "")
    $specDirectory = Join-Path $TestRoot ".ai-workspace\specs\features\$feature"
    $approvalPath = Join-Path $specDirectory "00_workflow_state.json"
    $requirementPath = Join-Path $specDirectory "01_server_rules.md"
    $designPath = Join-Path $specDirectory "06_design_contract.md"
    $runtimePath = Join-Path $specDirectory "00_runtime.json"
    $handoffPath = Join-Path $specDirectory "handoff.json"
    $ownerId = "approval-$($Agent.ToLowerInvariant())"
    $session = New-TestSuperpowersOwner `
        -Feature $feature `
        -SpecDirectory $specDirectory `
        -Agent $Agent `
        -OwnerId $ownerId
    try {
        [System.IO.File]::WriteAllText($requirementPath, "# Rules`n- BR-APPROVAL requirement", $Utf8NoBom)
        [System.IO.File]::WriteAllText($designPath, "# Design`n- DC-APPROVAL design", $Utf8NoBom)
        & $ScriptPath -Operation InitApproval -Path $approvalPath -Feature $feature `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId | Out-Null

        Assert-FailsWithMessageAndState `
            -ExpectedMessage "Requirement approval is required before design approval." `
            -StatePath $approvalPath `
            -AbsentPaths @($runtimePath, $handoffPath) `
            -Message "Design approval requires an approved requirement for $Agent." `
            -Action {
            & $ScriptPath -Operation Approve -Path $approvalPath `
                -Gate design -ApprovedBy "human:test" `
                -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId
        }
        Assert-FailsWithMessageAndState `
            -ExpectedMessage "JSON file does not exist: $runtimePath" `
            -StatePath $approvalPath `
            -AbsentPaths @($runtimePath, $handoffPath) `
            -Message "An explicit bad RuntimePath cannot fall back to stateless approval for $Agent." `
            -Action {
            & $ScriptPath -Operation Approve -Path $approvalPath -RuntimePath $runtimePath `
                -Gate requirement -ApprovedBy "human:test" `
                -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId
        }
        foreach ($invalidRuntime in @(
            [pscustomobject]@{ name = "null"; value = $null },
            [pscustomobject]@{ name = "empty"; value = "" },
            [pscustomobject]@{ name = "whitespace"; value = "   " }
        )) {
            Assert-FailsWithMessageAndState `
                -ExpectedMessage "Missing required argument: -RuntimePath" `
                -StatePath $approvalPath `
                -AbsentPaths @($runtimePath, $handoffPath) `
                -Message "Explicit $($invalidRuntime.name) RuntimePath must retain legacy failure semantics for $Agent." `
                -Action {
                & $ScriptPath -Operation Approve -Path $approvalPath -RuntimePath $invalidRuntime.value `
                    -Gate requirement -ApprovedBy "human:test" `
                    -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId
            }
            Assert-ApprovalGateFields -StatePath $approvalPath -GateName requirement `
                -Status DRAFT -Sha256 "" -ApprovedAt "" -ApprovedBy ""
            Assert-ApprovalGateFields -StatePath $approvalPath -GateName design `
                -Status DRAFT -Sha256 "" -ApprovedAt "" -ApprovedBy ""
        }
        Assert-FailsWithMessageAndState `
            -ExpectedMessage "Workflow owner identity does not match the active claim." `
            -StatePath $approvalPath `
            -AbsentPaths @($runtimePath, $handoffPath) `
            -Message "No-runtime approval requires the exact owner tuple for $Agent." `
            -Action {
            & $ScriptPath -Operation Approve -Path $approvalPath `
                -Gate requirement -ApprovedBy "human:test" `
                -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId "$ownerId-wrong"
        }

        & $ScriptPath -Operation Approve -Path $approvalPath `
            -Gate requirement -ApprovedBy "human:test" `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId | Out-Null
        $approval = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
        $requirementHash = (Get-TestArtifactHash -Path $requirementPath)
        if (
            $approval.requirement.status -ne "APPROVED" -or
            $approval.requirement.sha256 -ne $requirementHash
        ) {
            throw "No-runtime requirement approval did not record the current artifact hash for $Agent."
        }
        $approvedRequirementState = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
        $originalRequirement = [System.IO.File]::ReadAllText($requirementPath)
        [System.IO.File]::AppendAllText($requirementPath, "`nChanged after requirement approval.", $Utf8NoBom)
        Assert-FailsWithMessageAndState `
            -ExpectedMessage "Approved requirement artifact hash does not match:" `
            -StatePath $approvalPath `
            -AbsentPaths @($runtimePath, $handoffPath) `
            -Message "Requirement artifact drift must block no-runtime design approval for $Agent." `
            -Action {
            & $ScriptPath -Operation Approve -Path $approvalPath `
                -Gate design -ApprovedBy "human:test" `
                -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId
        }
        [System.IO.File]::WriteAllText($requirementPath, $originalRequirement, $Utf8NoBom)
        Assert-ApprovalGateFields -StatePath $approvalPath -GateName requirement `
            -Status APPROVED `
            -Sha256 $approvedRequirementState.requirement.sha256 `
            -ApprovedAt $approvedRequirementState.requirement.approvedAt `
            -ApprovedBy $approvedRequirementState.requirement.approvedBy
        Assert-ApprovalGateFields -StatePath $approvalPath -GateName design `
            -Status DRAFT -Sha256 "" -ApprovedAt "" -ApprovedBy ""
        if (
            (Test-Path -LiteralPath $runtimePath) -or
            (Test-Path -LiteralPath $handoffPath)
        ) {
            throw "No-runtime requirement approval created a runtime or Handoff file for $Agent."
        }

        & $ScriptPath -Operation Approve -Path $approvalPath `
            -Gate design -ApprovedBy "human:test" `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId | Out-Null
        $approval = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
        $designHash = (Get-TestArtifactHash -Path $designPath)
        if (
            $approval.design.status -ne "APPROVED" -or
            $approval.design.sha256 -ne $designHash
        ) {
            throw "No-runtime design approval did not record the current artifact hash for $Agent."
        }
        if (
            (Test-Path -LiteralPath $runtimePath) -or
            (Test-Path -LiteralPath $handoffPath)
        ) {
            throw "No-runtime design approval created a runtime or Handoff file for $Agent."
        }

        $fullyApproved = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
        & $ScriptPath -Operation ResetApproval -Path $approvalPath -Gate design `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId | Out-Null
        Assert-ApprovalGateFields -StatePath $approvalPath -GateName requirement `
            -Status APPROVED `
            -Sha256 $fullyApproved.requirement.sha256 `
            -ApprovedAt $fullyApproved.requirement.approvedAt `
            -ApprovedBy $fullyApproved.requirement.approvedBy
        Assert-ApprovalGateFields -StatePath $approvalPath -GateName design `
            -Status DRAFT -Sha256 "" -ApprovedAt "" -ApprovedBy ""

        & $ScriptPath -Operation Approve -Path $approvalPath `
            -Gate design -ApprovedBy "human:test" `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId | Out-Null
        & $ScriptPath -Operation ResetApproval -Path $approvalPath -Gate requirement `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent $Agent -OwnerId $ownerId | Out-Null
        Assert-ApprovalGateFields -StatePath $approvalPath -GateName requirement `
            -Status DRAFT -Sha256 "" -ApprovedAt "" -ApprovedBy ""
        Assert-ApprovalGateFields -StatePath $approvalPath -GateName design `
            -Status DRAFT -Sha256 "" -ApprovedAt "" -ApprovedBy ""
    } finally {
        Complete-TestSuperpowersOwner `
            -Feature $feature `
            -SpecDirectory $specDirectory `
            -Agent $Agent `
            -OwnerId $ownerId `
            -Session $session
    }
}

function Assert-CustomSkillsNoRuntimeApprovalRejected {
    $feature = "NoRuntimeCustomSkills"
    $specDirectory = Join-Path $TestRoot ".ai-workspace\specs\features\$feature"
    $approvalPath = Join-Path $specDirectory "00_workflow_state.json"
    $ownerId = "approval-custom-skills"
    Write-TestLegacyOwner `
        -Feature $feature `
        -SpecDirectory $specDirectory `
        -Workflow CUSTOM_SKILLS `
        -Agent COPILOT `
        -OwnerId $ownerId
    try {
        [System.IO.File]::WriteAllText(
            (Join-Path $specDirectory "01_server_rules.md"),
            "# Rules`n- BR-APPROVAL requirement",
            $Utf8NoBom
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $specDirectory "06_design_contract.md"),
            "# Design`n- DC-APPROVAL design",
            $Utf8NoBom
        )
        & $ScriptPath -Operation InitApproval -Path $approvalPath -Feature $feature `
            -OwnerWorkflow CUSTOM_SKILLS -OwnerAgent COPILOT -OwnerId $ownerId | Out-Null
        Assert-FailsWithMessageAndState `
            -ExpectedMessage "Approve without -RuntimePath requires SUPERPOWERS ownership." `
            -StatePath $approvalPath `
            -Message "CUSTOM_SKILLS cannot approve without a legacy runtime." `
            -Action {
            & $ScriptPath -Operation Approve -Path $approvalPath `
                -Gate requirement -ApprovedBy "human:test" `
                -OwnerWorkflow CUSTOM_SKILLS -OwnerAgent COPILOT -OwnerId $ownerId
        }
        Assert-ApprovalGateFields -StatePath $approvalPath -GateName requirement `
            -Status DRAFT -Sha256 "" -ApprovedAt "" -ApprovedBy ""
        Assert-ApprovalGateFields -StatePath $approvalPath -GateName design `
            -Status DRAFT -Sha256 "" -ApprovedAt "" -ApprovedBy ""
    } finally {
        & $OwnerScriptPath -Operation Complete -SpecDirectory $specDirectory `
            -Feature $feature -Workflow CUSTOM_SKILLS -Agent COPILOT `
            -OwnerId $ownerId | Out-Null
    }
}

function New-Handoff {
    param(
        [string]$RunId,
        [string]$Status,
        [string]$Result,
        [string]$RecommendedPhase,
        [string]$RetryFrom = "",
        [string]$FailureKey = "",
        [string]$BlockReason = "",
        [string[]]$Evidence = @()
    )

    if ($Status -eq "FAIL" -and [string]::IsNullOrWhiteSpace($FailureKey)) {
        $FailureKey = $Result
    }
    return [ordered]@{
        schemaVersion = "1.0"
        runId = $RunId
        sequence = 0
        status = $Status
        result = $Result
        recommendedPhase = $RecommendedPhase
        artifacts = @()
        scope = [ordered]@{
            files = @("Example.java")
            methods = @("Example#run")
            baseline = "WORKING"
        }
        retryFrom = $RetryFrom
        failureKey = $FailureKey
        blockReason = $BlockReason
        evidence = @($Evidence)
    }
}

function Set-TestHandoffSequence {
    param(
        [string]$Runtime,
        [object]$Handoff
    )

    $state = Get-Content -LiteralPath $Runtime -Raw | ConvertFrom-Json
    $Handoff.sequence = [int]$state.lastHandoffSequence + 1
}

function Apply-TestHandoff {
    param(
        [string]$Runtime,
        [object]$Handoff
    )

    Set-TestHandoffSequence -Runtime $Runtime -Handoff $Handoff
    Write-TestJson -Path $HandoffPath -Value $Handoff
    & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $Runtime | Out-Null
}

function Write-TestCoverage {
    param(
        [string[]]$RequirementIds = @("BR-CORE", "EX-DENIED", "AC-RESULT"),
        [string[]]$DesignIds = @("DC-PROTOCOL", "DR-COMPAT", "TW-FIXTURE"),
        [object]$Assertion = $null,
        [string]$AutomationCarrier = "src/test/ExampleFeatureTest.java",
        [string]$RequirementHash = ""
    )

    if ($null -eq $Assertion) {
        $Assertion = [ordered]@{
            target = "response.code"
            operator = "EQ"
            expected = 0
        }
    }
    if ([string]::IsNullOrWhiteSpace($RequirementHash)) {
        $RequirementHash = (Get-TestArtifactHash -Path $RequirementPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($AutomationCarrier)) {
        $carrierRel = ($AutomationCarrier -replace '#.*$', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($carrierRel)) {
            $carrierFull = if ([System.IO.Path]::IsPathRooted($carrierRel)) { $carrierRel } else { Join-Path $TestRoot $carrierRel }
            if (-not (Test-Path -LiteralPath $carrierFull)) {
                $carrierDir = Split-Path -Parent $carrierFull
                if ($carrierDir -and -not (Test-Path -LiteralPath $carrierDir)) {
                    [System.IO.Directory]::CreateDirectory($carrierDir) | Out-Null
                }
                if ($carrierFull -match '\.java$') {
                    [System.IO.File]::WriteAllText($carrierFull, "package test; import org.junit.Test; public class ExampleFeatureTest { @Test public void testCore() {} }", $Utf8NoBom)
                } else {
                    [System.IO.File]::WriteAllText($carrierFull, "# dummy carrier", $Utf8NoBom)
                }
            }
        }
    }
    $coverage = [ordered]@{
        schemaVersion = "1.0"
        feature = "Example"
        requirementArtifact = "01_server_rules.md"
        requirementSha256 = $RequirementHash
        designArtifact = "06_design_contract.md"
        designSha256 = (Get-TestArtifactHash -Path $DesignPath)
        testPlanArtifact = "05_test_plan.md"
        testPlanSha256 = (Get-TestArtifactHash -Path $TestPlanPath)
        cases = @(
            [ordered]@{
                id = "TC-CORE"
                title = "Core business flow"
                status = "VERIFIED"
                priority = "P0"
                testTypes = @("FUNCTIONAL", "NEGATIVE", "BOUNDARY")
                requirementIds = @($RequirementIds)
                designIds = @($DesignIds)
                setup = @("Create an isolated test player.")
                trigger = @("Send the formal feature protocol.")
                assertions = [ordered]@{
                    protocol = @($Assertion)
                    serverState = @(
                        [ordered]@{
                            target = "player.progress"
                            operator = "EQ"
                            expected = 1
                        }
                    )
                    sideEffects = @(
                        [ordered]@{
                            target = "reward.count"
                            operator = "INCREASES_BY"
                            expected = 1
                        }
                    )
                    regression = @(
                        [ordered]@{
                            target = "legacy.flag"
                            operator = "UNCHANGED"
                            expected = $false
                        }
                    )
                }
                cleanup = @("Delete the isolated test player.")
                automationCarrier = $AutomationCarrier
            }
        )
        riskExemptions = @()
    }
    $actualWsDigest = & $ScriptPath -Operation AssessRisk -Path (Split-Path -Parent $CoveragePath) 2>&1 | ConvertFrom-Json
    $covDigest = if ($actualWsDigest -and $actualWsDigest.changeSetDigest) { [string]$actualWsDigest.changeSetDigest } else { ("0" * 64) }
    $coverage["executionEvidence"] = [ordered]@{
        command = "pwsh test"
        exitCode = 0
        executedAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
        sourceCommitSha = "abcdef1234567890"
        workingTreeDigest = $covDigest
        testCount = 1
        passedCount = 1
        failedCount = 0
    }
    Write-TestJson -Path $CoveragePath -Value $coverage
}

function Write-NoRuntimeCoverageFixture {
    param(
        [string]$Feature,
        [string]$SpecDirectory
    )

    $requirementPath = Join-Path $SpecDirectory "01_server_rules.md"
    $designPath = Join-Path $SpecDirectory "06_design_contract.md"
    $testPlanPath = Join-Path $SpecDirectory "05_test_plan.md"
    $coveragePath = Join-Path $SpecDirectory "05_test_coverage.json"
    $actualWsDigest = & $ScriptPath -Operation AssessRisk -Path $SpecDirectory 2>&1 | ConvertFrom-Json
    $covDigest = if ($actualWsDigest -and $actualWsDigest.changeSetDigest) { [string]$actualWsDigest.changeSetDigest } else { ("0" * 64) }
    $coverage = [ordered]@{
        schemaVersion = "1.0"
        feature = $Feature
        requirementArtifact = "01_server_rules.md"
        requirementSha256 = (Get-TestArtifactHash -Path $requirementPath)
        designArtifact = "06_design_contract.md"
        designSha256 = (Get-TestArtifactHash -Path $designPath)
        testPlanArtifact = "05_test_plan.md"
        testPlanSha256 = (Get-TestArtifactHash -Path $testPlanPath)
        cases = @(
            [ordered]@{
                id = "TC-COVERAGE"
                title = "Approval state gates no-runtime coverage validation"
                status = "VERIFIED"
                priority = "P0"
                testTypes = @("FUNCTIONAL", "NEGATIVE")
                requirementIds = @("BR-COVERAGE")
                designIds = @("DC-COVERAGE")
                setup = @("Create canonical approval and coverage artifacts.")
                trigger = @("Validate coverage without a legacy runtime.")
                assertions = [ordered]@{
                    protocol = @(
                        [ordered]@{
                            target = "validation.result"
                            operator = "EQ"
                            expected = "VALID"
                        }
                    )
                    serverState = @(
                        [ordered]@{
                            target = "approval.requirement.status"
                            operator = "EQ"
                            expected = "APPROVED"
                        }
                    )
                    sideEffects = @(
                        [ordered]@{
                            target = "approval.design.status"
                            operator = "EQ"
                            expected = "APPROVED"
                        }
                    )
                    regression = @(
                        [ordered]@{
                            target = "coverage.approvalBypass"
                            operator = "EQ"
                            expected = $false
                        }
                    )
                }
                cleanup = @("Delete the isolated fixture directory.")
                automationCarrier = "TestRunner.ps1"
            }
        )
        riskExemptions = @()
        executionEvidence = [ordered]@{
            command = "pwsh test"
            exitCode = 0
            executedAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
            sourceCommitSha = "abcdef1234567890"
            workingTreeDigest = $covDigest
            testCount = 1
            passedCount = 1
            failedCount = 0
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $SpecDirectory "TestRunner.ps1"), "# test", $Utf8NoBom)
    Write-TestJson -Path $coveragePath -Value $coverage
}

function Assert-NoRuntimeCoverageApprovalState {
    $feature = "NoRuntimeCoverage"
    $specDirectory = Join-Path $TestRoot ".ai-workspace\specs\features\$feature"
    $approvalPath = Join-Path $specDirectory "00_workflow_state.json"
    $requirementPath = Join-Path $specDirectory "01_server_rules.md"
    $designPath = Join-Path $specDirectory "06_design_contract.md"
    $testPlanPath = Join-Path $specDirectory "05_test_plan.md"
    $coveragePath = Join-Path $specDirectory "05_test_coverage.json"
    $ownerId = "coverage-cursor"
    $session = New-TestSuperpowersOwner `
        -Feature $feature `
        -SpecDirectory $specDirectory `
        -Agent CURSOR `
        -OwnerId $ownerId
    try {
        [System.IO.File]::WriteAllText($requirementPath, "# Rules`n- BR-COVERAGE approval gate", $Utf8NoBom)
        [System.IO.File]::WriteAllText($designPath, "# Design`n- DC-COVERAGE approval gate", $Utf8NoBom)
        [System.IO.File]::WriteAllText($testPlanPath, "# Test Plan`n## TC-COVERAGE Approval gate", $Utf8NoBom)
        Write-NoRuntimeCoverageFixture -Feature $feature -SpecDirectory $specDirectory
        & $ScriptPath -Operation InitApproval -Path $approvalPath -Feature $feature `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $ownerId | Out-Null

        Assert-FailsWithMessageAndState `
            -ExpectedMessage "Requirement approval is required before validating test coverage." `
            -StatePath $approvalPath `
            -Message "Requirement DRAFT must block no-runtime coverage validation." `
            -Action {
            & $ScriptPath -Operation ValidateTestCoverage -Path $coveragePath
        }
        & $ScriptPath -Operation Approve -Path $approvalPath `
            -Gate requirement -ApprovedBy "human:test" `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $ownerId | Out-Null
        Assert-FailsWithMessageAndState `
            -ExpectedMessage "Design approval is required before validating test coverage." `
            -StatePath $approvalPath `
            -Message "Design DRAFT must block no-runtime coverage validation." `
            -Action {
            & $ScriptPath -Operation ValidateTestCoverage -Path $coveragePath
        }
        & $ScriptPath -Operation Approve -Path $approvalPath `
            -Gate design -ApprovedBy "human:test" `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $ownerId | Out-Null
        & $ScriptPath -Operation ValidateTestCoverage -Path $coveragePath | Out-Null

        # VerifyCompletion hard-gate: with no feature-state.json, tier=unknown and the
        # gate must FAIL (non-zero) — AI cannot Complete on an un-tiered feature.
        $featState = Join-Path $specDirectory "feature-state.json"
        if (Test-Path -LiteralPath $featState) { Remove-Item -LiteralPath $featState -Force }
        $verifyNoState = & $ScriptPath -Operation VerifyCompletion -Path $approvalPath 2>&1
        $verifyNoStateOut = $verifyNoState | Out-String
        if ($LASTEXITCODE -eq 0) { throw "VerifyCompletion must fail (non-zero) when feature-state.json is missing. Output: $verifyNoStateOut" }
        if ($verifyNoStateOut -notmatch "VERIFY_COMPLETION_FAIL") { throw "VerifyCompletion must emit VERIFY_COMPLETION_FAIL on missing feature-state. Output: $verifyNoStateOut" }

        # VerifyCompletion: T3 feature without 04_change_impact.json must FAIL
        $featState = Join-Path $specDirectory "feature-state.json"
        [System.IO.File]::WriteAllText($featState, '{"feature":"' + $feature + '","tier":"T3","phase":"DONE"}', $Utf8NoBom)
        $buildDir = Join-Path (Split-Path -Parent (Split-Path -Parent $specDirectory)) "build"
        [System.IO.Directory]::CreateDirectory($buildDir) | Out-Null
        
        $verifyNoImpact = & $ScriptPath -Operation VerifyCompletion -Path $approvalPath 2>&1
        $verifyNoImpactOut = $verifyNoImpact | Out-String
        if ($LASTEXITCODE -eq 0 -or $verifyNoImpactOut -notmatch "04_change_impact\.json is mandatory for T3") {
            throw "VerifyCompletion must fail when 04_change_impact.json is missing for T3 feature. Output: $verifyNoImpactOut"
        }

        $noRuntimeImpactPath = Join-Path $specDirectory "04_change_impact.json"
        $noRuntimeRisk = & $ScriptPath -Operation AssessRisk -Path $specDirectory -Baseline "0" 2>&1 | Out-String
        $noRuntimeDigest = ($noRuntimeRisk | ConvertFrom-Json).changeSetDigest
        $covObj = Get-Content -LiteralPath $coveragePath -Raw | ConvertFrom-Json -AsHashtable
        $covObj.executionEvidence.workingTreeDigest = $noRuntimeDigest
        [System.IO.File]::WriteAllText($coveragePath, ($covObj | ConvertTo-Json -Depth 10), $Utf8NoBom)
        $noRuntimeImpactJson = @"
{
  "schemaVersion": "1.0",
  "feature": "$feature",
  "baseline": "0",
  "changeSetDigest": "$noRuntimeDigest",
  "changedSymbols": ["NoRuntimeCoverage"],
  "entryPoints": ["TEST"],
  "upstreamCallers": ["TestRunner"],
  "downstreamEffects": [],
  "stateReadsWrites": [],
  "behaviorVariants": [],
  "invariants": [],
  "excludedWithReason": [],
  "requiredRegressionCases": ["TC-COVERAGE"]
}
"@
        [System.IO.File]::WriteAllText($noRuntimeImpactPath, $noRuntimeImpactJson, $Utf8NoBom)

        $verifyPass = & $ScriptPath -Operation VerifyCompletion -Path $approvalPath 2>&1
        $verifyPassOut = $verifyPass | Out-String
        if ($LASTEXITCODE -ne 0) { throw "VerifyCompletion must pass (exit 0) when gates APPROVED + coverage VALID + impact VALID + phase DONE. Output: $verifyPassOut" }
        if ($verifyPassOut -notmatch "VERIFY_COMPLETION_PASS") { throw "VerifyCompletion must emit VERIFY_COMPLETION_PASS when all T3 conditions met. Output: $verifyPassOut" }

        # Test VerifyCompletion on T2: passes even without build directory (non-blocking for T2)
        $t2TestFeature = "VerifyT2StandaloneFeature"
        $t2SpecDir = Join-Path $TestRoot "specs/features/$t2TestFeature"
        [System.IO.Directory]::CreateDirectory($t2SpecDir) | Out-Null
        $t2FeatState = Join-Path $t2SpecDir "feature-state.json"
        [System.IO.File]::WriteAllText($t2FeatState, '{"schemaVersion":"1.0","feature":"' + $t2TestFeature + '","tier":"T2","baseline":"0","phase":"IMPLEMENTING","updatedAt":"2026-08-23T00:00:00Z"}', $Utf8NoBom)
        $t2DummyPath = Join-Path $t2SpecDir "workflow-state.json"
        $verifyT2 = & $ScriptPath -Operation VerifyCompletion -Path $t2DummyPath 2>&1
        $verifyT2Out = $verifyT2 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "VerifyCompletion must pass on T2 without compile dir. Output: $verifyT2Out" }
        if ($verifyT2Out -notmatch "VERIFY_COMPLETION_PASS") { throw "VerifyCompletion must emit VERIFY_COMPLETION_PASS on T2. Output: $verifyT2Out" }

        # Test VerifyCompletion on FAST_TRACK and T1: passes as non-blocking
        $ftTestFeature = "VerifyFastTrackFeature"
        $ftSpecDir = Join-Path $TestRoot "specs/features/$ftTestFeature"
        [System.IO.Directory]::CreateDirectory($ftSpecDir) | Out-Null
        $ftFeatState = Join-Path $ftSpecDir "feature-state.json"
        [System.IO.File]::WriteAllText($ftFeatState, '{"schemaVersion":"1.0","feature":"' + $ftTestFeature + '","tier":"FAST_TRACK","baseline":"0","phase":"IMPLEMENTING","updatedAt":"2026-08-23T00:00:00Z"}', $Utf8NoBom)
        $verifyFt = & $ScriptPath -Operation VerifyCompletion -Path (Join-Path $ftSpecDir "workflow-state.json") 2>&1
        $verifyFtOut = $verifyFt | Out-String
        if ($LASTEXITCODE -ne 0) { throw "VerifyCompletion must pass on FAST_TRACK. Output: $verifyFtOut" }
        if ($verifyFtOut -notmatch "VERIFY_COMPLETION_PASS") { throw "VerifyCompletion must emit VERIFY_COMPLETION_PASS on FAST_TRACK. Output: $verifyFtOut" }

        $t1TestFeature = "VerifyT1Feature"
        $t1SpecDir = Join-Path $TestRoot "specs/features/$t1TestFeature"
        [System.IO.Directory]::CreateDirectory($t1SpecDir) | Out-Null
        $t1FeatState = Join-Path $t1SpecDir "feature-state.json"
        [System.IO.File]::WriteAllText($t1FeatState, '{"schemaVersion":"1.0","feature":"' + $t1TestFeature + '","tier":"T1","baseline":"0","phase":"IMPLEMENTING","updatedAt":"2026-08-23T00:00:00Z"}', $Utf8NoBom)
        $verifyT1 = & $ScriptPath -Operation VerifyCompletion -Path (Join-Path $t1SpecDir "workflow-state.json") 2>&1
        $verifyT1Out = $verifyT1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "VerifyCompletion must pass on T1. Output: $verifyT1Out" }
        if ($verifyT1Out -notmatch "VERIFY_COMPLETION_PASS") { throw "VerifyCompletion must emit VERIFY_COMPLETION_PASS on T1. Output: $verifyT1Out" }

        # Test T3 auto-escalation: if 01_server_rules.md exists, VerifyCompletion treats it as T3 even if feature-state claims T2
        $t3EscalateFeature = "T3AutoEscalateFeature"
        $t3EscalateSpec = Join-Path $TestRoot "specs/features/$t3EscalateFeature"
        [System.IO.Directory]::CreateDirectory($t3EscalateSpec) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $t3EscalateSpec "01_server_rules.md"), "# Rules", $Utf8NoBom)
        $t3EscalateFeatState = Join-Path $t3EscalateSpec "feature-state.json"
        [System.IO.File]::WriteAllText($t3EscalateFeatState, '{"schemaVersion":"1.0","feature":"' + $t3EscalateFeature + '","tier":"T2","baseline":"0","phase":"IMPLEMENTING","updatedAt":"2026-08-23T00:00:00Z"}', $Utf8NoBom)
        $t3EscalateVerify = & $ScriptPath -Operation VerifyCompletion -Path (Join-Path $t3EscalateSpec "workflow-state.json") 2>&1
        $t3EscalateVerifyOut = $t3EscalateVerify | Out-String
        if ($LASTEXITCODE -eq 0) { throw "VerifyCompletion must auto-escalate to T3 and fail when 01_server_rules.md exists but gates missing. Output: $t3EscalateVerifyOut" }
        if ($t3EscalateVerifyOut -notmatch "VERIFY_COMPLETION_FAIL") { throw "VerifyCompletion must emit VERIFY_COMPLETION_FAIL on auto-escalated T3. Output: $t3EscalateVerifyOut" }

        # Restore T3 state for subsequent tests
        [System.IO.File]::WriteAllText($featState, '{"schemaVersion":"1.0","feature":"' + $feature + '","tier":"T3","phase":"DONE","updatedAt":"2026-08-23T00:00:00Z"}', $Utf8NoBom)
        [System.IO.Directory]::CreateDirectory($buildDir) | Out-Null

        $originalRequirement = [System.IO.File]::ReadAllText($requirementPath)
        [System.IO.File]::AppendAllText($requirementPath, "`nChanged after approval.", $Utf8NoBom)
        Assert-FailsWithMessageAndState `
            -ExpectedMessage "Approved requirement artifact hash does not match:" `
            -StatePath $approvalPath `
            -Message "An approved artifact change must block no-runtime coverage validation." `
            -Action {
            & $ScriptPath -Operation ValidateTestCoverage -Path $coveragePath
        }
        Write-NoRuntimeCoverageFixture -Feature $feature -SpecDirectory $specDirectory
        Assert-FailsWithMessageAndState `
            -ExpectedMessage "Approved requirement artifact hash does not match:" `
            -StatePath $approvalPath `
            -Message "Updating coverage hashes cannot hide a stale approval hash." `
            -Action {
            & $ScriptPath -Operation ValidateTestCoverage -Path $coveragePath
        }
        [System.IO.File]::WriteAllText($requirementPath, $originalRequirement, $Utf8NoBom)
    } finally {
        Complete-TestSuperpowersOwner `
            -Feature $feature `
            -SpecDirectory $specDirectory `
            -Agent CURSOR `
            -OwnerId $ownerId `
            -Session $session
    }
}

function Assert-CurrentP0LegacyBootstrap {
    $feature = "AiSopPortabilityP0"
    $ownerId = "cursor-p0-7bb519c61ff3"
    $specDirectory = Join-Path $TestRoot ".ai-workspace\specs\features\$feature"
    $approvalPath = Join-Path $specDirectory "00_workflow_state.json"
    $runtimePath = Join-Path $specDirectory "00_runtime.json"
    $handoffPath = Join-Path $specDirectory "p0-design-handoff.json"
    $requirementPath = Join-Path $specDirectory "01_server_rules.md"
    $designPath = Join-Path $specDirectory "06_design_contract.md"
    Write-TestLegacyOwner `
        -Feature $feature `
        -SpecDirectory $specDirectory `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $ownerId
    try {
        [System.IO.File]::WriteAllText(
            $requirementPath,
            "# Rules`n- BR-P0-BOOTSTRAP approved requirement",
            $Utf8NoBom
        )
        [System.IO.File]::WriteAllText(
            $designPath,
            "# Design`n- DC-P0-BOOTSTRAP pending design",
            $Utf8NoBom
        )
        & $ScriptPath -Operation InitApproval -Path $approvalPath -Feature $feature `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $ownerId | Out-Null
        & $ScriptPath -Operation Approve -Path $approvalPath `
            -Gate requirement -ApprovedBy "human:test" `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $ownerId | Out-Null
        & $ScriptPath -Operation InitRuntime -Path $runtimePath -Feature $feature `
            -SpecDirectory $specDirectory -TaskType TECH_CONTRACT_CHANGE `
            -RunId $ownerId -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR `
            -OwnerId $ownerId | Out-Null
        & $ScriptPath -Operation TransitionRuntime -Path $runtimePath `
            -ToPhase DESIGN_DRAFT -OwnerWorkflow SUPERPOWERS `
            -OwnerAgent CURSOR -OwnerId $ownerId | Out-Null

        $designDraftRuntime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
        if (
            $designDraftRuntime.phase -cne "DESIGN_DRAFT" -or
            $designDraftRuntime.status -cne "RUNNING" -or
            $designDraftRuntime.runId -cne $ownerId
        ) {
            throw "The isolated P0 bootstrap did not enter DESIGN_DRAFT with the current runId."
        }

        $handoff = New-Handoff -RunId $ownerId -Status WAIT_HUMAN `
            -Result DESIGN_DRAFT_READY -RecommendedPhase WAIT_DESIGN_APPROVAL `
            -BlockReason "Waiting for P0 design approval." -Evidence @("06_design_contract.md")
        Set-TestHandoffSequence -Runtime $runtimePath -Handoff $handoff
        Write-TestJson -Path $handoffPath -Value $handoff
        & $ScriptPath -Operation ApplyHandoff -Path $handoffPath -RuntimePath $runtimePath `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $ownerId | Out-Null

        $waitingRuntime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
        if (
            $waitingRuntime.phase -cne "WAIT_DESIGN_APPROVAL" -or
            $waitingRuntime.status -cne "WAIT_HUMAN"
        ) {
            throw "The isolated P0 bootstrap did not reach WAIT_DESIGN_APPROVAL/WAIT_HUMAN."
        }

        & $ScriptPath -Operation Approve -Path $approvalPath -RuntimePath $runtimePath `
            -Gate design -ApprovedBy "human:test" `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $ownerId | Out-Null
        $approval = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
        $designHash = (Get-TestArtifactHash -Path $designPath)
        if (
            $approval.requirement.status -cne "APPROVED" -or
            $approval.design.status -cne "APPROVED" -or
            $approval.design.sha256 -cne $designHash
        ) {
            throw "The isolated P0 legacy design approval did not record the current design SHA."
        }
    } finally {
        & $OwnerScriptPath -Operation Complete -SpecDirectory $specDirectory `
            -Feature $feature -Workflow SUPERPOWERS -Agent CURSOR `
            -OwnerId $ownerId | Out-Null
    }
}

function Assert-InactiveOwner11MutationRejected {
    $feature = "InactiveOwner11"
    $specDirectory = Join-Path $TestRoot ".ai-workspace\specs\features\$feature"
    $approvalPath = Join-Path $specDirectory "00_workflow_state.json"
    $ownerId = "inactive-owner-11"
    $session = New-TestSuperpowersOwner `
        -Feature $feature `
        -SpecDirectory $specDirectory `
        -Agent CURSOR `
        -OwnerId $ownerId
    $sessionPath = Get-AiSopWorkflowSessionPath $session.Record.sessionKey
    $expired = Get-Content -LiteralPath $sessionPath -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $expired.expiresAt = [DateTimeOffset]::UtcNow.AddMilliseconds(-1).ToString("o")
    Write-TestJson -Path $sessionPath -Value $expired
    Assert-Fails -Message "Expired Owner 1.1 session authorized workflow mutation." -Action {
        & $ScriptPath -Operation InitApproval -Path $approvalPath -Feature $feature `
            -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $ownerId
    }
    if (Test-Path -LiteralPath $approvalPath) {
        throw "Rejected Owner 1.1 mutation created approval state."
    }
}

function Assert-LegacyOwnerIdentityCaseSensitive {
    $caseOnlyAccepted = [System.Collections.Generic.List[string]]::new()
    foreach ($identityCase in @(
        [pscustomobject]@{
            Name = "Feature"
            FeatureArgument = "legacycasefeature"
            WorkflowArgument = "CUSTOM_SKILLS"
            AgentArgument = "COPILOT"
            OwnerIdArgument = "CaseSensitiveOwner"
        },
        [pscustomobject]@{
            Name = "Workflow"
            FeatureArgument = "LegacyCaseWorkflow"
            WorkflowArgument = "custom_skills"
            AgentArgument = "COPILOT"
            OwnerIdArgument = "CaseSensitiveOwner"
        },
        [pscustomobject]@{
            Name = "Agent"
            FeatureArgument = "LegacyCaseAgent"
            WorkflowArgument = "CUSTOM_SKILLS"
            AgentArgument = "copilot"
            OwnerIdArgument = "CaseSensitiveOwner"
        },
        [pscustomobject]@{
            Name = "OwnerId"
            FeatureArgument = "LegacyCaseOwnerId"
            WorkflowArgument = "CUSTOM_SKILLS"
            AgentArgument = "COPILOT"
            OwnerIdArgument = "casesensitiveowner"
        }
    )) {
        $storedFeature = "LegacyCase$($identityCase.Name)"
        $specDirectory = Join-Path $TestRoot (
            ".ai-workspace\specs\features\$storedFeature"
        )
        $approvalPath = Join-Path $specDirectory "00_workflow_state.json"
        Write-TestLegacyOwner `
            -Feature $storedFeature `
            -SpecDirectory $specDirectory `
            -Workflow CUSTOM_SKILLS `
            -Agent COPILOT `
            -OwnerId "CaseSensitiveOwner"

        & $ScriptPath -Operation InitApproval -Path $approvalPath `
            -Feature $storedFeature `
            -OwnerWorkflow CUSTOM_SKILLS `
            -OwnerAgent COPILOT `
            -OwnerId "CaseSensitiveOwner" |
            Out-Null
        & $ScriptPath -Operation ValidateApproval -Path $approvalPath |
            Out-Null
        [System.IO.File]::Delete($approvalPath)

        try {
            & $ScriptPath -Operation InitApproval -Path $approvalPath `
                -Feature $identityCase.FeatureArgument `
                -OwnerWorkflow $identityCase.WorkflowArgument `
                -OwnerAgent $identityCase.AgentArgument `
                -OwnerId $identityCase.OwnerIdArgument |
                Out-Null
            $caseOnlyAccepted.Add($identityCase.Name)
        } catch {
            if (
                -not $_.Exception.Message.Contains(
                    "Workflow owner identity does not match the active claim.",
                    [System.StringComparison]::Ordinal
                )
            ) {
                throw
            }
        } finally {
            if (Test-Path -LiteralPath $approvalPath) {
                [System.IO.File]::Delete($approvalPath)
            }
        }
    }
    if ($caseOnlyAccepted.Count -ne 0) {
        throw (
            "Legacy Owner 1.0 accepted case-only identity mismatches: " +
            ($caseOnlyAccepted -join ", ")
        )
    }
}

function Write-ExampleApprovedStateFixture {
    $approvedAt = [DateTimeOffset]::UtcNow.ToString("o")
    Write-TestJson -Path $ApprovalPath -Value ([ordered]@{
        schemaVersion = "1.0"
        feature = "Example"
        requirement = [ordered]@{
            artifact = "01_server_rules.md"
            status = "APPROVED"
            sha256 = (Get-TestArtifactHash -Path $RequirementPath)
            approvedAt = $approvedAt
            approvedBy = "human:test"
        }
        design = [ordered]@{
            artifact = "06_design_contract.md"
            status = "APPROVED"
            sha256 = (Get-TestArtifactHash -Path $DesignPath)
            approvedAt = $approvedAt
            approvedBy = "human:test"
        }
    })
}

function Assert-ReadEntrypointsRecoverTransactions {
    param(
        [string]$ApprovalStatePath,
        [string]$RuntimeStatePath,
        [string]$CoverageStatePath
    )

    Write-TestCoverage
    & $ScriptPath -Operation ValidateApproval -Path $ApprovalStatePath |
        Out-Null
    & $ScriptPath -Operation ValidateRuntime -Path $RuntimeStatePath |
        Out-Null
    & $ScriptPath -Operation ValidateTestCoverage -Path $CoverageStatePath `
        -RuntimePath $RuntimeStatePath |
        Out-Null

    $corruptJournalPath = Join-Path (
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
    ) "read-corrupt.json"
    [System.IO.File]::WriteAllText(
        $corruptJournalPath,
        "{corrupt-transaction",
        $Utf8NoBom
    )
    Assert-Fails -Message (
        "ValidateApproval read authoritative state before corrupt recovery."
    ) -Action {
        & $ScriptPath -Operation ValidateApproval -Path $ApprovalStatePath
    }
    [System.IO.File]::Delete($corruptJournalPath)

    $indeterminateTargetPath = Join-Path $TestRoot "read-indeterminate-owner.json"
    $currentOwner = Get-Content -LiteralPath (
        Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY "example.json"
    ) -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $afterOwner = $currentOwner |
        ConvertTo-Json -Depth 30 |
        ConvertFrom-Json -AsHashtable -DateKind String
    $afterOwner.ownerId = "read-recovery-after"
    $afterJson = ConvertTo-AiSopWorkflowCanonicalJson $afterOwner
    $currentJson = ConvertTo-AiSopWorkflowCanonicalJson $currentOwner
    [System.IO.File]::WriteAllText(
        $indeterminateTargetPath,
        $currentJson,
        $Utf8NoBom
    )
    $indeterminateJournalPath = Join-Path (
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
    ) "read-indeterminate.json"
    Write-AiSopWorkflowTransactionJournal `
        -JournalPath $indeterminateJournalPath `
        -Journal ([ordered]@{
            schemaVersion = "1.0"
            transactionId = "read-indeterminate"
            operation = "CLAIM"
            phase = "PREPARED"
            feature = "Example"
            ownerPath = $indeterminateTargetPath
            sessionKeys = @()
            targets = @(
                [ordered]@{
                    path = $indeterminateTargetPath
                    kind = "OWNER"
                    schemaId = "OWNER"
                    before = New-AiSopWorkflowSnapshot -Exists $false
                    after = New-AiSopWorkflowSnapshot `
                        -Exists $true `
                        -CanonicalJson $afterJson
                }
            )
            createdAt = [DateTimeOffset]::UtcNow.ToString("o")
            committedAt = ""
        })
    Assert-Fails -Message (
        "ValidateRuntime read authoritative state after indeterminate recovery."
    ) -Action {
        & $ScriptPath -Operation ValidateRuntime -Path $RuntimeStatePath
    }
    [System.IO.File]::Delete($indeterminateJournalPath)
    [System.IO.File]::Delete($indeterminateTargetPath)

    $timeoutJournalPath = Join-Path (
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
    ) "read-timeout.json"
    [System.IO.File]::WriteAllText(
        $timeoutJournalPath,
        "{blocked-before-read",
        $Utf8NoBom
    )
    $timeoutLockPath = "$timeoutJournalPath.recovery.lock"
    $timeoutLock = [System.IO.File]::Open(
        $timeoutLockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        Assert-Fails -Message (
            "ValidateTestCoverage read authoritative state after recovery timeout."
        ) -Action {
            & $ScriptPath -Operation ValidateTestCoverage `
                -Path $CoverageStatePath `
                -RuntimePath $RuntimeStatePath
        }
    } finally {
        $timeoutLock.Dispose()
        [System.IO.File]::Delete($timeoutLockPath)
        [System.IO.File]::Delete($timeoutJournalPath)
    }
}

try {
    [System.IO.Directory]::CreateDirectory($FeatureRoot) | Out-Null
    # 从当前非 Claude harness 开始, 直接回归已复现的跨 harness mutation 拒绝.
    foreach ($mutationAgent in @("COPILOT", "ANTIGRAVITY", "CLAUDE_CODE", "CURSOR")) {
        Assert-SuperpowersMutationAccepted -Agent $mutationAgent
    }
    foreach ($approvalAgent in @("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR")) {
        Assert-NoRuntimeApprovalAccepted -Agent $approvalAgent
    }
    Assert-CustomSkillsNoRuntimeApprovalRejected
    Assert-NoRuntimeCoverageApprovalState
    Assert-CurrentP0LegacyBootstrap
    Assert-InactiveOwner11MutationRejected
    Assert-LegacyOwnerIdentityCaseSensitive

    Write-TestLegacyOwner `
        -Feature "Example" `
        -SpecDirectory $FeatureRoot `
        -Workflow CUSTOM_SKILLS `
        -Agent COPILOT `
        -OwnerId "feature-run"
    [System.IO.Directory]::CreateDirectory(
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
    ) | Out-Null
    $corruptRecoveryPath = Join-Path (
        $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY
    ) "must-recover-first.json"
    [System.IO.File]::WriteAllText(
        $corruptRecoveryPath,
        "{corrupt-transaction",
        $Utf8NoBom
    )
    Assert-Fails -Message "Mutation did not recover workflow transactions first." -Action {
        & $ScriptPath -Operation InitApproval -Path $ApprovalPath -Feature "Example"
    }
    if (Test-Path -LiteralPath $ApprovalPath) {
        throw "Recovery failure allowed workflow-state mutation side effects."
    }
    [System.IO.File]::Delete($corruptRecoveryPath)
    $ownerRegistryPath = Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY "example.json"
    $validOwnerJson = [System.IO.File]::ReadAllText($ownerRegistryPath)
    $wrongWorkspaceOwner = $validOwnerJson | ConvertFrom-Json
    $wrongWorkspaceOwner.specDirectory = Join-Path (
        $TestRoot
    ) "other\.ai-workspace\specs\features\Example"
    Write-TestJson -Path $ownerRegistryPath -Value $wrongWorkspaceOwner
    Assert-Fails -Message "Workflow state mutations require the owner worktree." -Action {
        & $ScriptPath -Operation InitApproval -Path $ApprovalPath -Feature "Example"
    }
    [System.IO.File]::WriteAllText($ownerRegistryPath, $validOwnerJson, $Utf8NoBom)
    [System.IO.File]::WriteAllText(
        $RequirementPath,
        "# Rules`n- BR-CORE core flow`n- EX-DENIED denied branch`n- AC-RESULT exact result`n`nExample `BR-INLINE` only.`n> - EX-QUOTE example only`n`n```text`nBR-FAKE example only`n```n<!-- EX-COMMENT example only -->",
        $Utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        $DesignPath,
        "# Design`n- DC-PROTOCOL protocol contract`n- DR-COMPAT compatibility risk`n- TW-FIXTURE test fixture",
        $Utf8NoBom
    )
    [System.IO.File]::WriteAllText($TestPlanPath, "# Test Plan`n## TC-CORE Core flow", $Utf8NoBom)
    Write-ExampleApprovedStateFixture
    Write-TestCoverage

    & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath | Out-Null
    Write-TestCoverage -RequirementIds @("BR-CORE")
    Assert-Fails -Message "Every requirement clause must be covered." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    Write-TestCoverage -RequirementHash ("0" * 64)
    Assert-Fails -Message "Artifact hashes must match the coverage contract." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    [System.IO.File]::WriteAllText($TestPlanPath, "# Test Plan`n## TC-OTHER Other flow", $Utf8NoBom)
    Write-TestCoverage
    Assert-Fails -Message "Markdown and coverage case IDs must match." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    [System.IO.File]::WriteAllText($TestPlanPath, "# Test Plan`n## TC-CORE Core flow", $Utf8NoBom)
    Write-TestCoverage -Assertion "response is correct"
    Assert-Fails -Message "Vague assertions without measurable values must be rejected." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    Write-TestCoverage -Assertion "protocol succeeds"
    Assert-Fails -Message "Assertions require positive measurable evidence, not only a vague-term blacklist." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    Write-TestCoverage
    $emptyAssertionCoverage = Get-Content -LiteralPath $CoveragePath -Raw | ConvertFrom-Json
    $emptyAssertionCoverage.cases[0].assertions.protocol = @()
    Write-TestJson -Path $CoveragePath -Value $emptyAssertionCoverage
    Assert-Fails -Message "Every assertion layer requires a structured assertion or explicit N_A reason." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    Write-TestCoverage -AutomationCarrier ""
    Assert-Fails -Message "P0 and P1 cases require an automation carrier." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    Write-TestCoverage
    $externalArtifactCoverage = Get-Content -LiteralPath $CoveragePath -Raw | ConvertFrom-Json
    $externalArtifactCoverage.requirementArtifact = (Join-Path $TestRoot "outside-rules.md")
    Write-TestJson -Path $CoveragePath -Value $externalArtifactCoverage
    Assert-Fails -Message "Canonical coverage paths are required without a custom runtime." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    Write-TestCoverage
    $absoluteCanonicalCoverage = Get-Content -LiteralPath $CoveragePath -Raw | ConvertFrom-Json
    $absoluteCanonicalCoverage.requirementArtifact = $RequirementPath
    Write-TestJson -Path $CoveragePath -Value $absoluteCanonicalCoverage
    Assert-Fails -Message "Coverage artifact fields cannot use absolute canonical paths." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    Write-TestCoverage
    $traversalCoverage = Get-Content -LiteralPath $CoveragePath -Raw | ConvertFrom-Json
    $traversalCoverage.requirementArtifact = "subdir\..\01_server_rules.md"
    Write-TestJson -Path $CoveragePath -Value $traversalCoverage
    Assert-Fails -Message "Coverage artifact fields cannot normalize through traversal segments." -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $CoveragePath
    }
    Write-TestCoverage

    & $ScriptPath -Operation ValidateTransitions | Out-Null
    Remove-Item -LiteralPath $ApprovalPath -Force
    & $ScriptPath -Operation InitApproval -Path $ApprovalPath -Feature "Example" | Out-Null
    & $ScriptPath -Operation ValidateApproval -Path $ApprovalPath | Out-Null

    $externalApproval = Get-Content -LiteralPath $ApprovalPath -Raw | ConvertFrom-Json
    $externalApproval.requirement.artifact = (Join-Path $TestRoot "outside-rules.md")
    Write-TestJson -Path $ApprovalPath -Value $externalApproval
    Assert-Fails -Message "Requirement approval artifacts must remain canonical." -Action {
        & $ScriptPath -Operation ValidateApproval -Path $ApprovalPath
    }
    $externalApproval.requirement.artifact = "01_server_rules.md"
    Write-TestJson -Path $ApprovalPath -Value $externalApproval

    $env:SERVER_NEW_WORKFLOW_OWNER_ID = "other-run"
    Assert-Fails -Message "Runtime mutations require the active workflow owner identity." -Action {
        & $ScriptPath -Operation ResetApproval -Path $ApprovalPath -Gate design
    }
    $env:SERVER_NEW_WORKFLOW_OWNER_ID = "feature-run"

    $techRuntimePath = Join-Path $TestRoot "tech-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $techRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType TECH_CONTRACT_CHANGE -RunId "tech-run" | Out-Null
    Assert-Fails -Message "Technical contract changes require approved requirements." -Action {
        & $ScriptPath -Operation TransitionRuntime -Path $techRuntimePath -ToPhase DESIGN_DRAFT
    }

    $fixRuntimePath = Join-Path $TestRoot "fix-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $fixRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType IMPLEMENTATION_FIX -RunId "fix-run" | Out-Null
    Assert-Fails -Message "Implementation fixes require approved requirement and design contracts." -Action {
        & $ScriptPath -Operation TransitionRuntime -Path $fixRuntimePath -ToPhase QA_PLAN
    }

    & $ScriptPath -Operation InitRuntime -Path $RuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType NEW_FEATURE -RunId "feature-run" | Out-Null

    Assert-Fails -Message "NEW_FEATURE cannot bypass requirement and design gates." -Action {
        & $ScriptPath -Operation TransitionRuntime -Path $RuntimePath -ToPhase IMPLEMENTATION
    }
    & $ScriptPath -Operation TransitionRuntime -Path $RuntimePath -ToPhase REQUIREMENT_DRAFT | Out-Null

    Assert-Fails -Message "Active phases cannot advance without applying a handoff." -Action {
        & $ScriptPath -Operation TransitionRuntime -Path $RuntimePath -ToPhase WAIT_REQUIREMENT_APPROVAL
    }

    Apply-TestHandoff -Runtime $RuntimePath -Handoff (
        New-Handoff -RunId "feature-run" -Status WAIT_HUMAN `
            -Result REQUIREMENT_DRAFT_READY -RecommendedPhase WAIT_REQUIREMENT_APPROVAL `
            -BlockReason "Waiting for requirement approval." -Evidence @("01_server_rules.md")
    )

    Assert-Fails -Message "Design cannot be approved at the requirement gate." -Action {
        & $ScriptPath -Operation Approve -Path $ApprovalPath -RuntimePath $RuntimePath `
            -Gate design -ApprovedBy "human:test"
    }
    & $ScriptPath -Operation Approve -Path $ApprovalPath -RuntimePath $RuntimePath `
        -Gate requirement -ApprovedBy "human:test" | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $RuntimePath -ToPhase DESIGN_DRAFT | Out-Null

    Apply-TestHandoff -Runtime $RuntimePath -Handoff (
        New-Handoff -RunId "feature-run" -Status WAIT_HUMAN `
            -Result DESIGN_DRAFT_READY -RecommendedPhase WAIT_DESIGN_APPROVAL `
            -BlockReason "Waiting for design approval." -Evidence @("06_design_contract.md")
    )

    Assert-Fails -Message "QA plan requires approved design." -Action {
        & $ScriptPath -Operation TransitionRuntime -Path $RuntimePath -ToPhase QA_PLAN
    }
    & $ScriptPath -Operation Approve -Path $ApprovalPath -RuntimePath $RuntimePath `
        -Gate design -ApprovedBy "human:test" | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $RuntimePath -ToPhase QA_PLAN | Out-Null

    Write-TestCoverage -RequirementIds @("BR-CORE", "AC-RESULT")
    $unapprovedExemptionCoverage = Get-Content -LiteralPath $CoveragePath -Raw | ConvertFrom-Json
    $unapprovedExemptionCoverage.riskExemptions = @(
        [ordered]@{
            clauseId = "EX-DENIED"
            reason = "Difficult to automate."
            approvedBy = "human:test"
        }
    )
    Write-TestJson -Path $CoveragePath -Value $unapprovedExemptionCoverage
    $unapprovedExemptionHandoff = New-Handoff -RunId "feature-run" -Status PASS `
        -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    Set-TestHandoffSequence -Runtime $RuntimePath -Handoff $unapprovedExemptionHandoff
    Write-TestJson -Path $HandoffPath -Value $unapprovedExemptionHandoff
    Assert-Fails -Message "QA cannot invent coverage exemptions after source approval." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $RuntimePath
    }

    $ExternalPlanPath = Join-Path $TestRoot "outside-test-plan.md"
    [System.IO.File]::WriteAllText($ExternalPlanPath, "# Test Plan`n## TC-CORE Core flow", $Utf8NoBom)
    Write-TestCoverage
    $externalCoverage = Get-Content -LiteralPath $CoveragePath -Raw | ConvertFrom-Json
    $externalCoverage.testPlanArtifact = $ExternalPlanPath
    $externalCoverage.testPlanSha256 = (Get-TestArtifactHash -Path $ExternalPlanPath)
    Write-TestJson -Path $CoveragePath -Value $externalCoverage
    $externalPlanHandoff = New-Handoff -RunId "feature-run" -Status PASS `
        -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    Set-TestHandoffSequence -Runtime $RuntimePath -Handoff $externalPlanHandoff
    Write-TestJson -Path $HandoffPath -Value $externalPlanHandoff
    Assert-Fails -Message "The workflow must reject test plans outside the specification directory." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $RuntimePath
    }

    Write-TestCoverage -RequirementHash ("0" * 64)
    $invalidCoverageHandoff = New-Handoff -RunId "feature-run" -Status PASS `
        -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    Set-TestHandoffSequence -Runtime $RuntimePath -Handoff $invalidCoverageHandoff
    Write-TestJson -Path $HandoffPath -Value $invalidCoverageHandoff
    Assert-Fails -Message "Invalid coverage cannot advance QA planning." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $RuntimePath
    }
    $unchangedQaPlan = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
    if ($unchangedQaPlan.phase -ne "QA_PLAN" -or $unchangedQaPlan.lastHandoffSequence -ne 2) {
        throw "Failed coverage validation must leave runtime state unchanged."
    }
    Write-TestCoverage
    Apply-TestHandoff -Runtime $RuntimePath -Handoff (
        New-Handoff -RunId "feature-run" -Status PASS `
            -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    )
    $failedAuditToImplementation = New-Handoff -RunId "feature-run" -Status FAIL `
        -Result TEST_PLAN_GAPS -RecommendedPhase IMPLEMENTATION `
        -RetryFrom IMPLEMENTATION -Evidence @("Coverage audit failed.")
    Set-TestHandoffSequence -Runtime $RuntimePath -Handoff $failedAuditToImplementation
    Write-TestJson -Path $HandoffPath -Value $failedAuditToImplementation
    Assert-Fails -Message "A failed test-plan audit cannot enter implementation." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $RuntimePath
    }
    Apply-TestHandoff -Runtime $RuntimePath -Handoff (
        New-Handoff -RunId "feature-run" -Status FAIL `
            -Result TEST_PLAN_GAPS -RecommendedPhase QA_PLAN `
            -RetryFrom QA_PLAN -Evidence @("TC-CORE misses a state transition.")
    )
    Apply-TestHandoff -Runtime $RuntimePath -Handoff (
        New-Handoff -RunId "feature-run" -Status PASS `
            -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    )
    Apply-TestHandoff -Runtime $RuntimePath -Handoff (
        New-Handoff -RunId "feature-run" -Status PASS `
            -Result TEST_PLAN_AUDIT_PASSED -RecommendedPhase IMPLEMENTATION
    )
    Apply-TestHandoff -Runtime $RuntimePath -Handoff (
        New-Handoff -RunId "feature-run" -Status PASS `
            -Result IMPLEMENTATION_COMPILED -RecommendedPhase IMPLEMENTATION_AUDIT
    )
    Assert-ReadEntrypointsRecoverTransactions `
        -ApprovalStatePath $ApprovalPath `
        -RuntimeStatePath $RuntimePath `
        -CoverageStatePath $CoveragePath

    $failureHandoff = New-Handoff -RunId "feature-run" -Status FAIL `
        -Result IMPLEMENTATION_FAILURE -RecommendedPhase IMPLEMENTATION `
        -RetryFrom IMPLEMENTATION -Evidence @("Audit failure.")
    Set-TestHandoffSequence -Runtime $RuntimePath -Handoff $failureHandoff
    Write-TestJson -Path $HandoffPath -Value $failureHandoff
    & $ScriptPath -Operation ValidateHandoff -Path $HandoffPath -RuntimePath $RuntimePath | Out-Null
    Assert-Fails -Message "A validated failure handoff cannot be ignored." -Action {
        & $ScriptPath -Operation TransitionRuntime -Path $RuntimePath -ToPhase QA_VERIFY
    }
    & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $RuntimePath | Out-Null
    Assert-Fails -Message "The same handoff cannot be applied twice." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $RuntimePath
    }

    $invalidBlocked = New-Handoff -RunId "feature-run" -Status BLOCKED `
        -Result ENVIRONMENT_BLOCKED -RecommendedPhase QA_VERIFY `
        -BlockReason "Environment unavailable." -Evidence @("Connection failed.")
    Set-TestHandoffSequence -Runtime $RuntimePath -Handoff $invalidBlocked
    Write-TestJson -Path $HandoffPath -Value $invalidBlocked
    Assert-Fails -Message "BLOCKED handoff must preserve the current phase." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $RuntimePath
    }
    Assert-Fails -Message "BLOCKED cannot tunnel to another resume phase." -Action {
        & $ScriptPath -Operation TransitionRuntime -Path $RuntimePath -ToPhase IMPLEMENTATION `
            -RuntimeStatus BLOCKED -NextPhase QA_VERIFY -BlockReason "Environment unavailable."
    }

    Apply-TestHandoff -Runtime $RuntimePath -Handoff (
        New-Handoff -RunId "feature-run" -Status BLOCKED `
            -Result ENVIRONMENT_BLOCKED -RecommendedPhase IMPLEMENTATION `
            -BlockReason "Environment unavailable." -Evidence @("Connection failed.")
    )
    $blocked = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
    if ($blocked.phase -ne "IMPLEMENTATION" -or $blocked.status -ne "BLOCKED") {
        throw "BLOCKED must be represented as a runtime status on the current phase."
    }
    & $ScriptPath -Operation TransitionRuntime -Path $RuntimePath -ToPhase IMPLEMENTATION | Out-Null

    $reportRuntimePath = Join-Path $TestRoot "report-runtime.json"
    Assert-Fails -Message "Audit stage order must follow the legal transition graph." -Action {
        & $ScriptPath -Operation InitRuntime -Path (Join-Path $TestRoot "invalid-audit-runtime.json") `
            -Feature "Example" -SpecDirectory $FeatureRoot -TaskType AUDIT_ONLY `
            -RunId "invalid-audit-run" -AuditFixPolicy REPORT_ONLY `
            -StandaloneStages LOGIC_AUDIT,IMPLEMENTATION_AUDIT
    }
    & $ScriptPath -Operation InitRuntime -Path $reportRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType AUDIT_ONLY -RunId "report-run" `
        -AuditFixPolicy REPORT_ONLY -StandaloneStages IMPLEMENTATION_AUDIT,LOGIC_AUDIT | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $reportRuntimePath `
        -ToPhase IMPLEMENTATION_AUDIT | Out-Null

    $reportFailure = New-Handoff -RunId "report-run" -Status FAIL `
        -Result IMPLEMENTATION_FAILURE -RecommendedPhase IMPLEMENTATION `
        -RetryFrom IMPLEMENTATION -Evidence @("Finding.")
    Set-TestHandoffSequence -Runtime $reportRuntimePath -Handoff $reportFailure
    Write-TestJson -Path $HandoffPath -Value $reportFailure
    Assert-Fails -Message "REPORT_ONLY audits must not route into repair." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $reportRuntimePath
    }

    Apply-TestHandoff -Runtime $reportRuntimePath -Handoff (
        New-Handoff -RunId "report-run" -Status FINDINGS `
            -Result AUDIT_FINDINGS -RecommendedPhase LOGIC_AUDIT -Evidence @("Finding.")
    )
    Apply-TestHandoff -Runtime $reportRuntimePath -Handoff (
        New-Handoff -RunId "report-run" -Status PASS `
            -Result PASS -RecommendedPhase DONE
    )
    $reportRuntime = Get-Content -LiteralPath $reportRuntimePath -Raw | ConvertFrom-Json
    if ($reportRuntime.status -ne "DONE" -or $reportRuntime.auditStageIndex -ne 2) {
        throw "REPORT_ONLY audit did not complete its requested stage sequence."
    }

    $standaloneAuditRuntimePath = Join-Path $TestRoot "standalone-audit-runtime.json"
    $savedOwnerId = $env:SERVER_NEW_WORKFLOW_OWNER_ID
    $env:SERVER_NEW_WORKFLOW_OWNER_ID = ""
    & $ScriptPath -Operation InitRuntime -Path $standaloneAuditRuntimePath -Feature "StandaloneClassAudit" `
        -SpecDirectory $TestRoot -TaskType AUDIT_ONLY -RunId "standalone-audit-run" `
        -AuditFixPolicy REPORT_ONLY -StandaloneStages IMPLEMENTATION_AUDIT | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $standaloneAuditRuntimePath `
        -ToPhase IMPLEMENTATION_AUDIT | Out-Null
    Apply-TestHandoff -Runtime $standaloneAuditRuntimePath -Handoff (
        New-Handoff -RunId "standalone-audit-run" -Status PASS `
            -Result PASS -RecommendedPhase DONE
    )
    $env:SERVER_NEW_WORKFLOW_OWNER_ID = $savedOwnerId

    $repairRuntimePath = Join-Path $TestRoot "repair-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $repairRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType AUDIT_ONLY -RunId "repair-run" `
        -AuditFixPolicy AUTO_REPAIR -StandaloneStages IMPLEMENTATION_AUDIT,LOGIC_AUDIT | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $repairRuntimePath `
        -ToPhase IMPLEMENTATION_AUDIT | Out-Null
    $invalidAuditFailure = New-Handoff -RunId "repair-run" -Status FAIL `
        -Result IMPLEMENTATION_FAILURE -RecommendedPhase QA_VERIFY `
        -RetryFrom QA_VERIFY -Evidence @("Audit failure.")
    Set-TestHandoffSequence -Runtime $repairRuntimePath -Handoff $invalidAuditFailure
    Write-TestJson -Path $HandoffPath -Value $invalidAuditFailure
    Assert-Fails -Message "Failed audits cannot advance to QA." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $repairRuntimePath
    }
    Apply-TestHandoff -Runtime $repairRuntimePath -Handoff (
        New-Handoff -RunId "repair-run" -Status PASS `
            -Result PASS -RecommendedPhase LOGIC_AUDIT
    )
    Apply-TestHandoff -Runtime $repairRuntimePath -Handoff (
        New-Handoff -RunId "repair-run" -Status FAIL `
            -Result LOGIC_FAILURE -RecommendedPhase IMPLEMENTATION `
            -RetryFrom IMPLEMENTATION -Evidence @("Logic failure.")
    )
    $repairRuntime = Get-Content -LiteralPath $repairRuntimePath -Raw | ConvertFrom-Json
    if ($repairRuntime.phase -ne "IMPLEMENTATION" -or $repairRuntime.auditStageIndex -ne 0) {
        throw "AUTO_REPAIR audit did not return to implementation and reset its audit sequence."
    }
    Apply-TestHandoff -Runtime $repairRuntimePath -Handoff (
        New-Handoff -RunId "repair-run" -Status PASS `
            -Result IMPLEMENTATION_COMPILED -RecommendedPhase IMPLEMENTATION_AUDIT
    )
    Apply-TestHandoff -Runtime $repairRuntimePath -Handoff (
        New-Handoff -RunId "repair-run" -Status PASS `
            -Result PASS -RecommendedPhase LOGIC_AUDIT
    )
    Apply-TestHandoff -Runtime $repairRuntimePath -Handoff (
        New-Handoff -RunId "repair-run" -Status PASS `
            -Result PASS -RecommendedPhase QA_VERIFY
    )
    Apply-TestHandoff -Runtime $repairRuntimePath -Handoff (
        New-Handoff -RunId "repair-run" -Status FAIL `
            -Result IMPLEMENTATION_FAILURE -RecommendedPhase IMPLEMENTATION `
            -RetryFrom IMPLEMENTATION -Evidence @("QA failure.")
    )
    $repairRuntime = Get-Content -LiteralPath $repairRuntimePath -Raw | ConvertFrom-Json
    if ($repairRuntime.auditStageIndex -ne 0) {
        throw "QA failure did not reset the AUTO_REPAIR audit sequence."
    }

    $logicOnlyRuntimePath = Join-Path $TestRoot "logic-only-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $logicOnlyRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType AUDIT_ONLY -RunId "logic-only-run" `
        -AuditFixPolicy AUTO_REPAIR -StandaloneStages LOGIC_AUDIT | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $logicOnlyRuntimePath -ToPhase LOGIC_AUDIT | Out-Null
    Apply-TestHandoff -Runtime $logicOnlyRuntimePath -Handoff (
        New-Handoff -RunId "logic-only-run" -Status FAIL `
            -Result LOGIC_FAILURE -RecommendedPhase IMPLEMENTATION `
            -RetryFrom IMPLEMENTATION -Evidence @("Logic failure.")
    )
    Apply-TestHandoff -Runtime $logicOnlyRuntimePath -Handoff (
        New-Handoff -RunId "logic-only-run" -Status PASS `
            -Result IMPLEMENTATION_COMPILED -RecommendedPhase IMPLEMENTATION_AUDIT
    )
    $logicOnlySkip = New-Handoff -RunId "logic-only-run" -Status PASS `
        -Result PASS -RecommendedPhase QA_VERIFY
    Set-TestHandoffSequence -Runtime $logicOnlyRuntimePath -Handoff $logicOnlySkip
    Write-TestJson -Path $HandoffPath -Value $logicOnlySkip
    Assert-Fails -Message "Logic-only AUTO_REPAIR must re-run the requested logic audit." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $logicOnlyRuntimePath
    }
    Apply-TestHandoff -Runtime $logicOnlyRuntimePath -Handoff (
        New-Handoff -RunId "logic-only-run" -Status PASS `
            -Result PASS -RecommendedPhase LOGIC_AUDIT
    )

    $configRuntimePath = Join-Path $TestRoot "config-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $configRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType CONFIG_VALUE_CHANGE -RunId "config-run" | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $configRuntimePath -ToPhase QA_PLAN | Out-Null
    Apply-TestHandoff -Runtime $configRuntimePath -Handoff (
        New-Handoff -RunId "config-run" -Status PASS `
            -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    )
    Apply-TestHandoff -Runtime $configRuntimePath -Handoff (
        New-Handoff -RunId "config-run" -Status PASS `
            -Result TEST_PLAN_AUDIT_PASSED -RecommendedPhase IMPLEMENTATION
    )
    Apply-TestHandoff -Runtime $configRuntimePath -Handoff (
        New-Handoff -RunId "config-run" -Status PASS `
            -Result CONFIG_APPLIED -RecommendedPhase IMPLEMENTATION_AUDIT
    )

    $configReclassRuntimePath = Join-Path $TestRoot "config-reclass-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $configReclassRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType CONFIG_VALUE_CHANGE -RunId "config-reclass-run" | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $configReclassRuntimePath -ToPhase QA_PLAN | Out-Null
    Apply-TestHandoff -Runtime $configReclassRuntimePath -Handoff (
        New-Handoff -RunId "config-reclass-run" -Status PASS `
            -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    )
    Apply-TestHandoff -Runtime $configReclassRuntimePath -Handoff (
        New-Handoff -RunId "config-reclass-run" -Status PASS `
            -Result TEST_PLAN_AUDIT_PASSED -RecommendedPhase IMPLEMENTATION
    )
    Apply-TestHandoff -Runtime $configReclassRuntimePath -Handoff (
        New-Handoff -RunId "config-reclass-run" -Status FAIL `
            -Result TECH_CONTRACT_CHANGE -RecommendedPhase DESIGN_DRAFT `
            -RetryFrom DESIGN_DRAFT -Evidence @("Configuration structure change required.")
    )
    $configReclassRuntime = Get-Content -LiteralPath $configReclassRuntimePath -Raw | ConvertFrom-Json
    if ($configReclassRuntime.taskType -ne "TECH_CONTRACT_CHANGE") {
        throw "Configuration structural change did not persist its reclassified task type."
    }

    $classifiedRuntimePath = Join-Path $TestRoot "classified-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $classifiedRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType UNCLASSIFIED -RunId "classify-run" | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $classifiedRuntimePath -ToPhase CLASSIFY | Out-Null
    Apply-TestHandoff -Runtime $classifiedRuntimePath -Handoff (
        New-Handoff -RunId "classify-run" -Status BLOCKED `
            -Result ENVIRONMENT_BLOCKED -RecommendedPhase CLASSIFY `
            -BlockReason "Source unavailable." -Evidence @("Source unavailable.")
    )
    $blockedClassification = Get-Content -LiteralPath $classifiedRuntimePath -Raw | ConvertFrom-Json
    if ($blockedClassification.taskType -ne "UNCLASSIFIED") {
        throw "Blocked classification must not resolve a task type."
    }
    & $ScriptPath -Operation TransitionRuntime -Path $classifiedRuntimePath -ToPhase CLASSIFY | Out-Null
    Apply-TestHandoff -Runtime $classifiedRuntimePath -Handoff (
        New-Handoff -RunId "classify-run" -Status PASS `
            -Result CONFIG_VALUE_CHANGE -RecommendedPhase QA_PLAN
    )
    $classifiedRuntime = Get-Content -LiteralPath $classifiedRuntimePath -Raw | ConvertFrom-Json
    if ($classifiedRuntime.taskType -ne "CONFIG_VALUE_CHANGE") {
        throw "Classification handoff did not persist the resolved task type."
    }

    $replayRuntimePath = Join-Path $TestRoot "replay-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $replayRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType IMPLEMENTATION_FIX -RunId "replay-run" | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $replayRuntimePath -ToPhase QA_PLAN | Out-Null
    Apply-TestHandoff -Runtime $replayRuntimePath -Handoff (
        New-Handoff -RunId "replay-run" -Status PASS `
            -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    )
    Apply-TestHandoff -Runtime $replayRuntimePath -Handoff (
        New-Handoff -RunId "replay-run" -Status PASS `
            -Result TEST_PLAN_AUDIT_PASSED -RecommendedPhase IMPLEMENTATION
    )
    Apply-TestHandoff -Runtime $replayRuntimePath -Handoff (
        New-Handoff -RunId "replay-run" -Status PASS `
            -Result IMPLEMENTATION_COMPILED -RecommendedPhase IMPLEMENTATION_AUDIT
    )
    Apply-TestHandoff -Runtime $replayRuntimePath -Handoff (
        New-Handoff -RunId "replay-run" -Status PASS `
            -Result PASS -RecommendedPhase QA_VERIFY
    )
    $invalidBusinessEntryRoute = New-Handoff -RunId "replay-run" -Status PASS `
        -Result BUSINESS_TEST_ENTRY_CHANGED -RecommendedPhase DONE
    Set-TestHandoffSequence -Runtime $replayRuntimePath -Handoff $invalidBusinessEntryRoute
    Write-TestJson -Path $HandoffPath -Value $invalidBusinessEntryRoute
    Assert-Fails -Message "Business test entry changes must be re-audited before completion." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $replayRuntimePath
    }
    $firstSelfLoop = New-Handoff -RunId "replay-run" -Status PASS `
        -Result ISOLATED_TEST_FIXED -RecommendedPhase QA_VERIFY
    Apply-TestHandoff -Runtime $replayRuntimePath -Handoff $firstSelfLoop
    Apply-TestHandoff -Runtime $replayRuntimePath -Handoff (
        New-Handoff -RunId "replay-run" -Status PASS `
            -Result ASSERTION_UPDATED -RecommendedPhase QA_VERIFY
    )
    Write-TestJson -Path $HandoffPath -Value $firstSelfLoop
    Assert-Fails -Message "Previously consumed handoffs cannot be replayed after later handoffs." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $replayRuntimePath
    }

    $attemptRuntimePath = Join-Path $TestRoot "attempt-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $attemptRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType IMPLEMENTATION_FIX -RunId "attempt-run" | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $attemptRuntimePath -ToPhase QA_PLAN | Out-Null
    Apply-TestHandoff -Runtime $attemptRuntimePath -Handoff (
        New-Handoff -RunId "attempt-run" -Status PASS `
            -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    )
    Apply-TestHandoff -Runtime $attemptRuntimePath -Handoff (
        New-Handoff -RunId "attempt-run" -Status PASS `
            -Result TEST_PLAN_AUDIT_PASSED -RecommendedPhase IMPLEMENTATION
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Apply-TestHandoff -Runtime $attemptRuntimePath -Handoff (
            New-Handoff -RunId "attempt-run" -Status FAIL `
                -Result IMPLEMENTATION_FAILURE -RecommendedPhase IMPLEMENTATION `
                -RetryFrom IMPLEMENTATION -Evidence @("Implementation attempt $attempt failed.")
        )
    }
    $attemptState = Get-Content -LiteralPath $attemptRuntimePath -Raw | ConvertFrom-Json
    if ($attemptState.attempts.implementation -ne 3) {
        throw "Failed implementation handoffs must atomically increment the attempt counter."
    }
    $excessAttempt = New-Handoff -RunId "attempt-run" -Status FAIL `
        -Result IMPLEMENTATION_FAILURE -RecommendedPhase IMPLEMENTATION `
        -RetryFrom IMPLEMENTATION -Evidence @("Fourth implementation attempt failed.")
    Set-TestHandoffSequence -Runtime $attemptRuntimePath -Handoff $excessAttempt
    Write-TestJson -Path $HandoffPath -Value $excessAttempt
    Assert-Fails -Message "The fourth failed attempt must be rejected by the persisted loop guard." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $attemptRuntimePath
    }
    Apply-TestHandoff -Runtime $attemptRuntimePath -Handoff (
        New-Handoff -RunId "attempt-run" -Status FAIL `
            -Result IMPLEMENTATION_FAILURE -RecommendedPhase IMPLEMENTATION `
            -RetryFrom IMPLEMENTATION -FailureKey "different-root-cause" `
            -Evidence @("A distinct implementation failure was discovered.")
    )
    $attemptState = Get-Content -LiteralPath $attemptRuntimePath -Raw | ConvertFrom-Json
    if (
        $attemptState.attempts.implementation -ne 4 -or
        $attemptState.failureAttempts.IMPLEMENTATION_FAILURE -ne 3 -or
        $attemptState.failureAttempts."different-root-cause" -ne 1
    ) {
        throw "A distinct root cause must start a new three-attempt window."
    }
    $repeatedOriginalRoot = New-Handoff -RunId "attempt-run" -Status FAIL `
        -Result IMPLEMENTATION_FAILURE -RecommendedPhase IMPLEMENTATION `
        -RetryFrom IMPLEMENTATION -Evidence @("The original root cause recurred.")
    Set-TestHandoffSequence -Runtime $attemptRuntimePath -Handoff $repeatedOriginalRoot
    Write-TestJson -Path $HandoffPath -Value $repeatedOriginalRoot
    Assert-Fails -Message "Interleaving another root cause must not reset the original retry window." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $attemptRuntimePath
    }

    $bugFixRuntimePath = Join-Path $TestRoot "bug-fix-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $bugFixRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType BUG_TRIAGE -RunId "bug-fix-run" | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $bugFixRuntimePath -ToPhase BUG_TRIAGE | Out-Null
    Apply-TestHandoff -Runtime $bugFixRuntimePath -Handoff (
        New-Handoff -RunId "bug-fix-run" -Status PASS `
            -Result IMPL_FAILURE -RecommendedPhase QA_PLAN
    )
    Apply-TestHandoff -Runtime $bugFixRuntimePath -Handoff (
        New-Handoff -RunId "bug-fix-run" -Status PASS `
            -Result TEST_PLAN_READY -RecommendedPhase TEST_PLAN_AUDIT
    )
    Apply-TestHandoff -Runtime $bugFixRuntimePath -Handoff (
        New-Handoff -RunId "bug-fix-run" -Status PASS `
            -Result TEST_PLAN_AUDIT_PASSED -RecommendedPhase IMPLEMENTATION
    )
    Apply-TestHandoff -Runtime $bugFixRuntimePath -Handoff (
        New-Handoff -RunId "bug-fix-run" -Status PASS `
            -Result IMPLEMENTATION_COMPILED -RecommendedPhase IMPLEMENTATION_AUDIT
    )
    Apply-TestHandoff -Runtime $bugFixRuntimePath -Handoff (
        New-Handoff -RunId "bug-fix-run" -Status PASS `
            -Result PASS -RecommendedPhase QA_VERIFY
    )

    $originalTestPlan = [System.IO.File]::ReadAllText($TestPlanPath)
    $originalCoverage = [System.IO.File]::ReadAllBytes($CoveragePath)
    [System.IO.File]::AppendAllText($TestPlanPath, "`nUnreviewed execution detail changed.", $Utf8NoBom)
    Write-TestCoverage
    $changedCoverageHandoff = New-Handoff -RunId "replay-run" -Status PASS `
        -Result QA_PASSED -RecommendedPhase DONE
    Set-TestHandoffSequence -Runtime $replayRuntimePath -Handoff $changedCoverageHandoff
    Write-TestJson -Path $HandoffPath -Value $changedCoverageHandoff
    Assert-Fails -Message "Coverage changes after TEST_PLAN_AUDIT must return to QA planning." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $replayRuntimePath
    }
    $changedBugCoverageHandoff = New-Handoff -RunId "bug-fix-run" -Status PASS `
        -Result QA_PASSED -RecommendedPhase DONE
    Set-TestHandoffSequence -Runtime $bugFixRuntimePath -Handoff $changedBugCoverageHandoff
    Write-TestJson -Path $HandoffPath -Value $changedBugCoverageHandoff
    Assert-Fails -Message "Implementation-defect bug flows must retain durable audited coverage." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $bugFixRuntimePath
    }
    [System.IO.File]::WriteAllText($TestPlanPath, $originalTestPlan, $Utf8NoBom)
    [System.IO.File]::WriteAllBytes($CoveragePath, $originalCoverage)

    # UpdateHash: cosmetic fix without invalidating approval (avoids avalanche reset).
    # At this point requirement is APPROVED. Apply a cosmetic change and update hash only.
    $beforeUpdate = Get-Content -LiteralPath $ApprovalPath -Raw | ConvertFrom-Json
    $requirementArtifact = Join-Path $FeatureRoot "01_server_rules.md"
    [System.IO.File]::AppendAllText($requirementArtifact, "`n<!-- typo fix -->", $Utf8NoBom)
    Assert-Fails -Message "Changed approved artifact must invalidate approval before UpdateHash." -Action {
        & $ScriptPath -Operation ValidateApproval -Path $ApprovalPath
    }
    & $ScriptPath -Operation UpdateHash -Path $ApprovalPath -Gate requirement | Out-Null
    $afterUpdate = Get-Content -LiteralPath $ApprovalPath -Raw | ConvertFrom-Json
    if ($afterUpdate.requirement.status -ne "APPROVED") {
        throw "UpdateHash must preserve APPROVED status; got '$($afterUpdate.requirement.status)'."
    }
    if ($afterUpdate.requirement.sha256 -eq $beforeUpdate.requirement.sha256) {
        throw "UpdateHash must refresh sha256 after a cosmetic change."
    }
    if (
        $afterUpdate.requirement.approvedAt -cne $beforeUpdate.requirement.approvedAt -or
        $afterUpdate.requirement.approvedBy -cne $beforeUpdate.requirement.approvedBy
    ) {
        throw "UpdateHash must not alter approvedAt/approvedBy."
    }
    & $ScriptPath -Operation ValidateApproval -Path $ApprovalPath | Out-Null
    # UpdateHash on a DRAFT gate must fail. Design is still APPROVED here; reset it to test.
    & $ScriptPath -Operation ResetApproval -Path $ApprovalPath -Gate design | Out-Null
    Assert-Fails -Message "UpdateHash must reject DRAFT gates." -Action {
        & $ScriptPath -Operation UpdateHash -Path $ApprovalPath -Gate design
    }

    # Status: read-only diagnostic, reports gate status + hash match.
    $statusOutput = & $ScriptPath -Operation Status -Path $ApprovalPath 2>&1 |
        Out-String
    if ($statusOutput -notmatch "gate=requirement status=APPROVED") {
        throw "Status must report requirement gate as APPROVED. Output: $statusOutput"
    }
    if ($statusOutput -notmatch "gate=design status=DRAFT") {
        throw "Status must report design gate as DRAFT (we reset it above). Output: $statusOutput"
    }
    # Status on a nonexistent state file must not throw.
    $missingStatus = & $ScriptPath -Operation Status -Path (Join-Path $TestRoot "nope.json") 2>&1 |
        Out-String
    if ($missingStatus -notmatch "NO_STATE") {
        throw "Status on missing file must report NO_STATE. Output: $missingStatus"
    }

    [System.IO.File]::AppendAllText((Join-Path $FeatureRoot "01_server_rules.md"), "-changed", $Utf8NoBom)
    Assert-Fails -Message "Changed approved artifact must invalidate approval." -Action {
        & $ScriptPath -Operation ValidateApproval -Path $ApprovalPath
    }
    & $ScriptPath -Operation ResetApproval -Path $ApprovalPath -Gate requirement | Out-Null
    & $ScriptPath -Operation ValidateApproval -Path $ApprovalPath | Out-Null

    $doneHandoff = New-Handoff -RunId "replay-run" -Status PASS `
        -Result QA_PASSED -RecommendedPhase DONE
    Set-TestHandoffSequence -Runtime $replayRuntimePath -Handoff $doneHandoff
    Write-TestJson -Path $HandoffPath -Value $doneHandoff
    Assert-Fails -Message "Revoked approvals must prevent delivery completion." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $replayRuntimePath
    }

    $bugRuntimePath = Join-Path $TestRoot "bug-runtime.json"
    & $ScriptPath -Operation InitRuntime -Path $bugRuntimePath -Feature "Example" `
        -SpecDirectory $FeatureRoot -TaskType BUG_TRIAGE -RunId "bug-run" | Out-Null
    & $ScriptPath -Operation TransitionRuntime -Path $bugRuntimePath -ToPhase BUG_TRIAGE | Out-Null
    $contradictoryBugResult = New-Handoff -RunId "bug-run" -Status PASS `
        -Result IMPLEMENTATION_FAILURE -RecommendedPhase DONE
    Set-TestHandoffSequence -Runtime $bugRuntimePath -Handoff $contradictoryBugResult
    Write-TestJson -Path $HandoffPath -Value $contradictoryBugResult
    Assert-Fails -Message "Bug triage result semantics must match the selected route." -Action {
        & $ScriptPath -Operation ApplyHandoff -Path $HandoffPath -RuntimePath $bugRuntimePath
    }
    Apply-TestHandoff -Runtime $bugRuntimePath -Handoff (
        New-Handoff -RunId "bug-run" -Status PASS `
            -Result INVALID -RecommendedPhase DONE
    )

    $approvalLockPath = $ApprovalPath + ".lock"
    $heldApprovalLock = [System.IO.File]::Open(
        $approvalLockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $stateRaceOut = Join-Path $TestRoot "state-race.out"
        $stateRaceErr = Join-Path $TestRoot "state-race.err"
        $stateRaceProcess = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList @(
                "-NoProfile",
                "-File",
                $ScriptPath,
                "-Operation",
                "ResetApproval",
                "-Path",
                $ApprovalPath,
                "-Gate",
                "design",
                "-OwnerWorkflow",
                "CUSTOM_SKILLS",
                "-OwnerAgent",
                "COPILOT",
                "-OwnerId",
                "feature-run"
            ) `
            -RedirectStandardOutput $stateRaceOut `
            -RedirectStandardError $stateRaceErr `
            -PassThru

        $ownerLockPath = Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY "example.json.lock"
        $ownerLockObserved = $false
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            if (Test-Path -LiteralPath $ownerLockPath) {
                $ownerLockObserved = $true
                break
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $ownerLockObserved) {
            $errContent = if (Test-Path -LiteralPath $stateRaceErr) { Get-Content -LiteralPath $stateRaceErr -Raw } else { "" }
            $outContent = if (Test-Path -LiteralPath $stateRaceOut) { Get-Content -LiteralPath $stateRaceOut -Raw } else { "" }
            throw "State mutation did not acquire the owner lock before its state lock. Err: $errContent | Out: $outContent"
        }

        $completeRaceOut = Join-Path $TestRoot "complete-race.out"
        $completeRaceErr = Join-Path $TestRoot "complete-race.err"
        $completeRaceProcess = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList @(
                "-NoProfile",
                "-File",
                $OwnerScriptPath,
                "-Operation",
                "Complete",
                "-SpecDirectory",
                $FeatureRoot,
                "-Feature",
                "Example",
                "-Workflow",
                "CUSTOM_SKILLS",
                "-Agent",
                "COPILOT",
                "-OwnerId",
                "feature-run"
            ) `
            -RedirectStandardOutput $completeRaceOut `
            -RedirectStandardError $completeRaceErr `
            -PassThru
        Start-Sleep -Milliseconds 300
        if ($completeRaceProcess.HasExited) {
            throw "Ownership completed while a guarded state mutation was still pending."
        }
    } finally {
        $heldApprovalLock.Dispose()
        Remove-Item -LiteralPath $approvalLockPath -Force -ErrorAction SilentlyContinue
    }
    $stateRaceProcess.WaitForExit()
    $completeRaceProcess.WaitForExit()
    if ($stateRaceProcess.ExitCode -ne 0 -or $completeRaceProcess.ExitCode -ne 0) {
        $sOut = if (Test-Path $stateRaceOut) { Get-Content $stateRaceOut -Raw } else { "" }
        $sErr = if (Test-Path $stateRaceErr) { Get-Content $stateRaceErr -Raw } else { "" }
        $cOut = if (Test-Path $completeRaceOut) { Get-Content $completeRaceOut -Raw } else { "" }
        $cErr = if (Test-Path $completeRaceErr) { Get-Content $completeRaceErr -Raw } else { "" }
        throw "The guarded state mutation and subsequent completion must both succeed. StateExit=$($stateRaceProcess.ExitCode), CompleteExit=$($completeRaceProcess.ExitCode)`nStateOut: $($sOut)`nStateErr: $($sErr)`nCompOut: $($cOut)`nCompErr: $($cErr)"
    }

    # Test SyncCoverage and Get-CoveragePlaceholderWarnings
    $syncFeature = "SyncCoverageTestFeature"
    $syncSpec = Join-Path $TestRoot ".ai-workspace/specs/features/$syncFeature"
    [System.IO.Directory]::CreateDirectory($syncSpec) | Out-Null
    $syncReq = Join-Path $syncSpec "01_server_rules.md"
    $syncDes = Join-Path $syncSpec "06_design_contract.md"
    [System.IO.File]::WriteAllText($syncReq, "# Rules`n- BR-01 buy flow`n- BR-02 limit flow", $Utf8NoBom)
    [System.IO.File]::WriteAllText($syncDes, "# Design`n- DC-01 buy design`n- DC-02 limit design", $Utf8NoBom)
    $syncApproval = Join-Path $syncSpec "00_workflow_state.json"
    $syncReqSha = Get-TestArtifactHash -Path $syncReq
    $syncDesSha = Get-TestArtifactHash -Path $syncDes
    $syncAppState = [ordered]@{
        schemaVersion = "1.0"
        feature = "SyncCoverageTestFeature"
        baseline = "0"
        requirement = @{ status = "APPROVED"; sha256 = $syncReqSha; approvedBy = "tester"; approvedAt = "2026-08-23T12:00:00Z"; artifact = "01_server_rules.md" }
        design = @{ status = "APPROVED"; sha256 = $syncDesSha; approvedBy = "tester"; approvedAt = "2026-08-23T12:00:00Z"; artifact = "06_design_contract.md" }
    }
    [System.IO.File]::WriteAllText($syncApproval, ($syncAppState | ConvertTo-Json -Depth 10), $Utf8NoBom)

    $syncTestPlan = Join-Path $syncSpec "05_test_plan.md"
    $testPlanText = @"
# Test Plan
- TC-01 Test Buy
- TC-02 Test Limit

<!-- meta: { "id": "TC-01", "title": "Test Buy", "covers": ["BR-01", "DC-01"] } -->
<!-- meta: { "id": "TC-02", "title": "Test Limit", "covers": ["BR-02", "DC-02"], "priority": "P0" } -->
"@
    [System.IO.File]::WriteAllText($syncTestPlan, $testPlanText, $Utf8NoBom)
    $syncCovPath = Join-Path $syncSpec "05_test_coverage.json"
    & $ScriptPath -Operation SyncCoverage -Path $syncCovPath
    if (-not (Test-Path -LiteralPath $syncCovPath)) { throw "SyncCoverage must generate 05_test_coverage.json" }
    $covObj = Get-Content -LiteralPath $syncCovPath -Raw | ConvertFrom-Json
    if ($covObj.cases.Count -ne 2) { throw "SyncCoverage must parse 2 cases, got $($covObj.cases.Count)" }
    if ($covObj.cases[0].priority -ne "P1") { throw "Default case priority must be P1, got $($covObj.cases[0].priority)" }
    if ($covObj.cases[0].status -ne "PLANNED") { throw "Synced case status must be PLANNED, got $($covObj.cases[0].status)" }
    if ($covObj.cases[1].priority -ne "P0") { throw "Explicit case priority must be P0, got $($covObj.cases[1].priority)" }
    if ($covObj.cases[1].status -ne "PLANNED") { throw "Explicit case status must be PLANNED, got $($covObj.cases[1].status)" }

    # Test Phase-Aware validation
    # In PLAN phase, non-existent carrier files are INFO/WARN and result is VALID
    $planValidation = & $ScriptPath -Operation ValidateTestCoverage -Path $syncCovPath -Phase PLAN
    if ($planValidation -notcontains "VALID") {
        throw "ValidateTestCoverage -Phase PLAN must output VALID, got: $($planValidation -join '; ')"
    }

    # Test automatic phase derivation for PLANNING phase
    $syncFeatState = Join-Path $syncSpec "feature-state.json"
    [System.IO.File]::WriteAllText($syncFeatState, '{"schemaVersion":"1.0","feature":"SyncCoverageTestFeature","tier":"T3","baseline":"0","phase":"PLANNING","updatedAt":"2026-08-27T00:00:00Z"}', $Utf8NoBom)
    $autoPlanValidation = & $ScriptPath -Operation ValidateTestCoverage -Path $syncCovPath
    if ($autoPlanValidation -notcontains "VALID") {
        throw "ValidateTestCoverage with PLANNING phase must auto-derive PLAN mode and output VALID, got: $($autoPlanValidation -join '; ')"
    }

    # In VERIFY phase, missing carrier files on disk for P0/P1 must be ERROR and throw VALIDATE_TEST_COVERAGE_FAILED
    Assert-Fails -Message "ValidateTestCoverage -Phase VERIFY must fail when carriers are missing or placeholders remain" -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $syncCovPath -Phase VERIFY
    }

    # In VERIFY phase with real carrier file in workspace root test/
    $realTestDir = Join-Path $TestRoot "test/com/game"
    [System.IO.Directory]::CreateDirectory($realTestDir) | Out-Null
    $realTestFile = Join-Path $realTestDir "RealTest.java"
    [System.IO.File]::WriteAllText($realTestFile, "package com.game; import org.junit.Test; public class RealTest { @Test public void testBuy() {} }", $Utf8NoBom)
    
    $syncRisk = & $ScriptPath -Operation AssessRisk -Path (Split-Path -Parent $syncCovPath) 2>&1 | Out-String
    $syncDigest = ($syncRisk | ConvertFrom-Json).changeSetDigest
    
    $covObj = Get-Content -LiteralPath $syncCovPath -Raw | ConvertFrom-Json -AsHashtable
    $covObj.cases[0].automationCarrier = "test/com/game/RealTest.java#testBuy"
    $covObj.cases[0].status = "VERIFIED"
    $covObj.cases[1].automationCarrier = "test/com/game/RealTest.java#testBuy"
    $covObj.cases[1].status = "VERIFIED"
    $covObj["executionEvidence"] = [ordered]@{
        command = "pwsh test"
        exitCode = 0
        executedAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
        sourceCommitSha = "abcdef1234567890"
        workingTreeDigest = $syncDigest
        testCount = 2
        passedCount = 2
        failedCount = 0
    }
    [System.IO.File]::WriteAllText($syncCovPath, ($covObj | ConvertTo-Json -Depth 10), $Utf8NoBom)
    
    $realVerifyValidation = & $ScriptPath -Operation ValidateTestCoverage -Path $syncCovPath -Phase VERIFY
    if ($realVerifyValidation -notcontains "VALID") {
        throw "ValidateTestCoverage -Phase VERIFY must output VALID when relative carrier exists in workspace root test/, got: $($realVerifyValidation -join '; ')"
    }

    # Test VCS untracked file detection in VerifyCompletion
    $vcsTestDir = Join-Path $TestRoot "vcs_untracked_test"
    [System.IO.Directory]::CreateDirectory($vcsTestDir) | Out-Null
    & git -C $vcsTestDir init --quiet
    $vcsSpecDir = Join-Path $vcsTestDir ".ai-workspace/specs/features/VcsTestFeature"
    [System.IO.Directory]::CreateDirectory($vcsSpecDir) | Out-Null
    $vcsFeatState = Join-Path $vcsSpecDir "feature-state.json"
    [System.IO.File]::WriteAllText($vcsFeatState, '{"schemaVersion":"1.0","feature":"VcsTestFeature","tier":"T2","baseline":"0","phase":"IMPLEMENTING"}', $Utf8NoBom)
    
    # Create untracked CSV file in config/
    $vcsConfigDir = Join-Path $vcsTestDir "config"
    [System.IO.Directory]::CreateDirectory($vcsConfigDir) | Out-Null
    $untrackedCsv = Join-Path $vcsConfigDir "new_table.csv"
    [System.IO.File]::WriteAllText($untrackedCsv, "id,value`n1,test", $Utf8NoBom)

    $vcsVerifyOut = & $ScriptPath -Operation VerifyCompletion -Path (Join-Path $vcsSpecDir "workflow-state.json")
    if ($LASTEXITCODE -eq 0 -or $vcsVerifyOut -notcontains "VERIFY_COMPLETION_FAIL") {
        throw "VerifyCompletion must FAIL when untracked .csv file exists in config/, got: $($vcsVerifyOut -join '; ')"
    }

    # Test DESIGN_ONLY gateMode (single design gate for technical contract changes)
    $designOnlyDir = Join-Path $TestRoot "design_only_feature"
    [System.IO.Directory]::CreateDirectory($designOnlyDir) | Out-Null
    $doSpecDir = Join-Path $designOnlyDir ".ai-workspace/specs/features/DesignOnlyFeature"
    [System.IO.Directory]::CreateDirectory($doSpecDir) | Out-Null
    $doApproval = Join-Path $doSpecDir "00_workflow_state.json"
    $doFeatState = Join-Path $doSpecDir "feature-state.json"
    $doReq = Join-Path $doSpecDir "01_server_rules.md"
    $doDes = Join-Path $doSpecDir "06_design_contract.md"
    $doPlan = Join-Path $doSpecDir "05_test_plan.md"
    $doCov = Join-Path $doSpecDir "05_test_coverage.json"

    $doTestFile = Join-Path $designOnlyDir "test/MyTest.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $doTestFile)) | Out-Null
    [System.IO.File]::WriteAllText($doTestFile, "package test; public class MyTest { @Test public void testProto() {} }", $Utf8NoBom)

    [System.IO.File]::WriteAllText($doDes, "# Design Contract`n`n- DC-01: Proto update`n- DR-01: Storage safety`n- TW-01: Workflow`n", $Utf8NoBom)
    [System.IO.File]::WriteAllText($doPlan, "# Test Plan`n`n- TC-01: Test proto update`n<!-- meta: { `"id`": `"TC-01`", `"title`": `"Test proto update`", `"covers`": [`"DC-01`", `"DR-01`", `"TW-01`"], `"carrier`": `"test/MyTest.java#testProto`" } -->`n", $Utf8NoBom)
    [System.IO.File]::WriteAllText($doFeatState, '{"schemaVersion":"1.0","feature":"DesignOnlyFeature","tier":"T3","gateMode":"DESIGN_ONLY","phase":"DONE"}', $Utf8NoBom)

    $doOwnerId = "do-cursor"
    $doSession = New-TestSuperpowersOwner `
        -Feature "DesignOnlyFeature" `
        -SpecDirectory $doSpecDir `
        -Agent CURSOR `
        -OwnerId $doOwnerId

    & $ScriptPath -Operation InitApproval -Path $doApproval -Feature "DesignOnlyFeature" -GateMode DESIGN_ONLY `
        -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $doOwnerId
    $doStatus = & $ScriptPath -Operation Status -Path $doApproval
    $doStatusStr = $doStatus | Out-String
    if ($doStatusStr -notmatch "status=EXEMPT\(DESIGN_ONLY\)") {
        throw "Status must show EXEMPT(DESIGN_ONLY) for requirement gate under DESIGN_ONLY mode, got: $doStatusStr"
    }

    # Approving design directly must succeed without requirement approval
    & $ScriptPath -Operation Approve -Path $doApproval -Gate design -ApprovedBy "human:reviewer" `
        -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $doOwnerId
    
    # SyncCoverage and ValidateTestCoverage
    & $ScriptPath -Operation SyncCoverage -Path $doCov
    $doVal = & $ScriptPath -Operation ValidateTestCoverage -Path $doCov -Phase PLAN
    if ($doVal -notcontains "VALID") {
        throw "ValidateTestCoverage must succeed in DESIGN_ONLY mode without requirement approval, got: $($doVal -join '; ')"
    }

    $doImpactPath = Join-Path $doSpecDir "04_change_impact.json"
    $doRisk = & $ScriptPath -Operation AssessRisk -Path $doSpecDir -Baseline "0" 2>&1 | Out-String
    $doDigest = ($doRisk | ConvertFrom-Json).changeSetDigest

    # Refine coverage to VERIFIED with executionEvidence for completion verification
    $doCovObj = Get-Content -LiteralPath $doCov -Raw | ConvertFrom-Json
    $doCovObj.cases[0].status = "VERIFIED"
    $doCovObj | Add-Member -NotePropertyName "executionEvidence" -NotePropertyValue ([ordered]@{
        command = "pwsh test"
        exitCode = 0
        executedAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
        sourceCommitSha = "abcdef1234567890"
        workingTreeDigest = $doDigest
        testCount = 1
        passedCount = 1
        failedCount = 0
    })
    [System.IO.File]::WriteAllText($doCov, ($doCovObj | ConvertTo-Json -Depth 10), $Utf8NoBom)
    $doImpactJson = @"
{
  "schemaVersion": "1.0",
  "feature": "DesignOnlyFeature",
  "baseline": "0",
  "changeSetDigest": "$doDigest",
  "changedSymbols": ["DesignOnlyFeature"],
  "entryPoints": ["TEST"],
  "upstreamCallers": ["TestRunner"],
  "downstreamEffects": [],
  "stateReadsWrites": [],
  "behaviorVariants": [],
  "invariants": [],
  "excludedWithReason": [],
  "requiredRegressionCases": ["TC-01"]
}
"@
    [System.IO.File]::WriteAllText($doImpactPath, $doImpactJson, $Utf8NoBom)

    # Create dummy classes dir so compile verification passes
    $doBuild = Join-Path $designOnlyDir "build/classes"
    [System.IO.Directory]::CreateDirectory($doBuild) | Out-Null
    $doVerify = & $ScriptPath -Operation VerifyCompletion -Path $doApproval
    $doVerifyStr = $doVerify | Out-String
    if ($doVerify -notcontains "VERIFY_COMPLETION_PASS" -or $doVerifyStr -notmatch "需求门禁\(豁免: 仅技术契约\)") {
        throw "VerifyCompletion must pass and display requirement gate exemption in DESIGN_ONLY mode, got: $doVerifyStr"
    }

    # Test ValidateChangeImpact operation
    $impactDir = Join-Path $TestRoot "impact_test"
    [System.IO.Directory]::CreateDirectory($impactDir) | Out-Null
    & git -C $impactDir init --quiet
    & git -C $impactDir config user.name "Tester"
    & git -C $impactDir config user.email "tester@test.local"
    $impactDummy = Join-Path $impactDir "dummy.txt"
    [System.IO.File]::WriteAllText($impactDummy, "dummy", $Utf8NoBom)
    & git -C $impactDir add .
    & git -C $impactDir commit -m "init" --quiet
    $impactBaseSha = (& git -C $impactDir rev-parse HEAD | Out-String).Trim()

    $impactSpecDir = Join-Path $impactDir ".ai-workspace/specs/features/ImpactTestFeature"
    [System.IO.Directory]::CreateDirectory($impactSpecDir) | Out-Null
    $impactPath = Join-Path $impactSpecDir "04_change_impact.json"
    
    $assessObj = (& $ScriptPath -Operation AssessRisk -Path $impactSpecDir -Baseline $impactBaseSha | ConvertFrom-Json)
    $expectedDigest = $assessObj.changeSetDigest
    $impactJson = @"
{
  "schemaVersion": "1.0",
  "feature": "ImpactTestFeature",
  "baseline": "$impactBaseSha",
  "changeSetDigest": "$expectedDigest",
  "changedSymbols": ["com.game.AirItemRecord#reset", "com.game.GiftPackHelper#buyGift"],
  "entryPoints": ["COUPON_PURCHASE", "GET_CYCLE_ACTIVITY_STORE_INFO"],
  "upstreamCallers": ["DispatchServlet", "AirProcess#doHttpRequest"],
  "downstreamEffects": [
    {
      "effectType": "PERSISTENCE",
      "targetSystem": "AirItemRecord",
      "persistenceMethod": "updateAirData"
    }
  ],
  "stateReadsWrites": [
    {
      "stateKey": "s_buyTotal",
      "operation": "RESET",
      "persisted": true
    }
  ],
  "behaviorVariants": [
    {
      "typeKey": "TYPE_45",
      "relationToLegacy": "IDENTICAL_TO_LEGACY",
      "description": "Daily limit reset logic is identical to legacy gift packs"
    }
  ],
  "invariants": [
    {
      "invariantId": "INV-01",
      "statement": "Yesterday purchase count must be reset before today first purchase",
      "violationRisk": "Over-purchase or limit permanently deadlocked to 0"
    }
  ],
  "excludedWithReason": [
    {
      "symbol": "com.game.ChatHelper",
      "reason": "Gift purchase does not trigger world broadcast"
    }
  ],
  "requiredRegressionCases": ["TC-01"]
}
"@
    [System.IO.File]::WriteAllText($impactPath, $impactJson, $Utf8NoBom)
    $impactVal = & $ScriptPath -Operation ValidateChangeImpact -Path $impactPath
    if ($impactVal -notcontains "VALID") {
        throw "ValidateChangeImpact must return VALID for schema-compliant impact JSON, got: $($impactVal -join '; ')"
    }

    # Test stale changeSetDigest rejection
    $staleImpactJson = $impactJson.Replace($expectedDigest, "0000000000000000000000000000000000000000000000000000000000000000")
    [System.IO.File]::WriteAllText($impactPath, $staleImpactJson, $Utf8NoBom)
    Assert-Fails -Message "ValidateChangeImpact must fail when changeSetDigest is stale" -Action {
        & $ScriptPath -Operation ValidateChangeImpact -Path $impactPath
    }

    # Test carrier method existence verification in Java test files
    $carrierMethodTestDir = Join-Path $TestRoot "carrier_method_test"
    [System.IO.Directory]::CreateDirectory($carrierMethodTestDir) | Out-Null
    $cmSpecDir = Join-Path $carrierMethodTestDir ".ai-workspace/specs/features/CarrierMethodFeature"
    [System.IO.Directory]::CreateDirectory($cmSpecDir) | Out-Null
    $cmTestJava = Join-Path $carrierMethodTestDir "test/CarrierTest.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $cmTestJava)) | Out-Null
    [System.IO.File]::WriteAllText($cmTestJava, "package test; public class CarrierTest { @Test public void realTestMethod() {} public void helperMethod() {} }", $Utf8NoBom)

    $cmReq = Join-Path $cmSpecDir "01_server_rules.md"
    $cmDes = Join-Path $cmSpecDir "06_design_contract.md"
    $cmPlan = Join-Path $cmSpecDir "05_test_plan.md"
    $cmApproval = Join-Path $cmSpecDir "00_workflow_state.json"
    [System.IO.File]::WriteAllText($cmReq, "# Rules`n- BR-01: Rule", $Utf8NoBom)
    [System.IO.File]::WriteAllText($cmDes, "# Design`n- DC-01: Contract", $Utf8NoBom)
    [System.IO.File]::WriteAllText($cmPlan, "# Plan`n- TC-01: Carrier method test", $Utf8NoBom)

    $cmOwnerId = "cm-cursor"
    $cmSession = New-TestSuperpowersOwner `
        -Feature "CarrierMethodFeature" `
        -SpecDirectory $cmSpecDir `
        -Agent CURSOR `
        -OwnerId $cmOwnerId

    & $ScriptPath -Operation InitApproval -Path $cmApproval -Feature "CarrierMethodFeature" -GateMode DESIGN_ONLY `
        -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $cmOwnerId
    & $ScriptPath -Operation Approve -Path $cmApproval -Gate design -ApprovedBy "human:reviewer" `
        -OwnerWorkflow SUPERPOWERS -OwnerAgent CURSOR -OwnerId $cmOwnerId

    $cmCovPath = Join-Path $cmSpecDir "05_test_coverage.json"
    $dynamicRecent = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $cmRisk = & $ScriptPath -Operation AssessRisk -Path $cmSpecDir -Baseline "0" 2>&1 | Out-String
    $cmDigest = ($cmRisk | ConvertFrom-Json).changeSetDigest
    $cmCovJson = @"
{
  "schemaVersion": "1.0",
  "feature": "CarrierMethodFeature",
  "requirementArtifact": "01_server_rules.md",
  "requirementSha256": "$((Get-TestArtifactHash -Path $cmReq))",
  "designArtifact": "06_design_contract.md",
  "designSha256": "$((Get-TestArtifactHash -Path $cmDes))",
  "testPlanArtifact": "05_test_plan.md",
  "testPlanSha256": "$((Get-TestArtifactHash -Path $cmPlan))",
  "cases": [
    {
      "id": "TC-01",
      "title": "Test non-existent carrier method",
      "status": "IMPLEMENTED",
      "priority": "P1",
      "testTypes": ["FUNCTIONAL"],
      "requirementIds": [],
      "designIds": ["DC-01"],
      "setup": ["Setup carrier fixture"],
      "trigger": ["Trigger carrier test"],
      "assertions": {
        "protocol": [
          { "target": "status", "operator": "EQ", "expected": "VALID" }
        ]
      },
      "cleanup": ["Cleanup carrier fixture"],
      "automationCarrier": "test/CarrierTest.java#nonExistentMethod"
    }
  ],
  "riskExemptions": [],
  "executionEvidence": {
    "command": "pwsh test",
    "exitCode": 0,
    "executedAt": "$dynamicRecent",
    "sourceCommitSha": "abcdef1234567890",
    "workingTreeDigest": "$cmDigest",
    "testCount": 1,
    "passedCount": 1,
    "failedCount": 0
  }
}
"@
    [System.IO.File]::WriteAllText($cmCovPath, $cmCovJson, $Utf8NoBom)
    $cmValidationStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($cmValidationStr -notmatch "does not exist in") {
        throw "ValidateTestCoverage must report error when carrier method does not exist in .java file. Output: $cmValidationStr"
    }

    # Test rejection of Java helper methods without @Test annotation
    $cmHelperCov = $cmCovJson.Replace("nonExistentMethod", "helperMethod")
    [System.IO.File]::WriteAllText($cmCovPath, $cmHelperCov, $Utf8NoBom)
    $cmHelperStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($cmHelperStr -notmatch "is not annotated with @Test") {
        throw "ValidateTestCoverage must reject helper methods without @Test. Output: $cmHelperStr"
    }

    # Test rejection of empty #method in carrier
    $cmEmptyMethodCov = $cmCovJson.Replace("test/CarrierTest.java#nonExistentMethod", "test/CarrierTest.java#")
    [System.IO.File]::WriteAllText($cmCovPath, $cmEmptyMethodCov, $Utf8NoBom)
    $cmEmptyStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($cmEmptyStr -notmatch "has empty method name after") {
        throw "ValidateTestCoverage must reject carrier with empty method name after '#'. Output: $cmEmptyStr"
    }

    # Test executionEvidence count mismatch rejection
    $cmMismatchCov = $cmCovJson.Replace('"passedCount": 1', '"passedCount": 2') # passed 2 + failed 0 != testCount 1
    [System.IO.File]::WriteAllText($cmCovPath, $cmMismatchCov, $Utf8NoBom)
    $cmMismatchStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($cmMismatchStr -notmatch "count mismatch") {
        throw "ValidateTestCoverage must reject executionEvidence count mismatch. Output: $cmMismatchStr"
    }

    # Test executionEvidence invalid timestamp rejection
    $cmBadDateCov = $cmCovJson.Replace("`"executedAt`": `"$dynamicRecent`"", '"executedAt": "invalid-timestamp"')
    [System.IO.File]::WriteAllText($cmCovPath, $cmBadDateCov, $Utf8NoBom)
    Assert-Fails -Message "ValidateTestCoverage must reject invalid executionEvidence timestamp" -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY
    }

    # Test executionEvidence future timestamp rejection
    $cmFutureDateCov = $cmCovJson.Replace("`"executedAt`": `"$dynamicRecent`"", '"executedAt": "2099-01-01T00:00:00Z"')
    [System.IO.File]::WriteAllText($cmCovPath, $cmFutureDateCov, $Utf8NoBom)
    $cmFutureStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($cmFutureStr -notmatch "is in the future") {
        throw "ValidateTestCoverage must reject future executionEvidence timestamp. Output: $cmFutureStr"
    }

    # Test executionEvidence invalid SHA rejection
    $cmBadShaCov = $cmCovJson.Replace('"sourceCommitSha": "abcdef1234567890"', '"sourceCommitSha": "invalid!@#$"')
    [System.IO.File]::WriteAllText($cmCovPath, $cmBadShaCov, $Utf8NoBom)
    Assert-Fails -Message "ValidateTestCoverage must reject invalid executionEvidence sourceCommitSha" -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY
    }

    # Test rejection of carrier #method on unsupported extension
    $xyzTestFile = Join-Path $TestRoot "demo.xyz"
    [System.IO.File]::WriteAllText($xyzTestFile, "some dummy text", $Utf8NoBom)
    $xyzHelperCov = $cmCovJson.Replace("test/CarrierTest.java#nonExistentMethod", ($xyzTestFile.Replace("\", "/") + "#someMethod"))
    [System.IO.File]::WriteAllText($cmCovPath, $xyzHelperCov, $Utf8NoBom)
    $xyzStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($xyzStr -notmatch "unsupported on file extension '\.xyz'") {
        throw "ValidateTestCoverage must reject carrier method on unsupported file extension. Output: $xyzStr"
    }

    # Test FAST_TRACK source code modification rejection in VerifyCompletion
    $ftTestDir = Join-Path $TestRoot "ft_src_test"
    [System.IO.Directory]::CreateDirectory($ftTestDir) | Out-Null
    & git -C $ftTestDir init --quiet
    & git -C $ftTestDir config user.name "Tester"
    & git -C $ftTestDir config user.email "tester@test.local"
    $ftDummy = Join-Path $ftTestDir "dummy.txt"
    [System.IO.File]::WriteAllText($ftDummy, "dummy", $Utf8NoBom)
    & git -C $ftTestDir add .
    & git -C $ftTestDir commit -m "init" --quiet
    $ftBaseSha = (& git -C $ftTestDir rev-parse HEAD | Out-String).Trim()

    $ftSpecDir = Join-Path $ftTestDir ".ai-workspace/specs/features/FtSrcFeature"
    [System.IO.Directory]::CreateDirectory($ftSpecDir) | Out-Null
    $ftFeatState = Join-Path $ftSpecDir "feature-state.json"
    $ftFeatStateContent = '{"schemaVersion":"1.0","feature":"FtSrcFeature","tier":"FAST_TRACK","phase":"DONE","baseline":"' + $ftBaseSha + '","updatedAt":"' + $dynamicRecent + '"}'
    [System.IO.File]::WriteAllText($ftFeatState, $ftFeatStateContent, $Utf8NoBom)
    $ftSrcFile = Join-Path $ftTestDir "src/com/game/Main.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $ftSrcFile)) | Out-Null
    [System.IO.File]::WriteAllText($ftSrcFile, "package com.game; public class Main {}", $Utf8NoBom)
    
    $ftVerifyOut = & $ScriptPath -Operation VerifyCompletion -Path (Join-Path $ftSpecDir "workflow-state.json") 2>&1
    $ftVerifyStr = $ftVerifyOut | Out-String
    if ($LASTEXITCODE -eq 0 -or ($ftVerifyStr -notmatch "FAST_TRACK violation" -and $ftVerifyStr -notmatch "HIGH_RISK_TIER_DOWNGRADE_FORBIDDEN")) {
        throw "VerifyCompletion must fail FAST_TRACK when src/ files are modified. Output: $ftVerifyStr"
    }

    # Test floating baseline rejection in ValidateChangeImpact
    $floatingImpDir = Join-Path $TestRoot "floating_baseline_spec"
    [System.IO.Directory]::CreateDirectory($floatingImpDir) | Out-Null
    $floatingImpPath = Join-Path $floatingImpDir "04_change_impact.json"
    $floatingImpJson = @"
{
  "schemaVersion": "1.0",
  "feature": "FloatingFeature",
  "baseline": "HEAD",
  "changeSetDigest": "1111111111111111111111111111111111111111111111111111111111111111",
  "changedSymbols": ["src/com/game/Shop.java"],
  "entryPoints": ["ProtoBuy"],
  "upstreamCallers": [],
  "downstreamEffects": [],
  "stateReadsWrites": [],
  "invariants": [],
  "requiredRegressionCases": ["TC-REG01"]
}
"@
    [System.IO.File]::WriteAllText($floatingImpPath, $floatingImpJson, $Utf8NoBom)
    Assert-Fails -Message "ValidateChangeImpact must reject floating baseline like HEAD/WORKING" -Action {
        & $ScriptPath -Operation ValidateChangeImpact -Path $floatingImpPath
    }

    # Test Python helper function carrier rejection
    $pyTestFile = Join-Path $TestRoot "test_demo.py"
    [System.IO.File]::WriteAllText($pyTestFile, "def helper_calc():`n    return 42`n`ndef test_real():`n    assert helper_calc() == 42`n", $Utf8NoBom)
    $pyHelperCov = $cmCovJson.Replace("test/CarrierTest.java#nonExistentMethod", ($pyTestFile.Replace("\", "/") + "#helper_calc"))
    [System.IO.File]::WriteAllText($cmCovPath, $pyHelperCov, $Utf8NoBom)
    $pyStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($pyStr -notmatch "is not a test \(must start with 'test_'") {
        throw "ValidateTestCoverage must reject Python helper function carrier. Output: $pyStr"
    }

    # Test Go helper function carrier rejection (missing *testing.T)
    $goTestFile = Join-Path $TestRoot "demo_test.go"
    [System.IO.File]::WriteAllText($goTestFile, "package demo`nfunc HelperFunc() {}`nfunc TestReal(t *testing.T) {}`n", $Utf8NoBom)
    $goHelperCov = $cmCovJson.Replace("test/CarrierTest.java#nonExistentMethod", ($goTestFile.Replace("\", "/") + "#HelperFunc"))
    [System.IO.File]::WriteAllText($cmCovPath, $goHelperCov, $Utf8NoBom)
    $goStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($goStr -notmatch "does not have a valid test") {
        throw "ValidateTestCoverage must reject Go helper function carrier without *testing.T. Output: $goStr"
    }

    # Test Go lowercase test name rejection (Testfoo with lowercase 'f' is not collected by go test)
    $goLowerTestFile = Join-Path $TestRoot "demo_lower_test.go"
    [System.IO.File]::WriteAllText($goLowerTestFile, "package demo`nfunc Testfoo(t *testing.T) {}`n", $Utf8NoBom)
    $goLowerCov = $cmCovJson.Replace("test/CarrierTest.java#nonExistentMethod", ($goLowerTestFile.Replace("\", "/") + "#Testfoo"))
    [System.IO.File]::WriteAllText($cmCovPath, $goLowerCov, $Utf8NoBom)
    $goLowerStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($goLowerStr -notmatch "does not have a valid test name/signature") {
        throw "ValidateTestCoverage must reject Go lowercase Testfoo. Output: $goLowerStr"
    }

    # Test JS describe block carrier rejection
    $jsTestFile = Join-Path $TestRoot "demo.test.js"
    [System.IO.File]::WriteAllText($jsTestFile, "describe('MySuite', () => { it('real_test', () => {}); });`n", $Utf8NoBom)
    $jsDescCov = $cmCovJson.Replace("test/CarrierTest.java#nonExistentMethod", ($jsTestFile.Replace("\", "/") + "#MySuite"))
    [System.IO.File]::WriteAllText($cmCovPath, $jsDescCov, $Utf8NoBom)
    $jsDescStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($jsDescStr -notmatch "is a describe/suite block, not a test case") {
        throw "ValidateTestCoverage must reject JS describe block as carrier. Output: $jsDescStr"
    }

    # Test PS1 Describe block carrier rejection
    $ps1TestFile = Join-Path $TestRoot "demo.tests.ps1"
    [System.IO.File]::WriteAllText($ps1TestFile, "Describe 'PS1Suite' { It 'PS1Test' {} }`n", $Utf8NoBom)
    $ps1DescCov = $cmCovJson.Replace("test/CarrierTest.java#nonExistentMethod", ($ps1TestFile.Replace("\", "/") + "#PS1Suite"))
    [System.IO.File]::WriteAllText($cmCovPath, $ps1DescCov, $Utf8NoBom)
    $ps1DescStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($ps1DescStr -notmatch "is a Describe/Context block, not an It test case") {
        throw "ValidateTestCoverage must reject PS1 Describe block as carrier. Output: $ps1DescStr"
    }

    # Test Rust helper function carrier rejection
    $rsTestFile = Join-Path $TestRoot "demo_test.rs"
    [System.IO.File]::WriteAllText($rsTestFile, "fn helper_fn() {}`n#[test]`nfn test_real() {}`n", $Utf8NoBom)
    $rsHelperCov = $cmCovJson.Replace("test/CarrierTest.java#nonExistentMethod", ($rsTestFile.Replace("\", "/") + "#helper_fn"))
    [System.IO.File]::WriteAllText($cmCovPath, $rsHelperCov, $Utf8NoBom)
    $rsStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($rsStr -notmatch "not annotated with #\[test\]") {
        throw "ValidateTestCoverage must reject Rust helper fn carrier without #[test]. Output: $rsStr"
    }

    # Test sourceCommitSha not in Git history rejection
    $fakeCommitDir = Join-Path $TestRoot "fake_commit_repo"
    [System.IO.Directory]::CreateDirectory($fakeCommitDir) | Out-Null
    & git -C $fakeCommitDir init --quiet
    & git -C $fakeCommitDir config user.name "Tester"
    & git -C $fakeCommitDir config user.email "tester@test.local"
    $dummyFile = Join-Path $fakeCommitDir "dummy.txt"
    [System.IO.File]::WriteAllText($dummyFile, "dummy", $Utf8NoBom)
    & git -C $fakeCommitDir add .
    & git -C $fakeCommitDir commit -m "init" --quiet
    $realCommitSha = (& git -C $fakeCommitDir rev-parse HEAD | Out-String).Trim()
    $fakeCommitSpecDir = Join-Path $fakeCommitDir ".ai-workspace/specs/features/FakeCommitFeature"
    [System.IO.Directory]::CreateDirectory($fakeCommitSpecDir) | Out-Null
    $fakeCommitCovPath = Join-Path $fakeCommitSpecDir "05_test_coverage.json"
    $realJavaTest = Join-Path $fakeCommitDir "test/RealTest.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $realJavaTest)) | Out-Null
    [System.IO.File]::WriteAllText($realJavaTest, "package test; import org.junit.Test; public class RealTest { @Test public void testOne() {} }", $Utf8NoBom)
    
    $fcReq = Join-Path $fakeCommitSpecDir "01_server_rules.md"
    $fcDes = Join-Path $fakeCommitSpecDir "06_design_contract.md"
    $fcPlan = Join-Path $fakeCommitSpecDir "05_test_plan.md"
    $fcApproval = Join-Path $fakeCommitSpecDir "00_workflow_state.json"
    [System.IO.File]::WriteAllText($fcReq, "# Rules`n- BR-01: Rule", $Utf8NoBom)
    [System.IO.File]::WriteAllText($fcDes, "# Design`n- DC-01: Contract", $Utf8NoBom)
    [System.IO.File]::WriteAllText($fcPlan, "# Plan`n- TC-01: Real test", $Utf8NoBom)
    $fcReqSha = Get-TestArtifactHash -Path $fcReq
    $fcDesSha = Get-TestArtifactHash -Path $fcDes
    $fcPlanSha = Get-TestArtifactHash -Path $fcPlan
    $fcState = [ordered]@{
        schemaVersion = "1.0"
        feature = "FakeCommitFeature"
        baseline = $realCommitSha
        requirement = @{ status = "APPROVED"; sha256 = $fcReqSha; approvedBy = "tester"; approvedAt = "2026-08-23T12:00:00Z"; artifact = "01_server_rules.md" }
        design = @{ status = "APPROVED"; sha256 = $fcDesSha; approvedBy = "tester"; approvedAt = "2026-08-23T12:00:00Z"; artifact = "06_design_contract.md" }
    }
    [System.IO.File]::WriteAllText($fcApproval, ($fcState | ConvertTo-Json -Depth 10), $Utf8NoBom)

    $validCovJson = @"
{
  "schemaVersion": "1.0",
  "feature": "FakeCommitFeature",
  "requirementArtifact": "01_server_rules.md",
  "requirementSha256": "$fcReqSha",
  "designArtifact": "06_design_contract.md",
  "designSha256": "$fcDesSha",
  "testPlanArtifact": "05_test_plan.md",
  "testPlanSha256": "$fcPlanSha",
  "riskExemptions": [],
  "cases": [
    {
      "id": "TC-01",
      "status": "VERIFIED",
      "title": "Real Test",
      "priority": "P1",
      "testTypes": ["FUNCTIONAL"],
      "requirementIds": ["BR-01"],
      "designIds": ["DC-01"],
      "setup": ["Setup real test"],
      "trigger": ["Trigger real test"],
      "assertions": {
        "protocol": [
          { "target": "status", "operator": "EQ", "expected": "VALID" }
        ]
      },
      "cleanup": ["Cleanup fixture"],
      "automationCarrier": "test/RealTest.java#testOne"
    }
  ],
  "executionEvidence": {
    "command": "mvn test",
    "exitCode": 0,
    "executedAt": "__EXECUTED_AT__",
    "sourceCommitSha": "deadbeefcafebabe0123456789abcdef01234567",
    "workingTreeDigest": "0000000000000000000000000000000000000000000000000000000000000000",
    "testCount": 1,
    "passedCount": 1,
    "failedCount": 0
  }
}
"@.Replace("__EXECUTED_AT__", $dynamicRecent)
    [System.IO.File]::WriteAllText($fakeCommitCovPath, $validCovJson, $Utf8NoBom)
    $fakeCommitStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $fakeCommitCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($fakeCommitStr -notmatch "does not exist in git repository history") {
        throw "ValidateTestCoverage must reject fabricated sourceCommitSha not in Git history. Output: $fakeCommitStr"
    }

    # Test AssessRisk operation and machine semantic risk blocking on high-risk diff
    $riskTestDir = Join-Path $TestRoot "risk_repo"
    [System.IO.Directory]::CreateDirectory($riskTestDir) | Out-Null
    & git -C $riskTestDir init --quiet
    & git -C $riskTestDir config user.name "Tester"
    & git -C $riskTestDir config user.email "tester@test.local"
    $riskDummy = Join-Path $riskTestDir "dummy.txt"
    [System.IO.File]::WriteAllText($riskDummy, "dummy", $Utf8NoBom)
    & git -C $riskTestDir add .
    & git -C $riskTestDir commit -m "init" --quiet
    $riskBaseSha = (& git -C $riskTestDir rev-parse HEAD | Out-String).Trim()

    $riskSpecDir = Join-Path $riskTestDir ".ai-workspace/specs/features/RiskFeature"
    [System.IO.Directory]::CreateDirectory($riskSpecDir) | Out-Null
    $riskFeatState = Join-Path $riskSpecDir "feature-state.json"
    $riskFeatStateContent = '{"schemaVersion":"1.0","feature":"RiskFeature","tier":"T2","phase":"DONE","baseline":"' + $riskBaseSha + '","updatedAt":"' + $dynamicRecent + '"}'
    [System.IO.File]::WriteAllText($riskFeatState, $riskFeatStateContent, $Utf8NoBom)
    $riskSrc = Join-Path $riskTestDir "src/com/game/ShopEnum.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $riskSrc)) | Out-Null
    [System.IO.File]::WriteAllText($riskSrc, "package com.game; public enum ShopEnum { TYPE_NEW_GIFT, TYPE_OLD }", $Utf8NoBom)
    
    $assessOut = & $ScriptPath -Operation AssessRisk -Path $riskSpecDir 2>&1
    $assessStr = $assessOut | Out-String
    if ($assessStr -notmatch "TYPE_EXTENSION" -or $assessStr -notmatch '"hasHighRisk":\s*true') {
        throw "AssessRisk must detect high risk TYPE_EXTENSION. Output: $assessStr"
    }

    # Verify inferredRisk was saved into feature-state.json with baseline and changeSetDigest
    $savedFeat = Get-Content -LiteralPath $riskFeatState -Raw | ConvertFrom-Json
    if ($null -eq $savedFeat.inferredRisk -or [string]::IsNullOrWhiteSpace($savedFeat.inferredRisk.changeSetDigest)) {
        throw "AssessRisk must persist inferredRisk with changeSetDigest to feature-state.json"
    }

    $riskVerifyOut = & $ScriptPath -Operation VerifyCompletion -Path (Join-Path $riskSpecDir "workflow-state.json") 2>&1
    $riskVerifyStr = $riskVerifyOut | Out-String
    if ($LASTEXITCODE -eq 0 -or $riskVerifyStr -notmatch "HIGH_RISK_TIER_DOWNGRADE_FORBIDDEN") {
        throw "VerifyCompletion must block T2 when high-risk semantic trigger is present. Output: $riskVerifyStr"
    }

    # A newly added JUnit file must not look like TYPE_EXTENSION (package/class/@Test only).
    $plainJavaDir = Join-Path $TestRoot "plain_java_repo"
    [System.IO.Directory]::CreateDirectory($plainJavaDir) | Out-Null
    & git -C $plainJavaDir init --quiet
    & git -C $plainJavaDir config user.name "Tester"
    & git -C $plainJavaDir config user.email "tester@test.local"
    $plainDummy = Join-Path $plainJavaDir "dummy.txt"
    [System.IO.File]::WriteAllText($plainDummy, "dummy", $Utf8NoBom)
    & git -C $plainJavaDir add .
    & git -C $plainJavaDir commit -m "init" --quiet
    $plainBaseSha = (& git -C $plainJavaDir rev-parse HEAD | Out-String).Trim()
    $plainSpecDir = Join-Path $plainJavaDir ".ai-workspace/specs/features/PlainJavaFeature"
    [System.IO.Directory]::CreateDirectory($plainSpecDir) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $plainSpecDir "feature-state.json"), '{"schemaVersion":"1.0","feature":"PlainJavaFeature","tier":"T3","phase":"DONE","baseline":"' + $plainBaseSha + '","updatedAt":"' + $dynamicRecent + '"}', $Utf8NoBom)
    $plainSrc = Join-Path $plainJavaDir "test/MyTest.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $plainSrc)) | Out-Null
    [System.IO.File]::WriteAllText($plainSrc, "package test; public class MyTest { @Test public void testProto() {} }", $Utf8NoBom)
    $plainRisk = & $ScriptPath -Operation AssessRisk -Path $plainSpecDir -Baseline $plainBaseSha 2>&1 | Out-String
    if ($plainRisk -match "TYPE_EXTENSION") {
        throw "AssessRisk must not treat a plain JUnit file as TYPE_EXTENSION. Output: $plainRisk"
    }

    # TYPE_EXTENSION / PUBLIC_ROUTING: 04_change_impact.json must be complete, not merely present
    $extDir = Join-Path $TestRoot "type_ext_complete_repo"
    [System.IO.Directory]::CreateDirectory($extDir) | Out-Null
    & git -C $extDir init --quiet
    & git -C $extDir config user.name "Tester"
    & git -C $extDir config user.email "tester@test.local"
    $extDummy = Join-Path $extDir "dummy.txt"
    [System.IO.File]::WriteAllText($extDummy, "dummy", $Utf8NoBom)
    & git -C $extDir add .
    & git -C $extDir commit -m "init" --quiet
    $extBaseSha = (& git -C $extDir rev-parse HEAD | Out-String).Trim()

    $extSrc = Join-Path $extDir "src/com/game/ShopEnum.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $extSrc)) | Out-Null
    [System.IO.File]::WriteAllText($extSrc, "package com.game; public enum ShopEnum { TYPE_OLD, TYPE_NEW_GIFT }", $Utf8NoBom)
    $extTestJava = Join-Path $extDir "test/TypeExtTest.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $extTestJava)) | Out-Null
    [System.IO.File]::WriteAllText($extTestJava, "package test; import org.junit.Test; public class TypeExtTest { @Test public void testLegacyReset() {} }", $Utf8NoBom)
    & git -C $extDir add src test

    $extSpecDir = Join-Path $extDir ".ai-workspace/specs/features/TypeExtFeature"
    [System.IO.Directory]::CreateDirectory($extSpecDir) | Out-Null
    $extReq = Join-Path $extSpecDir "01_server_rules.md"
    $extDes = Join-Path $extSpecDir "06_design_contract.md"
    $extPlan = Join-Path $extSpecDir "05_test_plan.md"
    $extApproval = Join-Path $extSpecDir "00_workflow_state.json"
    $extFeatState = Join-Path $extSpecDir "feature-state.json"
    $extCovPath = Join-Path $extSpecDir "05_test_coverage.json"
    $extImpactPath = Join-Path $extSpecDir "04_change_impact.json"
    [System.IO.File]::WriteAllText($extReq, "# Rules`n- BR-01: New type must not regress legacy dispatch", $Utf8NoBom)
    [System.IO.File]::WriteAllText($extDes, "# Design`n- DC-01: Extend ShopEnum without bypassing legacy reset", $Utf8NoBom)
    [System.IO.File]::WriteAllText($extPlan, "# Plan`n- TC-01: Legacy type still resets across day boundary", $Utf8NoBom)
    [System.IO.File]::WriteAllText($extFeatState, '{"schemaVersion":"1.0","feature":"TypeExtFeature","tier":"T3","phase":"DONE","baseline":"' + $extBaseSha + '","updatedAt":"' + [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + '"}', $Utf8NoBom)
    [System.IO.Directory]::CreateDirectory((Join-Path $extDir "build/classes")) | Out-Null

    $extReqSha = Get-TestArtifactHash -Path $extReq
    $extDesSha = Get-TestArtifactHash -Path $extDes
    $extPlanSha = Get-TestArtifactHash -Path $extPlan
    $extApprovalObj = [ordered]@{
        schemaVersion = "1.0"
        feature = "TypeExtFeature"
        baseline = $extBaseSha
        requirement = [ordered]@{
            artifact = "01_server_rules.md"
            status = "APPROVED"
            sha256 = $extReqSha
            approvedAt = "2026-08-23T12:00:00Z"
            approvedBy = "human:tester"
        }
        design = [ordered]@{
            artifact = "06_design_contract.md"
            status = "APPROVED"
            sha256 = $extDesSha
            approvedAt = "2026-08-23T12:00:00Z"
            approvedBy = "human:tester"
        }
    }
    Write-TestJson -Path $extApproval -Value $extApprovalObj

    $extRiskRaw = & $ScriptPath -Operation AssessRisk -Path $extSpecDir -Baseline $extBaseSha 2>&1 | Out-String
    $extRisk = $extRiskRaw | ConvertFrom-Json
    $extDigest = [string]$extRisk.changeSetDigest
    if ($extRisk.hasHighRisk -ne $true -or ($extRisk.triggersHit -join ",") -notmatch "TYPE_EXTENSION") {
        throw "Type-extension fixture must hit TYPE_EXTENSION. Output: $($extRisk | ConvertTo-Json -Depth 6)"
    }

    $extLifecycleFacets = @(
        "INIT", "QUERY", "VALIDATE", "MUTATE", "PERSIST", "RESET", "SERIALIZE", "COMPENSATE"
    ) | ForEach-Object {
        [ordered]@{ facetId = $_; coverage = "INHERITED"; evidence = "legacy dispatcher still covers $_" }
    }
    $extImpactBase = [ordered]@{
        schemaVersion = "1.0"
        feature = "TypeExtFeature"
        baseline = $extBaseSha
        changeSetDigest = $extDigest
        changedSymbols = @("com.game.ShopEnum")
        entryPoints = @("BUY_GIFT")
        upstreamCallers = @("DispatchServlet")
        downstreamEffects = @()
        stateReadsWrites = @()
        excludedWithReason = @()
        requiredRegressionCases = @("TC-01")
    }
    $extIncompleteObj = [ordered]@{}
    foreach ($k in $extImpactBase.Keys) { $extIncompleteObj[$k] = $extImpactBase[$k] }
    $extIncompleteObj["behaviorVariants"] = @()
    $extIncompleteObj["invariants"] = @()
    Write-TestJson -Path $extImpactPath -Value $extIncompleteObj
    $extValIncomplete = try { & $ScriptPath -Operation ValidateChangeImpact -Path $extImpactPath 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($extValIncomplete -notmatch "TYPE_EXTENSION_IMPACT_INCOMPLETE" -or $extValIncomplete -notmatch "behaviorVariants") {
        throw "ValidateChangeImpact must reject empty behaviorVariants on TYPE_EXTENSION. Output: $extValIncomplete"
    }

    $extOmittedObj = [ordered]@{}
    foreach ($k in $extImpactBase.Keys) { $extOmittedObj[$k] = $extImpactBase[$k] }
    $extOmittedObj["invariants"] = @()
    Write-TestJson -Path $extImpactPath -Value $extOmittedObj
    $extValOmitted = try { & $ScriptPath -Operation ValidateChangeImpact -Path $extImpactPath 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($extValOmitted -notmatch "TYPE_EXTENSION_IMPACT_INCOMPLETE" -or $extValOmitted -notmatch "behaviorVariants") {
        throw "ValidateChangeImpact must reject omitted behaviorVariants on TYPE_EXTENSION. Output: $extValOmitted"
    }

    $extVariantBlock = @(
        [ordered]@{ typeKey = "TYPE_OLD"; relationToLegacy = "IDENTICAL_TO_LEGACY"; description = "Existing gift type" }
        [ordered]@{ typeKey = "TYPE_NEW_GIFT"; relationToLegacy = "INTENTIONAL_DIFF"; description = "New gift type"; reason = "New billing path" }
    )
    $extInvariantBlock = @(
        [ordered]@{ invariantId = "INV-01"; statement = "Legacy types must still reset across day boundary"; violationRisk = "Stale counters" }
    )
    $extLegacyBlock = @(
        [ordered]@{ pathName = "GiftHelper.resetDaily"; protectedBehavior = "Old types reset at day boundary"; regressionCaseId = "TC-01" }
    )

    $extMissingFacetObj = [ordered]@{}
    foreach ($k in $extImpactBase.Keys) { $extMissingFacetObj[$k] = $extImpactBase[$k] }
    $extMissingFacetObj["behaviorVariants"] = $extVariantBlock
    $extMissingFacetObj["lifecycleFacets"] = @($extLifecycleFacets[0..($extLifecycleFacets.Count - 2)])
    $extMissingFacetObj["invariants"] = $extInvariantBlock
    $extMissingFacetObj["legacyPaths"] = $extLegacyBlock
    Write-TestJson -Path $extImpactPath -Value $extMissingFacetObj
    $extValMissingFacet = try { & $ScriptPath -Operation ValidateChangeImpact -Path $extImpactPath 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($extValMissingFacet -notmatch "TYPE_EXTENSION_IMPACT_INCOMPLETE" -or $extValMissingFacet -notmatch "COMPENSATE") {
        throw "ValidateChangeImpact must reject missing COMPENSATE lifecycle facet on TYPE_EXTENSION. Output: $extValMissingFacet"
    }

    $extNoRegressionObj = [ordered]@{}
    foreach ($k in $extImpactBase.Keys) { $extNoRegressionObj[$k] = $extImpactBase[$k] }
    $extNoRegressionObj["behaviorVariants"] = $extVariantBlock
    $extNoRegressionObj["lifecycleFacets"] = $extLifecycleFacets
    $extNoRegressionObj["invariants"] = $extInvariantBlock
    $extNoRegressionObj["legacyPaths"] = @(
        [ordered]@{ pathName = "GiftHelper.resetDaily"; protectedBehavior = "Old types reset at day boundary" }
    )
    Write-TestJson -Path $extImpactPath -Value $extNoRegressionObj
    $extValNoRegression = try { & $ScriptPath -Operation ValidateChangeImpact -Path $extImpactPath 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($extValNoRegression -notmatch "TYPE_EXTENSION_IMPACT_INCOMPLETE" -or $extValNoRegression -notmatch "regressionCaseId") {
        throw "ValidateChangeImpact must reject IDENTICAL_TO_LEGACY without legacyPaths regressionCaseId. Output: $extValNoRegression"
    }

    $extCompleteObj = [ordered]@{}
    foreach ($k in $extImpactBase.Keys) { $extCompleteObj[$k] = $extImpactBase[$k] }
    $extCompleteObj["behaviorVariants"] = $extVariantBlock
    $extCompleteObj["lifecycleFacets"] = $extLifecycleFacets
    $extCompleteObj["invariants"] = $extInvariantBlock
    $extCompleteObj["legacyPaths"] = $extLegacyBlock
    Write-TestJson -Path $extImpactPath -Value $extCompleteObj
    $extValComplete = & $ScriptPath -Operation ValidateChangeImpact -Path $extImpactPath
    if ($extValComplete -notcontains "VALID") {
        throw "ValidateChangeImpact must accept a complete TYPE_EXTENSION impact contract. Output: $($extValComplete | Out-String)"
    }

    $extRecent = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $extCov = [ordered]@{
        schemaVersion = "1.0"
        feature = "TypeExtFeature"
        requirementArtifact = "01_server_rules.md"
        requirementSha256 = $extReqSha
        designArtifact = "06_design_contract.md"
        designSha256 = $extDesSha
        testPlanArtifact = "05_test_plan.md"
        testPlanSha256 = $extPlanSha
        cases = @(
            [ordered]@{
                id = "TC-01"
                title = "Legacy type still resets"
                status = "VERIFIED"
                priority = "P1"
                testTypes = @("FUNCTIONAL", "RECOVERY", "CHARACTERIZATION")
                requirementIds = @("BR-01")
                designIds = @("DC-01")
                invariantIds = @("INV-01")
                entryPointIds = @("BUY_GIFT")
                variantKeys = @("TYPE_OLD", "TYPE_NEW_GIFT")
                facetIds = @("INIT", "QUERY", "VALIDATE", "MUTATE", "PERSIST", "RESET", "SERIALIZE", "COMPENSATE")
                bypassesPriorQuery = $true
                setup = @("Load a player whose legacy type is at the daily cap")
                trigger = @("Advance clock past reset and invoke the formal buy entry without a prior query")
                assertions = [ordered]@{
                    protocol = @(
                        [ordered]@{ target = "status"; operator = "EQ"; expected = "OK" }
                    )
                    serverState = @(
                        [ordered]@{ target = "buyCount"; operator = "EQ"; expected = "0" }
                    )
                    sideEffects = @(
                        [ordered]@{ target = "persistence.reset"; operator = "EQ"; expected = "true" }
                    )
                    regression = @(
                        [ordered]@{ target = "legacy.reset"; operator = "UNCHANGED"; expected = "true" }
                    )
                }
                cleanup = @("Delete the isolated test player")
                automationCarrier = "test/TypeExtTest.java#testLegacyReset"
            }
        )
        riskExemptions = @()
        executionEvidence = [ordered]@{
            command = "pwsh test"
            exitCode = 0
            executedAt = $extRecent
            sourceCommitSha = $extBaseSha
            workingTreeDigest = $extDigest
            testCount = 1
            passedCount = 1
            failedCount = 0
        }
    }
    Write-TestJson -Path $extCovPath -Value $extCov

    $extVerify = & $ScriptPath -Operation VerifyCompletion -Path $extApproval 2>&1
    $extVerifyStr = $extVerify | Out-String
    if ($LASTEXITCODE -ne 0 -or $extVerifyStr -notmatch "VERIFY_COMPLETION_PASS" -or $extVerifyStr -notmatch "类型/路由扩展完成度" -or $extVerifyStr -notmatch "类型/路由扩展覆盖完成度") {
        throw "VerifyCompletion must pass a complete TYPE_EXTENSION impact and characterization coverage contract. Output: $extVerifyStr"
    }

    $extCovIncomplete = [ordered]@{}
    foreach ($k in $extCov.Keys) { $extCovIncomplete[$k] = $extCov[$k] }
    $extCovIncomplete["cases"] = @(
        [ordered]@{
            id = "TC-01"
            title = "Legacy type still resets"
            status = "VERIFIED"
            priority = "P1"
            testTypes = @("FUNCTIONAL", "RECOVERY")
            requirementIds = @("BR-01")
            designIds = @("DC-01")
            invariantIds = @("INV-01")
            setup = @("Load a player whose legacy type is at the daily cap")
            trigger = @("Advance clock past reset and invoke the formal buy entry")
            assertions = @($extCov.cases)[0].assertions
            cleanup = @("Delete the isolated test player")
            automationCarrier = "test/TypeExtTest.java#testLegacyReset"
        }
    )
    Write-TestJson -Path $extCovPath -Value $extCovIncomplete
    $extVerifyCovIncomplete = & $ScriptPath -Operation VerifyCompletion -Path $extApproval 2>&1
    $extVerifyCovIncompleteStr = $extVerifyCovIncomplete | Out-String
    if ($LASTEXITCODE -eq 0 -or $extVerifyCovIncompleteStr -notmatch "TYPE_EXTENSION_COVERAGE_INCOMPLETE") {
        throw "VerifyCompletion must fail when TYPE_EXTENSION coverage lacks characterization/protocol-trace fields. Output: $extVerifyCovIncompleteStr"
    }

    $extCompleteCase = @($extCov.cases)[0]
    $extCovNoBypassCase = [ordered]@{}
    foreach ($k in $extCompleteCase.Keys) {
        if ($k -eq "bypassesPriorQuery") { continue }
        $extCovNoBypassCase[$k] = $extCompleteCase[$k]
    }
    $extCovNoBypass = [ordered]@{}
    foreach ($k in $extCov.Keys) { $extCovNoBypass[$k] = $extCov[$k] }
    $extCovNoBypass["cases"] = @($extCovNoBypassCase)
    Write-TestJson -Path $extCovPath -Value $extCovNoBypass
    $extVerifyNoBypass = & $ScriptPath -Operation VerifyCompletion -Path $extApproval 2>&1
    $extVerifyNoBypassStr = $extVerifyNoBypass | Out-String
    if ($LASTEXITCODE -eq 0 -or $extVerifyNoBypassStr -notmatch "TYPE_EXTENSION_COVERAGE_INCOMPLETE" -or $extVerifyNoBypassStr -notmatch "bypassesPriorQuery") {
        throw "VerifyCompletion must fail TYPE_EXTENSION coverage when QUERY is active but no case bypasses prior query. Output: $extVerifyNoBypassStr"
    }

    Write-TestJson -Path $extCovPath -Value $extCov

    # Incomplete impact must also fail VerifyCompletion (not only ValidateChangeImpact)
    Write-TestJson -Path $extImpactPath -Value $extIncompleteObj
    $extVerifyIncomplete = & $ScriptPath -Operation VerifyCompletion -Path $extApproval 2>&1
    $extVerifyIncompleteStr = $extVerifyIncomplete | Out-String
    if ($LASTEXITCODE -eq 0 -or $extVerifyIncompleteStr -notmatch "TYPE_EXTENSION_IMPACT_INCOMPLETE") {
        throw "VerifyCompletion must fail when TYPE_EXTENSION impact is incomplete. Output: $extVerifyIncompleteStr"
    }

    # Test CSV pure value modification does not trigger structural risk
    $csvTestDir = Join-Path $TestRoot "csv_repo"
    [System.IO.Directory]::CreateDirectory($csvTestDir) | Out-Null
    & git -C $csvTestDir init --quiet
    & git -C $csvTestDir config user.name "Tester"
    & git -C $csvTestDir config user.email "tester@test.local"
    $csvFile = Join-Path $csvTestDir "config/items.csv"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $csvFile)) | Out-Null
    [System.IO.File]::WriteAllText($csvFile, "id,cost,count`n1001,10,5`n", $Utf8NoBom)
    & git -C $csvTestDir add .
    & git -C $csvTestDir commit -m "add csv" --quiet
    $csvBaseSha = (& git -C $csvTestDir rev-parse HEAD | Out-String).Trim()
    
    # Modify only numeric value
    [System.IO.File]::WriteAllText($csvFile, "id,cost,count`n1001,20,5`n", $Utf8NoBom)
    $csvRisk = & $ScriptPath -Operation AssessRisk -Path $csvTestDir 2>&1 | Out-String
    if ($csvRisk -match "STRUCTURAL_CONFIG" -or $csvRisk -match '"hasHighRisk":\s*true') {
        throw "AssessRisk must NOT flag pure numeric CSV value modifications as structural high-risk. Output: $csvRisk"
    }

    # Test DAO / Repository persistence patterns in AssessRisk
    $daoTestDir = Join-Path $TestRoot "dao_repo"
    [System.IO.Directory]::CreateDirectory($daoTestDir) | Out-Null
    & git -C $daoTestDir init --quiet
    $daoSrc = Join-Path $daoTestDir "src/com/game/PlayerService.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $daoSrc)) | Out-Null
    [System.IO.File]::WriteAllText($daoSrc, "package com.game; public class PlayerService { public void save() { playerDao.save(player); } }", $Utf8NoBom)
    $daoRisk = & $ScriptPath -Operation AssessRisk -Path $daoTestDir 2>&1 | Out-String
    if ($daoRisk -notmatch "STATE_PERSISTENCE_MUTATION" -or $daoRisk -notmatch '"hasHighRisk":\s*true') {
        throw "AssessRisk must detect playerDao.save() as STATE_PERSISTENCE_MUTATION. Output: $daoRisk"
    }

    # Test Pester carrier exact matching (It 'foobar' must NOT match carrier #bar)
    $psPesterFile = Join-Path $TestRoot "PesterExactCarrier.Tests.ps1"
    [System.IO.File]::WriteAllText($psPesterFile, "Describe 'Suite' {`n    It 'foobar' { 1 | Should -Be 1 }`n}", $Utf8NoBom)
    $pesterMismatchCov = $cmCovJson.Replace("test/CarrierTest.java#nonExistentMethod", ($psPesterFile.Replace("\", "/") + "#bar"))
    [System.IO.File]::WriteAllText($cmCovPath, $pesterMismatchCov, $Utf8NoBom)
    $pesterStr = try { & $ScriptPath -Operation ValidateTestCoverage -Path $cmCovPath -Phase VERIFY 2>&1 | Out-String } catch { $_.Exception.ToString() }
    if ($pesterStr -notmatch "does not exist in") {
        throw "ValidateTestCoverage must reject #bar when only It 'foobar' exists. Output: $pesterStr"
    }

    # 1. Negative Test: Registry 为旧 SHA、镜像被篡改为新 SHA 时拒绝 (BASELINE_MUTATION_DETECTED)
    $regTamperFeature = "RegistryTamperFeature"
    $regTamperSpec = Join-Path $TestRoot ".ai-workspace/specs/features/$regTamperFeature"
    [System.IO.Directory]::CreateDirectory($regTamperSpec) | Out-Null
    $regDir = $env:SERVER_NEW_WORKFLOW_REGISTRY
    $regFile = Join-Path $regDir ($regTamperFeature.ToLowerInvariant() + ".json")
    [System.IO.File]::WriteAllText($regFile, '{"schemaVersion":"1.1","feature":"' + $regTamperFeature + '","baseline":"1111111111111111111111111111111111111111","activeOwner":{"workflow":"SUPERPOWERS","agent":"ANTIGRAVITY","ownerId":"ag-1","assignedAt":"2026-08-27T00:00:00Z","deadlineUtc":"2026-08-28T00:00:00Z","sessionKey":"s1","targetPaths":[]},"ownerHistory":[],"auditTrail":[]}', $Utf8NoBom)
    
    # Mirror in spec directory is tampered with a newer baseline
    $regTamperMirror = Join-Path $regTamperSpec ".workflow-owner.json"
    [System.IO.File]::WriteAllText($regTamperMirror, '{"schemaVersion":"1.1","feature":"' + $regTamperFeature + '","baseline":"2222222222222222222222222222222222222222","workflow":"SUPERPOWERS","agent":"ANTIGRAVITY","ownerId":"ag-1"}', $Utf8NoBom)
    
    Assert-FailsWithMessageAndState -ExpectedMessage "BASELINE_MUTATION_DETECTED" -StatePath $regTamperMirror -Message "Registry baseline mismatch with mirror must trigger BASELINE_MUTATION_DETECTED" -Action {
        & $ScriptPath -Operation AssessRisk -Path $regTamperSpec
    }

    # 2. Negative Test: 当前 HEAD + 脏工作区 + 缺失 workingTreeDigest 时拒绝 (workingTreeDigest is required)
    $dirtyGitDir = Join-Path $TestRoot "dirty_git_repo"
    [System.IO.Directory]::CreateDirectory($dirtyGitDir) | Out-Null
    & git -C $dirtyGitDir init --quiet
    & git -C $dirtyGitDir config user.name "Tester"
    & git -C $dirtyGitDir config user.email "tester@test.local"
    $dirtySrc = Join-Path $dirtyGitDir "src/Sample.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $dirtySrc)) | Out-Null
    [System.IO.File]::WriteAllText($dirtySrc, "public class Sample {}", $Utf8NoBom)
    $dirtyCarrier = Join-Path $dirtyGitDir "src/SampleTest.java"
    [System.IO.File]::WriteAllText($dirtyCarrier, "import org.junit.Test; public class SampleTest { @Test public void testOne() {} }", $Utf8NoBom)
    & git -C $dirtyGitDir add .
    & git -C $dirtyGitDir commit -m "init" --quiet
    $dirtyHeadSha = (& git -C $dirtyGitDir rev-parse HEAD | Out-String).Trim()

    # Modify working tree to make it dirty
    [System.IO.File]::WriteAllText($dirtySrc, "public class Sample { int x = 1; }", $Utf8NoBom)
    
    $dirtySpecDir = Join-Path $dirtyGitDir ".ai-workspace/specs/features/DirtyFeature"
    [System.IO.Directory]::CreateDirectory($dirtySpecDir) | Out-Null
    $dirtyCovPath = Join-Path $dirtySpecDir "05_test_coverage.json"
    $dirtyCarrierRel = "src/SampleTest.java"
    $dirtyCovJson = @"
{
  "schemaVersion": "1.0",
  "feature": "DirtyFeature",
  "requirementArtifact": "01_server_rules.md",
  "requirementSha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "designArtifact": "06_design_contract.md",
  "designSha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "testPlanArtifact": "05_test_plan.md",
  "testPlanSha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "cases": [
    {
      "id": "TC-DIRTY",
      "title": "Dirty tree verification test",
      "priority": "P0",
      "status": "VERIFIED",
      "automationCarrier": "$dirtyCarrierRel#testOne",
      "requirementIds": ["BR-01"],
      "designIds": ["DC-01"],
      "testTypes": ["FUNCTIONAL"],
      "setup": ["init context"],
      "trigger": ["execute test"],
      "cleanup": ["cleanup context"],
      "assertions": {
        "protocol": [
          {
            "target": "SampleTest#testOne",
            "operator": "EQ",
            "expected": "PASS"
          }
        ],
        "serverState": [],
        "sideEffects": [],
        "regression": []
      }
    }
  ],
  "riskExemptions": [],
  "executionEvidence": {
    "command": "gradle test",
    "exitCode": 0,
    "testCount": 1,
    "passedCount": 1,
    "failedCount": 0,
    "executedAt": "$dynamicRecent",
    "sourceCommitSha": "$dirtyHeadSha"
  }
}
"@
    [System.IO.File]::WriteAllText($dirtyCovPath, $dirtyCovJson, $Utf8NoBom)
    
    # 2. Negative Test: 当前 HEAD + 脏工作区 + 缺失 workingTreeDigest 时拒绝 (workingTreeDigest is required)
    Assert-Fails -Message "ValidateTestCoverage must reject coverage missing workingTreeDigest" -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $dirtyCovPath -Phase VERIFY
    }

    # Also test mismatched workingTreeDigest rejection
    $mismatchCovJson = $dirtyCovJson.Replace('"sourceCommitSha": "' + $dirtyHeadSha + '"', '"sourceCommitSha": "' + $dirtyHeadSha + '", "workingTreeDigest": "0000000000000000000000000000000000000000000000000000000000000000"')
    [System.IO.File]::WriteAllText($dirtyCovPath, $mismatchCovJson, $Utf8NoBom)
    Assert-Fails -Message "ValidateTestCoverage must reject mismatched workingTreeDigest" -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $dirtyCovPath -Phase VERIFY
    }

    # 3. Negative Test: 旧祖先 SHA + 当前工作区 digest 时拒绝
    # Create a second commit in dirtyGitDir
    [System.IO.File]::WriteAllText($dirtySrc, "public class Sample { int x = 2; }", $Utf8NoBom)
    & git -C $dirtyGitDir add .
    & git -C $dirtyGitDir commit -m "second commit" --quiet
    $newHeadSha = (& git -C $dirtyGitDir rev-parse HEAD | Out-String).Trim()
    
    # Calculate current digest on new HEAD
    $currentWsDigest = (Get-TestStringSha256 -Text "CLEAN_TREE_BASELINE:$($newHeadSha)")
    $ancestorCovJson = $dirtyCovJson.Replace('"sourceCommitSha": "' + $dirtyHeadSha + '"', '"sourceCommitSha": "' + $dirtyHeadSha + '", "workingTreeDigest": "' + $currentWsDigest + '"')
    [System.IO.File]::WriteAllText($dirtyCovPath, $ancestorCovJson, $Utf8NoBom)
    
    Assert-Fails -Message "ValidateTestCoverage must reject older ancestor commit even if workingTreeDigest is supplied" -Action {
        & $ScriptPath -Operation ValidateTestCoverage -Path $dirtyCovPath -Phase VERIFY
    }

    # 4. Negative Test: 独立临时目录（无工作区标记）时 Fail-Closed 判 T3
    $isolatedDir = Join-Path ([System.IO.Path]::GetTempPath()) ("isolated_spec_" + [guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($isolatedDir) | Out-Null
    try {
        $isolatedRisk = & $ScriptPath -Operation AssessRisk -Path $isolatedDir 2>&1 | Out-String
        if ($isolatedRisk -notmatch "WORKSPACE_UNRESOLVED" -or $isolatedRisk -notmatch '"minRequiredTier":\s*"T3"') {
            throw "AssessRisk must fail closed to T3 with WORKSPACE_UNRESOLVED for directories outside any workspace. Output: $isolatedRisk"
        }
    } finally {
        Remove-Item -LiteralPath $isolatedDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 5. Negative Test: 带空格路径 src/foo bar.txt 修改前后的 changeSetDigest 严格变异
    $spaceGitDir = Join-Path $TestRoot "space_git_repo"
    [System.IO.Directory]::CreateDirectory($spaceGitDir) | Out-Null
    & git -C $spaceGitDir init --quiet
    & git -C $spaceGitDir config user.name "Tester"
    & git -C $spaceGitDir config user.email "tester@test.local"
    $spaceFile = Join-Path $spaceGitDir "src/foo bar.txt"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $spaceFile)) | Out-Null
    [System.IO.File]::WriteAllText($spaceFile, "version 1", $Utf8NoBom)
    & git -C $spaceGitDir add .
    & git -C $spaceGitDir commit -m "add space file" --quiet
    $spaceBaseSha = (& git -C $spaceGitDir rev-parse HEAD | Out-String).Trim()
    
    $spaceSpecDir = Join-Path $spaceGitDir ".ai-workspace/specs/features/SpaceFeature"
    [System.IO.Directory]::CreateDirectory($spaceSpecDir) | Out-Null
    $spaceFeatState = Join-Path $spaceSpecDir "feature-state.json"
    [System.IO.File]::WriteAllText($spaceFeatState, '{"schemaVersion":"1.0","feature":"SpaceFeature","baseline":"' + $spaceBaseSha + '","tier":"T2"}', $Utf8NoBom)
    
    $spaceRisk1 = & $ScriptPath -Operation AssessRisk -Path $spaceSpecDir -Baseline $spaceBaseSha 2>&1 | Out-String
    $digest1 = ($spaceRisk1 | ConvertFrom-Json).changeSetDigest
    
    # Now modify content of src/foo bar.txt
    [System.IO.File]::WriteAllText($spaceFile, "version 2 with spaces and edits", $Utf8NoBom)
    $spaceRisk2 = & $ScriptPath -Operation AssessRisk -Path $spaceSpecDir -Baseline $spaceBaseSha 2>&1 | Out-String
    $digest2 = ($spaceRisk2 | ConvertFrom-Json).changeSetDigest
    
    if ($digest1 -eq $digest2) {
        throw "Get-ChangeSetDigest must produce different digests when a file with spaces (src/foo bar.txt) is modified. digest1=$digest1, digest2=$digest2"
    }

    # 6. Negative Test: src/feature-state.json (业务同名文件) 不被排除，修改时 digest 产生变化
    $bizSpecDir = Join-Path $spaceGitDir ".ai-workspace/specs/features/BizFeature"
    [System.IO.Directory]::CreateDirectory($bizSpecDir) | Out-Null
    $bizFile = Join-Path $spaceGitDir "src/feature-state.json"
    [System.IO.File]::WriteAllText($bizFile, '{"businessRule":"alpha"}', $Utf8NoBom)
    & git -C $spaceGitDir add .
    & git -C $spaceGitDir commit -m "add biz feature-state.json" --quiet
    $bizBaseSha = (& git -C $spaceGitDir rev-parse HEAD | Out-String).Trim()
    
    $bizFeatState = Join-Path $bizSpecDir "feature-state.json"
    [System.IO.File]::WriteAllText($bizFeatState, '{"schemaVersion":"1.0","feature":"BizFeature","baseline":"' + $bizBaseSha + '","tier":"T2"}', $Utf8NoBom)
    
    $bizRisk1 = & $ScriptPath -Operation AssessRisk -Path $bizSpecDir -Baseline $bizBaseSha 2>&1 | Out-String
    $bizDigest1 = ($bizRisk1 | ConvertFrom-Json).changeSetDigest
    
    [System.IO.File]::WriteAllText($bizFile, '{"businessRule":"beta"}', $Utf8NoBom)
    $bizRisk2 = & $ScriptPath -Operation AssessRisk -Path $bizSpecDir -Baseline $bizBaseSha 2>&1 | Out-String
    $bizDigest2 = ($bizRisk2 | ConvertFrom-Json).changeSetDigest
    
    if ($bizDigest1 -eq $bizDigest2) {
        throw "Get-ChangeSetDigest must NOT exclude business file src/feature-state.json. digest1=$bizDigest1, digest2=$bizDigest2"
    }

    # 7. Negative Test: Registry 损坏时抛出 BASELINE_REGISTRY_CORRUPTED 且不回退 HEAD
    $corruptFeature = "CorruptRegistryFeature"
    $corruptSpec = Join-Path $TestRoot ".ai-workspace/specs/features/$corruptFeature"
    [System.IO.Directory]::CreateDirectory($corruptSpec) | Out-Null
    $corruptRegFile = Join-Path $regDir ($corruptFeature.ToLowerInvariant() + ".json")
    [System.IO.File]::WriteAllText($corruptRegFile, '{INVALID_JSON_CORRUPT', $Utf8NoBom)
    
    Assert-Fails -Message "AssessRisk must fail closed with BASELINE_REGISTRY_CORRUPTED when registry is corrupted" -Action {
        & $ScriptPath -Operation AssessRisk -Path $corruptSpec
    }

    # 8. Negative Test: Cargo.lock and package-lock.json are NOT excluded
    $cargoFile = Join-Path $spaceGitDir "Cargo.lock"
    [System.IO.File]::WriteAllText($cargoFile, "version = 1", $Utf8NoBom)
    $lockRisk1 = & $ScriptPath -Operation AssessRisk -Path $bizSpecDir -Baseline $bizBaseSha 2>&1 | Out-String
    $lockDigest1 = ($lockRisk1 | ConvertFrom-Json).changeSetDigest
    [System.IO.File]::WriteAllText($cargoFile, "version = 2", $Utf8NoBom)
    $lockRisk2 = & $ScriptPath -Operation AssessRisk -Path $bizSpecDir -Baseline $bizBaseSha 2>&1 | Out-String
    $lockDigest2 = ($lockRisk2 | ConvertFrom-Json).changeSetDigest
    if ($lockDigest1 -eq $lockDigest2) {
        throw "Cargo.lock modification must change changeSetDigest. lockDigest1=$lockDigest1, lockDigest2=$lockDigest2"
    }

    # 9. Test: Space in file path following an internal spec metadata file is NOT skipped
    $spaceJava = Join-Path $spaceGitDir "src/nested space/Payment Processor.java"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $spaceJava)) | Out-Null
    [System.IO.File]::WriteAllText($spaceJava, "public enum ShopEnum { BUY, SELL }", $Utf8NoBom)
    $spaceJavaRisk = & $ScriptPath -Operation AssessRisk -Path $bizSpecDir -Baseline $bizBaseSha 2>&1 | Out-String
    $spaceJavaObj = $spaceJavaRisk | ConvertFrom-Json
    if (-not $spaceJavaObj.hasHighRisk) {
        throw "High-risk enum in path with space ('Payment Processor.java') must be detected and set hasHighRisk=true. Risk output: $spaceJavaRisk"
    }

    # 10. Test: Crash recovery journal recovers interrupted state
    $journalTestDir = Join-Path $TestRoot "journal_recovery_spec"
    [System.IO.Directory]::CreateDirectory($journalTestDir) | Out-Null
    $fileA = Join-Path $journalTestDir "00_workflow_state.json"
    $fileTmpA = $fileA + ".stage.tmp"
    $validStateJson = '{"schemaVersion":"1.0","feature":"JournalRecoveryFeature","requirement":{"artifact":"01_server_rules.md","status":"DRAFT","approvedBy":"","approvedAt":"","sha256":""},"design":{"artifact":"06_design_contract.md","status":"DRAFT","approvedBy":"","approvedAt":"","sha256":""}}'
    [System.IO.File]::WriteAllText($fileTmpA, $validStateJson, $Utf8NoBom)
    $journalObj = [ordered]@{
        journalId = "test-journal-1"
        state = "PREPARED"
        timestamp = [DateTimeOffset]::UtcNow.ToString("o")
        targets = @(
            [ordered]@{ path = $fileA; tmpPath = $fileTmpA; existed = $false; backupPath = "" }
        )
    }
    $journalFile = Join-Path $journalTestDir ".commit-journal.json"
    [System.IO.File]::WriteAllText($journalFile, ($journalObj | ConvertTo-Json -Depth 10), $Utf8NoBom)
    
    # Run AssessRisk on journalTestDir, which acquires lock and triggers Invoke-RecoverPendingJournal
    $dummyRisk = & $ScriptPath -Operation AssessRisk -Path $journalTestDir 2>&1 | Out-String
    if (-not (Test-Path -LiteralPath $fileA)) {
        throw "Invoke-RecoverPendingJournal must roll forward PREPARED tmp files. File '$fileA' was not found."
    }
    if (Test-Path -LiteralPath $journalFile) {
        throw "Invoke-RecoverPendingJournal must clean up journal file after recovery."
    }

    # 12. Negative Test: Crash-after-both-moves recovery keeps new content (never rolls back PREPARED when tmp files are already moved)
    $crashTestDir = Join-Path $TestRoot "spec-crash-test"
    [System.IO.Directory]::CreateDirectory($crashTestDir) | Out-Null
    $targetA = Join-Path $crashTestDir "00_workflow_state.json"
    $backupA = $targetA + ".stage.bak"
    $oldContent = '{"schemaVersion":"1.0","feature":"OldContent","baseline":"0"}'
    $newContent = '{"schemaVersion":"1.0","feature":"NewContent","baseline":"0","requirement":{"artifact":"01_server_rules.md","status":"DRAFT","approvedBy":"","approvedAt":"","sha256":""},"design":{"artifact":"06_design_contract.md","status":"DRAFT","approvedBy":"","approvedAt":"","sha256":""}}'
    [System.IO.File]::WriteAllText($targetA, $newContent, $Utf8NoBom)
    [System.IO.File]::WriteAllText($backupA, $oldContent, $Utf8NoBom)
    $preparedCrashJournal = [ordered]@{
        journalId = "crash-journal-2"
        state = "PREPARED"
        timestamp = [DateTimeOffset]::UtcNow.ToString("o")
        targets = @(
            [ordered]@{ path = $targetA; tmpPath = ($targetA + ".stage.tmp"); existed = $true; backupPath = $backupA }
        )
    }
    $crashJournalPath = Join-Path $crashTestDir ".commit-journal.json"
    [System.IO.File]::WriteAllText($crashJournalPath, ($preparedCrashJournal | ConvertTo-Json -Depth 10), $Utf8NoBom)

    & $ScriptPath -Operation AssessRisk -Path $crashTestDir 2>&1 | Out-Null
    $recoveredTargetContent = [System.IO.File]::ReadAllText($targetA)
    if ($recoveredTargetContent -notmatch "NewContent") {
        throw "Invoke-RecoverPendingJournal must preserve new content on PREPARED crash recovery when moves already completed. Expected 'NewContent', found: $recoveredTargetContent"
    }
    if (Test-Path -LiteralPath $backupA) {
        throw "Invoke-RecoverPendingJournal must clean up backup files after successful recovery."
    }
    if (Test-Path -LiteralPath $crashJournalPath) {
        throw "Invoke-RecoverPendingJournal must clean up journal file after successful recovery."
    }

    # 13. Negative Test: Corrupted journal fails closed
    $corruptJournalDir = Join-Path $TestRoot "spec-corrupt-journal"
    [System.IO.Directory]::CreateDirectory($corruptJournalDir) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $corruptJournalDir ".commit-journal.json"), "{ invalid-json :::", $Utf8NoBom)
    Assert-Fails -Message "Corrupted commit journal must fail closed with error." -Action {
        & $ScriptPath -Operation AssessRisk -Path $corruptJournalDir
    }

    # 14. Negative Test: Assert-FeatureBaselineIntegrity throws BASELINE_MISSING on feature state lacking authoritative baseline
    $missingBaselineDir = Join-Path $TestRoot "spec-missing-baseline"
    [System.IO.Directory]::CreateDirectory($missingBaselineDir) | Out-Null
    # Write a state file without baseline and no registry record
    [System.IO.File]::WriteAllText((Join-Path $missingBaselineDir "feature-state.json"), '{"schemaVersion":"1.0","feature":"MissingBaseline"}', $Utf8NoBom)
    Assert-Fails -Message "Assert-FeatureBaselineIntegrity must throw on missing authoritative baseline." -Action {
        & $ScriptPath -Operation AssessRisk -Path $missingBaselineDir
    }

    Write-Output "All workflow state tests passed."
} finally {
    foreach ($name in @(
        "SERVER_NEW_WORKFLOW_REGISTRY",
        "SERVER_NEW_WORKFLOW_SESSION_REGISTRY",
        "SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY",
        "SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY"
    )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $TestRoot) {
        try {
            Get-ChildItem -LiteralPath $TestRoot -Recurse -Force | ForEach-Object {
                if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                    $_.Attributes = $_.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
                }
            }
            Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}
