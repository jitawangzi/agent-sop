#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "InitApproval",
        "ValidateApproval",
        "Approve",
        "ResetApproval",
        "UpdateHash",
        "Status",
        "InitRuntime",
        "ValidateRuntime",
        "TransitionRuntime",
        "ApplyHandoff",
        "IncrementAttempt",
        "ValidateHandoff",
        "ValidateTestCoverage",
        "ValidateTransitions",
        "SyncCoverage",
        "CheckCompletion",
        "VerifyCompletion"
    )]
    [string]$Operation,

    [string]$Path,
    [string]$RuntimePath,
    [string]$Feature,
    [string]$SpecDirectory,
    [string]$RequirementArtifact = "01_server_rules.md",
    [string]$DesignArtifact = "06_design_contract.md",
    [ValidateSet("requirement", "design")]
    [string]$Gate,
    [string]$ApprovedBy,
    [string]$RunId,
    [ValidateSet(
        "UNCLASSIFIED",
        "NEW_FEATURE",
        "BUSINESS_CHANGE",
        "TECH_CONTRACT_CHANGE",
        "IMPLEMENTATION_FIX",
        "BUG_TRIAGE",
        "CONFIG_VALUE_CHANGE",
        "AUDIT_ONLY",
        "DOC_ONLY"
    )]
    [string]$TaskType,
    [ValidateSet(
        "INIT",
        "CLASSIFY",
        "REQUIREMENT_DRAFT",
        "WAIT_REQUIREMENT_APPROVAL",
        "DESIGN_DRAFT",
        "WAIT_DESIGN_APPROVAL",
        "BUG_TRIAGE",
        "QA_PLAN",
        "TEST_PLAN_AUDIT",
        "IMPLEMENTATION",
        "IMPLEMENTATION_AUDIT",
        "LOGIC_AUDIT",
        "QA_VERIFY",
        "DONE"
    )]
    [string]$ToPhase,
    [ValidateSet(
        "INIT",
        "CLASSIFY",
        "REQUIREMENT_DRAFT",
        "WAIT_REQUIREMENT_APPROVAL",
        "DESIGN_DRAFT",
        "WAIT_DESIGN_APPROVAL",
        "BUG_TRIAGE",
        "QA_PLAN",
        "TEST_PLAN_AUDIT",
        "IMPLEMENTATION",
        "IMPLEMENTATION_AUDIT",
        "LOGIC_AUDIT",
        "QA_VERIFY",
        "DONE"
    )]
    [string]$NextPhase,
    [ValidateSet("RUNNING", "WAIT_HUMAN", "BLOCKED", "DONE")]
    [string]$RuntimeStatus,
    [ValidateSet("implementation", "audit", "qa")]
    [string]$AttemptCategory,
    [ValidateSet("NONE", "REPORT_ONLY", "AUTO_REPAIR")]
    [string]$AuditFixPolicy = "NONE",
    [ValidateSet("AUTO", "FEATURE", "NONE")]
    [string]$ContractMode = "AUTO",
    [ValidateSet("IMPLEMENTATION_AUDIT", "LOGIC_AUDIT")]
    [string[]]$StandaloneStages = @(),
    [string]$LastResult = "",
    [string]$FailureKey = "",
    [string]$BlockReason = "",
    [ValidateSet("CUSTOM_SKILLS", "SUPERPOWERS")]
    [string]$OwnerWorkflow = $(if (-not [string]::IsNullOrWhiteSpace($env:AI_SOP_WORKFLOW_OWNER_WORKFLOW)) { $env:AI_SOP_WORKFLOW_OWNER_WORKFLOW } else { $env:SERVER_NEW_WORKFLOW_OWNER_WORKFLOW }),
    [ValidateSet("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR", "GEMINI", "PI")]
    [string]$OwnerAgent = $(if (-not [string]::IsNullOrWhiteSpace($env:AI_SOP_WORKFLOW_OWNER_AGENT)) { $env:AI_SOP_WORKFLOW_OWNER_AGENT } else { $env:SERVER_NEW_WORKFLOW_OWNER_AGENT }),
    [string]$OwnerId = $(if (-not [string]::IsNullOrWhiteSpace($env:AI_SOP_WORKFLOW_OWNER_ID)) { $env:AI_SOP_WORKFLOW_OWNER_ID } else { $env:SERVER_NEW_WORKFLOW_OWNER_ID }),
    [ValidateSet("PLAN", "VERIFY")]
    [string]$Phase = "",
    [ValidateSet("DUAL", "DESIGN_ONLY")]
    [string]$GateMode = "DUAL"
)

$ErrorActionPreference = "Stop"
$RuntimePathWasBound = $PSBoundParameters.ContainsKey("RuntimePath")

$ClaudeRoot = Split-Path -Parent $PSScriptRoot
$SchemaRoot = Join-Path $ClaudeRoot "schemas"
$TransitionPath = Join-Path $ClaudeRoot "config\workflow-transitions.json"
$TransitionSchemaPath = Join-Path $SchemaRoot "workflow-transitions.schema.json"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$mutationDeadlineMs = 750
$deadlineEnv = if (-not [string]::IsNullOrWhiteSpace($env:AI_SOP_WORKFLOW_DEADLINE_MS)) {
    $env:AI_SOP_WORKFLOW_DEADLINE_MS
} elseif (-not [string]::IsNullOrWhiteSpace($env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS)) {
    $env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS
} else {
    $null
}
if (-not [string]::IsNullOrWhiteSpace($deadlineEnv)) {
    $parsedMs = 0
    if ([int]::TryParse($deadlineEnv, [ref]$parsedMs) -and $parsedMs -gt 0) {
        $mutationDeadlineMs = $parsedMs
    }
}
$MutationDeadlineUtc = [DateTimeOffset]::UtcNow.AddMilliseconds($mutationDeadlineMs)
. (Join-Path $PSScriptRoot "workflow-transaction.ps1")
. (Join-Path $PSScriptRoot "workflow-session.ps1")

function Assert-Argument {
    param(
        [string]$Name,
        [object]$Value
    )

    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
        throw "Missing required argument: -$Name"
    }
}

function Get-AiSopArtifactHash {
    # Normalized SHA-256 for approval/test artifacts. CRLF/LF differences
    # (from Windows editors, git autocrlf, or cross-tool saves) must NOT cause
    # spurious hash drift that blocks the pipeline. Normalize: CRLF -> LF,
    # strip trailing whitespace per line, ensure file ends with one LF.
    # JSON coverage files keep raw-byte hashing (they are machine-generated
    # with stable encoding, and JSON whitespace is insignificant to parsers).
    param([string]$Path)

    $ext = [System.IO.Path]::GetExtension($Path)
    if ($ext -ieq ".json") {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $raw = [System.IO.File]::ReadAllText($Path)
    $normalized = $raw -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    # Strip trailing whitespace per line (spaces/tabs before newline).
    $normalized = $normalized -replace "[ \t]+`n", "`n"
    # Collapse trailing blank lines to a single final newline.
    $normalized = $normalized.TrimEnd() + "`n"
    $enc = [System.Text.UTF8Encoding]::new($false)
    $bytes = $enc.GetBytes($normalized)
    return (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($bytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-JsonSchema {
    param(
        [string]$Json,
        [string]$SchemaPath
    )

    if ($null -eq (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
        throw "Test-Json is required to validate workflow JSON schemas."
    }

    if (-not ($Json | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop)) {
        throw "JSON does not satisfy schema: $SchemaPath"
    }
}

function Read-JsonObject {
    param(
        [string]$FilePath,
        [string]$SchemaPath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "JSON file does not exist: $FilePath"
    }

    $json = Get-Content -LiteralPath $FilePath -Raw
    Assert-JsonSchema -Json $json -SchemaPath $SchemaPath
    return $json | ConvertFrom-Json
}

function Write-JsonAtomic {
    param(
        [string]$FilePath,
        [object]$Value,
        [string]$SchemaPath
    )

    $directory = Split-Path -Parent $FilePath
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = (Get-Location).Path
        $FilePath = Join-Path $directory $FilePath
    }
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null

    $json = $Value | ConvertTo-Json -Depth 20
    Assert-JsonSchema -Json $json -SchemaPath $SchemaPath

    $tempPath = Join-Path $directory (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($FilePath)), [guid]::NewGuid().ToString("N"))
    $backupPath = $tempPath + ".bak"
    try {
        [System.IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, $Utf8NoBom)
        if (Test-Path -LiteralPath $FilePath) {
            [System.IO.File]::Replace($tempPath, $FilePath, $backupPath)
        } else {
            [System.IO.File]::Move($tempPath, $FilePath)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
}

function Get-Transitions {
    $config = Read-JsonObject -FilePath $TransitionPath -SchemaPath $TransitionSchemaPath
    return $config.transitions
}

function Get-AllowedTransitions {
    param(
        [object]$Transitions,
        [string]$Phase
    )

    $property = $Transitions.PSObject.Properties[$Phase]
    if ($null -eq $property) {
        throw "No transition definition exists for phase: $Phase"
    }
    return @($property.Value)
}

function Assert-LegalTransition {
    param(
        [object]$Transitions,
        [string]$From,
        [string]$To
    )

    $allowed = Get-AllowedTransitions -Transitions $Transitions -Phase $From
    if ($To -notin $allowed) {
        throw "Illegal workflow transition: $From -> $To. Allowed: $($allowed -join ', ')"
    }
}

function Assert-TaskSpecificTransition {
    param(
        [object]$Runtime,
        [string]$From,
        [string]$To
    )

    if ($From -eq "INIT") {
        $expected = Get-InitialPhase -Runtime $Runtime
        if ($To -ne $expected) {
            throw "Task type '$($Runtime.taskType)' must start at '$expected', not '$To'."
        }
    }

    if ($From -eq "CLASSIFY") {
        if ($Runtime.taskType -eq "UNCLASSIFIED") {
            throw "Classification handoff did not resolve a task type."
        }
        $expected = Get-InitialPhase -Runtime $Runtime
        if ($To -ne $expected) {
            throw "Classified task type '$($Runtime.taskType)' must route to '$expected', not '$To'."
        }
    }

    if ($To -ne "DONE") {
        return
    }

    switch ($From) {
        "QA_VERIFY" { return }
        "BUG_TRIAGE" {
            if ($Runtime.taskType -eq "BUG_TRIAGE") {
                return
            }
        }
        { $_ -in @("INIT", "CLASSIFY") } {
            if ($Runtime.taskType -eq "DOC_ONLY") {
                return
            }
        }
        { $_ -in @("IMPLEMENTATION_AUDIT", "LOGIC_AUDIT") } {
            if ($Runtime.taskType -eq "AUDIT_ONLY") {
                return
            }
        }
    }

    throw "Task type '$($Runtime.taskType)' cannot complete from phase '$From'."
}

function Get-InitialPhase {
    param(
        [object]$Runtime
    )

    switch ($Runtime.taskType) {
        "UNCLASSIFIED" { return "CLASSIFY" }
        "NEW_FEATURE" { return "REQUIREMENT_DRAFT" }
        "BUSINESS_CHANGE" { return "REQUIREMENT_DRAFT" }
        "TECH_CONTRACT_CHANGE" { return "DESIGN_DRAFT" }
        "IMPLEMENTATION_FIX" { return "QA_PLAN" }
        "CONFIG_VALUE_CHANGE" { return "QA_PLAN" }
        "BUG_TRIAGE" { return "BUG_TRIAGE" }
        "DOC_ONLY" { return "DONE" }
        "AUDIT_ONLY" {
            if (@($Runtime.auditStages).Count -eq 0) {
                throw "AUDIT_ONLY runtime requires at least one audit stage."
            }
            return @($Runtime.auditStages)[0]
        }
        default {
            throw "Unsupported task type: $($Runtime.taskType)"
        }
    }
}

function Get-ClassifiedTaskType {
    param(
        [string]$Result
    )

    $supported = @(
        "BUSINESS_CHANGE",
        "TECH_CONTRACT_CHANGE",
        "IMPLEMENTATION_FIX",
        "CONFIG_VALUE_CHANGE",
        "DOC_ONLY"
    )
    if ($Result -notin $supported) {
        throw "Classification handoff result is not a supported task type: $Result"
    }
    return $Result
}

function Get-ApprovalPath {
    param(
        [object]$Runtime
    )

    return Join-Path $Runtime.specDirectory "00_workflow_state.json"
}

function Assert-RequiredApprovals {
    param(
        [object]$Runtime,
        [string]$TargetPhase
    )

    if ($Runtime.taskType -eq "AUDIT_ONLY" -and $Runtime.contractMode -eq "NONE") {
        return
    }

    $requirementOnly = @("DESIGN_DRAFT", "WAIT_DESIGN_APPROVAL")
    $bothRequired = @(
        "QA_PLAN",
        "TEST_PLAN_AUDIT",
        "IMPLEMENTATION",
        "IMPLEMENTATION_AUDIT",
        "LOGIC_AUDIT",
        "QA_VERIFY"
    )
    if ($TargetPhase -eq "DONE" -and $Runtime.taskType -notin @("DOC_ONLY", "BUG_TRIAGE")) {
        $bothRequired += "DONE"
    }
    if ($TargetPhase -notin $requirementOnly -and $TargetPhase -notin $bothRequired) {
        return
    }

    $approvalPath = Get-ApprovalPath -Runtime $Runtime
    $approval = Validate-ApprovalState -StatePath $approvalPath
    if ($approval.feature -ne $Runtime.feature) {
        throw "Approval feature '$($approval.feature)' does not match runtime feature '$($Runtime.feature)'."
    }
    if ($approval.requirement.status -ne "APPROVED") {
        throw "Requirement approval is required before entering $TargetPhase."
    }
    if ($TargetPhase -in $bothRequired -and $approval.design.status -ne "APPROVED") {
        throw "Design approval is required before entering $TargetPhase."
    }
}

function Get-ExpectedAuditContinuation {
    param(
        [object]$Runtime
    )

    $stages = @($Runtime.auditStages)
    $index = [int]$Runtime.auditStageIndex
    if ($index -ge $stages.Count -or $Runtime.phase -ne $stages[$index]) {
        throw "Audit runtime stage index does not match current phase '$($Runtime.phase)'."
    }
    if (($index + 1) -lt $stages.Count) {
        return $stages[$index + 1]
    }
    if ($Runtime.auditFixPolicy -eq "REPORT_ONLY") {
        return "DONE"
    }
    return "QA_VERIFY"
}

function Resolve-ArtifactPath {
    param(
        [string]$StatePath,
        [string]$Artifact
    )

    if ([System.IO.Path]::IsPathRooted($Artifact)) {
        return $Artifact
    }
    return Join-Path (Split-Path -Parent $StatePath) $Artifact
}

function Assert-CanonicalApprovalArtifacts {
    param(
        [string]$StatePath,
        [object]$State
    )

    $stateDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $StatePath))
    $trimmedDirectory = $stateDirectory.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    if (
        -not (Split-Path -Leaf $trimmedDirectory).Equals(
            $State.feature,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Approval feature must match its canonical specification directory name."
    }
    $featuresDirectory = Split-Path -Parent $trimmedDirectory
    $specsDirectory = Split-Path -Parent $featuresDirectory
    $claudeDirectory = Split-Path -Parent $specsDirectory
    if (
        -not (Split-Path -Leaf $featuresDirectory).Equals(
            "features",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Split-Path -Leaf $specsDirectory).Equals(
            "specs",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (
            (Split-Path -Leaf $claudeDirectory).Equals(
                ".ai-sop",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            (Split-Path -Leaf $claudeDirectory).Equals(
                ".ai-workspace",
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
    ) {
        throw "Approval state must use the canonical .claude\specs\features\<Feature> layout."
    }
    if (
        $State.requirement.artifact -ne "01_server_rules.md" -or
        $State.design.artifact -ne "06_design_contract.md"
    ) {
        throw "Approval artifacts must use canonical requirement and design file names."
    }
}

function Validate-ApprovalState {
    param(
        [string]$StatePath
    )

    $schema = Join-Path $SchemaRoot "workflow-state.schema.json"
    $state = Read-JsonObject -FilePath $StatePath -SchemaPath $schema
    Assert-CanonicalApprovalArtifacts -StatePath $StatePath -State $state
    foreach ($gateName in @("requirement", "design")) {
        $approval = $state.$gateName
        if ($approval.status -ne "APPROVED") {
            continue
        }

        $artifactPath = Resolve-ArtifactPath -StatePath $StatePath -Artifact $approval.artifact
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Approved $gateName artifact does not exist: $artifactPath"
        }
        $actualHash = (Get-AiSopArtifactHash -Path $artifactPath)
        if ($actualHash -ne $approval.sha256.ToLowerInvariant()) {
            throw "Approved $gateName artifact hash does not match: $artifactPath"
        }
    }
    return $state
}

function Get-MutationOwnershipContext {
    switch ($Operation) {
        "InitApproval" {
            return [ordered]@{
                feature = $Feature
                specDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
            }
        }
        "InitRuntime" {
            if ($TaskType -eq "AUDIT_ONLY" -and $AuditFixPolicy -eq "REPORT_ONLY") {
                return $null
            }
            return [ordered]@{
                feature = $Feature
                specDirectory = $SpecDirectory
            }
        }
        "Approve" {
            if (-not $RuntimePathWasBound) {
                $approval = Read-JsonObject -FilePath $Path -SchemaPath (
                    Join-Path $SchemaRoot "workflow-state.schema.json"
                )
                Assert-CanonicalApprovalArtifacts -StatePath $Path -State $approval
                return [ordered]@{
                    feature = $approval.feature
                    specDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
                }
            }
            Assert-Argument -Name "RuntimePath" -Value $RuntimePath
            $runtime = Validate-RuntimeState -StatePath $RuntimePath
            if ($runtime.taskType -eq "AUDIT_ONLY" -and $runtime.auditFixPolicy -eq "REPORT_ONLY") {
                return $null
            }
            return [ordered]@{
                feature = $runtime.feature
                specDirectory = $runtime.specDirectory
            }
        }
        "ApplyHandoff" {
            $runtime = Validate-RuntimeState -StatePath $RuntimePath
            if ($runtime.taskType -eq "AUDIT_ONLY" -and $runtime.auditFixPolicy -eq "REPORT_ONLY") {
                return $null
            }
            return [ordered]@{
                feature = $runtime.feature
                specDirectory = $runtime.specDirectory
            }
        }
        { $_ -in @("TransitionRuntime", "IncrementAttempt") } {
            $runtime = Validate-RuntimeState -StatePath $Path
            if ($runtime.taskType -eq "AUDIT_ONLY" -and $runtime.auditFixPolicy -eq "REPORT_ONLY") {
                return $null
            }
            return [ordered]@{
                feature = $runtime.feature
                specDirectory = $runtime.specDirectory
            }
        }
        "ResetApproval" {
            $approval = Read-JsonObject -FilePath $Path -SchemaPath (
                Join-Path $SchemaRoot "workflow-state.schema.json"
            )
            Assert-CanonicalApprovalArtifacts -StatePath $Path -State $approval
            return [ordered]@{
                feature = $approval.feature
                specDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
            }
        }
        "UpdateHash" {
            $approval = Read-JsonObject -FilePath $Path -SchemaPath (
                Join-Path $SchemaRoot "workflow-state.schema.json"
            )
            Assert-CanonicalApprovalArtifacts -StatePath $Path -State $approval
            return [ordered]@{
                feature = $approval.feature
                specDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
            }
        }
        "Status" {
            return $null
        }
    }
    return $null
}

function Assert-CanonicalOwnershipContext {
    param(
        [object]$Context
    )

    $resolvedSpecDirectory = [System.IO.Path]::GetFullPath($Context.specDirectory)
    $trimmedDirectory = $resolvedSpecDirectory.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $featuresDirectory = Split-Path -Parent $trimmedDirectory
    $specsDirectory = Split-Path -Parent $featuresDirectory
    $claudeDirectory = Split-Path -Parent $specsDirectory
    if (
        -not (Split-Path -Leaf $trimmedDirectory).Equals(
            $Context.feature,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Split-Path -Leaf $featuresDirectory).Equals(
            "features",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Split-Path -Leaf $specsDirectory).Equals(
            "specs",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (
            (Split-Path -Leaf $claudeDirectory).Equals(
                ".ai-sop",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            (Split-Path -Leaf $claudeDirectory).Equals(
                ".ai-workspace",
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
    ) {
        throw "Workflow mutation must use the canonical .claude\specs\features\<Feature> layout."
    }
}

function Invoke-WithMutationOwnership {
    param(
        [scriptblock]$Action
    )

    # Every workflow-state entry shares one absolute deadline and resolves
    # outstanding authority transactions before dispatch or state reads.
    Assert-AiSopWorkflowDeadline $MutationDeadlineUtc
    Invoke-AiSopWorkflowTransactionRecovery `
        -DeadlineUtc $MutationDeadlineUtc |
        Out-Null

    $context = Get-MutationOwnershipContext
    if ($null -eq $context) {
        & $Action
        return
    }

    Assert-Argument -Name "OwnerWorkflow" -Value $OwnerWorkflow
    Assert-Argument -Name "OwnerAgent" -Value $OwnerAgent
    Assert-Argument -Name "OwnerId" -Value $OwnerId
    Assert-CanonicalOwnershipContext -Context $context
    if (
        (
            $OwnerWorkflow -ceq "SUPERPOWERS" -and
            @("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR", "PI") -cnotcontains
                $OwnerAgent
        ) -or
        (
            $OwnerWorkflow -ceq "CUSTOM_SKILLS" -and
            @("CLAUDE_CODE", "CURSOR") -ccontains $OwnerAgent
        )
    ) {
        throw "Workflow '$OwnerWorkflow' cannot be owned by agent '$OwnerAgent'."
    }

    $registryRoot = Get-AiSopWorkflowOwnerRegistryRoot
    $ownerPath = Join-Path $registryRoot ($context.feature.ToLowerInvariant() + ".json")
    [System.IO.Directory]::CreateDirectory($registryRoot) | Out-Null
    $ownerSchema = Join-Path $SchemaRoot "workflow-owner.schema.json"
    $initialOwner = Read-JsonObject `
        -FilePath $ownerPath `
        -SchemaPath $ownerSchema
    $sessionKeys = @()
    if ([string]$initialOwner.schemaVersion -ceq "1.1") {
        $sessionKeys += [string]$initialOwner.sessionBinding.sessionKey
    }
    $lockResult = Enter-AiSopWorkflowTransactionLocks `
        -SessionKeys $sessionKeys `
        -OwnerPath $ownerPath `
        -Targets @() `
        -DeadlineUtc $MutationDeadlineUtc

    try {
        $owner = Read-JsonObject -FilePath $ownerPath -SchemaPath (
            $ownerSchema
        )
        if (
            [string]$owner.status -cne "ACTIVE" -or
            [string]$owner.feature -cne [string]$context.feature -or
            [string]$owner.workflow -cne $OwnerWorkflow -or
            [string]$owner.agent -cne $OwnerAgent -or
            [string]$owner.ownerId -cne $OwnerId -or
            -not ([System.IO.Path]::GetFullPath($owner.specDirectory)).Equals(
                [System.IO.Path]::GetFullPath($context.specDirectory),
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw "Workflow owner identity does not match the active claim."
        }
        if ([string]$owner.schemaVersion -ceq "1.1") {
            if (
                $sessionKeys.Count -ne 1 -or
                [string]$owner.sessionBinding.sessionKey -cne $sessionKeys[0]
            ) {
                throw "Workflow owner session binding changed during mutation authorization."
            }
            $sessionPath = Get-AiSopWorkflowSessionPath $sessionKeys[0]
            $session = Read-AiSopWorkflowSessionRecord `
                -SessionPath $sessionPath `
                -ExpectedSessionKey $sessionKeys[0]
            $now = [DateTimeOffset]::UtcNow
            $expiresAt = [DateTimeOffset]::Parse(
                [string]$session.expiresAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            $specPath = [System.IO.Path]::GetFullPath($context.specDirectory)
            $featuresPath = Split-Path -Parent $specPath
            $specsPath = Split-Path -Parent $featuresPath
            $claudePath = Split-Path -Parent $specsPath
            $workspacePath = [System.IO.Path]::GetFullPath(
                (Split-Path -Parent $claudePath)
            )
            if (
                [string]$owner.workflow -cne "SUPERPOWERS" -or
                [string]$owner.status -cne "ACTIVE" -or
                -not ([string]$owner.workspacePath).Equals(
                    $workspacePath,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -or
                [string]$session.status -cne "ACTIVE" -or
                [string]$session.lifecycleProof -cne "CONFIRMED" -or
                -not [string]::IsNullOrEmpty([string]$session.endedAt) -or
                $now -ge $expiresAt -or
                [string]$session.agent -cne $OwnerAgent -or
                -not ([string]$session.workspacePath).Equals(
                    $workspacePath,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -or
                [string]$session.sessionEpochId -cne
                    [string]$owner.sessionBinding.sessionEpochId -or
                [string]$session.boundFeature -cne $context.feature -or
                [string]$session.boundWorkflow -cne $OwnerWorkflow -or
                [string]$session.boundOwnerId -cne $OwnerId -or
                [string]$session.boundSessionEpochId -cne
                    [string]$session.sessionEpochId
            ) {
                throw "Workflow owner session does not authorize this mutation."
            }
        } elseif ([string]$owner.schemaVersion -cne "1.0") {
            throw "Workflow owner schema version is unsupported."
        }
        & $Action
    } finally {
        Exit-AiSopWorkflowLocks $lockResult.Locks
    }
}

function Assert-RuntimeSemantics {
    param(
        [object]$State
    )

    $transitions = Get-Transitions

    if ($State.status -eq "RUNNING") {
        if ($State.nextPhase -ne $State.phase) {
            Assert-LegalTransition -Transitions $transitions -From $State.phase -To $State.nextPhase
            Assert-TaskSpecificTransition -Runtime $State -From $State.phase -To $State.nextPhase
        }
    } elseif ($State.status -eq "WAIT_HUMAN") {
        Assert-LegalTransition -Transitions $transitions -From $State.phase -To $State.nextPhase
        Assert-TaskSpecificTransition -Runtime $State -From $State.phase -To $State.nextPhase
    } elseif ($State.status -eq "BLOCKED") {
        if ($State.nextPhase -ne $State.phase) {
            throw "Blocked runtime must resume in the same phase: $($State.phase)"
        }
    }
}

function Validate-RuntimeState {
    param(
        [string]$StatePath
    )

    $schema = Join-Path $SchemaRoot "runtime-state.schema.json"
    $state = Read-JsonObject -FilePath $StatePath -SchemaPath $schema
    Assert-RuntimeSemantics -State $state
    return $state
}

function Get-MarkdownContractText {
    param(
        [string]$ArtifactPath
    )

    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        throw "Coverage source artifact does not exist: $ArtifactPath"
    }
    $text = Get-Content -LiteralPath $ArtifactPath -Raw
    $text = [regex]::Replace(
        $text,
        "<!--.*?-->",
        "",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    $text = [regex]::Replace(
        $text,
        "(?ms)^[ \t]*```.*?^[ \t]*```[ \t]*$",
        ""
    )
    $text = [regex]::Replace(
        $text,
        "(?ms)^[ \t]*~~~.*?^[ \t]*~~~[ \t]*$",
        ""
    )
    return $text
}

function Get-DocumentClauseIds {
    param(
        [string]$ArtifactPath,
        [string[]]$Prefixes
    )

    $prefixPattern = ($Prefixes | ForEach-Object { [regex]::Escape($_) }) -join "|"
    $pattern = "(?im)^ {0,3}(?:[-*+]\s+|#{1,6}\s+)((?:$prefixPattern)-[A-Z0-9][A-Z0-9_-]*)\b"
    return @(
        [regex]::Matches(
            (Get-MarkdownContractText -ArtifactPath $ArtifactPath),
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        ) |
            ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } |
            Sort-Object -Unique
    )
}

function Resolve-CoverageArtifactPath {
    param(
        [string]$CoveragePath,
        [string]$Artifact
    )

    if ([System.IO.Path]::IsPathRooted($Artifact)) {
        return [System.IO.Path]::GetFullPath($Artifact)
    }
    return [System.IO.Path]::GetFullPath(
        (Join-Path (Split-Path -Parent $CoveragePath) $Artifact)
    )
}

function Assert-CoverageHash {
    param(
        [string]$ArtifactPath,
        [string]$ExpectedHash,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        throw "$Label artifact does not exist: $ArtifactPath"
    }
    $actualHash = (Get-AiSopArtifactHash -Path $ArtifactPath)
    if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) {
        throw "$Label artifact hash does not match coverage contract: $ArtifactPath"
    }
}

function Resolve-AiSopWorkspaceRoot {
    param([string]$StartPath)
    if ([string]::IsNullOrWhiteSpace($StartPath)) { return $null }
    $curDir = if (Test-Path -LiteralPath $StartPath -PathType Container) {
        [System.IO.Path]::GetFullPath($StartPath)
    } else {
        Split-Path -Parent ([System.IO.Path]::GetFullPath($StartPath))
    }
    while (-not [string]::IsNullOrWhiteSpace($curDir)) {
        if ((Test-Path -LiteralPath (Join-Path $curDir ".ai-workspace")) -or 
            (Test-Path -LiteralPath (Join-Path $curDir ".git")) -or 
            (Test-Path -LiteralPath (Join-Path $curDir ".svn"))) {
            return $curDir
        }
        $parent = Split-Path -Parent $curDir
        if ($parent -eq $curDir) { break }
        $curDir = $parent
    }
    return $null
}

function Validate-TestCoverageState {
    param(
        [string]$CoveragePath,
        [object]$Runtime
    )

    $coverageSchema = Join-Path $SchemaRoot "test-coverage.schema.json"
    $coverage = Read-JsonObject -FilePath $CoveragePath -SchemaPath $coverageSchema
    if (
        -not [System.IO.Path]::GetFileName($CoveragePath).Equals(
            "05_test_coverage.json",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Coverage contract must use the canonical file name: 05_test_coverage.json"
    }
    if (
        $coverage.requirementArtifact -cne "01_server_rules.md" -or
        $coverage.designArtifact -cne "06_design_contract.md" -or
        $coverage.testPlanArtifact -cne "05_test_plan.md"
    ) {
        throw "Coverage artifact fields must use canonical relative file names."
    }
    $coverageDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $CoveragePath))
    $trimmedCoverageDirectory = $coverageDirectory.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $featuresDirectory = Split-Path -Parent $trimmedCoverageDirectory
    $specsDirectory = Split-Path -Parent $featuresDirectory
    $claudeDirectory = Split-Path -Parent $specsDirectory
    if (
        -not (Split-Path -Leaf $trimmedCoverageDirectory).Equals(
            $coverage.feature,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Split-Path -Leaf $featuresDirectory).Equals(
            "features",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Split-Path -Leaf $specsDirectory).Equals(
            "specs",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (
            (Split-Path -Leaf $claudeDirectory).Equals(
                ".ai-sop",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            (Split-Path -Leaf $claudeDirectory).Equals(
                ".ai-workspace",
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
    ) {
        throw "Coverage contract must use the canonical .claude\specs\features\<Feature> layout."
    }
    if ($null -ne $Runtime) {
        if ($coverage.feature -ne $Runtime.feature) {
            throw "Coverage feature '$($coverage.feature)' does not match runtime feature '$($Runtime.feature)'."
        }
        $specDirectory = [System.IO.Path]::GetFullPath($Runtime.specDirectory)
        if ($coverageDirectory -ne $specDirectory) {
            throw "Coverage contract must be stored in runtime specification directory: $specDirectory"
        }
    }

    $requirementPath = Resolve-CoverageArtifactPath -CoveragePath $CoveragePath -Artifact $coverage.requirementArtifact
    $designPath = Resolve-CoverageArtifactPath -CoveragePath $CoveragePath -Artifact $coverage.designArtifact
    $testPlanPath = Resolve-CoverageArtifactPath -CoveragePath $CoveragePath -Artifact $coverage.testPlanArtifact
    $expectedRequirementPath = [System.IO.Path]::GetFullPath(
        (Join-Path $coverageDirectory "01_server_rules.md")
    )
    $expectedDesignPath = [System.IO.Path]::GetFullPath(
        (Join-Path $coverageDirectory "06_design_contract.md")
    )
    $expectedTestPlanPath = [System.IO.Path]::GetFullPath(
        (Join-Path $coverageDirectory "05_test_plan.md")
    )
    if (-not $requirementPath.Equals($expectedRequirementPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Coverage requirement artifact must be canonical: $expectedRequirementPath"
    }
    if (-not $designPath.Equals($expectedDesignPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Coverage design artifact must be canonical: $expectedDesignPath"
    }
    if (-not $testPlanPath.Equals($expectedTestPlanPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Coverage test plan artifact must be canonical: $expectedTestPlanPath"
    }

    $approvalPath = Join-Path $coverageDirectory "00_workflow_state.json"
    $approval = Validate-ApprovalState -StatePath $approvalPath
    if ($approval.feature -ne $coverage.feature) {
        throw "Approval feature '$($approval.feature)' does not match coverage feature '$($coverage.feature)'."
    }
    $isDesignOnly = ($approval.gateMode -eq "DESIGN_ONLY")
    if (-not $isDesignOnly -and $approval.requirement.status -ne "APPROVED") {
        throw "Requirement approval is required before validating test coverage."
    }
    if ($approval.design.status -ne "APPROVED") {
        throw "Design approval is required before validating test coverage."
    }
    if (-not $isDesignOnly) {
        $approvedRequirementPath = [System.IO.Path]::GetFullPath(
            (Resolve-ArtifactPath -StatePath $approvalPath -Artifact $approval.requirement.artifact)
        )
        if (-not $requirementPath.Equals($approvedRequirementPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Coverage requirement artifact is not the approved requirement artifact: $approvedRequirementPath"
        }
        $currentRequirementHash = (Get-AiSopArtifactHash -Path $requirementPath)
        if ($approval.requirement.sha256.ToLowerInvariant() -ne $currentRequirementHash) {
            throw "Approved requirement hash does not match the current artifact: $requirementPath"
        }
        Assert-CoverageHash -ArtifactPath $requirementPath -ExpectedHash $coverage.requirementSha256 -Label "Requirement"
    }
    $approvedDesignPath = [System.IO.Path]::GetFullPath(
        (Resolve-ArtifactPath -StatePath $approvalPath -Artifact $approval.design.artifact)
    )
    if (-not $designPath.Equals($approvedDesignPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Coverage design artifact is not the approved design artifact: $approvedDesignPath"
    }
    $currentDesignHash = (Get-AiSopArtifactHash -Path $designPath)
    if ($approval.design.sha256.ToLowerInvariant() -ne $currentDesignHash) {
        throw "Approved design hash does not match the current artifact: $designPath"
    }
    Assert-CoverageHash -ArtifactPath $designPath -ExpectedHash $coverage.designSha256 -Label "Design"
    Assert-CoverageHash -ArtifactPath $testPlanPath -ExpectedHash $coverage.testPlanSha256 -Label "Test plan"

    $designIds = @(Get-DocumentClauseIds -ArtifactPath $designPath -Prefixes @("DC", "DR", "TW"))
    if ($designIds.Count -eq 0) {
        throw "Design artifact contains no stable DC/DR/TW clause IDs."
    }
    $requirementIds = @()
    if (Test-Path -LiteralPath $requirementPath -PathType Leaf) {
        $requirementIds = @(Get-DocumentClauseIds -ArtifactPath $requirementPath -Prefixes @("BR", "EX", "AC"))
    }
    if (-not $isDesignOnly -and $requirementIds.Count -eq 0) {
        throw "Requirement artifact contains no stable BR/EX/AC clause IDs."
    }

    $caseIds = @($coverage.cases | ForEach-Object { $_.id.ToUpperInvariant() })
    if (@($caseIds | Sort-Object -Unique).Count -ne $caseIds.Count) {
        throw "Coverage contract contains duplicate test case IDs."
    }
    $planCaseIds = @(
        [regex]::Matches(
            (Get-MarkdownContractText -ArtifactPath $testPlanPath),
            "(?im)^ {0,3}(?:[-*+]\s+|#{1,6}\s+)(TC-[A-Z0-9][A-Z0-9_-]*)\b",
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        ) |
            ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } |
            Sort-Object -Unique
    )
    $missingFromPlan = @($caseIds | Where-Object { $_ -notin $planCaseIds })
    $missingFromCoverage = @($planCaseIds | Where-Object { $_ -notin $caseIds })
    if ($missingFromPlan.Count -gt 0 -or $missingFromCoverage.Count -gt 0) {
        throw "Test case IDs differ between coverage contract and test plan. Missing from plan: $($missingFromPlan -join ', '); missing from coverage: $($missingFromCoverage -join ', ')"
    }

    $referencedRequirementIds = @()
    $referencedDesignIds = @()
    foreach ($case in $coverage.cases) {
        $referencedRequirementIds += @($case.requirementIds | ForEach-Object { $_.ToUpperInvariant() })
        $referencedDesignIds += @($case.designIds | ForEach-Object { $_.ToUpperInvariant() })
    }

    $unknownRequirementIds = @($referencedRequirementIds | Where-Object { $_ -notin $requirementIds } | Sort-Object -Unique)
    $unknownDesignIds = @($referencedDesignIds | Where-Object { $_ -notin $designIds } | Sort-Object -Unique)
    if ($unknownRequirementIds.Count -gt 0) {
        throw "Coverage contract references unknown requirement clause IDs: $($unknownRequirementIds -join ', ')"
    }
    if ($unknownDesignIds.Count -gt 0) {
        throw "Coverage contract references unknown design clause IDs: $($unknownDesignIds -join ', ')"
    }

    $exemptions = @($coverage.riskExemptions | ForEach-Object { $_.clauseId.ToUpperInvariant() })
    $allClauseIds = @($requirementIds + $designIds)
    $unknownExemptions = @($exemptions | Where-Object { $_ -notin $allClauseIds } | Sort-Object -Unique)
    if ($unknownExemptions.Count -gt 0) {
        throw "Coverage contract exempts unknown clause IDs: $($unknownExemptions -join ', ')"
    }
    if ($exemptions.Count -gt 0 -and $null -eq $Runtime) {
        throw "Coverage exemptions require runtime approval context."
    }
    foreach ($exemption in @($coverage.riskExemptions)) {
        $clauseId = $exemption.clauseId.ToUpperInvariant()
        $isRequirementClause = $clauseId -match "^(BR|EX|AC)-"
        $sourcePath = if ($isRequirementClause) { $requirementPath } else { $designPath }
        $expectedApprover = if ($isRequirementClause) {
            $approval.requirement.approvedBy
        } else {
            $approval.design.approvedBy
        }
        if ($exemption.approvedBy -ne $expectedApprover) {
            throw "Coverage exemption '$clauseId' must use the approver recorded for its source artifact."
        }
        $sourceText = Get-MarkdownContractText -ArtifactPath $sourcePath
        $markerPattern = "(?im)^ {0,3}(?:[-*+]\s+|#{1,6}\s+)$([regex]::Escape($clauseId))\b.*\[TEST-EXEMPT:\s*(?<reason>[^\]]+)\].*$"
        $marker = [regex]::Match($sourceText, $markerPattern)
        if (-not $marker.Success) {
            throw "Coverage exemption '$clauseId' is not declared in the approved source artifact."
        }
        if ($marker.Groups["reason"].Value.Trim() -ne $exemption.reason.Trim()) {
            throw "Coverage exemption '$clauseId' reason does not match the approved source artifact."
        }
    }
    $uncoveredRequirementIds = if (-not $isDesignOnly) {
        @($requirementIds | Where-Object {
            $_ -notin $referencedRequirementIds -and $_ -notin $exemptions
        })
    } else {
        @()
    }
    $uncoveredDesignIds = @($designIds | Where-Object {
        $_ -notin $referencedDesignIds -and $_ -notin $exemptions
    })
    if ($uncoveredRequirementIds.Count -gt 0 -or $uncoveredDesignIds.Count -gt 0) {
        throw "Coverage contract has uncovered clauses. Requirements: $($uncoveredRequirementIds -join ', '); design: $($uncoveredDesignIds -join ', ')"
    }

    return $coverage
}

function Get-CoveragePlaceholderWarnings {
    # Detect SyncCoverage placeholder fields (expected="placeholder" / operator="N_A" /
    # target="see plan") that pass VALID but carry zero real assertions. Returns a
    # hashtable: Warnings (non-blocking, P2+ placeholders, or all placeholders during PLAN phase)
    # and Errors (blocking, P0/P1 priority TCs with placeholders during VERIFY phase).
    param(
        [string]$CoveragePath,
        [string]$Phase = "VERIFY"
    )
    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $coverageSchema = Join-Path $SchemaRoot "test-coverage.schema.json"
    $coverage = Read-JsonObject -FilePath $CoveragePath -SchemaPath $coverageSchema
    $isPlanPhase = ($Phase -ieq "PLAN")

    foreach ($case in $coverage.cases) {
        $caseId = [string]$case.id
        $prio = [string]$case.priority
        $isHighPriority = ($prio -ieq "P0") -or ($prio -ieq "P1")
        $caseStatus = [string]$case.status
        if ($caseStatus -ieq "PLACEHOLDER") {
            if ($isPlanPhase) {
                $warnings.Add("INFO: $caseId (priority=$prio) status is PLACEHOLDER (will be refined during implementation)")
            } else {
                $errors.Add("ERROR: $caseId (priority=$prio) status is PLACEHOLDER — must be refined to PLANNED/IMPLEMENTED/VERIFIED")
            }
        }
        $placeholderHits = [System.Collections.Generic.List[string]]::new()
        $hasNonNaAssertion = $false
        if ($null -ne $case.assertions) {
            foreach ($cat in $case.assertions.PSObject.Properties) {
                foreach ($entry in $cat.Value) {
                    $exp = [string]$entry.expected
                    $op = [string]$entry.operator
                    $tgt = [string]$entry.target
                    if ($op -cne "N_A") { $hasNonNaAssertion = $true }
                    $isPlaceholder = ($exp -ieq "placeholder") -or ($op -ieq "N_A") -or ($tgt -ieq "see plan")
                    if ($isPlaceholder) {
                        $placeholderHits.Add("${cat.Name}.$($op)/$($exp)")
                    }
                }
            }
        }
        if ($placeholderHits.Count -gt 0) {
            $hitSummary = ($placeholderHits -join '; ')
            if ($isPlanPhase) {
                $warnings.Add("INFO: $caseId (priority=$prio) assertions skeleton ($hitSummary)")
            } elseif ($isHighPriority) {
                $errors.Add("ERROR: $caseId (priority=$prio) assertions still placeholder ($hitSummary) — high-priority TC must carry real assertions before delivery")
            } else {
                $warnings.Add("WARN: $caseId (priority=$prio) assertions still placeholder ($hitSummary) — refine setup/trigger/assertions before delivery")
            }
        }
        if (-not $isPlanPhase -and $null -ne $case.assertions -and $isHighPriority -and -not $hasNonNaAssertion) {
            $errors.Add("ERROR: $caseId (priority=$prio) all assertions are N_A — high-priority cases must define at least one non-N_A assertion")
        }

        # automationCarrier validation.
        $carrier = [string]$case.automationCarrier
        $carrierTrim = $carrier.Trim()
        if ([string]::IsNullOrWhiteSpace($carrierTrim) -or $carrierTrim -ieq "__TODO__" -or $carrierTrim -ieq "see plan" -or $carrierTrim -ieq "TODO") {
            if ($isPlanPhase) {
                $warnings.Add("INFO: $caseId (priority=$prio) automationCarrier to be implemented ('$carrierTrim')")
            } elseif ($isHighPriority) {
                $errors.Add("ERROR: $caseId (priority=$prio) automationCarrier is placeholder ('$carrierTrim') — high-priority TC must point to test class/method or file")
            } else {
                $warnings.Add("WARN: $caseId automationCarrier is placeholder ('$carrierTrim') — point it at the real test method/path before delivery")
            }
        } elseif ($carrierTrim -in @("JUnit", "pytest", "go test", "cargo test", "npm test")) {
            if ($isPlanPhase) {
                $warnings.Add("INFO: $caseId (priority=$prio) automationCarrier carrier type: '$carrierTrim'")
            } elseif ($isHighPriority) {
                $errors.Add("ERROR: $caseId (priority=$prio) automationCarrier is too generic ('$carrierTrim') — specify exact test file or Class#method")
            }
        } elseif ($carrierTrim -match '[/\\]\.[a-zA-Z0-9]+$' -or $carrierTrim -match '\.[a-zA-Z]{1,5}#') {
            # Looks like a file path (has separator + extension, or extension#method).
            $filePathPart = $carrierTrim
            if ($filePathPart -match '^([^#]+)#') { $filePathPart = $Matches[1] }
            $resolved = $filePathPart
            if (-not [System.IO.Path]::IsPathRooted($resolved)) {
                $carrierWsRoot = Resolve-AiSopWorkspaceRoot -StartPath (Split-Path -Parent $CoveragePath)
                $candidateWs = if (-not [string]::IsNullOrWhiteSpace($carrierWsRoot)) { Join-Path $carrierWsRoot $filePathPart } else { $null }
                $candidateSpec = Join-Path (Split-Path -Parent $CoveragePath) $filePathPart
                if ($candidateWs -and (Test-Path -LiteralPath $candidateWs -PathType Leaf)) {
                    $resolved = $candidateWs
                } elseif (Test-Path -LiteralPath $candidateSpec -PathType Leaf) {
                    $resolved = $candidateSpec
                } elseif ($candidateWs) {
                    $resolved = $candidateWs
                } else {
                    $resolved = $candidateSpec
                }
            }
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                if ($isPlanPhase) {
                    $warnings.Add("INFO: $caseId automationCarrier target test file not yet created: $filePathPart (will be verified before completion)")
                } else {
                    $errors.Add("ERROR: $caseId automationCarrier points to a missing file: $filePathPart — verify the test path")
                }
            } elseif ($filePathPart -match '\.java$') {
                $javaSrc = [System.IO.File]::ReadAllText($resolved)
                if ($javaSrc -notmatch '@Test\b') {
                    if ($isPlanPhase) {
                        $warnings.Add("INFO: $caseId automationCarrier .java has no @Test method yet: $filePathPart")
                    } else {
                        $errors.Add("ERROR: $caseId automationCarrier .java has no @Test method: $filePathPart — carrier must be a real test")
                    }
                }
            }
        }
    }
    return [pscustomobject]@{ Warnings = $warnings; Errors = $errors }
}

function Assert-DurableTestCoverage {
    param(
        [object]$Runtime
    )

    if ([string]::IsNullOrWhiteSpace($Runtime.testCoverageSha256)) {
        throw "Runtime has no audited test coverage hash."
    }
    $coveragePath = Join-Path $Runtime.specDirectory "05_test_coverage.json"
    if (-not (Test-Path -LiteralPath $coveragePath -PathType Leaf)) {
        throw "Audited test coverage contract no longer exists: $coveragePath"
    }
    $actualHash = (Get-AiSopArtifactHash -Path $coveragePath)
    if ($actualHash -ne $Runtime.testCoverageSha256.ToLowerInvariant()) {
        throw "Test coverage contract changed after TEST_PLAN_AUDIT; return to QA_PLAN."
    }
    Validate-TestCoverageState -CoveragePath $coveragePath -Runtime $Runtime | Out-Null
}

function Get-DefaultRuntimeStatus {
    param(
        [string]$Phase
    )

    if ($Phase -eq "DONE") {
        return "DONE"
    }
    if ($Phase -in @("WAIT_REQUIREMENT_APPROVAL", "WAIT_DESIGN_APPROVAL")) {
        return "WAIT_HUMAN"
    }
    return "RUNNING"
}

function Get-DefaultNextPhase {
    param(
        [string]$Phase
    )

    switch ($Phase) {
        "WAIT_REQUIREMENT_APPROVAL" { return "DESIGN_DRAFT" }
        "WAIT_DESIGN_APPROVAL" { return "QA_PLAN" }
        "DONE" { return "DONE" }
        default { return $Phase }
    }
}

function Invoke-WithFileLock {
    param(
        [string]$StatePath,
        [scriptblock]$Action
    )

    $lockPath = $StatePath + ".lock"
    $lockStream = $null
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            $lockStream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            break
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    if ($null -eq $lockStream) {
        throw "Timed out acquiring runtime lock: $StatePath"
    }

    try {
        & $Action
    } finally {
        $lockStream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WithWorkflowLocks {
    param(
        [string]$RuntimePath,
        [scriptblock]$Action
    )

    $workflowAction = $Action
    Invoke-WithFileLock -StatePath $RuntimePath -Action {
        $runtime = Validate-RuntimeState -StatePath $RuntimePath
        $approvalPath = Get-ApprovalPath -Runtime $runtime
        Invoke-WithFileLock -StatePath $approvalPath -Action $workflowAction
    }
}

function Approve-CanonicalArtifact {
    param(
        [string]$StatePath,
        [string]$GateName,
        [string]$Approver
    )

    if (
        -not [System.IO.Path]::GetFileName($StatePath).Equals(
            "00_workflow_state.json",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Approval state must use the canonical file name: 00_workflow_state.json"
    }

    $state = Validate-ApprovalState -StatePath $StatePath
    $isDesignOnly = ($state.gateMode -eq "DESIGN_ONLY")
    if ($GateName -eq "design" -and -not $isDesignOnly -and $state.requirement.status -ne "APPROVED") {
        throw "Requirement approval is required before design approval."
    }

    $approval = $state.$GateName
    $artifactPath = Resolve-ArtifactPath -StatePath $StatePath -Artifact $approval.artifact
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Cannot approve missing artifact: $artifactPath"
    }

    $approval.status = "APPROVED"
    $approval.sha256 = (Get-AiSopArtifactHash -Path $artifactPath)
    $approval.approvedAt = [DateTimeOffset]::UtcNow.ToString("o")
    $approval.approvedBy = $Approver
    Write-JsonAtomic -FilePath $StatePath -Value $state -SchemaPath (
        Join-Path $SchemaRoot "workflow-state.schema.json"
    )
    Validate-ApprovalState -StatePath $StatePath | Out-Null
    Write-Output $StatePath
}

function Sync-FeatureStateTierToT3 {
    param([string]$StatePath)
    try {
        $specDir = Split-Path -Parent $StatePath
        $featStateFile = Join-Path $specDir "feature-state.json"
        if (Test-Path -LiteralPath $featStateFile -PathType Leaf) {
            $fs = Get-Content -LiteralPath $featStateFile -Raw | ConvertFrom-Json
            if ($fs.tier -ne "T3") {
                $fsDict = [ordered]@{}
                foreach ($p in $fs.psobject.Properties) {
                    $fsDict[$p.Name] = $p.Value
                }
                $fsDict["tier"] = "T3"
                $fsDict["updatedAt"] = [DateTimeOffset]::UtcNow.ToString("o")
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($featStateFile, ($fsDict | ConvertTo-Json -Depth 10), $utf8NoBom)
            }
        }
    } catch {
        Write-Warning "Failed to sync feature-state tier to T3: $_"
    }
}

function Invoke-LegacyRuntimeApproval {
    param(
        [string]$StatePath,
        [string]$RuntimeStatePath,
        [string]$GateName,
        [string]$Approver
    )

    Invoke-WithWorkflowLocks -RuntimePath $RuntimeStatePath -Action {
        $runtime = Validate-RuntimeState -StatePath $RuntimeStatePath
        $expectedPhase = if ($GateName -eq "requirement") {
            "WAIT_REQUIREMENT_APPROVAL"
        } else {
            "WAIT_DESIGN_APPROVAL"
        }
        if ($runtime.phase -ne $expectedPhase -or $runtime.status -ne "WAIT_HUMAN") {
            throw "Gate '$GateName' can only be approved while runtime is waiting at '$expectedPhase'."
        }
        $expectedApprovalPath = [System.IO.Path]::GetFullPath((Get-ApprovalPath -Runtime $runtime))
        if ([System.IO.Path]::GetFullPath($StatePath) -ne $expectedApprovalPath) {
            throw "Approval path does not match runtime specification directory."
        }

        $state = Validate-ApprovalState -StatePath $StatePath
        $approval = $state.$GateName
        $artifactPath = Resolve-ArtifactPath -StatePath $StatePath -Artifact $approval.artifact
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Cannot approve missing artifact: $artifactPath"
        }

        $approval.status = "APPROVED"
        $approval.sha256 = (Get-AiSopArtifactHash -Path $artifactPath)
        $approval.approvedAt = [DateTimeOffset]::UtcNow.ToString("o")
        $approval.approvedBy = $Approver
        Write-JsonAtomic -FilePath $StatePath -Value $state -SchemaPath (
            Join-Path $SchemaRoot "workflow-state.schema.json"
        )
        Validate-ApprovalState -StatePath $StatePath | Out-Null
        Write-Output $StatePath
    }
}

function Assert-PhaseResultContract {
    param(
        [object]$Runtime,
        [object]$Handoff
    )

    if ($Handoff.status -eq "BLOCKED") {
        return
    }
    if ($Handoff.status -eq "FINDINGS") {
        if ($Handoff.result -ne "AUDIT_FINDINGS") {
            throw "FINDINGS handoff must use result AUDIT_FINDINGS."
        }
        return
    }

    $route = "$($Handoff.status)|$($Handoff.result)|$($Handoff.recommendedPhase)"
    $allowed = switch ($Runtime.phase) {
        "CLASSIFY" {
            @(
                "PASS|BUSINESS_CHANGE|REQUIREMENT_DRAFT",
                "PASS|TECH_CONTRACT_CHANGE|DESIGN_DRAFT",
                "PASS|IMPLEMENTATION_FIX|QA_PLAN",
                "PASS|CONFIG_VALUE_CHANGE|QA_PLAN",
                "PASS|DOC_ONLY|DONE"
            )
        }
        "REQUIREMENT_DRAFT" {
            @("WAIT_HUMAN|REQUIREMENT_DRAFT_READY|WAIT_REQUIREMENT_APPROVAL")
        }
        "DESIGN_DRAFT" {
            @(
                "WAIT_HUMAN|DESIGN_DRAFT_READY|WAIT_DESIGN_APPROVAL",
                "FAIL|REQUIREMENT_GAP|REQUIREMENT_DRAFT"
            )
        }
        "BUG_TRIAGE" {
            @(
                "PASS|IMPL_FAILURE|QA_PLAN",
                "FAIL|DESIGN_FLAW|DESIGN_DRAFT",
                "FAIL|REQUIREMENT_GAP|REQUIREMENT_DRAFT",
                "PASS|CLIENT_ISSUE|DONE",
                "PASS|TEST_ERROR|DONE",
                "PASS|INVALID|DONE"
            )
        }
        "QA_PLAN" {
            @(
                "PASS|TEST_PLAN_READY|TEST_PLAN_AUDIT",
                "FAIL|TEST_PLAN_GAPS|QA_PLAN",
                "FAIL|REQUIREMENT_GAP|REQUIREMENT_DRAFT",
                "FAIL|DESIGN_FLAW|DESIGN_DRAFT"
            )
        }
        "TEST_PLAN_AUDIT" {
            @(
                "PASS|TEST_PLAN_AUDIT_PASSED|IMPLEMENTATION",
                "FAIL|TEST_PLAN_GAPS|QA_PLAN",
                "FAIL|REQUIREMENT_GAP|REQUIREMENT_DRAFT",
                "FAIL|DESIGN_FLAW|DESIGN_DRAFT"
            )
        }
        "IMPLEMENTATION" {
            @(
                "PASS|IMPLEMENTATION_COMPILED|IMPLEMENTATION_AUDIT",
                "PASS|CONFIG_APPLIED|IMPLEMENTATION_AUDIT",
                "FAIL|IMPLEMENTATION_FAILURE|IMPLEMENTATION",
                "FAIL|BUSINESS_CHANGE|REQUIREMENT_DRAFT",
                "FAIL|TECH_CONTRACT_CHANGE|DESIGN_DRAFT",
                "FAIL|REQUIREMENT_GAP|REQUIREMENT_DRAFT",
                "FAIL|DESIGN_FLAW|DESIGN_DRAFT",
                "FAIL|TEST_PLAN_STALE|QA_PLAN"
            )
        }
        { $_ -in @("IMPLEMENTATION_AUDIT", "LOGIC_AUDIT") } {
            @(
                "PASS|PASS|IMPLEMENTATION_AUDIT",
                "PASS|PASS|LOGIC_AUDIT",
                "PASS|PASS|QA_VERIFY",
                "PASS|PASS|DONE",
                "PASS|PASS_WITH_RISKS|IMPLEMENTATION_AUDIT",
                "PASS|PASS_WITH_RISKS|LOGIC_AUDIT",
                "PASS|PASS_WITH_RISKS|QA_VERIFY",
                "PASS|PASS_WITH_RISKS|DONE",
                "FAIL|IMPLEMENTATION_FAILURE|IMPLEMENTATION",
                "FAIL|LOGIC_FAILURE|IMPLEMENTATION",
                "FAIL|FAIL|IMPLEMENTATION",
                "FAIL|REQUIREMENT_GAP|REQUIREMENT_DRAFT",
                "FAIL|DESIGN_FLAW|DESIGN_DRAFT",
                "FAIL|TEST_PLAN_STALE|QA_PLAN"
            )
        }
        "QA_VERIFY" {
            @(
                "PASS|QA_PASSED|DONE",
                "PASS|BUSINESS_TEST_ENTRY_CHANGED|IMPLEMENTATION_AUDIT",
                "PASS|ISOLATED_TEST_FIXED|QA_VERIFY",
                "PASS|ASSERTION_UPDATED|QA_VERIFY",
                "FAIL|IMPLEMENTATION_FAILURE|IMPLEMENTATION",
                "FAIL|REQUIREMENT_GAP|REQUIREMENT_DRAFT",
                "FAIL|DESIGN_FLAW|DESIGN_DRAFT",
                "FAIL|TEST_PLAN_STALE|QA_PLAN"
            )
        }
        default {
            @()
        }
    }
    if ($route -notin $allowed) {
        throw "Handoff result/route is invalid for phase '$($Runtime.phase)': $route"
    }
}

function Validate-HandoffState {
    param(
        [string]$HandoffPath,
        [string]$CurrentRuntimePath
    )

    $handoffSchema = Join-Path $SchemaRoot "skill-handoff.schema.json"
    $handoff = Read-JsonObject -FilePath $HandoffPath -SchemaPath $handoffSchema
    $runtime = Validate-RuntimeState -StatePath $CurrentRuntimePath

    if ($handoff.runId -ne $runtime.runId) {
        throw "Handoff runId '$($handoff.runId)' does not match runtime runId '$($runtime.runId)'."
    }
    $expectedSequence = [int]$runtime.lastHandoffSequence + 1
    if ([int]$handoff.sequence -ne $expectedSequence) {
        throw "Handoff sequence '$($handoff.sequence)' does not match expected sequence '$expectedSequence'."
    }

    if ($handoff.status -eq "BLOCKED") {
        if ($handoff.recommendedPhase -ne $runtime.phase) {
            throw "BLOCKED handoff must preserve current phase '$($runtime.phase)'."
        }
        return [pscustomobject]@{
            handoff = $handoff
            runtime = $runtime
        }
    }

    Assert-PhaseResultContract -Runtime $runtime -Handoff $handoff

    if ($runtime.phase -eq "CLASSIFY" -and $runtime.taskType -eq "UNCLASSIFIED") {
        if ($handoff.status -ne "PASS") {
            throw "Classification can only resolve task type from a PASS handoff."
        }
        $runtime.taskType = Get-ClassifiedTaskType -Result $handoff.result
    }
    if (
        $runtime.taskType -eq "CONFIG_VALUE_CHANGE" -and
        $runtime.phase -eq "IMPLEMENTATION" -and
        $handoff.status -eq "FAIL" -and
        $handoff.result -in @("BUSINESS_CHANGE", "TECH_CONTRACT_CHANGE")
    ) {
        $expectedPhase = if ($handoff.result -eq "BUSINESS_CHANGE") {
            "REQUIREMENT_DRAFT"
        } else {
            "DESIGN_DRAFT"
        }
        if ($handoff.recommendedPhase -ne $expectedPhase) {
            throw "Configuration reclassification '$($handoff.result)' must route to '$expectedPhase'."
        }
        $runtime.taskType = $handoff.result
    }

    $transitions = Get-Transitions
    Assert-LegalTransition -Transitions $transitions -From $runtime.phase -To $handoff.recommendedPhase
    Assert-TaskSpecificTransition -Runtime $runtime -From $runtime.phase -To $handoff.recommendedPhase
    Assert-RequiredApprovals -Runtime $runtime -TargetPhase $handoff.recommendedPhase

    if ($handoff.result -eq "TEST_PLAN_READY") {
        if (
            $runtime.phase -ne "QA_PLAN" -or
            $handoff.status -ne "PASS" -or
            $handoff.recommendedPhase -ne "TEST_PLAN_AUDIT"
        ) {
            throw "TEST_PLAN_READY must be a PASS handoff from QA_PLAN to TEST_PLAN_AUDIT."
        }
    }
    if ($runtime.phase -eq "TEST_PLAN_AUDIT" -and $handoff.status -eq "PASS") {
        if (
            $handoff.result -ne "TEST_PLAN_AUDIT_PASSED" -or
            $handoff.recommendedPhase -ne "IMPLEMENTATION"
        ) {
            throw "A passing test-plan audit must return TEST_PLAN_AUDIT_PASSED and enter implementation."
        }
    }
    if ($handoff.result -eq "BUSINESS_TEST_ENTRY_CHANGED") {
        if (
            $runtime.phase -ne "QA_VERIFY" -or
            $handoff.status -ne "PASS" -or
            $handoff.recommendedPhase -ne "IMPLEMENTATION_AUDIT"
        ) {
            throw "BUSINESS_TEST_ENTRY_CHANGED must return from QA_VERIFY to IMPLEMENTATION_AUDIT."
        }
    }
    if ($runtime.phase -eq "QA_VERIFY" -and $handoff.recommendedPhase -eq "DONE") {
        if ($handoff.status -ne "PASS" -or $handoff.result -ne "QA_PASSED") {
            throw "QA_VERIFY may complete only with a PASS QA_PASSED handoff."
        }
    }
    if (
        $runtime.phase -eq "TEST_PLAN_AUDIT" -and
        $handoff.recommendedPhase -eq "IMPLEMENTATION" -and
        $handoff.status -ne "PASS"
    ) {
        throw "Only a PASS test-plan audit may enter implementation."
    }
    if (
        $handoff.status -eq "PASS" -and
        (
            ($runtime.phase -eq "QA_PLAN" -and $handoff.recommendedPhase -eq "TEST_PLAN_AUDIT") -or
            ($runtime.phase -eq "TEST_PLAN_AUDIT" -and $handoff.recommendedPhase -eq "IMPLEMENTATION")
        )
    ) {
        $coveragePath = Join-Path $runtime.specDirectory "05_test_coverage.json"
        Validate-TestCoverageState -CoveragePath $coveragePath -Runtime $runtime | Out-Null
    }
    if (
        $runtime.taskType -in @(
            "NEW_FEATURE",
            "BUSINESS_CHANGE",
            "TECH_CONTRACT_CHANGE",
            "IMPLEMENTATION_FIX",
            "BUG_TRIAGE",
            "CONFIG_VALUE_CHANGE"
        ) -and
        $runtime.phase -in @(
            "IMPLEMENTATION",
            "IMPLEMENTATION_AUDIT",
            "LOGIC_AUDIT",
            "QA_VERIFY"
        ) -and
        $handoff.status -eq "PASS"
    ) {
        Assert-DurableTestCoverage -Runtime $runtime
    }

    if ($handoff.status -eq "FAIL" -and $handoff.retryFrom -ne $handoff.recommendedPhase) {
        throw "FAIL handoff retryFrom must equal recommendedPhase."
    }
    if (
        $runtime.phase -in @("IMPLEMENTATION_AUDIT", "LOGIC_AUDIT") -and
        $handoff.status -eq "FAIL" -and
        $handoff.recommendedPhase -notin @("REQUIREMENT_DRAFT", "DESIGN_DRAFT", "QA_PLAN", "IMPLEMENTATION")
    ) {
        throw "Failed audit must return to requirement, design, QA planning, or implementation."
    }
    if ($handoff.status -eq "FINDINGS") {
        if ($runtime.taskType -ne "AUDIT_ONLY" -or $runtime.auditFixPolicy -ne "REPORT_ONLY") {
            throw "FINDINGS handoff is only valid for AUDIT_ONLY with REPORT_ONLY policy."
        }
    }
    if ($runtime.taskType -eq "AUDIT_ONLY" -and $runtime.phase -in @($runtime.auditStages)) {
        $expected = Get-ExpectedAuditContinuation -Runtime $runtime
        if ($runtime.auditFixPolicy -eq "REPORT_ONLY") {
            if ($handoff.status -notin @("PASS", "FINDINGS", "BLOCKED")) {
                throw "REPORT_ONLY audits must return PASS, FINDINGS, or BLOCKED."
            }
            if ($handoff.status -ne "BLOCKED" -and $handoff.recommendedPhase -ne $expected) {
                throw "REPORT_ONLY audit must continue to '$expected'."
            }
        } elseif ($handoff.status -eq "PASS" -and $handoff.recommendedPhase -ne $expected) {
            throw "AUTO_REPAIR audit pass must continue to '$expected'."
        }
    }
    if (
        $runtime.taskType -eq "AUDIT_ONLY" -and
        $runtime.auditFixPolicy -eq "AUTO_REPAIR" -and
        $runtime.phase -eq "IMPLEMENTATION_AUDIT" -and
        @($runtime.auditStages).Count -gt 0 -and
        @($runtime.auditStages)[0] -eq "LOGIC_AUDIT" -and
        [int]$runtime.auditStageIndex -eq 0 -and
        $handoff.status -eq "PASS" -and
        $handoff.recommendedPhase -ne "LOGIC_AUDIT"
    ) {
        throw "AUTO_REPAIR must return through the requested LOGIC_AUDIT stage after implementation."
    }
    return [pscustomobject]@{
        handoff = $handoff
        runtime = $runtime
    }
}

function Get-AttemptCategoryForPhase {
    param(
        [string]$Phase
    )

    if ($Phase -eq "IMPLEMENTATION") {
        return "implementation"
    }
    if ($Phase -in @("IMPLEMENTATION_AUDIT", "LOGIC_AUDIT")) {
        return "audit"
    }
    if ($Phase -in @("QA_PLAN", "TEST_PLAN_AUDIT", "QA_VERIFY")) {
        return "qa"
    }
    return ""
}

function Add-FailureAttempt {
    param(
        [object]$State,
        [string]$Category,
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "A failure key is required for retry tracking."
    }
    $property = $State.failureAttempts.PSObject.Properties[$Key]
    $failureAttempts = if ($null -eq $property) {
        1
    } else {
        [int]$property.Value + 1
    }
    if ($failureAttempts -gt 3) {
        throw "Attempt limit reached for failure key: $Key"
    }
    if ($null -eq $property) {
        $State.failureAttempts | Add-Member -NotePropertyName $Key -NotePropertyValue $failureAttempts
    } else {
        $property.Value = $failureAttempts
    }
    $State.attempts.$Category = [int]$State.attempts.$Category + 1
}

Invoke-WithMutationOwnership -Action {
switch ($Operation) {
    "InitApproval" {
        Assert-Argument -Name "Path" -Value $Path
        Assert-Argument -Name "Feature" -Value $Feature
        if (
            $RequirementArtifact -ne "01_server_rules.md" -or
            $DesignArtifact -ne "06_design_contract.md"
        ) {
            throw "Approval artifacts must use canonical requirement and design file names."
        }
        Invoke-WithFileLock -StatePath $Path -Action {
            if (Test-Path -LiteralPath $Path) {
                throw "Approval state already exists: $Path"
            }

            $state = [ordered]@{
                schemaVersion = "1.0"
                feature = $Feature
                gateMode = $GateMode
                requirement = [ordered]@{
                    artifact = $RequirementArtifact
                    status = "DRAFT"
                    sha256 = ""
                    approvedAt = ""
                    approvedBy = ""
                }
                design = [ordered]@{
                    artifact = $DesignArtifact
                    status = "DRAFT"
                    sha256 = ""
                    approvedAt = ""
                    approvedBy = ""
                }
            }
            Write-JsonAtomic -FilePath $Path -Value $state -SchemaPath (Join-Path $SchemaRoot "workflow-state.schema.json")
            Sync-FeatureStateTierToT3 -StatePath $Path
            Write-Output $Path
        }
    }
    "ValidateApproval" {
        Assert-Argument -Name "Path" -Value $Path
        Invoke-WithFileLock -StatePath $Path -Action {
            Validate-ApprovalState -StatePath $Path | Out-Null
            Write-Output "VALID"
        }
    }
    "Approve" {
        Assert-Argument -Name "Path" -Value $Path
        Assert-Argument -Name "Gate" -Value $Gate
        Assert-Argument -Name "ApprovedBy" -Value $ApprovedBy

        if (-not $RuntimePathWasBound) {
            if ($OwnerWorkflow -ne "SUPERPOWERS") {
                throw "Approve without -RuntimePath requires SUPERPOWERS ownership."
            }
            Invoke-WithFileLock -StatePath $Path -Action {
                Approve-CanonicalArtifact -StatePath $Path -GateName $Gate -Approver $ApprovedBy
                Sync-FeatureStateTierToT3 -StatePath $Path
            }
        } else {
            Assert-Argument -Name "RuntimePath" -Value $RuntimePath
            Invoke-LegacyRuntimeApproval -StatePath $Path -RuntimeStatePath $RuntimePath `
                -GateName $Gate -Approver $ApprovedBy
            Sync-FeatureStateTierToT3 -StatePath $Path
        }
    }
    "ResetApproval" {
        Assert-Argument -Name "Path" -Value $Path
        Assert-Argument -Name "Gate" -Value $Gate

        Invoke-WithFileLock -StatePath $Path -Action {
            $state = Read-JsonObject -FilePath $Path -SchemaPath (Join-Path $SchemaRoot "workflow-state.schema.json")
            $gatesToReset = if ($Gate -eq "requirement") {
                @("requirement", "design")
            } else {
                @("design")
            }
            foreach ($gateName in $gatesToReset) {
                $state.$gateName.status = "DRAFT"
                $state.$gateName.sha256 = ""
                $state.$gateName.approvedAt = ""
                $state.$gateName.approvedBy = ""
            }
            Write-JsonAtomic -FilePath $Path -Value $state -SchemaPath (Join-Path $SchemaRoot "workflow-state.schema.json")
            Write-Output $Path
        }
    }
    "UpdateHash" {
        Assert-Argument -Name "Path" -Value $Path
        Assert-Argument -Name "Gate" -Value $Gate

        Invoke-WithFileLock -StatePath $Path -Action {
            $state = Read-JsonObject -FilePath $Path -SchemaPath (Join-Path $SchemaRoot "workflow-state.schema.json")
            $approval = $state.$Gate
            if (-not $approval) {
                throw "Unknown gate: $Gate"
            }
            if ($approval.status -ne "APPROVED") {
                throw "UpdateHash only applies to APPROVED gates; gate '$Gate' is '$($approval.status)'. Use ResetApproval + Approve to re-approve after substantive changes."
            }
            $artifactPath = Resolve-ArtifactPath -StatePath $Path -Artifact $approval.artifact
            if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                throw "Cannot update hash for missing artifact: $artifactPath"
            }
            $approval.sha256 = (Get-AiSopArtifactHash -Path $artifactPath)
            Write-JsonAtomic -FilePath $Path -Value $state -SchemaPath (Join-Path $SchemaRoot "workflow-state.schema.json")
            Write-Output $Path
        }
    }
    "InitRuntime" {
        Assert-Argument -Name "Path" -Value $Path
        Assert-Argument -Name "Feature" -Value $Feature
        Assert-Argument -Name "SpecDirectory" -Value $SpecDirectory
        Assert-Argument -Name "TaskType" -Value $TaskType
        $resolvedSpecDirectory = [System.IO.Path]::GetFullPath($SpecDirectory)
        if (-not (Test-Path -LiteralPath $resolvedSpecDirectory -PathType Container)) {
            throw "Specification directory does not exist: $resolvedSpecDirectory"
        }
        if (Test-Path -LiteralPath $Path) {
            throw "Runtime state already exists: $Path"
        }
        if ($TaskType -eq "AUDIT_ONLY") {
            if ($AuditFixPolicy -eq "NONE" -or @($StandaloneStages).Count -eq 0) {
                throw "AUDIT_ONLY requires -AuditFixPolicy and at least one -StandaloneStages value."
            }
            $transitions = Get-Transitions
            for ($index = 0; $index -lt (@($StandaloneStages).Count - 1); $index++) {
                Assert-LegalTransition -Transitions $transitions `
                    -From $StandaloneStages[$index] -To $StandaloneStages[$index + 1]
            }
        } elseif ($AuditFixPolicy -ne "NONE" -or @($StandaloneStages).Count -ne 0) {
            throw "Audit policy and standalone stages are only valid for AUDIT_ONLY."
        }
        $resolvedContractMode = if ($TaskType -eq "AUDIT_ONLY") {
            if ($ContractMode -eq "AUTO") {
                if (Test-Path -LiteralPath (Join-Path $resolvedSpecDirectory "00_workflow_state.json") -PathType Leaf) {
                    "FEATURE"
                } else {
                    "NONE"
                }
            } else {
                $ContractMode
            }
        } else {
            if ($ContractMode -ne "AUTO") {
                throw "-ContractMode is only valid for AUDIT_ONLY."
            }
            "FEATURE"
        }
        if ([string]::IsNullOrWhiteSpace($RunId)) {
            $RunId = "{0}-{1}" -f [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss"), [guid]::NewGuid().ToString("N").Substring(0, 8)
        }

        $state = [ordered]@{
            schemaVersion = "1.0"
            runId = $RunId
            feature = $Feature
            specDirectory = $resolvedSpecDirectory
            contractMode = $resolvedContractMode
            taskType = $TaskType
            phase = "INIT"
            status = "RUNNING"
            attempts = [ordered]@{
                implementation = 0
                audit = 0
                qa = 0
            }
            scope = [ordered]@{
                files = @()
                methods = @()
                baseline = ""
            }
            testMode = "PROJECT_DEFINED"
            auditFixPolicy = $AuditFixPolicy
            auditStages = @($StandaloneStages)
            auditStageIndex = 0
            lastResult = ""
            lastHandoffSequence = 0
            testCoverageSha256 = ""
            failureAttempts = [ordered]@{}
            blockReason = ""
            nextPhase = ""
            updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
        }
        $state.nextPhase = Get-InitialPhase -Runtime ([pscustomobject]$state)
        Assert-RuntimeSemantics -State ([pscustomobject]$state)
        Write-JsonAtomic -FilePath $Path -Value $state -SchemaPath (Join-Path $SchemaRoot "runtime-state.schema.json")
        Validate-RuntimeState -StatePath $Path | Out-Null
        Write-Output $Path
    }
    "ValidateRuntime" {
        Assert-Argument -Name "Path" -Value $Path
        Validate-RuntimeState -StatePath $Path | Out-Null
        Write-Output "VALID"
    }
    "TransitionRuntime" {
        Assert-Argument -Name "Path" -Value $Path
        Assert-Argument -Name "ToPhase" -Value $ToPhase

        Invoke-WithWorkflowLocks -RuntimePath $Path -Action {
            $state = Validate-RuntimeState -StatePath $Path
            $transitions = Get-Transitions
            $targetStatus = if ([string]::IsNullOrWhiteSpace($RuntimeStatus)) {
                Get-DefaultRuntimeStatus -Phase $ToPhase
            } else {
                $RuntimeStatus
            }

            if ($targetStatus -eq "BLOCKED") {
                if ($ToPhase -ne $state.phase) {
                    throw "Entering BLOCKED must preserve the current phase '$($state.phase)'."
                }
                if (-not [string]::IsNullOrWhiteSpace($NextPhase) -and $NextPhase -ne $state.phase) {
                    throw "BLOCKED runtime must use the current phase as nextPhase."
                }
            } elseif ($state.status -eq "BLOCKED") {
                if ($ToPhase -ne $state.nextPhase) {
                    throw "Blocked runtime can only resume at nextPhase '$($state.nextPhase)'."
                }
            } elseif ($state.phase -eq "INIT") {
                Assert-LegalTransition -Transitions $transitions -From $state.phase -To $ToPhase
                Assert-TaskSpecificTransition -Runtime $state -From $state.phase -To $ToPhase
            } elseif ($state.status -eq "WAIT_HUMAN") {
                Assert-LegalTransition -Transitions $transitions -From $state.phase -To $ToPhase
                Assert-TaskSpecificTransition -Runtime $state -From $state.phase -To $ToPhase
            } else {
                throw "Active workflow phases must advance through -Operation ApplyHandoff."
            }
            Assert-RequiredApprovals -Runtime $state -TargetPhase $ToPhase

            $targetNextPhase = if ([string]::IsNullOrWhiteSpace($NextPhase)) {
                if ($targetStatus -eq "BLOCKED") {
                    $ToPhase
                } else {
                    Get-DefaultNextPhase -Phase $ToPhase
                }
            } else {
                $NextPhase
            }
            $state.phase = $ToPhase
            $state.status = $targetStatus
            $state.nextPhase = $targetNextPhase
            $state.lastResult = $LastResult
            $state.blockReason = $BlockReason
            $state.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
            Assert-RuntimeSemantics -State $state
            Write-JsonAtomic -FilePath $Path -Value $state -SchemaPath (Join-Path $SchemaRoot "runtime-state.schema.json")
            Validate-RuntimeState -StatePath $Path | Out-Null
            Write-Output $Path
        }
    }
    "ApplyHandoff" {
        Assert-Argument -Name "Path" -Value $Path
        Assert-Argument -Name "RuntimePath" -Value $RuntimePath

        Invoke-WithWorkflowLocks -RuntimePath $RuntimePath -Action {
            $validated = Validate-HandoffState -HandoffPath $Path -CurrentRuntimePath $RuntimePath
            $handoff = $validated.handoff
            $state = $validated.runtime

            $sourcePhase = $state.phase
            if ($handoff.status -eq "BLOCKED") {
                $targetPhase = $state.phase
                $targetStatus = "BLOCKED"
                $targetNextPhase = $state.phase
            } else {
                $targetPhase = $handoff.recommendedPhase
                $targetStatus = Get-DefaultRuntimeStatus -Phase $targetPhase
                $targetNextPhase = Get-DefaultNextPhase -Phase $targetPhase
            }

            if (
                $state.taskType -eq "AUDIT_ONLY" -and
                $state.auditFixPolicy -eq "AUTO_REPAIR" -and
                $handoff.recommendedPhase -in @(
                    "REQUIREMENT_DRAFT",
                    "DESIGN_DRAFT",
                    "QA_PLAN",
                    "IMPLEMENTATION",
                    "IMPLEMENTATION_AUDIT"
                )
            ) {
                $state.auditStageIndex = 0
            } elseif ($state.taskType -eq "AUDIT_ONLY" -and $sourcePhase -in @($state.auditStages)) {
                if ($handoff.status -in @("PASS", "FINDINGS")) {
                    $state.auditStageIndex = [Math]::Min(
                        [int]$state.auditStageIndex + 1,
                        @($state.auditStages).Count
                    )
                }
            }

            if ($handoff.status -eq "FAIL") {
                $attemptCategory = Get-AttemptCategoryForPhase -Phase $sourcePhase
                if (-not [string]::IsNullOrWhiteSpace($attemptCategory)) {
                    Add-FailureAttempt -State $state -Category $attemptCategory -Key $handoff.failureKey
                }
            }

            if (
                $sourcePhase -eq "TEST_PLAN_AUDIT" -and
                $handoff.status -eq "PASS" -and
                $targetPhase -eq "IMPLEMENTATION"
            ) {
                $coveragePath = Join-Path $state.specDirectory "05_test_coverage.json"
                $state.testCoverageSha256 = (Get-AiSopArtifactHash -Path $coveragePath)
            } elseif ($targetPhase -in @(
                "REQUIREMENT_DRAFT",
                "DESIGN_DRAFT",
                "QA_PLAN",
                "TEST_PLAN_AUDIT"
            )) {
                $state.testCoverageSha256 = ""
            }
            if ($targetPhase -in @("REQUIREMENT_DRAFT", "DESIGN_DRAFT")) {
                $state.failureAttempts = [pscustomobject]@{}
            }

            $state.phase = $targetPhase
            $state.status = $targetStatus
            $state.nextPhase = $targetNextPhase
            $state.lastResult = $handoff.result
            $state.lastHandoffSequence = [int]$handoff.sequence
            $state.blockReason = $handoff.blockReason
            $state.scope = $handoff.scope
            $state.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
            Assert-RuntimeSemantics -State $state
            Write-JsonAtomic -FilePath $RuntimePath -Value $state -SchemaPath (Join-Path $SchemaRoot "runtime-state.schema.json")
            Validate-RuntimeState -StatePath $RuntimePath | Out-Null
            Write-Output $RuntimePath
        }
    }
    "IncrementAttempt" {
        Assert-Argument -Name "Path" -Value $Path
        Assert-Argument -Name "AttemptCategory" -Value $AttemptCategory
        Assert-Argument -Name "FailureKey" -Value $FailureKey

        Invoke-WithFileLock -StatePath $Path -Action {
            $state = Validate-RuntimeState -StatePath $Path
            Add-FailureAttempt -State $state -Category $AttemptCategory -Key $FailureKey
            $state.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
            Write-JsonAtomic -FilePath $Path -Value $state -SchemaPath (Join-Path $SchemaRoot "runtime-state.schema.json")
            Write-Output $state.attempts.$AttemptCategory
        }
    }
    "ValidateHandoff" {
        Assert-Argument -Name "Path" -Value $Path
        Assert-Argument -Name "RuntimePath" -Value $RuntimePath
        Invoke-WithWorkflowLocks -RuntimePath $RuntimePath -Action {
            Validate-HandoffState -HandoffPath $Path -CurrentRuntimePath $RuntimePath | Out-Null
            Write-Output "VALID"
        }
    }
    "ValidateTestCoverage" {
        Assert-Argument -Name "Path" -Value $Path
        $runtime = $null
        if (-not [string]::IsNullOrWhiteSpace($RuntimePath)) {
            $runtime = Validate-RuntimeState -StatePath $RuntimePath
        }
        Validate-TestCoverageState -CoveragePath $Path -Runtime $runtime | Out-Null
        $effectivePhase = $Phase
        if ([string]::IsNullOrWhiteSpace($effectivePhase)) {
            $specDir = Split-Path -Parent $Path
            $featStatePath = Join-Path $specDir "feature-state.json"
            if (Test-Path -LiteralPath $featStatePath -PathType Leaf) {
                try {
                    $fs = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json
                    $planPhases = @(
                        "INIT", "CLASSIFY", "PLANNING", "INTENT", "CLAIMED",
                        "REQUIREMENT_DRAFT", "WAIT_REQUIREMENT_APPROVAL", "REQUIREMENT_APPROVED",
                        "DESIGN_DRAFT", "WAIT_DESIGN_APPROVAL", "DESIGN_REVIEWED", "DESIGN_APPROVED",
                        "QA_PLAN", "TEST_PLAN_AUDIT"
                    )
                    if ($fs.phase -in $planPhases) {
                        $effectivePhase = "PLAN"
                    }
                } catch {}
            }
        }
        if ([string]::IsNullOrWhiteSpace($effectivePhase)) { $effectivePhase = "VERIFY" }
        $placeholderResult = Get-CoveragePlaceholderWarnings -CoveragePath $Path -Phase $effectivePhase
        if ($placeholderResult.Errors.Count -gt 0) {
            foreach ($e in $placeholderResult.Errors) { Write-Output $e }
            Write-Output "INVALID_PLACEHOLDERS"
            Write-Output "DIAGNOSTIC: traceability/hash/id-cross-check passed, but P0/P1 TCs above still carry SyncCoverage placeholder assertions (expected=placeholder/operator=N_A/target=see plan). High-priority cases must be refined with real assertions before delivery. Refine and re-run."
        } else {
            Write-Output "VALID"
            if ($placeholderResult.Warnings.Count -gt 0) {
                foreach ($w in $placeholderResult.Warnings) { Write-Output $w }
                Write-Output "DIAGNOSTIC: VALID means traceability/hash/id-cross-check passed; WARN above means some lower-priority assertions are still SyncCoverage placeholders and should be refined before delivery — T3 done-condition #2 is not truly met while placeholders remain."
            }
        }
    }
    "ValidateTransitions" {
        Get-Transitions | Out-Null
        Write-Output "VALID"
    }
    "Status" {
        Assert-Argument -Name "Path" -Value $Path
        # Read-only diagnostic: no lock, no throw. Reports gate status + hash match + tier.
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Output ("NO_STATE: approval state file does not exist: $Path")
        } else {
            $schema = Join-Path $SchemaRoot "workflow-state.schema.json"
            $state = Read-JsonObject -FilePath $Path -SchemaPath $schema
            $feature = [string]$state.feature
            # Read tier from feature-state.json (sibling file) if present.
            $featStatePath = Join-Path (Split-Path -Parent $Path) "feature-state.json"
            $tier = "unknown"
            $phase = "unknown"
            if (Test-Path -LiteralPath $featStatePath -PathType Leaf) {
                try {
                    $fs = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json
                    $tier = [string]$fs.tier
                    $phase = [string]$fs.phase
                } catch { }
            }
            Write-Output "feature=$feature tier=$tier phase=$phase"
            $isDesignOnly = ($state.gateMode -eq "DESIGN_ONLY")
            foreach ($gateName in @("requirement", "design")) {
                if ($gateName -eq "requirement" -and $isDesignOnly) {
                    Write-Output "gate=requirement status=EXEMPT(DESIGN_ONLY) sha256= artifact=01_server_rules.md artifactExists=True hashMatch=MATCH"
                    continue
                }
                $approval = $state.$gateName
                $status = [string]$approval.status
                $recordedSha = [string]$approval.sha256
                $artifact = [string]$approval.artifact
                $hashMatch = "N/A"
                $artifactExists = $false
                if ($status -eq "APPROVED" -and $artifact) {
                    $artifactPath = Resolve-ArtifactPath -StatePath $Path -Artifact $artifact
                    $artifactExists = Test-Path -LiteralPath $artifactPath -PathType Leaf
                    if ($artifactExists) {
                        $actualHash = (Get-AiSopArtifactHash -Path $artifactPath)
                        $hashMatch = if ($actualHash -eq $recordedSha.ToLowerInvariant()) { "MATCH" } else { "DRIFT" }
                    }
                }
                Write-Output (
                    "gate=$gateName status=$status sha256=$recordedSha " +
                    "artifact=$artifact artifactExists=$artifactExists hashMatch=$hashMatch"
                )
            }
            Write-Output "DIAGNOSTIC: hashMatch=DRIFT means the approved artifact was modified after approval. Use UpdateHash (cosmetic) or ResetApproval+Approve (substantive)."
        }
    }
    "SyncCoverage" {
        # Generate 05_test_coverage.json from 05_test_plan.md HTML-comment metadata.
        # Expected format in 05_test_plan.md: <!-- meta: { "id": "TC01", "covers": ["BR01", "DC01"] } -->
        # Produces a minimal schema-valid coverage JSON; user/AI refines setup/trigger/assertions.
        Assert-Argument -Name "Path" -Value $Path
        $specDir = Split-Path -Parent $Path
        $testPlanPath = Join-Path $specDir "05_test_plan.md"
        if (-not (Test-Path -LiteralPath $testPlanPath -PathType Leaf)) {
            throw "05_test_plan.md not found at: $testPlanPath (SyncCoverage requires it)"
        }
        $raw = [System.IO.File]::ReadAllText($testPlanPath)
        $cases = [System.Collections.Generic.List[hashtable]]::new()
        $pattern = '<!--\s*meta:\s*(\{.*?\})\s*-->'
        foreach ($m in [regex]::Matches($raw, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
            try {
                $meta = $m.Groups[1].Value | ConvertFrom-Json
                $tcId = [string]$meta.id
                $covers = @($meta.covers)
                $reqIds = @($covers | Where-Object { $_ -match '^(BR|EX|AC)-' })
                $desIds = @($covers | Where-Object { $_ -match '^(DC|DR|TW)-' })
                if ($reqIds.Count -eq 0 -and $desIds.Count -eq 0) {
                    $desIds = @("DC-PLACEHOLDER")
                }
                $cases.Add([ordered]@{
                    id = $tcId
                    status = "PLANNED"
                    title = [string]$meta.title
                    priority = if ($meta.priority) { [string]$meta.priority } else { "P1" }
                    testTypes = @("FUNCTIONAL")
                    requirementIds = $reqIds
                    designIds = $desIds
                    automationCarrier = if ($meta.carrier) { [string]$meta.carrier } else { "__TODO__" }
                })
            } catch {
                Write-Host "WARN: skipped bad meta block: $($m.Groups[1].Value)" -ForegroundColor Yellow
            }
        }
        if ($cases.Count -eq 0) {
            throw "No valid <!-- meta: {...} --> blocks found in 05_test_plan.md. Add metadata like: <!-- meta: { ""id"": ""TC01"", ""covers"": [""BR01"", ""DC01""] } -->"
        }
        # Build feature name from spec dir name.
        $feature = [System.IO.Path]::GetFileName($specDir.TrimEnd('\', '/'))
        # Compute artifact SHAs (normalized) for requirement/design.
        $reqPath = Join-Path $specDir "01_server_rules.md"
        $desPath = Join-Path $specDir "06_design_contract.md"
        $reqSha = if (Test-Path -LiteralPath $reqPath -PathType Leaf) { Get-AiSopArtifactHash -Path $reqPath } else { ("0" * 64) }
        $desSha = if (Test-Path -LiteralPath $desPath -PathType Leaf) { Get-AiSopArtifactHash -Path $desPath } else { ("0" * 64) }
        $tpSha = Get-AiSopArtifactHash -Path $testPlanPath
        $coverage = [ordered]@{
            schemaVersion = "1.0"
            feature = $feature
            requirementArtifact = "01_server_rules.md"
            requirementSha256 = $reqSha
            designArtifact = "06_design_contract.md"
            designSha256 = $desSha
            testPlanArtifact = "05_test_plan.md"
            testPlanSha256 = $tpSha
            cases = $cases
            riskExemptions = @()
        }
        $json = $coverage | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($Path, $json, $Utf8NoBom)
        Sync-FeatureStateTierToT3 -StatePath $Path
        Write-Output "Synced $Path ($($cases.Count) test cases from 05_test_plan.md)"
    }
    "CheckCompletion" {
        # Machine-checkable completion conditions per tier. Outputs ASCII checklist.
        # Reads tier from feature-state.json; auto-escalates to T3 if approval state or spec artifacts exist.
        Assert-Argument -Name "Path" -Value $Path
        $specDir = Split-Path -Parent $Path
        $featStatePath = Join-Path $specDir "feature-state.json"
        $tier = "unknown"
        $phase = "unknown"
        if (Test-Path -LiteralPath $featStatePath -PathType Leaf) {
            try { $fs = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json; $tier = [string]$fs.tier; $phase = [string]$fs.phase } catch { }
        }
        $hasWorkflowState = (Test-Path -LiteralPath $Path -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $specDir "workflow-state.json") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $specDir "00_workflow_state.json") -PathType Leaf)
        $hasSpecArtifacts = (Test-Path -LiteralPath (Join-Path $specDir "01_server_rules.md") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $specDir "06_design_contract.md") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $specDir "05_test_plan.md") -PathType Leaf)
        
        $effectiveTier = $tier
        if ($hasWorkflowState -or $hasSpecArtifacts -or $tier -eq "T3") {
            $effectiveTier = "T3"
            if ($phase -eq "unknown" -or [string]::IsNullOrWhiteSpace($phase)) { $phase = "IN_PROGRESS" }
        } elseif ($tier -in @("T1", "T2", "FAST_TRACK")) {
            $effectiveTier = $tier
        } else {
            $effectiveTier = "unknown"
        }
        Write-Output "tier=$effectiveTier phase=$phase"
        $checks = [System.Collections.Generic.List[string]]::new()
        
        # Workspace root resolution (search upward for .ai-workspace, .git, or .svn)
        $specFullPath = [System.IO.Path]::GetFullPath($specDir)
        $wsRoot = Resolve-AiSopWorkspaceRoot -StartPath $specDir
        if ([string]::IsNullOrWhiteSpace($wsRoot)) { $wsRoot = (Get-Location).Path }

        # 1. Gate approval state (T3 only).
        if ($effectiveTier -eq "T3") {
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $st = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
                $isDesignOnly = ($st.gateMode -eq "DESIGN_ONLY")
                $reqOk = ($st.requirement.status -eq "APPROVED")
                $desOk = ($st.design.status -eq "APPROVED")
                if ($isDesignOnly) {
                    $checks.Add("[v] 需求门禁(豁免: 仅技术契约)")
                } else {
                    $checks.Add("[$(if($reqOk){'v'}else{'X'})] 需求门禁 APPROVED")
                }
                $checks.Add("[$(if($desOk){'v'}else{'X'})] 设计门禁 APPROVED")
            } else {
                $checks.Add("[X] 门禁状态文件缺失")
            }
            # 2. Coverage.
            $covPath = Join-Path $specDir "05_test_coverage.json"
            $covOk = Test-Path -LiteralPath $covPath -PathType Leaf
            $checks.Add("[$(if($covOk){'v'}else{'X'})] 测试覆盖矩阵存在")
        }
        # 3. Compile (check candidate roots for build/ classes/ target artifacts).
        $specParent2 = Split-Path -Parent (Split-Path -Parent $specFullPath)
        $specParent4 = Split-Path -Parent (Split-Path -Parent $specParent2)
        $candidateRoots = @($wsRoot, $specParent2, $specParent4) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $compileOk = $false
        foreach ($r in $candidateRoots) {
            if ((Test-Path -LiteralPath (Join-Path $r "build/classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "build/libs") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "build") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "target/classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "WebRoot/WEB-INF/classes") -PathType Container)) {
                $compileOk = $true
                break
            }
            if (Test-Path -LiteralPath $r -PathType Container) {
                $subClasses = Get-ChildItem -LiteralPath $r -Directory -Depth 4 -Filter "classes" -ErrorAction SilentlyContinue
                if ($subClasses.Count -gt 0) {
                    $compileOk = $true
                    break
                }
            }
        }
        $checks.Add("[$(if($compileOk){'v'}else{'?'})] 编译产物存在(以构建/测试命令执行结果为准)")
        
        # 4. VCS delivery surface state (3-state detection).
        if (Test-Path -LiteralPath (Join-Path $wsRoot ".svn") -PathType Container) {
            $checks.Add("[?] VCS 交付状态: SVN 工作副本 (准备 svn commit)")
        } elseif (Test-Path -LiteralPath (Join-Path $wsRoot ".git") -PathType Container) {
            $checks.Add("[?] VCS 交付状态: Git 仓库 (人工确认 git commit / status)")
        } else {
            $checks.Add("[?] VCS 交付状态: 通用工程目录")
        }
        # 5. T2 / T1 / FAST_TRACK checklist reminders (AI self-reported).
        if ($effectiveTier -eq "T2") {
            $checks.Add("[?] 文档待更新提醒(AI 自报)")
        } elseif ($effectiveTier -eq "FAST_TRACK") {
            $checks.Add("[?] 快通道: 纯数值/文档检查(AI 自报)")
        } elseif ($effectiveTier -eq "T1") {
            $checks.Add("[?] T1: 急速逃生口(AI 自报)")
        }
        foreach ($c in $checks) { Write-Output $c }
        Write-Output "DIAGNOSTIC: [v]=pass, [X]=fail, [?]=needs human/AI verification. Machine-checked items only; AI must verify the rest per AGENTS.md done-definition table."
    }
    "VerifyCompletion" {
        Assert-Argument -Name "Path" -Value $Path
        $specDir = Split-Path -Parent $Path
        $featStatePath = Join-Path $specDir "feature-state.json"
        $tier = "unknown"
        $phase = "unknown"
        if (Test-Path -LiteralPath $featStatePath -PathType Leaf) {
            try { $fs = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json; $tier = [string]$fs.tier; $phase = [string]$fs.phase } catch { }
        }
        $hasWorkflowState = (Test-Path -LiteralPath $Path -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $specDir "workflow-state.json") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $specDir "00_workflow_state.json") -PathType Leaf)
        $hasSpecArtifacts = (Test-Path -LiteralPath (Join-Path $specDir "01_server_rules.md") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $specDir "06_design_contract.md") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $specDir "05_test_plan.md") -PathType Leaf)
        
        $effectiveTier = $tier
        if ($hasWorkflowState -or $hasSpecArtifacts -or $tier -eq "T3") {
            $effectiveTier = "T3"
        } elseif ($tier -in @("T1", "T2", "FAST_TRACK")) {
            $effectiveTier = $tier
        } else {
            $effectiveTier = "unknown"
        }
        $failures = [System.Collections.Generic.List[string]]::new()
        $checks = [System.Collections.Generic.List[string]]::new()
        
        # Workspace root resolution
        $specFullPath = [System.IO.Path]::GetFullPath($specDir)
        $wsRoot = Resolve-AiSopWorkspaceRoot -StartPath $specDir
        if ([string]::IsNullOrWhiteSpace($wsRoot)) { $wsRoot = (Get-Location).Path }

        $specParent2 = Split-Path -Parent (Split-Path -Parent $specFullPath)
        $specParent4 = Split-Path -Parent (Split-Path -Parent $specParent2)
        $candidateRoots = @($wsRoot, $specParent2, $specParent4) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $compileOk = $false
        foreach ($r in $candidateRoots) {
            if ((Test-Path -LiteralPath (Join-Path $r "build/classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "build/libs") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "build") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "target/classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "WebRoot/WEB-INF/classes") -PathType Container)) {
                $compileOk = $true
                break
            }
            if (Test-Path -LiteralPath $r -PathType Container) {
                $subClasses = Get-ChildItem -LiteralPath $r -Directory -Depth 4 -Filter "classes" -ErrorAction SilentlyContinue
                if ($subClasses.Count -gt 0) {
                    $compileOk = $true
                    break
                }
            }
        }
        if ($effectiveTier -eq "T3") {
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $st = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
                $isDesignOnly = ($st.gateMode -eq "DESIGN_ONLY")
                $reqOk = ([string]$st.requirement.status -eq "APPROVED")
                $desOk = ([string]$st.design.status -eq "APPROVED")
                if (-not $isDesignOnly -and -not $reqOk) { $failures.Add("requirement gate not APPROVED") }
                if (-not $desOk) { $failures.Add("design gate not APPROVED") }
                if ($isDesignOnly) {
                    $checks.Add("[v] 需求门禁(豁免: 仅技术契约)")
                } else {
                    $checks.Add("[$(if($reqOk){'v'}else{'X'})] 需求门禁 APPROVED")
                }
                $checks.Add("[$(if($desOk){'v'}else{'X'})] 设计门禁 APPROVED")
            } else {
                $failures.Add("workflow-state.json missing")
                $checks.Add("[X] 门禁状态文件缺失")
            }
            # Coverage VALID (no placeholder/carrier errors).
            $covPath = Join-Path $specDir "05_test_coverage.json"
            $covOk = Test-Path -LiteralPath $covPath -PathType Leaf
            $checks.Add("[$(if($covOk){'v'}else{'X'})] 测试覆盖矩阵存在")
            if ($covOk) {
                try {
                    Validate-TestCoverageState -CoveragePath $covPath -Runtime $null | Out-Null
                    $phResult = Get-CoveragePlaceholderWarnings -CoveragePath $covPath -Phase "VERIFY"
                    if ($phResult.Errors.Count -gt 0) {
                        $failures.Add("coverage has $($phResult.Errors.Count) placeholder/carrier error(s)")
                        $checks.Add("[X] 覆盖校验无占位/carrier错误($($phResult.Errors.Count) error)")
                    } else {
                        $checks.Add("[v] 覆盖校验无占位/carrier错误")
                    }
                } catch {
                    $failures.Add("coverage validation threw: $($_.Exception.Message)")
                    $checks.Add("[X] 覆盖校验异常")
                }
            } else {
                $failures.Add("coverage matrix missing")
            }
            # feature-state phase must not be initial/empty.
            $phaseOk = (-not [string]::IsNullOrWhiteSpace($phase)) -and ($phase -ne "INIT") -and ($phase -ne "unknown") -and ($phase -ne "UNCLASSIFIED")
            if (-not $phaseOk) { $failures.Add("feature-state phase is initial/unknown ($phase)") }
            $checks.Add("[$(if($phaseOk){'v'}else{'X'})] feature-state 阶段非初始($phase)")
        } elseif ($effectiveTier -in @("T1", "T2", "FAST_TRACK")) {
            # T1/T2/FAST_TRACK: compile artifact check is non-blocking (advisory); Claim validity is workflow-owner.ps1 Validate's job
            if ($effectiveTier -eq "T2") {
                $checks.Add("[?] 归属 Validate(owner.ps1 -Operation Validate,另跑)")
                $checks.Add("[?] 相关测试/回归(AI 据定向 JUnit 结果自报)")
            } elseif ($effectiveTier -eq "FAST_TRACK") {
                $checks.Add("[?] 快通道: 纯数值/文档检查自报")
            } elseif ($effectiveTier -eq "T1") {
                $checks.Add("[?] T1: 急速逃生口(仅编译检查)")
            }
        } else {
            $failures.Add("tier unknown — feature-state.json missing or tier not set")
            $checks.Add("[X] tier 未知(feature-state.json 缺失或未设 tier)")
        }
        $checks.Add("[$(if($compileOk){'v'}else{'?'})] 编译产物存在(以构建/测试命令执行结果为准)")
        if (-not $compileOk -and $effectiveTier -eq "T3") { $failures.Add("compile verification failed — no build artifacts found") }

        # VCS unversioned/missing file detection (hard blocker for code/config files).
        $untrackedFiles = [System.Collections.Generic.List[string]]::new()
        $codeExtensions = @(".java", ".groovy", ".kt", ".xml", ".properties", ".proto", ".ps1", ".csv", ".json", ".sql", ".yml", ".yaml")
        $codeDirPrefixes = @("src/", "test/", "scripts/", "distribution/", "config/")
        
        if (Test-Path -LiteralPath (Join-Path $wsRoot ".svn") -PathType Container) {
            try {
                $svnOutput = & svn status --ignore-externals $wsRoot 2>&1
                if ($LASTEXITCODE -eq 0) {
                    foreach ($line in $svnOutput) {
                        if ($line -match '^(\?|\!)\s+(.+)$') {
                            $flag = $Matches[1]
                            $rawPath = $Matches[2].Trim()
                            $normPath = $rawPath.Replace("\", "/")
                            $isTargetDir = $false
                            foreach ($pfx in $codeDirPrefixes) {
                                if ($normPath.StartsWith($pfx) -or ($normPath -match "(^|/)$([regex]::Escape($pfx))")) { $isTargetDir = $true; break }
                            }
                            $ext = [System.IO.Path]::GetExtension($normPath).ToLowerInvariant()
                            if ($isTargetDir -and ($ext -in $codeExtensions)) {
                                if ($flag -eq "?") {
                                    $untrackedFiles.Add("$rawPath (需 svn add)")
                                } elseif ($flag -eq "!") {
                                    $untrackedFiles.Add("$rawPath (需 svn delete)")
                                }
                            }
                        }
                    }
                }
            } catch {}
            if ($untrackedFiles.Count -gt 0) {
                $failures.Add("VCS untracked/missing code files found: $($untrackedFiles -join ', ') -> AI 请在后台自动执行 svn add <files> / svn delete <files> 修复后重试 VerifyCompletion")
                $checks.Add("[X] VCS 交付状态: SVN 存在未同步代码 ($($untrackedFiles.Count) 个文件未执行 svn add/delete)")
            } else {
                $checks.Add("[?] VCS 交付状态: SVN 工作副本 (准备 svn commit)")
            }
        } elseif (Test-Path -LiteralPath (Join-Path $wsRoot ".git") -PathType Container) {
            try {
                $gitOutput = & git -C $wsRoot status --porcelain -uall 2>&1
                if ($LASTEXITCODE -eq 0) {
                    foreach ($line in $gitOutput) {
                        if ($line -match '^\?\?\s+(.+)$') {
                            $rawPath = $Matches[1].Trim()
                            $normPath = $rawPath.Replace("\", "/")
                            $isTargetDir = $false
                            foreach ($pfx in $codeDirPrefixes) {
                                if ($normPath.StartsWith($pfx) -or ($normPath -match "(^|/)$([regex]::Escape($pfx))")) { $isTargetDir = $true; break }
                            }
                            $ext = [System.IO.Path]::GetExtension($normPath).ToLowerInvariant()
                            if ($isTargetDir -and ($ext -in $codeExtensions)) {
                                $untrackedFiles.Add("$rawPath (需 git add)")
                            }
                        }
                    }
                }
            } catch {}
            if ($untrackedFiles.Count -gt 0) {
                $failures.Add("VCS untracked code files found: $($untrackedFiles -join ', ') -> AI 请在后台自动执行 git add <files> 修复后重试 VerifyCompletion")
                $checks.Add("[X] VCS 交付状态: Git 存在未跟踪代码 ($($untrackedFiles.Count) 个文件未执行 git add)")
            } else {
                $checks.Add("[?] VCS 交付状态: Git 仓库 (人工确认 git commit / status)")
            }
        } else {
            $checks.Add("[?] VCS 交付状态: 通用工程目录")
        }

        Write-Output "tier=$effectiveTier phase=$phase"
        foreach ($c in $checks) { Write-Output $c }
        if ($failures.Count -eq 0) {
            Write-Output "VERIFY_COMPLETION_PASS"
            exit 0
        } else {
            Write-Output "VERIFY_COMPLETION_FAIL"
            Write-Output "FAILURES: $($failures -join '; ')"
            exit 1
        }
    }
}
}
