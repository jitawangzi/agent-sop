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
        "ValidateChangeImpact",
        "AssessRisk",
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
    [string]$GateMode = "DUAL",
    [string]$Baseline = ""
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

function Get-StringSha256 {
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
    $isDesignOnly = ($approval.gateMode -eq "DESIGN_ONLY")
    if (-not $isDesignOnly -and $approval.requirement.status -ne "APPROVED") {
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
    $pattern = "(?im)^ {0,3}(?:[-*+]\s+|#{1,6}\s+)(?:\*\*)?((?:$prefixPattern)-[A-Z0-9][A-Z0-9_-]*)\b"
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

function Test-AiSopPathIsInsideWorkspaceLayer {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $norm = $Path.Replace('\', '/').TrimEnd('/')
    return $norm -match '(?i)(?:^|/)\.ai-workspace(?:/|$)'
}

function Test-IsSvnRevisionBaseline {
    param([string]$Baseline)
    if ([string]::IsNullOrWhiteSpace($Baseline)) { return $false }
    return ($Baseline -match '^(?:rev|r)?\d+$')
}

function Test-IsGitCommitBaseline {
    param([string]$Baseline)
    if ([string]::IsNullOrWhiteSpace($Baseline)) { return $false }
    # All-digit values are SVN revisions even when they match hex length (7+).
    if (Test-IsSvnRevisionBaseline -Baseline $Baseline) { return $false }
    return ($Baseline -match '^[0-9a-fA-F]{7,64}$')
}

function Test-SvnWorkingCopyUsable {
    param([string]$WorkspaceRoot)
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".svn"))) { return $false }
    try {
        $svnRev = (& svn info --non-interactive --show-item revision $WorkspaceRoot 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $svnRev -match '^\d+$') { return $true }
        $svnInfo = (& svn info --non-interactive $WorkspaceRoot 2>&1 | Out-String)
        return [bool]($svnInfo -match '(?m)^Revision:\s*(\d+)')
    } catch {
        return $false
    }
}

function Test-IsHybridGitSvnWorkspace {
    param([string]$WorkspaceRoot)
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return $false }
    $hasGit = Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git")
    $hasSvn = Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".svn")
    return [bool]($hasGit -and $hasSvn)
}

function Test-GitCommitExists {
    param(
        [string]$WorkspaceRoot,
        [string]$Baseline
    )
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or [string]::IsNullOrWhiteSpace($Baseline)) { return $false }
    if (-not (Test-IsGitCommitBaseline -Baseline $Baseline)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git"))) { return $false }
    try {
        $spec = $Baseline + '^{commit}'
        & git -C $WorkspaceRoot cat-file -e $spec 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-CanFailSoftStaleOverlayGitBaseline {
    param([string]$WorkspaceRoot)
    # Overlay git SHAs are not production identity. When the SVN working copy
    # can be scanned, a missing overlay commit must not abort risk assessment.
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return $false }
    return (Test-SvnWorkingCopyUsable -WorkspaceRoot $WorkspaceRoot)
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
        # Canonical project root: the directory that owns `.ai-workspace`.
        if (Test-Path -LiteralPath (Join-Path $curDir ".ai-workspace")) {
            return $curDir
        }
        # Nested git/svn under `.ai-workspace` is a spec-store, not the project.
        if (-not (Test-AiSopPathIsInsideWorkspaceLayer -Path $curDir)) {
            if ((Test-Path -LiteralPath (Join-Path $curDir ".ai-sop")) -or
                (Test-Path -LiteralPath (Join-Path $curDir "tools\ai-sop\ai-sop.lock.json")) -or
                (Test-Path -LiteralPath (Join-Path $curDir ".git")) -or
                (Test-Path -LiteralPath (Join-Path $curDir ".svn"))) {
                return $curDir
            }
        }
        $parent = Split-Path -Parent $curDir
        if ($parent -eq $curDir) { break }
        $curDir = $parent
    }
    return $null
}

function Get-VcsBaselineRevision {
    param([string]$StartPath)
    if ([string]::IsNullOrWhiteSpace($StartPath)) { return $null }
    $cur = if (Test-Path -LiteralPath $StartPath -PathType Container) { [System.IO.Path]::GetFullPath($StartPath) } else { Split-Path -Parent ([System.IO.Path]::GetFullPath($StartPath)) }
    $gitRoot = $null
    $svnRoot = $null
    while (-not [string]::IsNullOrWhiteSpace($cur)) {
        $insideWorkspaceLayer = Test-AiSopPathIsInsideWorkspaceLayer -Path $cur
        if (-not $insideWorkspaceLayer) {
            if ([string]::IsNullOrWhiteSpace($gitRoot) -and (Test-Path -LiteralPath (Join-Path $cur ".git"))) {
                $gitRoot = $cur
            }
            if ([string]::IsNullOrWhiteSpace($svnRoot) -and (Test-Path -LiteralPath (Join-Path $cur ".svn"))) {
                $svnRoot = $cur
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($gitRoot) -and -not [string]::IsNullOrWhiteSpace($svnRoot)) { break }
        $parent = Split-Path -Parent $cur
        if ($parent -eq $cur) { break }
        $cur = $parent
    }
    # Overlay git + production SVN: the production changeset identity is the SVN revision.
    if (-not [string]::IsNullOrWhiteSpace($svnRoot) -and (Test-SvnWorkingCopyUsable -WorkspaceRoot $svnRoot)) {
        try {
            $svnRev = (& svn info --non-interactive --show-item revision $svnRoot 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $svnRev -match '^\d+$') { return $svnRev }
            $svnInfo = (& svn info --non-interactive $svnRoot 2>&1 | Out-String)
            if ($svnInfo -match '(?m)^Revision:\s*(\d+)') { return $Matches[1] }
        } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($gitRoot)) {
        try {
            $headSha = (& git -C $gitRoot rev-parse HEAD 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and (Test-IsGitCommitBaseline -Baseline $headSha)) {
                return $headSha
            }
        } catch {}
    }
    return $null
}

function Unquote-GitPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $p = $Path.Trim()
    if ($p.StartsWith('"') -and $p.EndsWith('"') -and $p.Length -ge 2) {
        $p = $p.Substring(1, $p.Length - 2)
        $p = [regex]::Replace($p, '\\([0-7]{3})', {
            param($m)
            [char][Convert]::ToInt32($m.Groups[1].Value, 8)
        })
        $p = $p -replace '\\"', '"' -replace '\\\\', '\' -replace '\\t', "`t" -replace '\\n', "`n" -replace '\\r', "`r"
    }
    return $p
}

function Filter-SvnDiffBlocks {
    param([string]$DiffText)
    if ([string]::IsNullOrWhiteSpace($DiffText)) { return "" }
    $metaExcludes = @("04_change_impact.json", "00_workflow_state.json", "feature-state.json", "05_test_coverage.json")
    $blocks = [regex]::Split($DiffText, '(?m)(?=^Index:\s+)')
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($b in $blocks) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        $exclude = $false
        foreach ($ex in $metaExcludes) {
            if ($b -match '(?m)^(?:Index:\s+|---[ \t]+|\+\+\+[ \t]+)(?:.*[\\/])?' + [regex]::Escape($ex) + '(?:\s|\(|$|\.lock)') {
                $exclude = $true
                break
            }
        }
        if (-not $exclude) {
            $kept.Add($b.TrimEnd())
        }
    }
    return ($kept -join "`n`n")
}

function Assert-VcsCommitExists {
    param(
        [string]$WorkspaceRoot,
        [string]$Baseline
    )
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or [string]::IsNullOrWhiteSpace($Baseline)) { return }
    if ($Baseline -eq "0") { return }
    if (-not (Test-IsGitCommitBaseline -Baseline $Baseline)) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git"))) { return }
    if (Test-GitCommitExists -WorkspaceRoot $WorkspaceRoot -Baseline $Baseline) { return }
    if (Test-CanFailSoftStaleOverlayGitBaseline -WorkspaceRoot $WorkspaceRoot) { return }
    throw "INVALID_BASELINE: Git baseline commit '$Baseline' does not exist in repository '$WorkspaceRoot'."
}

function Get-FileRawSha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return ("0" * 64) }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
}

function Test-IsAiSopInternalSpecMetadata {
    param([string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    $norm = $RelativePath.Replace("\", "/").TrimStart('/').TrimEnd('/')
    
    # 1. Root-level governance metadata & lock files
    if ($norm -match '^(?:\.workflow-owner\.json(?:\.(?:lock|bak|stage\.tmp))?|\.workflow-mutation\.lock|\.workflow-mutation\.lock\.lock|\.ai-workspace|\.ai-sop|\.ai-sop/.*)$') {
        return $true
    }
    
    # 2. .ai-workspace spec tree internal state files and their specific lock/temp/backup files
    if ($norm -match '^\.ai-workspace/specs/features/[^/]+/(?:04_change_impact\.json|00_workflow_state\.json|workflow-state\.json|feature-state\.json|05_test_coverage\.json|\.workflow-owner\.json|\.workflow-mutation\.lock|\.commit-journal\.json)(?:\.(?:lock|bak|stage\.tmp))?$') {
        return $true
    }
    
    # 3. .ai-workspace directory ancestors
    if ($norm -match '^\.ai-workspace(?:/specs(?:/features(?:/[^/]+)?)?)?$') {
        return $true
    }

    return $false
}

function Get-NormalizedDiffBlockPath {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return "" }
    $p = Unquote-GitPath -Path $Raw.Trim()
    $p = $p.Replace('\', '/')
    $p = $p -replace '\t.*$', ''
    $p = $p -replace '\s+\([^)]*\)\s*$', ''
    $p = $p.Trim().TrimStart('/')
    if ($p.StartsWith('b/')) { $p = $p.Substring(2) }
    if ($p.StartsWith('a/')) { $p = $p.Substring(2) }
    return $p
}

function Get-FeatureSpecLocatorStopWords {
    return [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            'Player', 'String', 'Integer', 'Boolean', 'Object', 'System', 'Exception',
            'Override', 'Nullable', 'Optional', 'Collection', 'ArrayList', 'HashMap',
            'Logger', 'Json', 'JSONObject', 'JSONArray', 'Request', 'Response',
            'Config', 'Helper', 'Manager', 'Service', 'Action', 'Handler', 'Processor',
            'Controller', 'Test', 'Tests', 'Before', 'After', 'Setup', 'Expected',
            'Actual', 'Feature', 'Design', 'Requirement', 'Workflow', 'Coverage',
            'Schema', 'Baseline', 'Status', 'Error', 'Success', 'Failure', 'True',
            'False', 'Null', 'Type', 'Value', 'Result', 'State', 'Data', 'Info',
            'Item', 'List', 'Map', 'Set', 'File', 'Path', 'Name', 'Level', 'Class',
            'Enum', 'Interface', 'Abstract', 'Default', 'Common', 'Util', 'Utils',
            'Help', 'Rules', 'Plan', 'Contract', 'Display', 'Server', 'Client'
        ),
        [System.StringComparer]::Ordinal
    )
}

function Add-FeatureSpecLocator {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [string]$Token,
        [System.Collections.Generic.HashSet[string]]$StopWords
    )
    if ($null -eq $Set -or [string]::IsNullOrWhiteSpace($Token)) { return }
    $t = $Token.Trim().Trim('`', '"', "'")
    $t = $t.Replace('\', '/')
    if ($t.Length -lt 5) { return }
    if ($t -match '^(?:BR|EX|AC|DC|DR|TW|TC|INV)-') { return }
    if ($StopWords.Contains($t)) { return }
    [void]$Set.Add($t)
}

function Get-FeatureSpecLocators {
    param([string]$SpecDir)
    $locators = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ([string]::IsNullOrWhiteSpace($SpecDir) -or -not (Test-Path -LiteralPath $SpecDir -PathType Container)) {
        return [string[]]@()
    }
    $stop = Get-FeatureSpecLocatorStopWords
    $specFiles = @(
        "01_server_rules.md",
        "06_design_contract.md",
        "05_test_plan.md",
        "00_server_rules_draft.md",
        "04_change_impact.json"
    )
    foreach ($name in $specFiles) {
        $path = Join-Path $SpecDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $text = [System.IO.File]::ReadAllText($path)
        foreach ($m in [regex]::Matches($text, '(?i)(?<![A-Za-z0-9_./])((?:[\w.-]+/)+[\w.-]+\.(?:java|kt|kts|groovy|cs|go|py|xml|json|csv))\b')) {
            Add-FeatureSpecLocator -Set $locators -Token $m.Groups[1].Value -StopWords $stop
            Add-FeatureSpecLocator -Set $locators -Token ([System.IO.Path]::GetFileNameWithoutExtension($m.Groups[1].Value)) -StopWords $stop
        }
        foreach ($m in [regex]::Matches($text, '(?i)\b([A-Za-z_][\w.-]*\.(?:java|kt|kts|groovy|cs|go|py|xml|json|csv))\b')) {
            Add-FeatureSpecLocator -Set $locators -Token $m.Groups[1].Value -StopWords $stop
            Add-FeatureSpecLocator -Set $locators -Token ([System.IO.Path]::GetFileNameWithoutExtension($m.Groups[1].Value)) -StopWords $stop
        }
        foreach ($m in [regex]::Matches($text, '\b([A-Z][A-Za-z0-9]+)(?:#|\.)([A-Za-z_][A-Za-z0-9]*)\b')) {
            Add-FeatureSpecLocator -Set $locators -Token $m.Groups[1].Value -StopWords $stop
        }
        foreach ($m in [regex]::Matches($text, '`([^`]+)`')) {
            $inner = $m.Groups[1].Value.Trim()
            if ($inner -match '^[A-Z][A-Za-z0-9]+$') {
                Add-FeatureSpecLocator -Set $locators -Token $inner -StopWords $stop
            } elseif ($inner -match '^([A-Z][A-Za-z0-9]+)[#.]') {
                Add-FeatureSpecLocator -Set $locators -Token $Matches[1] -StopWords $stop
            }
        }
        foreach ($m in [regex]::Matches($text, '\b([A-Z][A-Za-z0-9]*(?:Helper|Manager|Service|Action|Handler|Processor|Interceptor|Filter|Controller|Dispatcher|Router|Impl|Dao|Repository|Operation|Enum|Help))\b')) {
            Add-FeatureSpecLocator -Set $locators -Token $m.Groups[1].Value -StopWords $stop
        }
        if ($name -eq "04_change_impact.json") {
            try {
                $impact = $text | ConvertFrom-Json
                foreach ($field in @('changedSymbols', 'entryPoints', 'upstreamCallers')) {
                    foreach ($item in @($impact.$field)) {
                        if ($null -eq $item) { continue }
                        $sym = [string]$item
                        if ([string]::IsNullOrWhiteSpace($sym)) { continue }
                        if ($sym -match '^([A-Z][A-Za-z0-9]+)') {
                            Add-FeatureSpecLocator -Set $locators -Token $Matches[1] -StopWords $stop
                        }
                        Add-FeatureSpecLocator -Set $locators -Token $sym -StopWords $stop
                    }
                }
            } catch {}
        }
    }
    return [string[]]@($locators)
}

function Test-RelativePathMatchesFeatureLocators {
    param(
        [string]$RelativePath,
        [string[]]$Locators
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    if ($null -eq $Locators -or @($Locators).Count -eq 0) { return $false }
    $norm = $RelativePath.Replace('\', '/').TrimStart('/')
    $fileName = [System.IO.Path]::GetFileName($norm)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($norm)
    foreach ($loc in @($Locators)) {
        if ([string]::IsNullOrWhiteSpace($loc)) { continue }
        $l = $loc.Replace('\', '/').TrimStart('/')
        if ($norm.Equals($l, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($norm.EndsWith('/' + $l, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($fileName.Equals($l, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($baseName.Equals($l, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-SpecDirHasRequirementOrDesign {
    param([string]$SpecDir)
    if ([string]::IsNullOrWhiteSpace($SpecDir)) { return $false }
    return (
        (Test-Path -LiteralPath (Join-Path $SpecDir "01_server_rules.md") -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $SpecDir "06_design_contract.md") -PathType Leaf)
    )
}

function Get-GitDiffHeaderPaths {
    param([string]$DiffLine)
    if ($DiffLine -notmatch '^diff --git\s+') { return $null }
    $rest = $DiffLine.Substring(11).Trim()
    $pA = ""
    $pB = ""
    if ($rest -match '^"a/(.+?)"\s+"b/(.+?)"$') {
        $pA = $Matches[1]
        $pB = $Matches[2]
    } elseif ($rest -match '^"(.+?)"\s+"(.+?)"$') {
        $pA = $Matches[1] -replace '^a/', ''
        $pB = $Matches[2] -replace '^b/', ''
    } elseif ($rest -match '^a/(.+?)\s+b/(.+)$') {
        $pA = $Matches[1]
        $pB = $Matches[2]
    } elseif ($rest -match '^([^\s]+)\s+([^\s]+)$') {
        $pA = $Matches[1] -replace '^a/', ''
        $pB = $Matches[2] -replace '^b/', ''
    }
    return @{
        PathA = Unquote-GitPath -Path $pA
        PathB = Unquote-GitPath -Path $pB
    }
}

function Get-AuthoritativeFeatureBaseline {
    param(
        [Alias("SpecDirectory")]
        [string]$SpecDir,
        [string]$WorkspaceRoot = $null
    )
    if ([string]::IsNullOrWhiteSpace($SpecDir)) { return $null }
    $specDirFull = [System.IO.Path]::GetFullPath($SpecDir)
    $featureName = Split-Path -Leaf $specDirFull
    
    $effectiveWs = if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot
    } else {
        Resolve-AiSopWorkspaceRoot -StartPath $specDirFull
    }
    if ([string]::IsNullOrWhiteSpace($effectiveWs)) {
        $ownerMirrorPath = Join-Path $specDirFull ".workflow-owner.json"
        if (Test-Path -LiteralPath $ownerMirrorPath -PathType Leaf) {
            try {
                $ow = Get-Content -LiteralPath $ownerMirrorPath -Raw | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace($ow.workspacePath)) {
                    $effectiveWs = [string]$ow.workspacePath
                }
            } catch {
                throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse .workflow-owner.json in '$specDirFull': $($_.Exception.Message)"
            }
        }
    }

    $registryRoot = Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $effectiveWs
    $ownerRegPath = Join-Path $registryRoot ($featureName.ToLowerInvariant() + ".json")
    $defaultRegRoot = Get-AiSopWorkflowOwnerRegistryRoot
    $defaultOwnerRegPath = Join-Path $defaultRegRoot ($featureName.ToLowerInvariant() + ".json")
    
    $foundRegPath = if (Test-Path -LiteralPath $ownerRegPath -PathType Leaf) {
        $ownerRegPath
    } elseif (Test-Path -LiteralPath $defaultOwnerRegPath -PathType Leaf) {
        $defaultOwnerRegPath
    } else {
        $null
    }

    # 1. Authority 1: Transaction Registry (Single authoritative truth)
    if ($null -ne $foundRegPath) {
        $owReg = $null
        try {
            $regRaw = [System.IO.File]::ReadAllText($foundRegPath)
            $owReg = $regRaw | ConvertFrom-Json
        } catch {
            throw "BASELINE_REGISTRY_CORRUPTED: Transaction registry record at '$foundRegPath' is corrupted: $($_.Exception.Message)"
        }
        if ($null -eq $owReg -or [string]::IsNullOrWhiteSpace($owReg.baseline)) {
            throw "BASELINE_REGISTRY_CORRUPTED: Transaction registry record at '$foundRegPath' lacks a valid baseline."
        }
        $regBaseline = [string]$owReg.baseline
        if (-not [string]::IsNullOrWhiteSpace($effectiveWs)) {
            Assert-VcsCommitExists -WorkspaceRoot $effectiveWs -Baseline $regBaseline
        }
        
        # Check mirror in spec dir: if present, mirror MUST match registry!
        $ownerMirrorPath = Join-Path $specDirFull ".workflow-owner.json"
        if (Test-Path -LiteralPath $ownerMirrorPath -PathType Leaf) {
            try {
                $owMirror = Get-Content -LiteralPath $ownerMirrorPath -Raw | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace($owMirror.baseline) -and 
                    $owMirror.baseline.ToLowerInvariant() -ne $regBaseline.ToLowerInvariant()) {
                    throw "BASELINE_MUTATION_DETECTED: .workflow-owner.json baseline '$($owMirror.baseline)' does not match transaction registry baseline '$regBaseline'. Scope tampering detected."
                }
            } catch {
                if ($_.Exception.Message -match "BASELINE_MUTATION_DETECTED") { throw }
                throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse .workflow-owner.json in '$specDirFull': $($_.Exception.Message)"
            }
        }

        # Check feature-state.json and 00_workflow_state.json
        $featStatePath = Join-Path $specDirFull "feature-state.json"
        $wfStatePath = Join-Path $specDirFull "00_workflow_state.json"
        if (Test-Path -LiteralPath $featStatePath -PathType Leaf) {
            try {
                $fs = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace($fs.baseline) -and 
                    $fs.baseline.ToLowerInvariant() -ne $regBaseline.ToLowerInvariant()) {
                    throw "BASELINE_MUTATION_DETECTED: feature-state.json baseline '$($fs.baseline)' does not match transaction registry baseline '$regBaseline'."
                }
            } catch {
                if ($_.Exception.Message -match "BASELINE_MUTATION_DETECTED") { throw }
                throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse feature-state.json in '$specDirFull': $($_.Exception.Message)"
            }
        }
        if (Test-Path -LiteralPath $wfStatePath -PathType Leaf) {
            try {
                $wf = Get-Content -LiteralPath $wfStatePath -Raw | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace($wf.baseline) -and 
                    $wf.baseline.ToLowerInvariant() -ne $regBaseline.ToLowerInvariant()) {
                    throw "BASELINE_MUTATION_DETECTED: 00_workflow_state.json baseline '$($wf.baseline)' does not match transaction registry baseline '$regBaseline'."
                }
            } catch {
                if ($_.Exception.Message -match "BASELINE_MUTATION_DETECTED") { throw }
                throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse 00_workflow_state.json in '$specDirFull': $($_.Exception.Message)"
            }
        }

        return $regBaseline
    }

    # 2. Authority 2: If no registry record exists
    # Check if spec state files exist (in-progress feature)
    $hasExistingState = (Test-Path -LiteralPath (Join-Path $specDirFull ".workflow-owner.json")) -or
                         (Test-Path -LiteralPath (Join-Path $specDirFull "feature-state.json")) -or
                         (Test-Path -LiteralPath (Join-Path $specDirFull "00_workflow_state.json")) -or
                         (Test-Path -LiteralPath (Join-Path $specDirFull "04_change_impact.json")) -or
                         (Test-Path -LiteralPath (Join-Path $specDirFull "05_test_plan.md"))

    $mirrorBaseline = $null
    $ownerMirrorPath = Join-Path $specDirFull ".workflow-owner.json"
    if (Test-Path -LiteralPath $ownerMirrorPath -PathType Leaf) {
        try {
            $ow = Get-Content -LiteralPath $ownerMirrorPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($ow.baseline)) { $mirrorBaseline = [string]$ow.baseline }
        } catch {
            throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse .workflow-owner.json in '$specDirFull': $($_.Exception.Message)"
        }
    }

    $featStatePath = Join-Path $specDirFull "feature-state.json"
    $wfStatePath = Join-Path $specDirFull "00_workflow_state.json"
    $impactPath = Join-Path $specDirFull "04_change_impact.json"
    $fsBaseline = $null
    $wfBaseline = $null
    $impactBaseline = $null
    if (Test-Path -LiteralPath $featStatePath -PathType Leaf) {
        try {
            $fs = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($fs.baseline)) { $fsBaseline = [string]$fs.baseline }
        } catch {
            throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse feature-state.json in '$specDirFull': $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $wfStatePath -PathType Leaf) {
        try {
            $wf = Get-Content -LiteralPath $wfStatePath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($wf.baseline)) { $wfBaseline = [string]$wf.baseline }
        } catch {
            throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse 00_workflow_state.json in '$specDirFull': $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $impactPath -PathType Leaf) {
        try {
            $imp = Get-Content -LiteralPath $impactPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($imp.baseline)) { $impactBaseline = [string]$imp.baseline }
        } catch {
            throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse 04_change_impact.json in '$specDirFull': $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($fsBaseline) -and -not [string]::IsNullOrWhiteSpace($wfBaseline)) {
        if ($fsBaseline.ToLowerInvariant() -ne $wfBaseline.ToLowerInvariant()) {
            throw "BASELINE_MUTATION_DETECTED: feature-state.json baseline '$fsBaseline' does not match 00_workflow_state.json baseline '$wfBaseline'."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($mirrorBaseline)) {
        if (-not [string]::IsNullOrWhiteSpace($fsBaseline) -and $fsBaseline.ToLowerInvariant() -ne $mirrorBaseline.ToLowerInvariant()) {
            throw "BASELINE_MUTATION_DETECTED: feature-state.json baseline '$fsBaseline' does not match .workflow-owner.json baseline '$mirrorBaseline'."
        }
        if (-not [string]::IsNullOrWhiteSpace($wfBaseline) -and $wfBaseline.ToLowerInvariant() -ne $mirrorBaseline.ToLowerInvariant()) {
            throw "BASELINE_MUTATION_DETECTED: 00_workflow_state.json baseline '$wfBaseline' does not match .workflow-owner.json baseline '$mirrorBaseline'."
        }
    }

    $resolvedStateBaseline = if (-not [string]::IsNullOrWhiteSpace($mirrorBaseline)) {
        $mirrorBaseline
    } elseif (-not [string]::IsNullOrWhiteSpace($fsBaseline)) {
        $fsBaseline
    } elseif (-not [string]::IsNullOrWhiteSpace($wfBaseline)) {
        $wfBaseline
    } elseif (-not [string]::IsNullOrWhiteSpace($impactBaseline)) {
        $impactBaseline
    } else {
        $null
    }

    if ($hasExistingState) {
        if ([string]::IsNullOrWhiteSpace($resolvedStateBaseline)) {
            if (-not [string]::IsNullOrWhiteSpace($effectiveWs) -and (Test-SvnWorkingCopyUsable -WorkspaceRoot $effectiveWs)) {
                $detectedFromSvn = Get-VcsBaselineRevision -StartPath $effectiveWs
                if (-not [string]::IsNullOrWhiteSpace($detectedFromSvn)) {
                    return $detectedFromSvn
                }
            }
            throw "BASELINE_MISSING: Existing feature state in '$specDirFull' lacks an authoritative baseline. Cannot evaluate risk against arbitrary commit."
        }
        if (-not [string]::IsNullOrWhiteSpace($effectiveWs)) {
            Assert-VcsCommitExists -WorkspaceRoot $effectiveWs -Baseline $resolvedStateBaseline
        }
        return $resolvedStateBaseline
    }

    # 3. Fallback to VCS detection ONLY if starting brand new feature from scratch
    $startPath = if (-not [string]::IsNullOrWhiteSpace($effectiveWs)) { $effectiveWs } else { $specDirFull }
    $detected = Get-VcsBaselineRevision -StartPath $startPath
    if (-not [string]::IsNullOrWhiteSpace($detected)) {
        return $detected
    }
    return "0"
}

function Assert-FeatureBaselineIntegrity {
    param(
        [string]$SpecDir,
        [string]$ProposedBaseline = $null,
        [string]$WorkspaceRoot = $null
    )
    if ([string]::IsNullOrWhiteSpace($SpecDir)) { return }
    $authoritative = Get-AuthoritativeFeatureBaseline -SpecDir $SpecDir -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($authoritative)) {
        throw "BASELINE_MISSING: Spec directory '$SpecDir' lacks an authoritative baseline."
    }
    
    if (-not [string]::IsNullOrWhiteSpace($ProposedBaseline)) {
        if ($ProposedBaseline.ToLowerInvariant() -ne $authoritative.ToLowerInvariant()) {
            throw "BASELINE_MUTATION_DETECTED: Specified baseline '$ProposedBaseline' does not match authoritative Claim baseline '$authoritative'. Narrowing review scope by altering baseline is prohibited."
        }
    }
    
    $fsPath = Join-Path $SpecDir "feature-state.json"
    if (Test-Path -LiteralPath $fsPath -PathType Leaf) {
        try {
            $fs = Get-Content -LiteralPath $fsPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($fs.baseline) -and $fs.baseline.ToLowerInvariant() -ne $authoritative.ToLowerInvariant()) {
                throw "BASELINE_MUTATION_DETECTED: feature-state.json baseline '$($fs.baseline)' does not match authoritative Claim baseline '$authoritative'."
            }
        } catch {
            if ($_.Exception.Message -match "BASELINE_MUTATION_DETECTED") { throw }
            throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse feature-state.json in '$SpecDir': $($_.Exception.Message)"
        }
    }
    
    $wfPath = Join-Path $SpecDir "00_workflow_state.json"
    if (Test-Path -LiteralPath $wfPath -PathType Leaf) {
        try {
            $wf = Get-Content -LiteralPath $wfPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($wf.baseline) -and $wf.baseline.ToLowerInvariant() -ne $authoritative.ToLowerInvariant()) {
                throw "BASELINE_MUTATION_DETECTED: 00_workflow_state.json baseline '$($wf.baseline)' does not match authoritative Claim baseline '$authoritative'."
            }
        } catch {
            if ($_.Exception.Message -match "BASELINE_MUTATION_DETECTED") { throw }
            throw "BASELINE_REGISTRY_CORRUPTED: Failed to parse 00_workflow_state.json in '$SpecDir': $($_.Exception.Message)"
        }
    }

    $owPath = Join-Path $SpecDir ".workflow-owner.json"
    if (Test-Path -LiteralPath $owPath -PathType Leaf) {
        try {
            $ow = Get-Content -LiteralPath $owPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($ow.baseline) -and $ow.baseline.ToLowerInvariant() -ne $authoritative.ToLowerInvariant()) {
                throw "BASELINE_MUTATION_DETECTED: .workflow-owner.json baseline '$($ow.baseline)' does not match authoritative Claim baseline '$authoritative'."
            }
        } catch {
            if ($_.Exception.Message -match "BASELINE_MUTATION_DETECTED") { throw }
        }
    }
}

function Get-ChangeSetDigest {
    param(
        [string]$WorkspaceRoot,
        [string]$Baseline = $null,
        [string[]]$ChangedSymbols = $null
    )
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot)) {
        throw "WORKSPACE_UNRESOLVED: WorkspaceRoot '$WorkspaceRoot' does not exist or is invalid."
    }
    $hasGit = Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git")
    $hasSvn = Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".svn")
    
    $combined = [System.Collections.Generic.List[string]]::new()
    
    # 1. Git diff + status
    if ($hasGit) {
        $gitTarget = $null
        $skipOverlayGitRange = $false
        if (Test-IsGitCommitBaseline -Baseline $Baseline) {
            if (Test-GitCommitExists -WorkspaceRoot $WorkspaceRoot -Baseline $Baseline) {
                $gitTarget = $Baseline
            } elseif (Test-CanFailSoftStaleOverlayGitBaseline -WorkspaceRoot $WorkspaceRoot) {
                # Stale overlay git SHA: production changeset is the SVN working copy.
                $skipOverlayGitRange = $true
            } else {
                throw "Baseline commit '$Baseline' does not exist in git workspace: $WorkspaceRoot"
            }
        } else {
            $mb = (& git -C $WorkspaceRoot merge-base HEAD origin/main 2>&1 | Out-String).Trim()
            $gitTarget = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($mb)) { $mb } else { "HEAD~1" }
        }

        if (-not $skipOverlayGitRange -and -not [string]::IsNullOrWhiteSpace($gitTarget)) {
        $gitDiff = & git -C $WorkspaceRoot -c core.quotepath=false diff $gitTarget -- . 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git diff failed against target '$gitTarget' in workspace: $WorkspaceRoot"
        }
        if ($null -ne $gitDiff) {
            $filteredGitLines = [System.Collections.Generic.List[string]]::new()
            $skipBlock = $false
            foreach ($dLine in ($gitDiff | Out-String -Stream)) {
                if ($dLine -match '^diff --git\s+') {
                    $skipBlock = $false
                    $paths = Get-GitDiffHeaderPaths -DiffLine $dLine
                    if ($null -ne $paths) {
                        $pA = $paths.PathA
                        $pB = $paths.PathB
                        if (-not [string]::IsNullOrWhiteSpace($pA) -or -not [string]::IsNullOrWhiteSpace($pB)) {
                            $skipBlock = (Test-IsAiSopInternalSpecMetadata -RelativePath $pA) -or (Test-IsAiSopInternalSpecMetadata -RelativePath $pB)
                        }
                    }
                }
                if (-not $skipBlock) {
                    $filteredGitLines.Add($dLine)
                }
            }
            $diffStr = ($filteredGitLines -join "`n").Trim()
            if (-not [string]::IsNullOrWhiteSpace($diffStr)) { $combined.Add("GIT_DIFF:`n$diffStr") }
        }

        $gitStat = & git -C $WorkspaceRoot -c core.quotepath=false status --porcelain -uall 2>&1
        if ($null -ne $gitStat) {
            foreach ($line in ($gitStat | Out-String -Stream)) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                if ($trimmed -match '^\?\?\s+(.*)$') {
                    $untrackedRel = Unquote-GitPath -Path $Matches[1].Trim()
                    if (Test-IsAiSopInternalSpecMetadata -RelativePath $untrackedRel) { continue }
                    $fullPath = Join-Path $WorkspaceRoot $untrackedRel
                    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                        $fHash = Get-FileRawSha256 -Path $fullPath
                        $combined.Add("GIT_UNTRACKED:$($untrackedRel):$($fHash)")
                    } else {
                        $combined.Add("GIT_UNTRACKED:$($untrackedRel)")
                    }
                } else {
                    $pStatus = ($trimmed -split '\s+', 2)[-1].Trim()
                    if (-not (Test-IsAiSopInternalSpecMetadata -RelativePath $pStatus)) {
                        $combined.Add("GIT_STATUS:$($trimmed)")
                    }
                }
            }
        }
        }
    }
    
    # 2. SVN diff + status
    if ($hasSvn) {
        $svnRev = if (-not [string]::IsNullOrWhiteSpace($Baseline) -and ($Baseline -replace '^(?:rev|r)', '') -match '^\d+$') {
            $Baseline -replace '^(?:rev|r)', ''
        } else {
            $infoRev = (& svn info --non-interactive --show-item revision $WorkspaceRoot 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $infoRev -match '^\d+$') { $infoRev } else {
                throw "SVN_INFO_FAILED: svn info failed in workspace '$WorkspaceRoot'. Output: $infoRev"
            }
        }

        $diffArgs = if (-not [string]::IsNullOrWhiteSpace($svnRev)) { @("-r", $svnRev) } else { @() }
        $svnDiff = & svn diff --non-interactive @diffArgs $WorkspaceRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "svn diff failed against revision '$Baseline' in workspace: $WorkspaceRoot"
        }
        $svnStat = & svn status --non-interactive --ignore-externals $WorkspaceRoot 2>&1
        if ($null -ne $svnDiff) {
            $filteredSvnDiff = Filter-SvnDiffBlocks -DiffText ($svnDiff | Out-String)
            if (-not [string]::IsNullOrWhiteSpace($filteredSvnDiff)) { $combined.Add("SVN_DIFF:`n$filteredSvnDiff") }
        }
        if ($null -ne $svnStat) {
            foreach ($line in ($svnStat | Out-String -Stream)) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                if ($trimmed -match '^\?\s+(.*)$') {
                    $untrackedPath = $Matches[1].Trim()
                    $rel = if ([System.IO.Path]::IsPathRooted($untrackedPath)) {
                        $untrackedPath.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace("\", "/")
                    } else {
                        $untrackedPath.Replace("\", "/")
                    }
                    if (Test-IsAiSopInternalSpecMetadata -RelativePath $rel) { continue }
                    $fullPath = if ([System.IO.Path]::IsPathRooted($untrackedPath)) { $untrackedPath } else { Join-Path $WorkspaceRoot $untrackedPath }
                    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                        $fHash = Get-FileRawSha256 -Path $fullPath
                        $combined.Add("SVN_UNTRACKED:$($rel):$($fHash)")
                    } else {
                        $combined.Add("SVN_UNTRACKED:$($rel)")
                    }
                } else {
                    $combined.Add("SVN_STATUS:$($trimmed)")
                }
            }
        }
    }
    
    # 3. Non-VCS workspace fallback
    if (-not $hasGit -and -not $hasSvn) {
        $srcFiles = Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { 
                $rel = $_.FullName.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace("\", "/")
                $_.FullName -notmatch '[\\/](\.ai-workspace|\.git|\.svn|build|target|node_modules|\.gradle)[\\/]' -and
                -not (Test-IsAiSopInternalSpecMetadata -RelativePath $rel)
            } | Sort-Object { $_.FullName }
        foreach ($f in $srcFiles) {
            $rel = $f.FullName.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace("\", "/")
            $h = Get-FileRawSha256 -Path $f.FullName
            $combined.Add("FILE:$($rel):$($h)")
        }
    }
    
    if ($combined.Count -eq 0) {
        $cleanTarget = if ($hasGit) { $Baseline } elseif ($hasSvn) { $Baseline } else { $WorkspaceRoot }
        $combined.Add("CLEAN_TREE_BASELINE:$($cleanTarget)")
    }
    $script:LastDigestCombined = ($combined -join " | ")
    return (Get-StringSha256 -Text ($combined -join "`n"))
}

function Validate-ChangeImpactState {
    param(
        [string]$ImpactPath
    )
    if (-not (Test-Path -LiteralPath $ImpactPath -PathType Leaf)) {
        throw "Change impact file does not exist: $ImpactPath"
    }
    $impactSchema = Join-Path $SchemaRoot "change-impact.schema.json"
    $impact = Read-JsonObject -FilePath $ImpactPath -SchemaPath $impactSchema
    
    if ([string]::IsNullOrWhiteSpace($impact.baseline) -or 
        $impact.baseline -match '^(?:HEAD|WORKING|master|main|origin/.*|trunk|branches/.*)$' -or
        $impact.baseline -notmatch '^(?:[0-9a-fA-F]{7,64}|(?:rev|r)?[0-9]+)$') {
        throw "Invalid baseline '$($impact.baseline)' in 04_change_impact.json: baseline must be a fixed immutable commit SHA (7-64 hex) or numeric SVN revision, not a floating branch/ref"
    }

    $specDir = Split-Path -Parent $ImpactPath
    Assert-FeatureBaselineIntegrity -SpecDir $specDir -ProposedBaseline $impact.baseline

    $wsRoot = Resolve-AiSopWorkspaceRoot -StartPath $specDir
    if ([string]::IsNullOrWhiteSpace($wsRoot)) {
        throw "WORKSPACE_UNRESOLVED: unable to resolve workspace root (.ai-workspace, .git, or .svn) for 04_change_impact.json at '$ImpactPath'."
    }
    $currentDigest = Get-ChangeSetDigest -WorkspaceRoot $wsRoot -Baseline $impact.baseline -ChangedSymbols $impact.changedSymbols
    if ([string]::IsNullOrWhiteSpace($currentDigest) -or $impact.changeSetDigest.ToLowerInvariant() -ne $currentDigest.ToLowerInvariant()) {
        throw "Change impact analysis is stale: recorded changeSetDigest does not match actual workspace diff against baseline '$($impact.baseline)'. Re-run Behavior Impact Analysis."
    }

    Assert-ExtensionImpactCompleteness -Impact $impact -WorkspaceRoot $wsRoot -Baseline $impact.baseline -SpecDir $specDir
    return $impact
}

function Get-RequiredLifecycleFacetIds {
    return @(
        "INIT",
        "QUERY",
        "VALIDATE",
        "MUTATE",
        "PERSIST",
        "RESET",
        "SERIALIZE",
        "COMPENSATE"
    )
}

function Test-IsTypeExtensionRisk {
    param($TriggersHit)
    $extensionTriggers = @("TYPE_EXTENSION", "PUBLIC_ROUTING")
    foreach ($t in @($TriggersHit)) {
        if ($extensionTriggers -contains [string]$t) { return $true }
    }
    return $false
}

function Test-IsFailClosedRisk {
    param($TriggersHit)
    $opaque = @("WORKSPACE_UNRESOLVED", "VCS_ERROR", "VCS_UNAVAILABLE", "HYBRID_PRODUCTION_VCS_UNSCANNED", "FEATURE_SCOPE_UNRESOLVED")
    foreach ($t in @($TriggersHit)) {
        if ($opaque -contains [string]$t) { return $true }
    }
    return $false
}

function Test-ChangeImpactRequired {
    param($TriggersHit)
    if (Test-IsTypeExtensionRisk -TriggersHit $TriggersHit) { return $true }
    return (Test-IsFailClosedRisk -TriggersHit $TriggersHit)
}

function Get-JsonObjectArray {
    # ConvertFrom-Json yields $null for a missing property. @($null).Count is 1 in
    # PowerShell, which would treat an omitted array as non-empty. Normalize to a
    # real object array (empty if absent).
    param($Value)
    if ($null -eq $Value) { return [object[]]@() }
    if ($Value -is [string]) { return @($Value) }
    if ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) {
        return @($Value | Where-Object { $null -ne $_ })
    }
    return @($Value)
}

function Get-JsonStringArray {
    param($Value)
    $items = @(Get-JsonObjectArray -Value $Value)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $result.Add($text.Trim())
        }
    }
    return [string[]]@($result)
}

function Test-JsonFlagTrue {
    param($Value)
    if ($Value -is [bool]) { return [bool]$Value }
    if ($null -eq $Value) { return $false }
    $text = [string]$Value
    return $text -eq "True" -or $text -eq "true"
}

function Test-IsWeakEvidence {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $t = $Text.Trim()
    if ($t.Length -lt 24) { return $true }
    if ($t -match '(?is)^(n/?a|n\.a\.|na|none|no|not applicable|不适用|不涉及|无|skip|no impact|不影响|not needed|none needed|main path covers|already covered|no change)[\s.]*$') {
        return $true
    }
    if ($t -match '(?i)^legacy dispatcher still covers\b') { return $true }
    return $false
}

function Test-EvidenceHasLocator {
    param(
        [string]$Text,
        [string[]]$TypeKeys
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '[A-Za-z_][\w./]*#[A-Za-z_][\w]*') { return $true }
    if ($Text -match '(?i)[\w./\\-]+\.(?:java|kt|kts|groovy|cs|go|py|xml|json)\b') { return $true }
    foreach ($k in @($TypeKeys)) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if ([regex]::IsMatch($Text, ('\b' + [regex]::Escape($k) + '\b'))) { return $true }
    }
    return $false
}

function Get-WorkspaceChangedRelativePaths {
    param(
        [string]$WorkspaceRoot,
        [string]$Baseline,
        [string]$SpecDir = $null
    )
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot)) {
        return [string[]]@()
    }
    $hasGit = Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git")
    $hasSvn = Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".svn")
    if ($hasGit) {
        $skipGitNameScan = $false
        $diffTarget = $null
        if (Test-IsGitCommitBaseline -Baseline $Baseline) {
            if (Test-GitCommitExists -WorkspaceRoot $WorkspaceRoot -Baseline $Baseline) {
                $diffTarget = $Baseline
            } elseif (Test-CanFailSoftStaleOverlayGitBaseline -WorkspaceRoot $WorkspaceRoot) {
                $skipGitNameScan = $true
            } else {
                $diffTarget = $Baseline
            }
        } else {
            $diffTarget = "HEAD"
        }
        if (-not $skipGitNameScan -and -not [string]::IsNullOrWhiteSpace($diffTarget)) {
        foreach ($cmd in @(
            @("diff", "--name-only", $diffTarget, "--", "."),
            @("diff", "--cached", "--name-only", $diffTarget, "--", "."),
            @("ls-files", "--others", "--exclude-standard")
        )) {
            $lines = & git -C $WorkspaceRoot -c core.quotepath=false @cmd 2>&1
            if ($LASTEXITCODE -ne 0) { continue }
            foreach ($line in @($lines | Out-String -Stream)) {
                $rel = Unquote-GitPath -Path ([string]$line).Trim()
                if ([string]::IsNullOrWhiteSpace($rel)) { continue }
                if (Test-IsAiSopInternalSpecMetadata -RelativePath $rel) { continue }
                [void]$paths.Add($rel.Replace('\', '/'))
            }
        }
        }
    }
    if ($hasSvn) {
        $svnRev = if (-not [string]::IsNullOrWhiteSpace($Baseline) -and ($Baseline -replace '^(?:rev|r)', '') -match '^\d+$') {
            $Baseline -replace '^(?:rev|r)', ''
        } else {
            $null
        }
        $sumArgs = @("diff", "--summarize", "--non-interactive")
        if (-not [string]::IsNullOrWhiteSpace($svnRev)) { $sumArgs += @("-r", $svnRev) }
        $sumArgs += $WorkspaceRoot
        $sumLines = & svn @sumArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in @($sumLines | Out-String -Stream)) {
                if ($line -match '^\s*[A-Z]\s+(.*)$') {
                    $full = $Matches[1].Trim()
                    $rel = $full
                    if ($full.StartsWith($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $rel = $full.Substring($WorkspaceRoot.Length).TrimStart([char[]]@('\', '/'))
                    }
                    if (-not [string]::IsNullOrWhiteSpace($rel) -and -not (Test-IsAiSopInternalSpecMetadata -RelativePath $rel)) {
                        [void]$paths.Add($rel.Replace('\', '/'))
                    }
                }
            }
        }
        $statLines = & svn status --non-interactive --ignore-externals $WorkspaceRoot 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in @($statLines | Out-String -Stream)) {
                if ($line -match '^\s*[?ACMR]\s+(.*)$') {
                    $full = $Matches[1].Trim()
                    $rel = $full
                    if ($full.StartsWith($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $rel = $full.Substring($WorkspaceRoot.Length).TrimStart([char[]]@('\', '/'))
                    }
                    if (-not [string]::IsNullOrWhiteSpace($rel) -and -not (Test-IsAiSopInternalSpecMetadata -RelativePath $rel)) {
                        [void]$paths.Add($rel.Replace('\', '/'))
                    }
                }
            }
        }
    }
    $all = [string[]]@($paths)
    if ([string]::IsNullOrWhiteSpace($SpecDir)) { return $all }
    $locators = @(Get-FeatureSpecLocators -SpecDir $SpecDir)
    if ($locators.Count -eq 0) { return $all }
    $scoped = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $all) {
        if (Test-RelativePathMatchesFeatureLocators -RelativePath $rel -Locators $locators) {
            $scoped.Add($rel)
        }
    }
    return [string[]]@($scoped)
}

function Get-JavaTypeKeyCandidates {
    param([string]$Source)
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ([string]::IsNullOrWhiteSpace($Source)) { return [string[]]@() }
    foreach ($em in [regex]::Matches($Source, '(?s)\benum\s+\w+[^{]*\{(?<body>.*?)\}')) {
        $body = $em.Groups['body'].Value
        $semi = $body.IndexOf(';')
        $constRegion = if ($semi -ge 0) { $body.Substring(0, $semi) } else { $body }
        foreach ($m in [regex]::Matches($constRegion, '\b([A-Z][A-Z0-9_]{2,})\b')) {
            [void]$names.Add($m.Groups[1].Value)
        }
    }
    foreach ($m in [regex]::Matches($Source, '\bstatic\s+final\s+int\s+(TYPE_[A-Z0-9_]{2,})\b')) {
        [void]$names.Add($m.Groups[1].Value)
    }
    return [string[]]@($names)
}

function Resolve-CoverageCarrier {
    param(
        [string]$CoveragePath,
        [string]$Carrier,
        [string]$WorkspaceRoot
    )
    $carrierTrim = ([string]$Carrier).Trim()
    $filePathPart = $carrierTrim
    $methodName = $null
    if ($filePathPart -match '^([^#]+)#(.*)$') {
        $filePathPart = $Matches[1].Trim()
        $methodName = $Matches[2].Trim()
    }
    $resolved = $filePathPart
    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        $candidateWs = if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path $WorkspaceRoot $filePathPart } else { $null }
        $candidateSpec = if (-not [string]::IsNullOrWhiteSpace($CoveragePath)) {
            Join-Path (Split-Path -Parent $CoveragePath) $filePathPart
        } else {
            $null
        }
        if ($candidateWs -and (Test-Path -LiteralPath $candidateWs -PathType Leaf)) {
            $resolved = $candidateWs
        } elseif ($candidateSpec -and (Test-Path -LiteralPath $candidateSpec -PathType Leaf)) {
            $resolved = $candidateSpec
        } elseif ($candidateWs) {
            $resolved = $candidateWs
        } elseif ($candidateSpec) {
            $resolved = $candidateSpec
        }
    }
    return [pscustomobject]@{
        Path = $resolved
        Method = $methodName
        Relative = $filePathPart
    }
}

function Get-SourceMethodBody {
    param(
        [string]$FilePath,
        [string]$MethodName
    )
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($MethodName)) { return $null }
    $source = [System.IO.File]::ReadAllText($FilePath)
    $sig = [regex]::Match(
        $source,
        '(?s)\b(?:void|fun|func|function|def)\s+' + [regex]::Escape($MethodName) + '\s*\([^)]*\)\s*\{'
    )
    if (-not $sig.Success) {
        $sig = [regex]::Match(
            $source,
            '(?s)\b(?:public|protected|private|static|\s)+\s+\w+\s+' + [regex]::Escape($MethodName) + '\s*\([^)]*\)\s*\{'
        )
    }
    if (-not $sig.Success) { return $null }
    $open = $sig.Index + $sig.Length - 1
    $depth = 0
    for ($i = $open; $i -lt $source.Length; $i++) {
        $ch = $source[$i]
        if ($ch -eq [char]'{') { $depth++ }
        elseif ($ch -eq [char]'}') {
            $depth--
            if ($depth -eq 0) {
                return $source.Substring($open, $i - $open + 1)
            }
        }
    }
    return $null
}

function Test-SourceHasStorageReload {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch(
        $Text,
        '(?i)\b(?:selectById|getById|findById|find_by_id|get_by_id|select_by_id|findOneById|queryById|loadById|reloadFresh\w*|reloadEntity)\s*\('
    )
}

function Get-NonNaColdReloadAssertions {
    param($Case)
    $hits = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Case -or $null -eq $Case.assertions) { return [object[]]@() }
    foreach ($entry in (Get-JsonObjectArray -Value $Case.assertions.persistenceColdReload)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.operator -ceq "N_A") { continue }
        $hits.Add($entry)
    }
    if ($hits.Count -eq 0) { return [object[]]@() }
    return $hits.ToArray()
}

function Assert-ExtensionImpactEvidence {
    param(
        $Impact,
        [string]$WorkspaceRoot,
        [string]$Baseline,
        [string]$SpecDir
    )
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return }

    $prefix = "TYPE_EXTENSION_IMPACT_INCOMPLETE"
    $variants = Get-JsonObjectArray -Value $Impact.behaviorVariants
    $typeKeys = @()
    $declaredKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $excludedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($variant in $variants) {
        if ($null -eq $variant -or [string]::IsNullOrWhiteSpace($variant.typeKey)) { continue }
        $typeKey = [string]$variant.typeKey
        $typeKeys += $typeKey
        [void]$declaredKeys.Add($typeKey)
        $relation = [string]$variant.relationToLegacy
        if ($relation -eq "N_A") {
            $reason = [string]$variant.reason
            if (Test-IsWeakEvidence -Text $reason) {
                throw "${prefix}: behaviorVariants typeKey '$typeKey' is N_A but reason is boilerplate or shorter than 24 characters. Name the grep/symbol that proves this key is out of scope."
            }
            if (-not (Test-EvidenceHasLocator -Text $reason -TypeKeys $typeKeys)) {
                throw "${prefix}: behaviorVariants typeKey '$typeKey' is N_A but reason has no locatable symbol (Class#method, file path, or typeKey)."
            }
        }
    }
    foreach ($ex in (Get-JsonObjectArray -Value $Impact.excludedWithReason)) {
        if ($null -ne $ex -and -not [string]::IsNullOrWhiteSpace($ex.symbol)) {
            [void]$excludedKeys.Add([string]$ex.symbol)
        }
    }

    $highRiskNaFacets = @("QUERY", "VALIDATE", "RESET", "COMPENSATE")
    $requiredFacetSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in (Get-RequiredLifecycleFacetIds)) { [void]$requiredFacetSet.Add($id) }
    $naRequiredCount = 0
    foreach ($facet in (Get-JsonObjectArray -Value $Impact.lifecycleFacets)) {
        if ($null -eq $facet -or [string]::IsNullOrWhiteSpace($facet.facetId)) { continue }
        $facetId = [string]$facet.facetId
        $coverageKind = [string]$facet.coverage
        $evidence = [string]$facet.evidence
        if (Test-IsWeakEvidence -Text $evidence) {
            throw "${prefix}: lifecycleFacets '$facetId' evidence is boilerplate or shorter than 24 characters. Cite Class#method, file, or typeKey — not 'n/a' / 'main path covers'."
        }
        if (-not (Test-EvidenceHasLocator -Text $evidence -TypeKeys $typeKeys)) {
            throw "${prefix}: lifecycleFacets '$facetId' evidence has no locatable symbol (Class#method, source file, or typeKey)."
        }
        if ($coverageKind -eq "N_A" -and $requiredFacetSet.Contains($facetId)) {
            $naRequiredCount++
            if ($highRiskNaFacets -contains $facetId -and $evidence.Trim().Length -lt 40) {
                throw "${prefix}: lifecycleFacets '$facetId' is N_A but QUERY/VALIDATE/RESET/COMPENSATE require >= 40 characters of locatable evidence (grep the missing entry; do not N_A a live facet)."
            }
        }
    }
    if ($naRequiredCount -gt 4) {
        throw "${prefix}: $naRequiredCount of the 8 required lifecycle facets are N_A. Type/strategy extensions may N_A at most 4; extra N_A usually hides QUERY/RESET/COMPENSATE."
    }

    $siblingKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $changedRels = Get-WorkspaceChangedRelativePaths -WorkspaceRoot $WorkspaceRoot -Baseline $Baseline -SpecDir $SpecDir
    foreach ($rel in $changedRels) {
        if ($rel -notmatch '\.(?:java|kt|kts|groovy)$') { continue }
        $full = Join-Path $WorkspaceRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $source = [System.IO.File]::ReadAllText($full)
        $candidates = Get-JavaTypeKeyCandidates -Source $source
        if ($candidates.Count -eq 0 -or $candidates.Count -gt 32) { continue }
        foreach ($c in $candidates) { [void]$siblingKeys.Add($c) }
    }
    $missingSiblings = @()
    foreach ($sibling in $siblingKeys) {
        if ($declaredKeys.Contains($sibling)) { continue }
        if ($excludedKeys.Contains($sibling)) { continue }
        $missingSiblings += $sibling
    }
    if ($missingSiblings.Count -gt 0) {
        throw "${prefix}: changed enum/TYPE_ constants are not all declared in behaviorVariants or excludedWithReason: $($missingSiblings -join ', '). Listing only the new key hides IDENTICAL_TO_LEGACY siblings."
    }
}

function Assert-ExtensionCoverageCompleteness {
    param(
        $Impact,
        $Coverage,
        [string]$WorkspaceRoot,
        [string]$Baseline,
        [string]$SpecDir
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return }

    $risk = Get-SemanticRiskAssessment -WorkspaceRoot $WorkspaceRoot -Baseline $Baseline -SpecDir $SpecDir
    if (-not (Test-IsTypeExtensionRisk -TriggersHit $risk.TriggersHit)) { return }

    $triggerList = (@($risk.TriggersHit) | Where-Object { $_ -in @("TYPE_EXTENSION", "PUBLIC_ROUTING") }) -join ", "
    $prefix = "TYPE_EXTENSION_COVERAGE_INCOMPLETE"

    $cases = Get-JsonObjectArray -Value $Coverage.cases
    if ($cases.Count -eq 0) {
        throw "${prefix}: changeset hits $triggerList but 05_test_coverage.json has no cases."
    }

    $coveredEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $coveredVariants = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $coveredFacets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $characterizationKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $hasQueryBypass = $false

    foreach ($case in $cases) {
        if ($null -eq $case) { continue }
        foreach ($entryId in (Get-JsonStringArray -Value $case.entryPointIds)) {
            [void]$coveredEntries.Add($entryId)
        }
        $testTypes = Get-JsonStringArray -Value $case.testTypes
        $isCharacterization = $false
        foreach ($testType in $testTypes) {
            if ($testType -eq "CHARACTERIZATION") { $isCharacterization = $true; break }
        }
        foreach ($variantKey in (Get-JsonStringArray -Value $case.variantKeys)) {
            [void]$coveredVariants.Add($variantKey)
            if ($isCharacterization) {
                [void]$characterizationKeys.Add($variantKey)
            }
        }
        foreach ($facetId in (Get-JsonStringArray -Value $case.facetIds)) {
            [void]$coveredFacets.Add($facetId)
        }
        if (Test-JsonFlagTrue -Value $case.bypassesPriorQuery) {
            $hasQueryBypass = $true
        }
    }

    $missingEntries = @()
    foreach ($entryId in (Get-JsonStringArray -Value $Impact.entryPoints)) {
        if (-not $coveredEntries.Contains($entryId)) { $missingEntries += $entryId }
    }
    if ($missingEntries.Count -gt 0) {
        throw "${prefix}: 04.entryPoints not covered by any case entryPointIds: $($missingEntries -join ', '). Add protocol-trace cases that invoke each public entry from its formal input, not from a helper class."
    }

    $intentionalKeys = New-Object System.Collections.Generic.List[string]
    $identicalKeys = New-Object System.Collections.Generic.List[string]
    foreach ($variant in (Get-JsonObjectArray -Value $Impact.behaviorVariants)) {
        if ($null -eq $variant -or [string]::IsNullOrWhiteSpace($variant.typeKey)) { continue }
        $relation = [string]$variant.relationToLegacy
        if ($relation -eq "N_A") { continue }
        $typeKey = [string]$variant.typeKey
        if ($relation -eq "IDENTICAL_TO_LEGACY") {
            $identicalKeys.Add($typeKey)
        }
        elseif ($relation -eq "INTENTIONAL_DIFF") {
            $intentionalKeys.Add($typeKey)
        }
    }

    $missingIntentional = @()
    foreach ($typeKey in $intentionalKeys) {
        if (-not $coveredVariants.Contains($typeKey)) { $missingIntentional += $typeKey }
    }
    if ($missingIntentional.Count -gt 0) {
        throw "${prefix}: INTENTIONAL_DIFF typeKeys not covered by any case variantKeys: $($missingIntentional -join ', '). The new type must have its own FUNCTIONAL (or CHARACTERIZATION) case; sampling applies only to IDENTICAL_TO_LEGACY siblings that share one dispatcher."
    }

    if ($identicalKeys.Count -gt 0) {
        $sampledIdentical = $false
        foreach ($typeKey in $identicalKeys) {
            if ($characterizationKeys.Contains($typeKey)) {
                $sampledIdentical = $true
                break
            }
        }
        if (-not $sampledIdentical) {
            throw ("${prefix}: none of the IDENTICAL_TO_LEGACY typeKeys ({0}) appear in any CHARACTERIZATION case variantKeys. Sample at least one representative old type that shares the dispatcher; do not require a case per sibling. Independent branches/config still need their own sample (see 04.legacyPaths)." -f ($identicalKeys -join ", "))
        }
    }

    $missingFacets = @()
    $queryFacetActive = $false
    foreach ($facet in (Get-JsonObjectArray -Value $Impact.lifecycleFacets)) {
        if ($null -eq $facet -or [string]::IsNullOrWhiteSpace($facet.facetId)) { continue }
        $coverageKind = [string]$facet.coverage
        if ($coverageKind -notin @("TOUCHED", "INHERITED")) { continue }
        $facetId = [string]$facet.facetId
        if (-not $coveredFacets.Contains($facetId)) { $missingFacets += $facetId }
        if ($facetId -eq "QUERY") { $queryFacetActive = $true }
    }
    if ($missingFacets.Count -gt 0) {
        throw "${prefix}: TOUCHED/INHERITED lifecycleFacets not covered by any case facetIds: $($missingFacets -join ', ')."
    }
    if ($queryFacetActive -and -not $hasQueryBypass) {
        throw "${prefix}: QUERY facet is TOUCHED/INHERITED but no case sets bypassesPriorQuery=true. Characterization must invoke the mutating public entry without a prior QUERY (lazy-reset / stale-state)."
    }

    $coveragePath = Join-Path $SpecDir "05_test_coverage.json"
    foreach ($case in $cases) {
        if ($null -eq $case) { continue }
        $testTypes = Get-JsonStringArray -Value $case.testTypes
        $isCharacterization = $false
        foreach ($testType in $testTypes) {
            if ($testType -eq "CHARACTERIZATION") { $isCharacterization = $true; break }
        }
        if (-not $isCharacterization) { continue }

        $carrierInfo = Resolve-CoverageCarrier -CoveragePath $coveragePath -Carrier ([string]$case.automationCarrier) -WorkspaceRoot $WorkspaceRoot
        if ([string]::IsNullOrWhiteSpace($carrierInfo.Path) -or -not (Test-Path -LiteralPath $carrierInfo.Path -PathType Leaf)) {
            throw "${prefix}: CHARACTERIZATION case '$($case.id)' automationCarrier '$($case.automationCarrier)' does not resolve to a test file. Characterization cannot be a JSON-only claim."
        }
        if ([string]::IsNullOrWhiteSpace($carrierInfo.Method)) {
            throw "${prefix}: CHARACTERIZATION case '$($case.id)' automationCarrier must include #methodName so the gate can inspect the method body."
        }
        $methodBody = Get-SourceMethodBody -FilePath $carrierInfo.Path -MethodName $carrierInfo.Method
        if ([string]::IsNullOrWhiteSpace($methodBody) -or $methodBody -match '^\{\s*\}$') {
            throw "${prefix}: CHARACTERIZATION case '$($case.id)' carrier $($carrierInfo.Relative)#$($carrierInfo.Method) has an empty method body. Bind the typeKey and public entry as literals/calls; an empty @Test does not lock legacy dispatch."
        }
        if ($methodBody -notmatch '\(') {
            throw "${prefix}: CHARACTERIZATION case '$($case.id)' carrier method body has no call. Act must invoke a formal public entry, not only mention identifiers."
        }
        foreach ($variantKey in (Get-JsonStringArray -Value $case.variantKeys)) {
            if (-not [regex]::IsMatch($methodBody, ('\b' + [regex]::Escape($variantKey) + '\b'))) {
                throw "${prefix}: CHARACTERIZATION case '$($case.id)' carrier method does not mention variantKey '$variantKey'. The test must bind that legacy/new key in the method that actually runs."
            }
        }
        foreach ($entryId in (Get-JsonStringArray -Value $case.entryPointIds)) {
            if (-not [regex]::IsMatch($methodBody, ('\b' + [regex]::Escape($entryId) + '\b'))) {
                throw "${prefix}: CHARACTERIZATION case '$($case.id)' carrier method does not mention entryPointId '$entryId'. Act must go through that public entry, not a helper class."
            }
        }

        $coldReloadAssertions = @(Get-NonNaColdReloadAssertions -Case $case)
        if ($coldReloadAssertions.Count -eq 0) {
            throw "${prefix}: CHARACTERIZATION case '$($case.id)' has no non-N_A assertions.persistenceColdReload. Protocol JSON is not enough; re-read storage after Act (selectById/getById/findById or equivalent) and assert the persisted fields."
        }
        foreach ($entry in $coldReloadAssertions) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.coldReloadEntity)) {
                throw "${prefix}: CHARACTERIZATION case '$($case.id)' persistenceColdReload assertion on '$($entry.target)' is missing coldReloadEntity. Name the storage record the test reloads."
            }
        }
        if (-not (Test-SourceHasStorageReload -Text $methodBody)) {
            throw "${prefix}: CHARACTERIZATION case '$($case.id)' carrier $($carrierInfo.Relative)#$($carrierInfo.Method) never re-reads storage (no selectById/getById/findById/reloadFresh call). In-memory protocol assertions are a false green."
        }
    }
}

function Assert-ExtensionImpactCompleteness {
    param(
        $Impact,
        [string]$WorkspaceRoot,
        [string]$Baseline,
        [string]$SpecDir
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return }

    $risk = Get-SemanticRiskAssessment -WorkspaceRoot $WorkspaceRoot -Baseline $Baseline -SpecDir $SpecDir
    if (-not (Test-IsTypeExtensionRisk -TriggersHit $risk.TriggersHit)) { return }

    $triggerList = (@($risk.TriggersHit) | Where-Object { $_ -in @("TYPE_EXTENSION", "PUBLIC_ROUTING") }) -join ", "
    $prefix = "TYPE_EXTENSION_IMPACT_INCOMPLETE"

    $variants = Get-JsonObjectArray -Value $Impact.behaviorVariants
    if ($variants.Count -eq 0) {
        throw "${prefix}: changeset hits $triggerList but 04_change_impact.json has empty behaviorVariants. Declare every new and legacy type/strategy key as IDENTICAL_TO_LEGACY, INTENTIONAL_DIFF, or N_A."
    }

    $legacyPaths = Get-JsonObjectArray -Value $Impact.legacyPaths
    if ($legacyPaths.Count -eq 0) {
        throw "${prefix}: changeset hits $triggerList but 04_change_impact.json has empty legacyPaths. List old dispatch/entry paths whose protected behavior must not regress."
    }

    $invariants = Get-JsonObjectArray -Value $Impact.invariants
    if ($invariants.Count -eq 0) {
        throw "${prefix}: changeset hits $triggerList but 04_change_impact.json has empty invariants. Add at least one INV-* that 05_test_coverage.json can cover."
    }

    $facets = Get-JsonObjectArray -Value $Impact.lifecycleFacets
    $facetIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $facets) {
        if ($null -ne $f -and -not [string]::IsNullOrWhiteSpace($f.facetId)) {
            [void]$facetIds.Add([string]$f.facetId)
        }
    }
    $missingFacets = @()
    foreach ($required in (Get-RequiredLifecycleFacetIds)) {
        if (-not $facetIds.Contains($required)) { $missingFacets += $required }
    }
    if ($missingFacets.Count -gt 0) {
        throw "${prefix}: changeset hits $triggerList but lifecycleFacets is missing required ids: $($missingFacets -join ', '). Every type/strategy extension must verdict INIT, QUERY, VALIDATE, MUTATE, PERSIST, RESET, SERIALIZE, and COMPENSATE as TOUCHED, INHERITED, or N_A."
    }

    $identicalVariants = @($variants | Where-Object { [string]$_.relationToLegacy -eq "IDENTICAL_TO_LEGACY" })
    if ($identicalVariants.Count -gt 0) {
        $regressionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($lp in $legacyPaths) {
            if ($null -ne $lp -and -not [string]::IsNullOrWhiteSpace($lp.regressionCaseId)) {
                [void]$regressionIds.Add([string]$lp.regressionCaseId)
            }
        }
        $requiredCases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($rc in @($Impact.requiredRegressionCases)) {
            if (-not [string]::IsNullOrWhiteSpace($rc)) { [void]$requiredCases.Add([string]$rc) }
        }
        if ($regressionIds.Count -eq 0) {
            throw "${prefix}: IDENTICAL_TO_LEGACY variants require at least one legacyPaths[].regressionCaseId (differential regression on old types)."
        }
        foreach ($rid in $regressionIds) {
            if (-not $requiredCases.Contains($rid)) {
                throw "${prefix}: legacyPaths regression case '$rid' is not listed in requiredRegressionCases."
            }
        }
    }

    Assert-ExtensionImpactEvidence -Impact $Impact -WorkspaceRoot $WorkspaceRoot -Baseline $Baseline -SpecDir $SpecDir
}

function Get-SemanticRiskAssessment {
    param(
        [string]$WorkspaceRoot,
        [string]$Baseline = $null,
        [string]$DeclaredTier = $null,
        [string]$SpecDir = $null
    )
    $triggersHit = [System.Collections.Generic.List[string]]::new()
    $details = [System.Collections.Generic.List[string]]::new()
    
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot)) {
        return [pscustomobject]@{
            TriggersHit = @("WORKSPACE_UNRESOLVED")
            Details = @("Workspace root is missing or unreadable; failing closed to T3")
            MinRequiredTier = "T3"
            HasHighRisk = $true
            Baseline = $Baseline
        }
    }

    $isGit = Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git")
    $isSvn = Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".svn")
    $isHybrid = $isGit -and $isSvn

    # 1. Resolve baseline from authoritative state or VCS
    $effectiveBaseline = if (-not [string]::IsNullOrWhiteSpace($Baseline)) {
        $Baseline
    } elseif (-not [string]::IsNullOrWhiteSpace($SpecDir)) {
        Get-AuthoritativeFeatureBaseline -SpecDir $SpecDir -WorkspaceRoot $WorkspaceRoot
    } else {
        Get-VcsBaselineRevision -StartPath $WorkspaceRoot
    }
    if (
        (Test-IsGitCommitBaseline -Baseline $effectiveBaseline) -and
        -not (Test-GitCommitExists -WorkspaceRoot $WorkspaceRoot -Baseline $effectiveBaseline) -and
        (Test-CanFailSoftStaleOverlayGitBaseline -WorkspaceRoot $WorkspaceRoot)
    ) {
        $details.Add("Overlay git baseline '$effectiveBaseline' is not in this repository; production risk is assessed from the SVN working copy.")
    }

    # 2. Collect full diff string against baseline.
    # Hybrid overlay git + production SVN: semantic triggers come from SVN only.
    # Overlay git (SOP files, gitignored src/) must not prove "no TYPE_EXTENSION".
    $fullDiff = ""
    $vcsFailed = $false
    if ($isGit -and -not $isHybrid) {
        $diffTarget = if (Test-IsGitCommitBaseline -Baseline $effectiveBaseline) {
            $effectiveBaseline
        } else {
            $mb = (& git -C $WorkspaceRoot merge-base HEAD origin/main 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($mb)) { $mb } else { "HEAD~1" }
        }
        
        try {
            $gitDiff = & git -C $WorkspaceRoot -c core.quotepath=false diff $diffTarget -- . 2>&1
            if ($LASTEXITCODE -ne 0) {
                $vcsFailed = $true
            } elseif ($null -ne $gitDiff) {
                $filteredGitLines = [System.Collections.Generic.List[string]]::new()
                $skipBlock = $false
                foreach ($dLine in ($gitDiff | Out-String -Stream)) {
                    if ($dLine -match '^diff --git\s+') {
                        $skipBlock = $false
                        $paths = Get-GitDiffHeaderPaths -DiffLine $dLine
                        if ($null -ne $paths) {
                            $pA = $paths.PathA
                            $pB = $paths.PathB
                            if (-not [string]::IsNullOrWhiteSpace($pA) -or -not [string]::IsNullOrWhiteSpace($pB)) {
                                $skipBlock = (Test-IsAiSopInternalSpecMetadata -RelativePath $pA) -or (Test-IsAiSopInternalSpecMetadata -RelativePath $pB)
                            }
                        }
                    }
                    if (-not $skipBlock) {
                        $filteredGitLines.Add($dLine)
                    }
                }
                $diffStr = ($filteredGitLines -join "`n").Trim()
                if (-not [string]::IsNullOrWhiteSpace($diffStr)) { $fullDiff += "`n" + $diffStr }
            }
            $gitStat = & git -C $WorkspaceRoot -c core.quotepath=false status --porcelain -uall 2>&1
            if ($null -ne $gitStat) {
                foreach ($line in ($gitStat | Out-String -Stream)) {
                    $trimmed = $line.Trim()
                    if ($trimmed -match '^\?\?\s+(.*)$') {
                        $untrackedRel = Unquote-GitPath -Path $Matches[1].Trim()
                        if (Test-IsAiSopInternalSpecMetadata -RelativePath $untrackedRel) { continue }
                        $fullPath = Join-Path $WorkspaceRoot $untrackedRel
                        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                            $lines = [System.IO.File]::ReadAllLines($fullPath)
                            $fullDiff += "`n+++ $untrackedRel`n" + (($lines | ForEach-Object { "+$_" }) -join "`n")
                        }
                    }
                }
            }
        } catch {
            $vcsFailed = $true
        }
    }
    if ($isSvn) {
        $svnRev = if (Test-IsSvnRevisionBaseline -Baseline $effectiveBaseline) {
            $effectiveBaseline -replace '^(?:rev|r)', ''
        } else {
            $infoRev = (& svn info --non-interactive --show-item revision $WorkspaceRoot 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $infoRev -match '^\d+$') { $infoRev } else {
                $vcsFailed = $true
                $null
            }
        }
        $diffArgs = if (-not [string]::IsNullOrWhiteSpace($svnRev)) { @("-r", $svnRev) } else { @() }
        try {
            $svnDiff = & svn diff --non-interactive @diffArgs $WorkspaceRoot 2>&1
            if ($LASTEXITCODE -ne 0) {
                $vcsFailed = $true
            } elseif ($null -ne $svnDiff) {
                $filteredSvnDiff = Filter-SvnDiffBlocks -DiffText ($svnDiff | Out-String)
                if (-not [string]::IsNullOrWhiteSpace($filteredSvnDiff)) { $fullDiff += "`n" + $filteredSvnDiff }
            }
            $svnStat = & svn status --non-interactive --ignore-externals $WorkspaceRoot 2>&1
            if ($null -ne $svnStat) {
                foreach ($line in ($svnStat | Out-String -Stream)) {
                    $trimmed = $line.Trim()
                    if ($trimmed -match '^\?\s+(.*)$') {
                        $untrackedRel = $Matches[1].Trim()
                        $rel = if ([System.IO.Path]::IsPathRooted($untrackedRel)) {
                            $untrackedRel.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace("\", "/")
                        } else {
                            $untrackedRel.Replace("\", "/")
                        }
                        if (Test-IsAiSopInternalSpecMetadata -RelativePath $rel) { continue }
                        $fullPath = if ([System.IO.Path]::IsPathRooted($untrackedRel)) { $untrackedRel } else { Join-Path $WorkspaceRoot $untrackedRel }
                        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                            $lines = [System.IO.File]::ReadAllLines($fullPath)
                            $fullDiff += "`n+++ $untrackedRel`n" + (($lines | ForEach-Object { "+$_" }) -join "`n")
                        }
                    }
                }
            }
        } catch {
            $vcsFailed = $true
        }
    }
    if ($isHybrid) {
        $details.Add("Hybrid overlay git + SVN: semantic triggers scanned from SVN working copy, not overlay git")
        if (-not (Test-SvnWorkingCopyUsable -WorkspaceRoot $WorkspaceRoot)) {
            $triggersHit.Add("HYBRID_PRODUCTION_VCS_UNSCANNED")
            $details.Add("Overlay git + .svn present but SVN working copy is unusable; production src may be gitignored. Failing closed.")
            $vcsFailed = $true
        }
    }
    if (-not $isGit -and -not $isSvn) {
        # Non-VCS directory: scan source files under WorkspaceRoot directly
        try {
            $srcFiles = Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { 
                    $rel = $_.FullName.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace("\", "/")
                    $_.FullName -notmatch '[\\/](\.git|\.svn|\.ai-workspace|build|target|node_modules|\.gradle)[\\/]' -and
                    -not (Test-IsAiSopInternalSpecMetadata -RelativePath $rel)
                }
            foreach ($sf in $srcFiles) {
                $lines = [System.IO.File]::ReadAllLines($sf.FullName)
                $relPath = $sf.FullName.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace("\", "/")
                $fullDiff += "`n+++ $relPath`n" + (($lines | ForEach-Object { "+$_" }) -join "`n")
            }
        } catch {}
    }

    if ($vcsFailed) {
        $triggersHit.Add("VCS_ERROR")
        $details.Add("VCS diff against baseline failed or errored; failing closed to T3")
    }

    $locators = [string[]]@()
    if (-not [string]::IsNullOrWhiteSpace($SpecDir)) {
        $locators = @(Get-FeatureSpecLocators -SpecDir $SpecDir)
    }
    $scopedDiff = $fullDiff
    if ($locators.Count -gt 0) {
        $kept = [System.Text.StringBuilder]::new()
        $prodTotal = 0
        $prodKept = 0
        $scopeBlocks = [regex]::Matches($fullDiff, '(?ms)(?:diff --git a/([^\r\n]+?)\s+b/[^\r\n]+|\+\+\+\s+(?:b/)?([^\r\n]+))(?:(?!diff --git|\+\+\+).)*')
        foreach ($fb in $scopeBlocks) {
            $rawPath = if ($fb.Groups[1].Success) { $fb.Groups[1].Value } else { $fb.Groups[2].Value }
            $blockPath = Get-NormalizedDiffBlockPath -Raw $rawPath
            if ([string]::IsNullOrWhiteSpace($blockPath)) { continue }
            if (Test-IsAiSopInternalSpecMetadata -RelativePath $blockPath) { continue }
            $prodTotal++
            if (Test-RelativePathMatchesFeatureLocators -RelativePath $blockPath -Locators $locators) {
                $prodKept++
                [void]$kept.AppendLine($fb.Value)
            }
        }
        $scopedDiff = $kept.ToString()
        $excluded = $prodTotal - $prodKept
        $sample = (@($locators | Select-Object -First 8) -join ", ")
        $details.Add("Feature-scoped semantic scan: kept $prodKept of $prodTotal production diff files matching spec locators ($sample). Excluded $excluded unrelated workspace files.")
    } elseif ((Test-SpecDirHasRequirementOrDesign -SpecDir $SpecDir) -and ($fullDiff -match '(?i)(?:diff --git |\+\+\+\s+)\S+\.(?:java|kt|kts|groovy|cs|go)\b')) {
        $triggersHit.Add("FEATURE_SCOPE_UNRESOLVED")
        $details.Add("Feature specs cite no Class/file locators while the workspace has production source diffs; failing closed rather than attributing unrelated dirt to this feature.")
        $scopedDiff = ""
    }
    
    # 3. Precision Semantic Trigger detection
    # Extract code-only diff blocks (exclude pure data files like .csv, .tsv, .json, .txt, .md)
    $fileBlocks = [regex]::Matches($scopedDiff, '(?ms)(?:diff --git a/([^\r\n]+?)\s+b/[^\r\n]+|\+\+\+\s+(?:b/)?([^\r\n]+))(?:(?!diff --git|\+\+\+).)*')
    $codeDiffBuilder = [System.Text.StringBuilder]::new()
    foreach ($fb in $fileBlocks) {
        $filePath = if ($fb.Groups[1].Success) { $fb.Groups[1].Value.Trim() } else { $fb.Groups[2].Value.Trim() }
        $filePath = Unquote-GitPath -Path $filePath
        if ($filePath -notmatch '\.(?:csv|tsv|json|txt|md|ya?ml)$') {
            [void]$codeDiffBuilder.AppendLine($fb.Value)
        }
    }
    $codeDiff = $codeDiffBuilder.ToString()

    # Trigger 1: TYPE_EXTENSION (Enums, Enum constants, Handler/Processor/Strategy subclasses)
    # ALL_CAPS token alternative must use -cmatch: PowerShell -match is case-insensitive
    # even with a case-sensitive character class, so "package test;" would look like TYPE_EXTENSION.
    if ($codeDiff -match '(?im)^\+\s*.*?\b(?:(?:public\s+|protected\s+|private\s+)?(?:final\s+|abstract\s+)?enum\s+\w+|public\s+static\s+final\s+int\s+TYPE_|\bTYPE_\w+\b)' -or
        $codeDiff -cmatch '(?m)^\+\s*.*?\b[A-Z][A-Z0-9_]{2,}\s*(?:\([^)]*\))?\s*[,;]' -or
        $codeDiff -match '(?im)^\+\s*.*?\b(?:public\s+|protected\s+|private\s+)?(?:final\s+|abstract\s+)?class\s+\w*(?:Processor|Handler|Action|Strategy|Listener|Interceptor|Filter|Controller|Dispatcher|Router)\b' -or
        $codeDiff -match '(?im)^\+\s*.*?\b(?:implements|extends)\s+\w*(?:Handler|Processor|Action|Strategy|Listener|Interceptor|Filter|Controller|Dispatcher|Router)\b') {
        $triggersHit.Add("TYPE_EXTENSION")
        $details.Add("Type/enum/strategy/handler extension detected in diff")
    }
    
    # Trigger 2: PUBLIC_ROUTING (Dispatcher / routing modifications, multi-branch insertions in entry points)
    if ($codeDiff -match '(?im)^\+\s*.*?\b(?:registerHandler|addHandler|router\.add|routes\.put|registerAction|registerProcessor)\b' -or
        $codeDiff -match '(?im)(?:diff --git a/.*?(?:Action|Servlet|Router|Dispatcher|Controller|Process|Handler|Protocol|Endpoint|Resource)|\+\+\+\s+.*?(?:Action|Servlet|Router|Dispatcher|Controller|Process|Handler|Protocol|Endpoint|Resource))[\s\S]*?(?:^\+\s*(?:switch\s*\(|case\s+[^:]+:|if\s*\(|else\s+if\s*\(|return\s+new\s+ResponseEntity|@(?:GetMapping|PostMapping|RequestMapping|PatchMapping|DeleteMapping)))') {
        $triggersHit.Add("PUBLIC_ROUTING")
        $details.Add("Public routing / dispatcher / entry point switch-case or branch modified")
    }
    
    # Trigger 3: STATE_PERSISTENCE_MUTATION (Player state, persistence, daily/cycle resets, resource grants)
    if ($codeDiff -match '(?im)^\+\s*.*?\b(?:player|user|account|hero|role|character|avatar|member)\s*\.\s*(?:get\w+\(\)\s*\.\s*)?(?:set|add|cost|reduce|consume|deduct|modify|reset|grant|pay|spend|give|clear|charge)\w*\b' -or
        $codeDiff -match '(?im)^\+\s*.*?\b\w*(?:Dao|Repository|Repo|Mapper|Service|Manager|Store|Cache|Table|Entity|Record|Helper)\s*\.\s*(?:save|saveOrUpdate|saveAll|insert|insertSelective|update|updateById|delete|deleteById|deleteAll|remove|modify|upsert|persist|merge|flush|findAndModify|findByIdAndUpdate|batchUpdate|execute|cost|add|reduce|consume|deduct|grant|reset)\w*\b' -or
        $codeDiff -match '(?im)^\+\s*.*?\b(?:mongoTemplate|redisTemplate|entityManager|session|jdbcTemplate|sqlSession)\b' -or
        $codeDiff -match '(?im)^\+\s*.*?\b(?:resetDaily|resetCycle|resetWeekly|resetMonth|addReward|costItem|consumeItem|addGold|reduceGold|addDiamond|costDiamond|addCurrency|deductCurrency|modifyCurrency|s_buyTotal|\b(?:get|set|add|cost|reduce|consume|has)(?:Gold|Diamond|Money|Currency|Recharge|Point|Score|Energy|Vip|Exp)\b)\b') {
        $triggersHit.Add("STATE_PERSISTENCE_MUTATION")
        $details.Add("State / persistence mutation or resource reset/grant detected")
    }
    
    # Trigger 4: COMPAT_CONCURRENCY (Serialization, locks, concurrency primitives)
    if ($codeDiff -match '(?im)^\+\s*.*?\b(?:implements\s+Serializable|serialVersionUID|RLock|DistributedLock|synchronized\s*\(|volatile\s+|Atomic(?:Integer|Long|Boolean|Reference))\b') {
        $triggersHit.Add("COMPAT_CONCURRENCY")
        $details.Add("Concurrency / lock / serialization logic modified")
    }
    
    # Trigger 5: STRUCTURAL_CONFIG (Configuration tables, new columns, new rows, non-numeric edits)
    $csvBlocks = [regex]::Matches($scopedDiff, '(?ms)(?:diff --git a/.*?\.csv|\+\+\+\s+.*?\.csv)(?:(?!diff --git|\+\+\+).)*')
    $hasCsvStructural = $false
    foreach ($blockMatch in $csvBlocks) {
        $block = $blockMatch.Value
        if ($block -match 'new file mode' -or $block -match 'deleted file mode') { $hasCsvStructural = $true; break }
        $lines = $block -split "\r?\n"
        $plusLines = @($lines | Where-Object { $_ -match '^\+(?!\+\+)' })
        $minusLines = @($lines | Where-Object { $_ -match '^\-(?!\-\-)' })
        if ($plusLines.Count -eq 0 -and $minusLines.Count -eq 0) { continue }
        if ($plusLines.Count -ne $minusLines.Count) { $hasCsvStructural = $true; break }
        for ($i = 0; $i -lt $plusLines.Count; $i++) {
            $p = $plusLines[$i].Substring(1)
            $m = $minusLines[$i].Substring(1)
            $pCols = $p.Split(',')
            $mCols = $m.Split(',')
            if ($pCols.Count -ne $mCols.Count) { $hasCsvStructural = $true; break }
            for ($c = 0; $c -lt $pCols.Count; $c++) {
                $pVal = $pCols[$c].Trim()
                $mVal = $mCols[$c].Trim()
                if ($pVal -ne $mVal) {
                    $pIsNum = $pVal -match '^-?\d+(?:\.\d+)?$'
                    $mIsNum = $mVal -match '^-?\d+(?:\.\d+)?$'
                    if (-not ($pIsNum -and $mIsNum)) { $hasCsvStructural = $true; break }
                }
            }
            if ($hasCsvStructural) { break }
        }
        if ($hasCsvStructural) { break }
    }
    if ($hasCsvStructural -or $scopedDiff -match '(?m)(?:diff --git a/.*?(?:config|data)/.*?\.(?:json|xml)|\+\+\+\s+.*?(?:config|data)/.*?\.(?:json|xml))') {
        $triggersHit.Add("STRUCTURAL_CONFIG")
        $details.Add("Structural table/column configuration changes detected")
    }

    $minRequiredTier = if ($triggersHit.Count -gt 0) { "T3" } else { "T2" }
    
    return [pscustomobject]@{
        TriggersHit = $triggersHit.ToArray()
        Details = $details.ToArray()
        MinRequiredTier = $minRequiredTier
        HasHighRisk = ($triggersHit.Count -gt 0)
        Baseline = $effectiveBaseline
    }
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
    Assert-FeatureBaselineIntegrity -SpecDir $coverageDirectory
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
        if ($caseStatus -in @("PLACEHOLDER", "PLANNED")) {
            if ($isPlanPhase) {
                $warnings.Add("INFO: $caseId (priority=$prio) status is $caseStatus (will be refined during implementation)")
            } else {
                $errors.Add("ERROR: $caseId (priority=$prio) status is $caseStatus — must be refined to IMPLEMENTED/VERIFIED")
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
            } else {
                $errors.Add("ERROR: $caseId (priority=$prio) assertions contain placeholder ($hitSummary) — all cases must carry real assertions before delivery")
            }
        }
        if (-not $isPlanPhase -and $null -ne $case.assertions -and -not $hasNonNaAssertion) {
            $errors.Add("ERROR: $caseId (priority=$prio) all assertions are N_A — cases must define at least one non-N_A assertion")
        }

        # Validate setup/trigger/cleanup non-emptiness in VERIFY phase
        if (-not $isPlanPhase) {
            if ($null -ne $case.setup) {
                foreach ($s in $case.setup) {
                    $sStr = [string]$s
                    if ($sStr -match '^(?:see plan|placeholder|TODO|__TODO__)$' -or [string]::IsNullOrWhiteSpace($sStr)) {
                        $errors.Add("ERROR: $caseId (priority=$prio) setup contains placeholder ('$sStr')")
                    }
                }
            }
            if ($null -ne $case.trigger) {
                foreach ($t in $case.trigger) {
                    $tStr = [string]$t
                    if ($tStr -match '^(?:see plan|placeholder|TODO|__TODO__)$' -or [string]::IsNullOrWhiteSpace($tStr)) {
                        $errors.Add("ERROR: $caseId (priority=$prio) trigger contains placeholder ('$tStr')")
                    }
                }
            }
            if ($null -ne $case.cleanup) {
                foreach ($c in $case.cleanup) {
                    $cStr = [string]$c
                    if ($cStr -match '^(?:see plan|placeholder|TODO|__TODO__)$' -or [string]::IsNullOrWhiteSpace($cStr)) {
                        $errors.Add("ERROR: $caseId (priority=$prio) cleanup contains placeholder ('$cStr')")
                    }
                }
            }
        }

        # automationCarrier validation.
        $carrier = [string]$case.automationCarrier
        $carrierTrim = $carrier.Trim()
        $isPathLike = ($carrierTrim -match '(?i)[/\\][a-zA-Z0-9_\-\.]+\.[a-zA-Z0-9]+' -or 
                       $carrierTrim -match '(?i)^[a-zA-Z0-9_\-\.]+\.[a-zA-Z0-9]+' -or 
                       $carrierTrim -match '(?i)\.[a-zA-Z0-9]+#')

        if ([string]::IsNullOrWhiteSpace($carrierTrim) -or $carrierTrim -ieq "__TODO__" -or $carrierTrim -ieq "see plan" -or $carrierTrim -ieq "TODO") {
            if ($isPlanPhase) {
                $warnings.Add("INFO: $caseId (priority=$prio) automationCarrier to be implemented ('$carrierTrim')")
            } else {
                $errors.Add("ERROR: $caseId (priority=$prio) automationCarrier is placeholder ('$carrierTrim') — must point to real test class/method or file before delivery")
            }
        } elseif ($carrierTrim -in @("JUnit", "pytest", "go test", "cargo test", "npm test")) {
            if ($isPlanPhase) {
                $warnings.Add("INFO: $caseId (priority=$prio) automationCarrier carrier type: '$carrierTrim'")
            } else {
                $errors.Add("ERROR: $caseId (priority=$prio) automationCarrier is too generic ('$carrierTrim') — specify exact test file or Class#method")
            }
        } elseif ($isPathLike) {
            # Looks like a file path (has separator + extension, or extension#method).
            $filePathPart = $carrierTrim
            $methodName = $null
            if ($filePathPart -match '^([^#]+)#(.*)$') {
                $filePathPart = $Matches[1].Trim()
                $methodName = $Matches[2].Trim()
                if ([string]::IsNullOrWhiteSpace($methodName)) {
                    if ($isPlanPhase) {
                        $warnings.Add("INFO: $caseId automationCarrier has empty method name after '#' ('$carrierTrim')")
                    } else {
                        $errors.Add("ERROR: $caseId automationCarrier has empty method name after '#' ('$carrierTrim') — must specify a valid test method name")
                    }
                }
            }
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
                if ($javaSrc -notmatch '@(?:Test|ParameterizedTest|RepeatedTest|org\.junit(?:\.jupiter\.api)?\.Test)\b') {
                    if ($isPlanPhase) {
                        $warnings.Add("INFO: $caseId automationCarrier .java has no @Test method yet: $filePathPart")
                    } else {
                        $errors.Add("ERROR: $caseId automationCarrier .java has no @Test method: $filePathPart — carrier must be a real test class")
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($methodName)) {
                    $testAnnotationPattern = '(?s)@(?:Test|ParameterizedTest|RepeatedTest|org\.junit(?:\.jupiter\.api)?\.Test)\b[^{};]*?\bvoid\s+' + [regex]::Escape($methodName) + '\s*\('
                    $anyMethodPattern = '(?s)\b(?:void|boolean|int|long|String|[A-Z]\w*)\s+' + [regex]::Escape($methodName) + '\s*\('
                    if ($javaSrc -notmatch $anyMethodPattern) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier test method '$methodName' not yet in $filePathPart")
                        } else {
                            $errors.Add("ERROR: $caseId automationCarrier test method '$methodName' does not exist in $filePathPart")
                        }
                    } elseif ($javaSrc -notmatch $testAnnotationPattern) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier test method '$methodName' not yet in $filePathPart")
                        } else {
                            $errors.Add("ERROR: $caseId automationCarrier method '$methodName' in $filePathPart is not annotated with @Test — ordinary/helper/private methods cannot serve as test carrier")
                        }
                    }
                }
            } elseif ($filePathPart -match '\.py$') {
                $pySrc = [System.IO.File]::ReadAllText($resolved)
                if (-not [string]::IsNullOrWhiteSpace($methodName)) {
                    $anyPyFunc = '(?m)^\s*(?:async\s+)?def\s+' + [regex]::Escape($methodName) + '\s*\('
                    $testPyFunc = '(?m)^\s*(?:async\s+)?def\s+test_' + [regex]::Escape($methodName) + '\s*\('
                    $isTestNamed = ($methodName -match '^test_' -and $pySrc -match $anyPyFunc)
                    if ($pySrc -notmatch $anyPyFunc -and $pySrc -notmatch $testPyFunc) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier python test function '$methodName' not yet in $filePathPart")
                        } else {
                            $errors.Add("ERROR: $caseId automationCarrier test function '$methodName' does not exist in $filePathPart")
                        }
                    } elseif (-not $isTestNamed) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier python function '$methodName' may not be a test function")
                        } else {
                            $errors.Add("ERROR: $caseId automationCarrier python function '$methodName' in $filePathPart is not a test (must start with 'test_') — helper functions or fixtures cannot serve as test carrier")
                        }
                    }
                }
            } elseif ($filePathPart -match '\.go$') {
                $goSrc = [System.IO.File]::ReadAllText($resolved)
                if (-not [string]::IsNullOrWhiteSpace($methodName)) {
                    $anyGoFunc = '(?m)^\s*func\s+' + [regex]::Escape($methodName) + '\s*\('
                    $testGoSig = if ($methodName -cmatch '^Test[A-Z0-9_]') {
                        '(?m)^\s*func\s+' + [regex]::Escape($methodName) + '\s*\(\s*\w+\s+\*testing\.T\s*\)'
                    } elseif ($methodName -cnotmatch '^Test') {
                        $testNamed = "Test" + $methodName.Substring(0, 1).ToUpperInvariant() + $methodName.Substring(1)
                        '(?m)^\s*func\s+' + [regex]::Escape($testNamed) + '\s*\(\s*\w+\s+\*testing\.T\s*\)'
                    } else {
                        $null
                    }
                    $benchGoSig = if ($methodName -cmatch '^Benchmark[A-Z0-9_]') {
                        '(?m)^\s*func\s+' + [regex]::Escape($methodName) + '\s*\(\s*\w+\s+\*testing\.B\s*\)'
                    } elseif ($methodName -cnotmatch '^Benchmark') {
                        $benchNamed = "Benchmark" + $methodName.Substring(0, 1).ToUpperInvariant() + $methodName.Substring(1)
                        '(?m)^\s*func\s+' + [regex]::Escape($benchNamed) + '\s*\(\s*\w+\s+\*testing\.B\s*\)'
                    } else {
                        $null
                    }
                    $exampleGoSig = if ($methodName -cmatch '^Example[A-Z0-9_]') {
                        '(?m)^\s*func\s+' + [regex]::Escape($methodName) + '\s*\(\s*\)'
                    } elseif ($methodName -cnotmatch '^Example') {
                        $exampleNamed = "Example" + $methodName.Substring(0, 1).ToUpperInvariant() + $methodName.Substring(1)
                        '(?m)^\s*func\s+' + [regex]::Escape($exampleNamed) + '\s*\(\s*\)'
                    } else {
                        $null
                    }
                    $isValidGoTest = (($null -ne $testGoSig -and $goSrc -match $testGoSig) -or ($null -ne $benchGoSig -and $goSrc -match $benchGoSig) -or ($null -ne $exampleGoSig -and $goSrc -match $exampleGoSig))
                    if ($goSrc -notmatch $anyGoFunc -and -not $isValidGoTest) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier Go test function '$methodName' not yet in $filePathPart")
                        } else {
                            $errors.Add("ERROR: $caseId automationCarrier test function '$methodName' does not exist in $filePathPart")
                        }
                    } elseif (-not $isValidGoTest) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier Go function '$methodName' may not have valid Test[A-Z0-9_] name or testing.T signature")
                        } else {
                            $errors.Add("ERROR: $caseId automationCarrier Go function '$methodName' in $filePathPart does not have a valid test name/signature (go test requires func Test[A-Z0-9_]...(t *testing.T)) — helper functions or lowercase Testfoo cannot serve as test carrier")
                        }
                    }
                }
            } elseif ($filePathPart -match '\.rs$') {
                $rsSrc = [System.IO.File]::ReadAllText($resolved)
                if (-not [string]::IsNullOrWhiteSpace($methodName)) {
                    $anyRsFunc = '(?s)\bfn\s+' + [regex]::Escape($methodName) + '\s*\('
                    $testRsFunc = '(?s)#\[test\][^{};]*?fn\s+' + [regex]::Escape($methodName) + '\s*\('
                    if ($rsSrc -notmatch $anyRsFunc) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier Rust fn '$methodName' not yet in $filePathPart")
                        } else {
                            $errors.Add("ERROR: $caseId automationCarrier Rust test function '$methodName' does not exist in $filePathPart")
                        }
                    } elseif ($rsSrc -notmatch $testRsFunc) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier Rust fn '$methodName' is not annotated with #[test]")
                        } else {
                            $errors.Add("ERROR: $caseId automationCarrier Rust fn '$methodName' in $filePathPart is not annotated with #[test] — helper functions cannot serve as test carrier")
                        }
                    }
                }
            } elseif ($filePathPart -match '\.(js|ts|jsx|tsx)$') {
                $jsSrc = [System.IO.File]::ReadAllText($resolved)
                if (-not [string]::IsNullOrWhiteSpace($methodName)) {
                    $jsEsc = [regex]::Escape($methodName)
                    $jsTestPattern = '(?m)(?:it|test)\s*\(\s*[''"`]' + $jsEsc + '[''"`]'
                    $jsSuitePattern = '(?m)(?:describe|suite)\s*\(\s*[''"`]' + $jsEsc + '[''"`]'
                    $anyJsPattern = '(?m)(?:function\s+' + $jsEsc + '|const\s+' + $jsEsc + '\s*=)'
                    if ($jsSrc -notmatch $jsTestPattern) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier JS/TS test '$methodName' not yet in $filePathPart")
                        } else {
                            if ($jsSrc -match $jsSuitePattern) {
                                $errors.Add("ERROR: $caseId automationCarrier JS/TS target '$methodName' in $filePathPart is a describe/suite block, not a test case — carrier must point to an it() or test() case")
                            } elseif ($jsSrc -match $anyJsPattern) {
                                $errors.Add("ERROR: $caseId automationCarrier JS/TS function '$methodName' in $filePathPart is not inside an it() or test() block — helper functions cannot serve as test carrier")
                            } else {
                                $errors.Add("ERROR: $caseId automationCarrier JS/TS test block '$methodName' does not exist in $filePathPart")
                            }
                        }
                    }
                }
            } elseif ($filePathPart -match '\.ps1$') {
                $psSrc = [System.IO.File]::ReadAllText($resolved)
                if (-not [string]::IsNullOrWhiteSpace($methodName)) {
                    $psEsc = [regex]::Escape($methodName)
                    $psTestPattern = '(?im)^\s*It\s+[''"]\s*' + $psEsc + '\s*[''"]|^\s*function\s+(?:Test|Assert)-' + $psEsc + '\b'
                    $psSuitePattern = '(?im)^\s*(?:Describe|Context)\s+[''"]\s*' + $psEsc + '\s*[''"]'
                    $anyPsFunc = '(?im)^\s*function\s+' + $psEsc + '\b'
                    if ($psSrc -notmatch $psTestPattern) {
                        if ($isPlanPhase) {
                            $warnings.Add("INFO: $caseId automationCarrier PS1 test '$methodName' not yet in $filePathPart")
                        } else {
                            if ($psSrc -match $psSuitePattern) {
                                $errors.Add("ERROR: $caseId automationCarrier PowerShell target '$methodName' in $filePathPart is a Describe/Context block, not an It test case — carrier must point to an It block or Test-/Assert- function")
                            } elseif ($psSrc -match $anyPsFunc) {
                                $errors.Add("ERROR: $caseId automationCarrier PowerShell function '$methodName' in $filePathPart is not a test/assertion function — helper functions cannot serve as test carrier")
                            } else {
                                $errors.Add("ERROR: $caseId automationCarrier PowerShell test block '$methodName' does not exist in $filePathPart")
                            }
                        }
                    }
                }
            } else {
                if (-not [string]::IsNullOrWhiteSpace($methodName)) {
                    $ext = [System.IO.Path]::GetExtension($filePathPart)
                    if ($isPlanPhase) {
                        $warnings.Add("INFO: $caseId automationCarrier has method '$methodName' on unrecognized extension '$ext'")
                    } else {
                        $errors.Add("ERROR: $caseId automationCarrier '#method' is unsupported on file extension '$ext' — carrier method validation only supports Java/Groovy/Kotlin/Python/Go/Rust/JS/TS/PS1")
                    }
                }
            }
        } else {
            if ($isPlanPhase) {
                $warnings.Add("INFO: $caseId (priority=$prio) unknown carrier format ('$carrierTrim')")
            } else {
                $errors.Add("ERROR: $caseId (priority=$prio) invalid carrier format ('$carrierTrim') — must specify test file path or Class#method")
            }
        }
    }

    if (-not $isPlanPhase) {
        $coldReloadWsRoot = Resolve-AiSopWorkspaceRoot -StartPath (Split-Path -Parent $CoveragePath)
        foreach ($case in $coverage.cases) {
            $caseId = [string]$case.id
            $coldHits = @(Get-NonNaColdReloadAssertions -Case $case)
            if ($coldHits.Count -eq 0) { continue }
            foreach ($entry in $coldHits) {
                if ([string]::IsNullOrWhiteSpace([string]$entry.coldReloadEntity)) {
                    $errors.Add("ERROR: COLD_RELOAD_INCOMPLETE: $caseId persistenceColdReload assertion on '$($entry.target)' is missing coldReloadEntity — name the storage record the test reloads")
                }
            }
            $carrierInfo = Resolve-CoverageCarrier -CoveragePath $CoveragePath -Carrier ([string]$case.automationCarrier) -WorkspaceRoot $coldReloadWsRoot
            if ([string]::IsNullOrWhiteSpace($carrierInfo.Path) -or -not (Test-Path -LiteralPath $carrierInfo.Path -PathType Leaf)) {
                $errors.Add("ERROR: COLD_RELOAD_INCOMPLETE: $caseId declares persistenceColdReload but automationCarrier '$($case.automationCarrier)' does not resolve to a test file")
                continue
            }
            if ([string]::IsNullOrWhiteSpace($carrierInfo.Method)) {
                $errors.Add("ERROR: COLD_RELOAD_INCOMPLETE: $caseId declares persistenceColdReload but automationCarrier must include #methodName so the gate can inspect the reload call")
                continue
            }
            $methodBody = Get-SourceMethodBody -FilePath $carrierInfo.Path -MethodName $carrierInfo.Method
            if (-not (Test-SourceHasStorageReload -Text $methodBody)) {
                $errors.Add("ERROR: COLD_RELOAD_INCOMPLETE: $caseId carrier $($carrierInfo.Relative)#$($carrierInfo.Method) never re-reads storage (no selectById/getById/findById/reloadFresh call). In-memory protocol assertions are a false green.")
            }
        }
    }

    # executionEvidence validation in VERIFY phase or when executionEvidence is present
    $mustCheckEvidence = (-not $isPlanPhase) -or ($null -ne $coverage.executionEvidence)
    if ($mustCheckEvidence) {
        if ($null -eq $coverage.executionEvidence) {
            $errors.Add("ERROR: executionEvidence is missing in 05_test_coverage.json — real test execution record is mandatory in VERIFY phase")
        } else {
            $ev = $coverage.executionEvidence
            if ($ev.exitCode -ne 0) {
                $errors.Add("ERROR: executionEvidence indicates failed test execution (exitCode=$($ev.exitCode))")
            }
            if ($ev.failedCount -gt 0) {
                $errors.Add("ERROR: executionEvidence indicates $($ev.failedCount) test failure(s)")
            }
            if ($ev.testCount -lt 1) {
                $errors.Add("ERROR: executionEvidence indicates zero tests were executed (testCount=$($ev.testCount))")
            }
            if ($ev.testCount -lt $coverage.cases.Count) {
                $errors.Add("ERROR: executionEvidence testCount ($($ev.testCount)) is less than covered test cases count ($($coverage.cases.Count))")
            }
            if (($ev.passedCount + $ev.failedCount) -ne $ev.testCount) {
                $errors.Add("ERROR: executionEvidence count mismatch (passedCount ($($ev.passedCount)) + failedCount ($($ev.failedCount)) != testCount ($($ev.testCount)))")
            }
            $rfc3339Regex = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$'
            $rawTimeStr = if ($ev.executedAt -is [System.DateTime]) {
                $ev.executedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            } elseif ($ev.executedAt -is [System.DateTimeOffset]) {
                $ev.executedAt.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            } else {
                [string]$ev.executedAt
            }
            if ([string]::IsNullOrWhiteSpace($rawTimeStr) -or $rawTimeStr -notmatch $rfc3339Regex) {
                $errors.Add("ERROR: executionEvidence executedAt '$rawTimeStr' is not a valid strict RFC 3339 timestamp (e.g. 2026-08-26T18:00:00Z)")
            } else {
                $parsedTime = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse($rawTimeStr, [ref]$parsedTime)) {
                    $errors.Add("ERROR: executionEvidence executedAt '$rawTimeStr' could not be parsed as a DateTimeOffset")
                } elseif ($parsedTime -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
                    $errors.Add("ERROR: executionEvidence executedAt '$rawTimeStr' is in the future")
                } elseif ($parsedTime -lt [DateTimeOffset]::UtcNow.AddDays(-30)) {
                    $errors.Add("ERROR: executionEvidence executedAt '$rawTimeStr' is stale (older than 30 days)")
                }
            }

            $evDigest = [string]$ev.workingTreeDigest
            if ([string]::IsNullOrWhiteSpace($evDigest)) {
                $errors.Add("ERROR: executionEvidence workingTreeDigest is required in 05_test_coverage.json")
            }

            if ([string]::IsNullOrWhiteSpace($ev.sourceCommitSha) -or $ev.sourceCommitSha -notmatch '^(?:[0-9a-fA-F]{7,64}|(?:rev|r)?[0-9]+)$') {
                $errors.Add("ERROR: executionEvidence sourceCommitSha '$($ev.sourceCommitSha)' must be a valid commit SHA or numeric SVN revision string")
            } else {
                $specDir = Split-Path -Parent $CoveragePath
                $carrierWsRoot = Resolve-AiSopWorkspaceRoot -StartPath $specDir
                if (-not $carrierWsRoot) {
                    $errors.Add("ERROR: executionEvidence verification failed — unable to resolve workspace root (.ai-workspace / .git / .svn) for spec directory '$specDir'")
                } else {
                    $hasGit = Test-Path -LiteralPath (Join-Path $carrierWsRoot ".git")
                    $hasSvn = Test-Path -LiteralPath (Join-Path $carrierWsRoot ".svn")
                    if ($hasSvn -and (Test-IsSvnRevisionBaseline -Baseline $ev.sourceCommitSha)) {
                    $svnNum = $ev.sourceCommitSha -replace '^(?:rev|r)', ''
                    if ($svnNum -match '^\d+$') {
                        $currentSvn = (& svn info --non-interactive --show-item revision $carrierWsRoot 2>&1 | Out-String).Trim()
                        if ($LASTEXITCODE -ne 0 -or $currentSvn -notmatch '^\d+$') {
                            $errors.Add("ERROR: svn info failed in SVN workspace '$carrierWsRoot' (exitCode=$LASTEXITCODE, output=$currentSvn). Corrupted SVN copy or unavailable VCS.")
                        } elseif ([long]$svnNum -ne [long]$currentSvn) {
                            $errors.Add("ERROR: executionEvidence sourceCommitSha '$($ev.sourceCommitSha)' does not match current SVN working revision ($currentSvn)")
                        } else {
                            $currentDigest = Get-ChangeSetDigest -WorkspaceRoot $carrierWsRoot -Baseline $currentSvn
                            if ([string]::IsNullOrWhiteSpace($evDigest)) {
                                # already added error
                            } elseif ($evDigest.ToLowerInvariant() -ne $currentDigest.ToLowerInvariant()) {
                                $errors.Add("ERROR: executionEvidence workingTreeDigest ('$evDigest') does not match current workspace changeSetDigest ('$currentDigest'). Tests must be re-run on current code state.")
                            }
                        }
                    } else {
                        $errors.Add("ERROR: executionEvidence sourceCommitSha '$($ev.sourceCommitSha)' is not a valid SVN revision in SVN workspace")
                    }
                    } elseif ($hasGit -and (Test-IsGitCommitBaseline -Baseline $ev.sourceCommitSha)) {
                        $verifyRef = & git -C $carrierWsRoot rev-parse --verify --quiet "$($ev.sourceCommitSha)^{commit}" 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            $errors.Add("ERROR: executionEvidence sourceCommitSha '$($ev.sourceCommitSha)' does not exist in git repository history")
                        } else {
                            $headSha = (& git -C $carrierWsRoot rev-parse HEAD 2>&1 | Out-String).Trim()
                            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($headSha)) {
                                $isCleanHead = $headSha.Equals($ev.sourceCommitSha, [System.StringComparison]::OrdinalIgnoreCase) -or
                                               ($headSha.StartsWith($ev.sourceCommitSha, [System.StringComparison]::OrdinalIgnoreCase) -and $ev.sourceCommitSha.Length -ge 7)
                                if (-not $isCleanHead) {
                                    $errors.Add("ERROR: executionEvidence sourceCommitSha '$($ev.sourceCommitSha)' is an older ancestor commit and does not match current repository HEAD ($headSha). Tests must be executed against current HEAD.")
                                } else {
                                    $currentDigest = Get-ChangeSetDigest -WorkspaceRoot $carrierWsRoot -Baseline $headSha
                                    if ([string]::IsNullOrWhiteSpace($evDigest)) {
                                        # already added error
                                    } elseif ($evDigest.ToLowerInvariant() -ne $currentDigest.ToLowerInvariant()) {
                                        $errors.Add("ERROR: executionEvidence workingTreeDigest ('$evDigest') does not match current workspace changeSetDigest ('$currentDigest'). Tests must be re-run on current code state.")
                                    }
                                }
                            }
                        }
                    } elseif ($hasSvn) {
                        $errors.Add("ERROR: executionEvidence sourceCommitSha '$($ev.sourceCommitSha)' is not a valid SVN revision in SVN workspace")
                    } elseif ($hasGit) {
                        $errors.Add("ERROR: executionEvidence sourceCommitSha '$($ev.sourceCommitSha)' is not a valid git commit SHA in git workspace")
                    } else {
                    $nonVcsBaseline = Get-AuthoritativeFeatureBaseline -SpecDir $specDir
                    $currentDigest = Get-ChangeSetDigest -WorkspaceRoot $carrierWsRoot -Baseline $nonVcsBaseline
                    if ([string]::IsNullOrWhiteSpace($evDigest)) {
                        # already added error
                    } elseif ($evDigest.ToLowerInvariant() -ne $currentDigest.ToLowerInvariant()) {
                        $errors.Add("ERROR: executionEvidence workingTreeDigest ('$evDigest') does not match current workspace changeSetDigest ('$currentDigest'). Tests must be re-run on current code state.")
                    }
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

if ($null -eq $script:HeldFileLocks) {
    $script:HeldFileLocks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
}

function Invoke-WithFileLock {
    param(
        [string]$StatePath,
        [scriptblock]$Action
    )

    $fullPath = [System.IO.Path]::GetFullPath($StatePath)
    $specDir = if (Test-Path -LiteralPath $fullPath -PathType Container) {
        $fullPath
    } else {
        Split-Path -Parent $fullPath
    }
    $specLockPath = Join-Path $specDir ".workflow-mutation.lock"
    $stateLockPath = $fullPath + ".lock"

    [System.IO.Directory]::CreateDirectory($specDir) | Out-Null

    $acquiredSpecLock = $false
    $specStream = $null
    if (-not $script:HeldFileLocks.Contains($specLockPath)) {
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            try {
                $specStream = [System.IO.File]::Open(
                    $specLockPath,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::None
                )
                break
            } catch [System.IO.IOException] {
                Start-Sleep -Milliseconds 100
            }
        }
        if ($null -eq $specStream) {
            throw "Timed out acquiring spec mutation lock: $specLockPath"
        }
        $script:HeldFileLocks.Add($specLockPath) | Out-Null
        $acquiredSpecLock = $true
    }

    $acquiredStateLock = $false
    $stateStream = $null
    try {
        if ($stateLockPath -ne $specLockPath -and -not $script:HeldFileLocks.Contains($stateLockPath)) {
            for ($attempt = 0; $attempt -lt 50; $attempt++) {
                try {
                    $stateStream = [System.IO.File]::Open(
                        $stateLockPath,
                        [System.IO.FileMode]::OpenOrCreate,
                        [System.IO.FileAccess]::ReadWrite,
                        [System.IO.FileShare]::None
                    )
                    break
                } catch [System.IO.IOException] {
                    Start-Sleep -Milliseconds 100
                }
            }
            if ($null -eq $stateStream) {
                throw "Timed out acquiring state file lock: $stateLockPath"
            }
            $script:HeldFileLocks.Add($stateLockPath) | Out-Null
            $acquiredStateLock = $true
        }

        # Recover any crashed transactions from prior runs
        Invoke-RecoverPendingJournal -SpecDir $specDir

        & $Action
    } finally {
        if ($acquiredStateLock) {
            $script:HeldFileLocks.Remove($stateLockPath) | Out-Null
            if ($null -ne $stateStream) {
                $stateStream.Dispose()
            }
        }
        if ($acquiredSpecLock) {
            $script:HeldFileLocks.Remove($specLockPath) | Out-Null
            if ($null -ne $specStream) {
                $specStream.Dispose()
            }
        }
    }
}

function Invoke-RecoverPendingJournal {
    param([string]$SpecDir)
    if ([string]::IsNullOrWhiteSpace($SpecDir) -or -not (Test-Path -LiteralPath $SpecDir)) { return }
    $journalPath = Join-Path $SpecDir ".commit-journal.json"
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { return }

    try {
        $raw = [System.IO.File]::ReadAllText($journalPath)
        $journal = $raw | ConvertFrom-Json
        if ($null -eq $journal -or [string]::IsNullOrWhiteSpace($journal.state)) {
            throw "CORRUPT_JOURNAL: Journal file at '$journalPath' is empty or corrupt."
        }

        if ($journal.state -eq "PREPARED") {
            # Roll-forward: move any remaining .tmp files to their target paths.
            # If a .tmp file is already missing, it was already moved before the crash (no-op).
            foreach ($item in $journal.targets) {
                if (-not [string]::IsNullOrWhiteSpace($item.tmpPath) -and (Test-Path -LiteralPath $item.tmpPath)) {
                    [System.IO.File]::Move($item.tmpPath, $item.path, $true)
                }
            }
        } elseif ($journal.state -eq "ROLLED_BACK") {
            # Roll-back: restore backups or delete newly created files
            foreach ($item in $journal.targets) {
                if ($item.existed -and -not [string]::IsNullOrWhiteSpace($item.backupPath) -and (Test-Path -LiteralPath $item.backupPath)) {
                    [System.IO.File]::Copy($item.backupPath, $item.path, $true)
                } elseif (-not $item.existed -and (Test-Path -LiteralPath $item.path)) {
                    [System.IO.File]::Delete($item.path)
                }
            }
        }

        # Cleanup backups and temp files
        foreach ($item in $journal.targets) {
            if (-not [string]::IsNullOrWhiteSpace($item.tmpPath) -and (Test-Path -LiteralPath $item.tmpPath)) {
                Remove-Item -LiteralPath $item.tmpPath -Force -ErrorAction SilentlyContinue
            }
            if (-not [string]::IsNullOrWhiteSpace($item.backupPath) -and (Test-Path -LiteralPath $item.backupPath)) {
                Remove-Item -LiteralPath $item.backupPath -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
    } catch {
        throw "JOURNAL_RECOVERY_FAILED: Failed to recover pending journal at '$journalPath': $($_.Exception.Message)"
    }
}

function Invoke-AiSopTwoFileAtomicCommit {
    param(
        [string]$PathA,
        [object]$ValueA,
        [string]$SchemaA,
        [string]$PathB,
        [object]$ValueB,
        [string]$SchemaB,
        [string]$SpecDir
    )

    if ([string]::IsNullOrWhiteSpace($SpecDir)) {
        throw "SpecDir is mandatory for Invoke-AiSopTwoFileAtomicCommit"
    }
    if ([string]::IsNullOrWhiteSpace($PathA) -or [string]::IsNullOrWhiteSpace($ValueA)) {
        throw "PathA and ValueA are mandatory for Invoke-AiSopTwoFileAtomicCommit"
    }

    Invoke-RecoverPendingJournal -SpecDir $SpecDir

    $jsonA = if ($ValueA -is [string]) { $ValueA } else { $ValueA | ConvertTo-Json -Depth 10 }
    $jsonB = if ($null -ne $PathB -and $null -ne $ValueB) {
        if ($ValueB -is [string]) { $ValueB } else { $ValueB | ConvertTo-Json -Depth 10 }
    } else { $null }

    if (-not [string]::IsNullOrWhiteSpace($SchemaA) -and (Test-Path -LiteralPath $SchemaA)) {
        if (-not ($jsonA | Test-Json -SchemaFile $SchemaA -ErrorAction Stop)) {
            throw "Pre-commit schema validation failed for $PathA against $SchemaA"
        }
    }
    if ($null -ne $jsonB -and -not [string]::IsNullOrWhiteSpace($SchemaB) -and (Test-Path -LiteralPath $SchemaB)) {
        if (-not ($jsonB | Test-Json -SchemaFile $SchemaB -ErrorAction Stop)) {
            throw "Pre-commit schema validation failed for $PathB against $SchemaB"
        }
    }

    $journalId = [guid]::NewGuid().ToString("N")
    $journalPath = Join-Path $SpecDir ".commit-journal.json"
    $backupA = Join-Path $SpecDir ".commit-backupA-$journalId.bak"
    $backupB = if ($null -ne $PathB) { Join-Path $SpecDir ".commit-backupB-$journalId.bak" } else { $null }
    $tmpA = $PathA + ".stage.tmp"
    $tmpB = if ($null -ne $PathB -and $null -ne $jsonB) { $PathB + ".stage.tmp" } else { $null }

    $aExisted = Test-Path -LiteralPath $PathA -PathType Leaf
    $bExisted = if ($null -ne $PathB) { Test-Path -LiteralPath $PathB -PathType Leaf } else { $false }
    if ($aExisted) { [System.IO.File]::Copy($PathA, $backupA, $true) }
    if ($bExisted -and $null -ne $backupB) { [System.IO.File]::Copy($PathB, $backupB, $true) }

    [System.IO.File]::WriteAllText($tmpA, $jsonA, $script:WorkflowUtf8NoBom)
    if ($null -ne $tmpB) {
        [System.IO.File]::WriteAllText($tmpB, $jsonB, $script:WorkflowUtf8NoBom)
    }

    $journalObj = [ordered]@{
        journalId = $journalId
        state = "PREPARED"
        timestamp = [DateTimeOffset]::UtcNow.ToString("o")
        targets = @(
            [ordered]@{ path = $PathA; tmpPath = $tmpA; existed = $aExisted; backupPath = $backupA }
        )
    }
    if ($null -ne $PathB) {
        $journalObj.targets += [ordered]@{ path = $PathB; tmpPath = $tmpB; existed = $bExisted; backupPath = $backupB }
    }
    [System.IO.File]::WriteAllText($journalPath, ($journalObj | ConvertTo-Json -Depth 10), $script:WorkflowUtf8NoBom)

    try {
        [System.IO.File]::Move($tmpA, $PathA, $true)
        if ($null -ne $tmpB -and $null -ne $PathB) {
            [System.IO.File]::Move($tmpB, $PathB, $true)
        }

        $journalObj.state = "COMMITTED"
        [System.IO.File]::WriteAllText($journalPath, ($journalObj | ConvertTo-Json -Depth 10), $script:WorkflowUtf8NoBom)
        Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
        if ($aExisted -and (Test-Path -LiteralPath $backupA)) { Remove-Item -LiteralPath $backupA -Force -ErrorAction SilentlyContinue }
        if ($bExisted -and $null -ne $backupB -and (Test-Path -LiteralPath $backupB)) { Remove-Item -LiteralPath $backupB -Force -ErrorAction SilentlyContinue }
    } catch {
        $journalObj.state = "ROLLED_BACK"
        try { [System.IO.File]::WriteAllText($journalPath, ($journalObj | ConvertTo-Json -Depth 10), $script:WorkflowUtf8NoBom) } catch {}
        if ($aExisted -and (Test-Path -LiteralPath $backupA)) {
            [System.IO.File]::Copy($backupA, $PathA, $true)
        } elseif (-not $aExisted -and (Test-Path -LiteralPath $PathA)) {
            [System.IO.File]::Delete($PathA)
        }
        if ($bExisted -and $null -ne $backupB -and (Test-Path -LiteralPath $backupB)) {
            [System.IO.File]::Copy($backupB, $PathB, $true)
        } elseif (-not $bExisted -and $null -ne $PathB -and (Test-Path -LiteralPath $PathB)) {
            [System.IO.File]::Delete($PathB)
        }
        Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $backupA) { Remove-Item -LiteralPath $backupA -Force -ErrorAction SilentlyContinue }
        if ($null -ne $backupB -and (Test-Path -LiteralPath $backupB)) { Remove-Item -LiteralPath $backupB -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmpA) { Remove-Item -LiteralPath $tmpA -Force -ErrorAction SilentlyContinue }
        if ($null -ne $tmpB -and (Test-Path -LiteralPath $tmpB)) { Remove-Item -LiteralPath $tmpB -Force -ErrorAction SilentlyContinue }
        throw "TWO_PHASE_COMMIT_FAILED: $($_.Exception.Message)"
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
            $fsDict = [ordered]@{}
            foreach ($p in $fs.psobject.Properties) {
                $fsDict[$p.Name] = $p.Value
            }
            $changed = $false
            if ($fs.tier -ne "T3") {
                $fsDict["tier"] = "T3"
                $changed = $true
            }
            if (-not $fsDict.Contains("baseline") -or [string]::IsNullOrWhiteSpace($fsDict["baseline"])) {
                $detectedBaseline = Get-AuthoritativeFeatureBaseline -SpecDir $specDir
                if (-not [string]::IsNullOrWhiteSpace($detectedBaseline)) {
                    $fsDict["baseline"] = $detectedBaseline
                    $changed = $true
                }
            }
            if ($changed) {
                $fsDict["updatedAt"] = [DateTimeOffset]::UtcNow.ToString("o")
                $fsSchema = Join-Path $SchemaRoot "feature-state.schema.json"
                Write-JsonAtomic -FilePath $featStateFile -Value $fsDict -SchemaPath $fsSchema
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
            $specDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
            $detectedBaseline = Get-AuthoritativeFeatureBaseline -SpecDir $specDir

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
            if (-not [string]::IsNullOrWhiteSpace($detectedBaseline)) {
                $state["baseline"] = $detectedBaseline
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
            throw "VALIDATE_TEST_COVERAGE_FAILED: $($placeholderResult.Errors -join '; ')"
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
    "ValidateChangeImpact" {
        Assert-Argument -Name "Path" -Value $Path
        $impact = Validate-ChangeImpactState -ImpactPath $Path
        Write-Output "VALID"
        return $impact
    }
    "AssessRisk" {
        $specDir = if (-not [string]::IsNullOrWhiteSpace($Path)) {
            if (Test-Path -LiteralPath $Path -PathType Container) { $Path } else { Split-Path -Parent $Path }
        } elseif (-not [string]::IsNullOrWhiteSpace($SpecDirectory)) {
            $SpecDirectory
        } else {
            $PSScriptRoot
        }
        $wsRoot = Resolve-AiSopWorkspaceRoot -StartPath $specDir
        if ([string]::IsNullOrWhiteSpace($wsRoot)) {
            return [pscustomobject]@{
                workspaceRoot = $null
                baseline = if (-not [string]::IsNullOrWhiteSpace($Baseline)) { $Baseline } else { "0" }
                changeSetDigest = ("0" * 64)
                declaredTier = if (-not [string]::IsNullOrWhiteSpace($declaredTier)) { $declaredTier } else { "T2" }
                minRequiredTier = "T3"
                hasHighRisk = $true
                triggersHit = @("WORKSPACE_UNRESOLVED")
                details = @("Spec directory '$specDir' is outside any known workspace root (.ai-workspace, .git, or .svn). Failing closed to T3.")
                evaluatedAt = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            } | ConvertTo-Json -Depth 5 | Write-Output
        }
        
        # Verify baseline integrity & get authoritative baseline
        Assert-FeatureBaselineIntegrity -SpecDir $specDir -ProposedBaseline $Baseline
        $effectiveBaseline = if (-not [string]::IsNullOrWhiteSpace($Baseline)) {
            $Baseline
        } else {
            Get-AuthoritativeFeatureBaseline -SpecDir $specDir -WorkspaceRoot $wsRoot
        }

        $featStatePath = Join-Path $specDir "feature-state.json"
        $declaredTier = $null
        if (Test-Path -LiteralPath $featStatePath -PathType Leaf) {
            try {
                $fs = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json
                $declaredTier = [string]$fs.tier
            } catch {}
        }
        $risk = Get-SemanticRiskAssessment -WorkspaceRoot $wsRoot -Baseline $effectiveBaseline -DeclaredTier $declaredTier -SpecDir $specDir
        if (-not [string]::IsNullOrWhiteSpace($risk.Baseline)) {
            $effectiveBaseline = $risk.Baseline
        }
        
        $changeSetDigest = $null
        if (-not [string]::IsNullOrWhiteSpace($wsRoot)) {
            try {
                $changeSetDigest = Get-ChangeSetDigest -WorkspaceRoot $wsRoot -Baseline $effectiveBaseline
            } catch {
                $risk.HasHighRisk = $true
                $risk.MinRequiredTier = "T3"
                if (@($risk.TriggersHit) -notcontains "VCS_UNAVAILABLE") {
                    $risk.TriggersHit = @($risk.TriggersHit + "VCS_UNAVAILABLE")
                }
                $risk.Details = @($risk.Details + "Failed to calculate changeSetDigest: $($_.Exception.Message)")
            }
        }
        if ([string]::IsNullOrWhiteSpace($changeSetDigest)) {
            $changeSetDigest = ("0" * 64)
        }
        
        # Atomically persist to feature-state.json & 00_workflow_state.json with two-phase commit & lock
        $lockTarget = if (Test-Path -LiteralPath $featStatePath -PathType Leaf) { $featStatePath } else { (Join-Path $specDir "workflow-state.json") }
        Invoke-WithFileLock -StatePath $lockTarget -Action {
            $isoNow = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            $fsDict = $null
            $fsSchema = Join-Path $SchemaRoot "feature-state.schema.json"
            if (Test-Path -LiteralPath $featStatePath -PathType Leaf) {
                $fsRaw = [System.IO.File]::ReadAllText($featStatePath)
                $fsObj = $fsRaw | ConvertFrom-Json
                $fsDict = [ordered]@{}
                foreach ($p in $fsObj.psobject.Properties) {
                    $fsDict[$p.Name] = $p.Value
                }
                if (-not $fsDict.Contains("schemaVersion") -or [string]::IsNullOrWhiteSpace($fsDict["schemaVersion"])) { $fsDict["schemaVersion"] = "1.0" }
                if (-not $fsDict.Contains("feature") -or [string]::IsNullOrWhiteSpace($fsDict["feature"])) { $fsDict["feature"] = Split-Path -Leaf $specDir }
                if (-not $fsDict.Contains("tier") -or [string]::IsNullOrWhiteSpace($fsDict["tier"])) { $fsDict["tier"] = if (-not [string]::IsNullOrWhiteSpace($declaredTier)) { $declaredTier } else { "T2" } }
                if (-not $fsDict.Contains("phase") -or [string]::IsNullOrWhiteSpace($fsDict["phase"])) { $fsDict["phase"] = "CLAIMED" }
                if (-not $fsDict.Contains("baseline") -or [string]::IsNullOrWhiteSpace($fsDict["baseline"])) {
                    if (-not [string]::IsNullOrWhiteSpace($effectiveBaseline)) {
                        $fsDict["baseline"] = $effectiveBaseline
                    }
                }
                $fsDict["inferredRisk"] = [ordered]@{
                    baseline = if (-not [string]::IsNullOrWhiteSpace($effectiveBaseline)) { $effectiveBaseline } else { "0" }
                    changeSetDigest = $changeSetDigest
                    declaredTier = if (-not [string]::IsNullOrWhiteSpace($declaredTier)) { $declaredTier } else { "T2" }
                    minRequiredTier = $risk.MinRequiredTier
                    hasHighRisk = $risk.HasHighRisk
                    triggersHit = @($risk.TriggersHit)
                    details = @($risk.Details)
                    evaluatedAt = $isoNow
                }
                $fsDict["updatedAt"] = $isoNow
            }

            $wfStatePath = Join-Path $specDir "00_workflow_state.json"
            $wfDict = $null
            $wfSchema = Join-Path $SchemaRoot "workflow-state.schema.json"
            if (Test-Path -LiteralPath $wfStatePath -PathType Leaf) {
                $wfRaw = [System.IO.File]::ReadAllText($wfStatePath)
                $wfObj = $wfRaw | ConvertFrom-Json
                $wfDict = [ordered]@{}
                foreach ($p in $wfObj.psobject.Properties) {
                    $wfDict[$p.Name] = $p.Value
                }
                if (-not $wfDict.Contains("baseline") -or [string]::IsNullOrWhiteSpace($wfDict["baseline"])) {
                    if (-not [string]::IsNullOrWhiteSpace($effectiveBaseline)) {
                        $wfDict["baseline"] = $effectiveBaseline
                    }
                }
                $wfDict["inferredRisk"] = [ordered]@{
                    baseline = if (-not [string]::IsNullOrWhiteSpace($effectiveBaseline)) { $effectiveBaseline } else { "0" }
                    changeSetDigest = $changeSetDigest
                    declaredTier = if (-not [string]::IsNullOrWhiteSpace($declaredTier)) { $declaredTier } else { "T2" }
                    minRequiredTier = $risk.MinRequiredTier
                    hasHighRisk = $risk.HasHighRisk
                    triggersHit = @($risk.TriggersHit)
                    details = @($risk.Details)
                    evaluatedAt = $isoNow
                }
            }

            # Execute transactional commit across both state files
            if ($null -ne $fsDict -and $null -ne $wfDict) {
                Invoke-AiSopTwoFileAtomicCommit -PathA $featStatePath -ValueA $fsDict -SchemaA $fsSchema `
                    -PathB $wfStatePath -ValueB $wfDict -SchemaB $wfSchema -SpecDir $specDir
            } elseif ($null -ne $fsDict) {
                Write-JsonAtomic -FilePath $featStatePath -Value $fsDict -SchemaPath $fsSchema
            } elseif ($null -ne $wfDict) {
                Write-JsonAtomic -FilePath $wfStatePath -Value $wfDict -SchemaPath $wfSchema
            }
        }

        [pscustomobject]@{
            workspaceRoot = $wsRoot
            baseline = $effectiveBaseline
            changeSetDigest = $changeSetDigest
            declaredTier = $declaredTier
            minRequiredTier = $risk.MinRequiredTier
            hasHighRisk = $risk.HasHighRisk
            triggersHit = @($risk.TriggersHit)
            details = @($risk.Details)
            evaluatedAt = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        } | ConvertTo-Json -Depth 5 | Write-Output
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
                    setup = @("Execute test according to 05_test_plan.md")
                    trigger = @("Trigger test case $tcId")
                    assertions = [ordered]@{
                        protocol = @(
                            [ordered]@{
                                target = "status"
                                operator = "EQ"
                                expected = "VALID"
                            }
                        )
                    }
                    cleanup = @("Clean up test fixture")
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
        $hasSpecArtifacts = (Test-Path -LiteralPath (Join-Path $specDir "01_server_rules.md") -PathType Leaf) -or 
                            (Test-Path -LiteralPath (Join-Path $specDir "06_design_contract.md") -PathType Leaf) -or 
                            (Test-Path -LiteralPath (Join-Path $specDir "05_test_plan.md") -PathType Leaf) -or
                            (Test-Path -LiteralPath (Join-Path $specDir "04_change_impact.json") -PathType Leaf)
        
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
        if ([string]::IsNullOrWhiteSpace($wsRoot)) {
            $checks.Add("[X] 工作区解析失败: spec directory 未位于有效工作区内 (.ai-workspace / .git / .svn)")
        }

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
        if (-not [string]::IsNullOrWhiteSpace($wsRoot) -and (Test-Path -LiteralPath (Join-Path $wsRoot ".svn") -PathType Container)) {
            $checks.Add("[?] VCS 交付状态: SVN 工作副本 (准备 svn commit)")
        } elseif (-not [string]::IsNullOrWhiteSpace($wsRoot) -and (Test-Path -LiteralPath (Join-Path $wsRoot ".git") -PathType Container)) {
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
        $hasSpecArtifacts = (Test-Path -LiteralPath (Join-Path $specDir "01_server_rules.md") -PathType Leaf) -or 
                            (Test-Path -LiteralPath (Join-Path $specDir "06_design_contract.md") -PathType Leaf) -or 
                            (Test-Path -LiteralPath (Join-Path $specDir "05_test_plan.md") -PathType Leaf) -or
                            (Test-Path -LiteralPath (Join-Path $specDir "04_change_impact.json") -PathType Leaf)
        
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
        if ([string]::IsNullOrWhiteSpace($wsRoot)) {
            $failures.Add("WORKSPACE_UNRESOLVED: unable to resolve workspace root (.ai-workspace, .git, or .svn) for spec directory '$specDir'.")
            $checks.Add("[X] 工作区解析失败: spec directory 未位于有效工作区内")
        }

        $candidateRoots = if (-not [string]::IsNullOrWhiteSpace($wsRoot)) { @($wsRoot) } else { @() }
        $compileOk = $false
        foreach ($r in $candidateRoots) {
            if ((Test-Path -LiteralPath (Join-Path $r "build/classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "build/libs") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "build") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "target/classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "WebRoot/WEB-INF/classes") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "bin") -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $r "out") -PathType Container)) {
                $compileOk = $true
                break
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
                        $failures.Add("coverage has $($phResult.Errors.Count) placeholder/carrier error(s): $($phResult.Errors -join '; ')")
                        $checks.Add("[X] 覆盖校验无占位/carrier错误($($phResult.Errors.Count) error: $($phResult.Errors -join '; '))")
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
            # Change impact: required for TYPE_EXTENSION/PUBLIC_ROUTING, or when risk cannot be assessed.
            $impactPath = Join-Path $specDir "04_change_impact.json"
            $impactOk = Test-Path -LiteralPath $impactPath -PathType Leaf
            $extRisk = Get-SemanticRiskAssessment -WorkspaceRoot $wsRoot -SpecDir $specDir
            $impactRequired = Test-ChangeImpactRequired -TriggersHit $extRisk.TriggersHit
            if (-not $impactOk) {
                if ($impactRequired) {
                    $triggerList = (@($extRisk.TriggersHit) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ", "
                    if (Test-IsTypeExtensionRisk -TriggersHit $extRisk.TriggersHit) {
                        $failures.Add("04_change_impact.json is mandatory for TYPE_EXTENSION/PUBLIC_ROUTING but missing at $impactPath")
                    } else {
                        $failures.Add("04_change_impact.json is mandatory because semantic risk could not be assessed ($triggerList) but missing at $impactPath")
                    }
                    $checks.Add("[X] 行为影响分析产物(04_change_impact.json)缺失(类型/路由扩展或风险无法评估)")
                } else {
                    $checks.Add("[v] 行为影响分析产物(04_change_impact.json)未要求(非类型/路由扩展且风险可评估)")
                }
            } else {
                $checks.Add("[v] 行为影响分析产物(04_change_impact.json)存在")
                try {
                    $impact = Validate-ChangeImpactState -ImpactPath $impactPath
                    $checks.Add("[v] 行为影响分析有效且未过期")
                    $extRisk = Get-SemanticRiskAssessment -WorkspaceRoot $wsRoot -Baseline $impact.baseline -SpecDir $specDir
                    if (Test-IsTypeExtensionRisk -TriggersHit $extRisk.TriggersHit) {
                        $checks.Add("[v] 类型/路由扩展完成度(behaviorVariants/legacyPaths/invariants/8-lifecycleFacets/证据与兄弟键)")
                    }

                    # Cross-validation with 05_test_coverage.json
                    if ($covOk) {
                        $covObj = Read-JsonObject -FilePath $covPath -SchemaPath (Join-Path $SchemaRoot "test-coverage.schema.json")
                        $coveredInvariants = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        $declaredCases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($c in $covObj.cases) {
                            $declaredCases.Add([string]$c.id) | Out-Null
                            if ($c.invariantIds) {
                                foreach ($invId in $c.invariantIds) {
                                    $coveredInvariants.Add([string]$invId) | Out-Null
                                }
                            }
                        }
                        if ($impact.invariants) {
                            foreach ($inv in $impact.invariants) {
                                $invId = [string]$inv.invariantId
                                if (-not $coveredInvariants.Contains($invId)) {
                                    $failures.Add("Invariant '$invId' in 04_change_impact.json is not covered by any test case in 05_test_coverage.json")
                                }
                            }
                        }
                        if ($impact.requiredRegressionCases) {
                            foreach ($rc in $impact.requiredRegressionCases) {
                                if (-not $declaredCases.Contains([string]$rc)) {
                                    $failures.Add("Required regression case '$rc' in 04_change_impact.json is missing from 05_test_coverage.json")
                                }
                            }
                        }
                        if (Test-IsTypeExtensionRisk -TriggersHit $extRisk.TriggersHit) {
                            try {
                                Assert-ExtensionCoverageCompleteness -Impact $impact -Coverage $covObj -WorkspaceRoot $wsRoot -Baseline $impact.baseline -SpecDir $specDir
                                $checks.Add("[v] 类型/路由扩展覆盖完成度(CHARACTERIZATION载体方法体/entryPointIds/variantKeys/facetIds/bypassesPriorQuery/persistenceColdReload)")
                            } catch {
                                $failures.Add($_.Exception.Message)
                                $checks.Add("[X] 类型/路由扩展覆盖完成度(CHARACTERIZATION载体方法体/entryPointIds/variantKeys/facetIds/bypassesPriorQuery/persistenceColdReload)")
                            }
                        }
                    }
                } catch {
                    $failures.Add("change impact validation threw: $($_.Exception.Message)")
                    $checks.Add("[X] 行为影响分析校验失败")
                }
            }
            # feature-state phase must not be initial/empty.
            $phaseOk = (-not [string]::IsNullOrWhiteSpace($phase)) -and ($phase -ne "INIT") -and ($phase -ne "unknown") -and ($phase -ne "UNCLASSIFIED")
            if (-not $phaseOk) { $failures.Add("feature-state phase is initial/unknown ($phase)") }
            $checks.Add("[$(if($phaseOk){'v'}else{'X'})] feature-state 阶段非初始($phase)")
            $checks.Add("[v] 语义风险分档: T3已纳管")
        } elseif ($effectiveTier -in @("T1", "T2", "FAST_TRACK")) {
            # Machine-enforced semantic risk tiering check
            $risk = Get-SemanticRiskAssessment -WorkspaceRoot $wsRoot -DeclaredTier $effectiveTier -SpecDir $specDir
            if ($risk.HasHighRisk) {
                $failures.Add("HIGH_RISK_TIER_DOWNGRADE_FORBIDDEN: changeset hits high-risk semantic triggers ($($risk.TriggersHit -join ', ')). High-risk changes CANNOT execute as $effectiveTier (even with 04_change_impact.json); they MUST be upgraded to T3 with full requirements, design contract, test coverage, and dual auditor verification.")
                $checks.Add("[X] 语义风险防降档: 命中高危触发器($($risk.TriggersHit -join ', '))，禁止降档为 $effectiveTier (必须升级为 T3)")
            } else {
                $checks.Add("[v] 语义风险分档: 无高危触发器")
            }

            # T1/T2/FAST_TRACK: compile artifact check is non-blocking (advisory); Claim validity is workflow-owner.ps1 Validate's job
            if ($effectiveTier -eq "T2") {
                $checks.Add("[?] 归属 Validate(owner.ps1 -Operation Validate,另跑)")
                $checks.Add("[?] 相关测试/回归(AI 据定向 JUnit 结果自报)")
            } elseif ($effectiveTier -eq "FAST_TRACK") {
                $hasSourceCodeChanges = $false
                if (Test-Path -LiteralPath (Join-Path $wsRoot ".git")) {
                    try {
                        $gitStat = & git -C $wsRoot status --porcelain -uall 2>&1
                        if ($gitStat -match '(?m)^\s*[MADRCU?]+\s+(src|pkg|internal|app)/') {
                            $hasSourceCodeChanges = $true
                        }
                        $gitDiff = & git -C $wsRoot diff HEAD~1 2>&1
                        if ($gitDiff -match '(?m)^diff --git a/(src|pkg|internal|app)/') {
                            $hasSourceCodeChanges = $true
                        }
                    } catch {}
                } elseif (Test-Path -LiteralPath (Join-Path $wsRoot ".svn")) {
                    try {
                        $svnStat = & svn status --non-interactive --ignore-externals $wsRoot 2>&1
                        if ($svnStat -match '(?m)^[MAD?]\s+.*(src|pkg|internal|app)[/\\].*') {
                            $hasSourceCodeChanges = $true
                        }
                        $svnDiff = & svn diff --non-interactive $wsRoot 2>&1
                        if ($svnDiff -match '(?m)^Index:\s+.*(src|pkg|internal|app)[/\\].*') {
                            $hasSourceCodeChanges = $true
                        }
                    } catch {}
                }
                if ($hasSourceCodeChanges) {
                    $failures.Add("FAST_TRACK violation: production source code was modified under src/. Changes to source code require at least T2 tier.")
                    $checks.Add("[X] 快通道合规: 源码目录发生修改(禁止快通道)")
                } else {
                    $checks.Add("[?] 快通道: 纯数值/文档检查自报")
                }
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
                $svnOutput = & svn status --non-interactive --ignore-externals $wsRoot 2>&1
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
