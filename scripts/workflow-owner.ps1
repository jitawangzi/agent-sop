#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet(
        "Claim",
        "BindSession",
        "RebindSession",
        "Validate",
        "Complete",
        "Transfer",
        "Suspend",
        "Cancel",
        "Checkpoint",
        "ForceRelease",
        "Recover",
        "Check",
        "Status"
    )]
    [string]$Operation,

    [Parameter(Mandatory = $false)]
    [string]$SpecDirectory,

    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$")]
    [string]$Feature,

    [Parameter(Mandatory = $false)]
    [ValidateSet("CUSTOM_SKILLS", "SUPERPOWERS")]
    [string]$Workflow = "SUPERPOWERS",

    [Parameter(Mandatory = $false)]
    [ValidateSet(
        "CLAUDE_CODE",
        "COPILOT",
        "ANTIGRAVITY",
        "CURSOR",
        "CODEX",
        "GEMINI",
        "PI"
    )]
    [string]$Agent,

    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[A-Za-z0-9._:-]+$")]
    [string]$OwnerId,

    [Parameter(Mandatory = $false)]
    [ValidateSet("T1", "T2", "T3", "FAST_TRACK")]
    [string]$Tier = "T2",

    [Parameter(Mandatory = $false)]
    [string]$TaskId,
    [string]$Objective,
    [string]$NextAction = "",
    [string]$Notes = "",
    [string]$EvidencePath,
    [string]$TaskUpdateJson,
    [switch]$ImpactReviewed,
    [switch]$ForceRecovery,
    [switch]$QuarantineInvalidEvidence,
    [string]$RecoveryReason,
    [switch]$ConfirmTakeover,
    [switch]$RetryEvidence,
    [switch]$CreateTaskOnly,
    [switch]$CaptureBaseline,
    [string]$Baseline = $null,
    # Internal callers can cap all lock phases at the original run lease.
    [Nullable[DateTimeOffset]]$DeadlineUtc
)

$ErrorActionPreference = "Stop"
if ($CaptureBaseline -and ($Operation -ne 'Claim' -or -not $CreateTaskOnly)) { throw 'CAPTURE_BASELINE_REQUIRES_START' }

if ([string]::IsNullOrWhiteSpace($Operation)) {
    throw "WORKFLOW_OPERATION_REQUIRED: -Operation parameter is required. Allowed values: Claim, BindSession, RebindSession, Validate, Complete, Transfer, ForceRelease, Check, Status."
}

$ClaudeRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "path-identity.ps1")
. (Join-Path $PSScriptRoot "workflow-transaction.ps1")
. (Join-Path $PSScriptRoot "workflow-session.ps1")
. (Join-Path $PSScriptRoot "workflow-command-grant.ps1")
. (Join-Path $PSScriptRoot "task-context.ps1")
$SchemaPath = Join-Path $ClaudeRoot "schemas\workflow-owner.schema.json"

function Assert-OwnerSchema {
    param([string]$Json)

    $jsonErr = $null
    if (
        -not (
            $Json |
                Test-Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue -ErrorVariable jsonErr
        )
    ) {
        Write-Warning "Owner schema validation failed for schema $SchemaPath : $jsonErr"
        throw "WORKFLOW_OWNER_CORRUPT"
    }
}

function Assert-CanonicalSpecDirectory {
    if ([string]::IsNullOrWhiteSpace($ResolvedSpecDirectory)) {
        throw "WORKFLOW_SPEC_DIRECTORY_INVALID"
    }
    $trimmedDirectory = $ResolvedSpecDirectory.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $featuresDirectory = Split-Path -Parent $trimmedDirectory
    $specsDirectory = Split-Path -Parent $featuresDirectory
    $specRootDirectory = Split-Path -Parent $specsDirectory
    # The spec root may be `.claude` (legacy/standard-flow submodule) or
    # `.ai-workspace` (project-domain layer, AiSopLayering). Both layouts share
    # the `specs/features/<Feature>` structure; only the root name differs.
    if (
        -not (Split-Path -Leaf $trimmedDirectory).Equals(
            $Feature,
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
            (Split-Path -Leaf $specRootDirectory).Equals(
                ".ai-sop",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            (Split-Path -Leaf $specRootDirectory).Equals(
                ".ai-workspace",
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
    ) {
        throw "WORKFLOW_SPEC_DIRECTORY_INVALID"
    }
}

function Get-OwnerWorkspacePath {
    if (-not [string]::IsNullOrWhiteSpace($ResolvedSpecDirectory)) {
        try {
            $featuresDirectory = Split-Path -Parent $ResolvedSpecDirectory
            $specsDirectory = Split-Path -Parent $featuresDirectory
            $claudeDirectory = Split-Path -Parent $specsDirectory
            return Resolve-PhysicalPathIdentity -Path (
                Split-Path -Parent $claudeDirectory
            )
        } catch {}
    }
    $ws = try { Resolve-AiSopWorkspaceRoot -StartPath (Get-Location).Path } catch { $null }
    if (-not [string]::IsNullOrWhiteSpace($ws)) { return $ws }
    return Resolve-PhysicalPathIdentity -Path (Get-Location).Path
}

function Read-Owner {
    param([switch]$AllowMissing)

    if ($null -eq $OwnerPath -or -not [System.IO.File]::Exists($OwnerPath)) {
        if ($AllowMissing) {
            return $null
        }
        throw "WORKFLOW_OWNER_NOT_FOUND"
    }
    try {
        $raw = [System.IO.File]::ReadAllText($OwnerPath)
        Assert-OwnerSchema $raw
        return ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
    } catch {
        if ($_.Exception.Message -eq "WORKFLOW_OWNER_CORRUPT") {
            throw
        }
        throw "WORKFLOW_OWNER_IO_ERROR"
    }
}

function Write-OwnerAtomic {
    param([System.Collections.IDictionary]$Owner)

    $json = ConvertTo-AiSopWorkflowCanonicalJson $Owner
    Assert-OwnerSchema $json
    Write-AiSopWorkflowTextAtomic -Path $OwnerPath -Text $json
}

function Write-OwnerMirror {
    param([System.Collections.IDictionary]$Owner)

    try {
        if (-not [string]::IsNullOrWhiteSpace($ResolvedSpecDirectory)) {
            [System.IO.Directory]::CreateDirectory($ResolvedSpecDirectory) |
                Out-Null
            $json = ConvertTo-AiSopWorkflowCanonicalJson $Owner
            Write-AiSopWorkflowTextAtomic -Path $MirrorPath -Text $json
        }
    } catch {
        Write-Warning (
            "Authoritative ownership is valid, but the readable mirror " +
            "could not be updated: $MirrorPath"
        )
    }
}

function Assert-OwnerIdentity {
    param([System.Collections.IDictionary]$Owner)

    if (
        [string]$Owner.feature -cne $Feature -or
        [string]$Owner.workflow -cne $Workflow -or
        [string]$Owner.agent -cne $Agent -or
        [string]$Owner.ownerId -cne $OwnerId -or
        -not ([string]$Owner.specDirectory).Equals(
            $ResolvedSpecDirectory,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        (
            [string]$Owner.schemaVersion -ceq "1.1" -and
            -not ([string]$Owner.workspacePath).Equals(
                (Get-OwnerWorkspacePath),
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
    ) {
        throw "WORKFLOW_OWNER_IDENTITY_MISMATCH"
    }
}

function Detect-AiSopAgentHarness {
    if (-not [string]::IsNullOrWhiteSpace($env:ANTIGRAVITY_SESSION_ID) -or
        -not [string]::IsNullOrWhiteSpace($env:ANTIGRAVITY_AGENT_ID)) {
        return "ANTIGRAVITY"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CODE)) {
        return "CLAUDE_CODE"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SESSION_ID)) {
        return "CODEX"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CURSOR_VERSION)) {
        return "CURSOR"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_COPILOT)) {
        return "COPILOT"
    }
    return "ANTIGRAVITY"
}

# 1. Resolve Feature from SpecDirectory or current working directory
if ([string]::IsNullOrWhiteSpace($Feature) -and -not [string]::IsNullOrWhiteSpace($SpecDirectory)) {
    $trimmedSpec = $SpecDirectory.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $Feature = Split-Path -Leaf $trimmedSpec
}
if ([string]::IsNullOrWhiteSpace($Feature)) {
    $cwd = (Get-Location).Path
    $parent = Split-Path -Parent $cwd
    if ($parent -match '(?i)[\\/]features$') {
        $Feature = Split-Path -Leaf $cwd
        if ([string]::IsNullOrWhiteSpace($SpecDirectory)) {
            $SpecDirectory = $cwd
        }
    }
}

# 2. Workspace path resolution
$ownerWs = try { Get-OwnerWorkspacePath } catch { $null }
if ([string]::IsNullOrWhiteSpace($ownerWs)) {
    $ownerWs = try { Resolve-AiSopWorkspaceRoot -StartPath (Get-Location).Path } catch { $null }
}
if ([string]::IsNullOrWhiteSpace($ownerWs)) {
    $ownerWs = try { Resolve-PhysicalPathIdentity -Path (Get-Location).Path } catch { (Get-Location).Path }
}

# 3. Resolve SpecDirectory from candidate folders in workspace/PWD if Feature is known
if ([string]::IsNullOrWhiteSpace($SpecDirectory) -and -not [string]::IsNullOrWhiteSpace($Feature)) {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ownerWs)) {
        $candidates += (Join-Path $ownerWs ".ai-workspace\specs\features\$Feature")
        $candidates += (Join-Path $ownerWs ".ai-sop\specs\features\$Feature")
    }
    $candidates += (Join-Path (Get-Location).Path ".ai-workspace\specs\features\$Feature")
    $candidates += (Join-Path (Get-Location).Path ".ai-sop\specs\features\$Feature")
    foreach ($cand in $candidates) {
        if (Test-Path -LiteralPath $cand -PathType Container) {
            $SpecDirectory = $cand
            break
        }
    }
}

$RegistryRoot = Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $ownerWs
$OwnerPath = if (-not [string]::IsNullOrWhiteSpace($Feature)) {
    Join-Path $RegistryRoot ($Feature.ToLowerInvariant() + ".json")
} else { $null }

# 4. If SpecDirectory is still unknown, try reading specDirectory from existing owner registry
if ([string]::IsNullOrWhiteSpace($SpecDirectory) -and $null -ne $OwnerPath -and [System.IO.File]::Exists($OwnerPath)) {
    try {
        $rawEarly = [System.IO.File]::ReadAllText($OwnerPath)
        $objEarly = ConvertFrom-AiSopWorkflowJson -Json $rawEarly -AsHashtable
        if ($null -ne $objEarly -and -not [string]::IsNullOrWhiteSpace($objEarly.specDirectory)) {
            $SpecDirectory = [string]$objEarly.specDirectory
        }
    } catch {}
}

$ResolvedSpecDirectory = if (-not [string]::IsNullOrWhiteSpace($SpecDirectory)) {
    try { Resolve-PhysicalPathIdentity -Path $SpecDirectory } catch { $SpecDirectory }
} else { $null }
$MirrorPath = if (-not [string]::IsNullOrWhiteSpace($ResolvedSpecDirectory)) {
    Join-Path $ResolvedSpecDirectory ".workflow-owner.json"
} else { $null }

if (-not [string]::IsNullOrWhiteSpace($ResolvedSpecDirectory)) {
    $ownerWs = try { Get-OwnerWorkspacePath } catch { $ownerWs }
    $RegistryRoot = Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $ownerWs
    $OwnerPath = if (-not [string]::IsNullOrWhiteSpace($Feature)) {
        Join-Path $RegistryRoot ($Feature.ToLowerInvariant() + ".json")
    } else { $OwnerPath }
}

$AcceptedAt = [DateTimeOffset]::UtcNow
# Production budget default is 3000ms (supports subprocess verification and cross-platform IO).
$ownerDeadlineMs = 3000
$ownerDeadlineEnv = [string]$env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS
if (
    -not [string]::IsNullOrWhiteSpace($ownerDeadlineEnv) -and
    [int]::TryParse($ownerDeadlineEnv, [ref]$ownerDeadlineEnv)
) {
    $ownerDeadlineMs = [int]$ownerDeadlineEnv
}
$WorkflowDeadlineUtc = $AcceptedAt.AddMilliseconds($ownerDeadlineMs)
if ($null -ne $DeadlineUtc -and $DeadlineUtc -lt $WorkflowDeadlineUtc) { $WorkflowDeadlineUtc = [DateTimeOffset]$DeadlineUtc }

# 5. Read existing owner (from registry or mirror fallback)
$existingOwner = Read-Owner -AllowMissing
if ($null -eq $existingOwner -and -not [string]::IsNullOrWhiteSpace($MirrorPath) -and (Test-Path -LiteralPath $MirrorPath -PathType Leaf)) {
    try {
        $rawMirror = [System.IO.File]::ReadAllText($MirrorPath)
        Assert-OwnerSchema $rawMirror
        $existingOwner = ConvertFrom-AiSopWorkflowJson -Json $rawMirror -AsHashtable
    } catch {}
}

# 6. Auto-populate missing parameters from existing owner if present
if ($null -ne $existingOwner) {
    if ([string]::IsNullOrWhiteSpace($Feature) -and -not [string]::IsNullOrWhiteSpace($existingOwner.feature)) {
        $Feature = [string]$existingOwner.feature
    }
    if ([string]::IsNullOrWhiteSpace($ResolvedSpecDirectory) -and -not [string]::IsNullOrWhiteSpace($existingOwner.specDirectory)) {
        $SpecDirectory = [string]$existingOwner.specDirectory
        $ResolvedSpecDirectory = Resolve-PhysicalPathIdentity -Path $SpecDirectory
        $MirrorPath = Join-Path $ResolvedSpecDirectory ".workflow-owner.json"
    }
    if ([string]::IsNullOrWhiteSpace($Workflow)) {
        $Workflow = if (-not [string]::IsNullOrWhiteSpace($existingOwner.workflow)) { [string]$existingOwner.workflow } else { "SUPERPOWERS" }
    }
    if ([string]::IsNullOrWhiteSpace($Agent)) {
        $Agent = if (-not [string]::IsNullOrWhiteSpace($existingOwner.agent)) { [string]$existingOwner.agent } else { Detect-AiSopAgentHarness }
    }
    if ([string]::IsNullOrWhiteSpace($OwnerId)) {
        $OwnerId = if (-not [string]::IsNullOrWhiteSpace($existingOwner.ownerId)) { [string]$existingOwner.ownerId } else { "" }
    }
} else {
    if ([string]::IsNullOrWhiteSpace($Workflow)) {
        $Workflow = "SUPERPOWERS"
    }
    if ([string]::IsNullOrWhiteSpace($Agent)) {
        $Agent = Detect-AiSopAgentHarness
    }
}

# 7. Check and Status read-only queries
if ($Operation -in @("Check", "Status")) {
    if ([string]::IsNullOrWhiteSpace($Feature)) {
        throw "WORKFLOW_PARAMETER_MISSING: -Feature or -SpecDirectory is required for $Operation."
    }
    if ($null -eq $existingOwner) {
        throw "WORKFLOW_OWNER_NOT_FOUND"
    }
    if ($Operation -eq "Check") {
        if ([string]$existingOwner.status -eq "ACTIVE") {
            Write-Output "VALID"
            exit 0
        } else {
            throw "WORKFLOW_OWNER_NOT_ACTIVE: feature '$Feature' owner status is '$($existingOwner.status)'"
        }
    } else {
        $statusObj = [ordered]@{
            feature = [string]$existingOwner.feature
            status = [string]$existingOwner.status
            workflow = [string]$existingOwner.workflow
            agent = [string]$existingOwner.agent
            ownerId = [string]$existingOwner.ownerId
            specDirectory = [string]$existingOwner.specDirectory
            workspacePath = [string]$existingOwner.workspacePath
            startedAt = [string]$existingOwner.startedAt
            completedAt = [string]$existingOwner.completedAt
        }
        Write-Output (ConvertTo-AiSopWorkflowCanonicalJson $statusObj)
        exit 0
    }
}

# 8. Parameter validation for mutating/verifying operations
if ([string]::IsNullOrWhiteSpace($Feature)) {
    throw "WORKFLOW_PARAMETER_MISSING: -Feature or -SpecDirectory is required."
}
if ([string]::IsNullOrWhiteSpace($ResolvedSpecDirectory)) {
    throw "WORKFLOW_PARAMETER_MISSING: -SpecDirectory is required or could not be resolved for feature '$Feature'."
}
if ($Operation -eq "Claim" -and [string]::IsNullOrWhiteSpace($OwnerId)) {
    throw "WORKFLOW_PARAMETER_MISSING: -OwnerId is required for Claim."
}
if ($Operation -in @("Validate", "Complete", "BindSession", "RebindSession", "Transfer", "ForceRelease", "Recover", "Suspend", "Cancel", "Checkpoint") -and [string]::IsNullOrWhiteSpace($OwnerId)) {
    throw "WORKFLOW_PARAMETER_MISSING: -OwnerId could not be resolved for feature '$Feature'."
}

function Assert-NewOwnerPair {
    if (
        $Workflow -cne "SUPERPOWERS" -or
        $Agent -notin @("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR", "CODEX", "PI")
    ) {
        throw "WORKFLOW_OWNER_NEW_PRIVILEGE_DENIED"
    }
}

function Copy-WorkflowRecord {
    param([object]$Record)

    return ConvertFrom-AiSopWorkflowJson `
        -Json ($Record | ConvertTo-Json -Depth 50) `
        -AsHashtable
}

function New-OwnerTarget {
    param(
        [string]$Path,
        [ValidateSet("SESSION", "OWNER", "COMMAND_GRANT", "TASK")]
        [string]$Kind,
        [ValidateSet("SESSION", "OWNER", "COMMAND_GRANT", "TASK")]
        [string]$SchemaId,
        [object]$After,
        [bool]$BeforeExists,
        [AllowNull()]
        [object]$Before
    )

    return [pscustomobject][ordered]@{
        path = $Path
        kind = $Kind
        schemaId = $SchemaId
        afterJson = ConvertTo-AiSopWorkflowCanonicalJson $After
        expectedBeforeExists = $BeforeExists
        expectedBeforeJson = if ($BeforeExists) {
            ConvertTo-AiSopWorkflowCanonicalJson $Before
        } else {
            ""
        }
    }
}

function Get-ExactGrant {
    $ws = Get-OwnerWorkspacePath
    $sessionFilter = @{}
    if ($TaskId -or $existingOwner.taskId) {
        # Task calls must not borrow a matching intent grant left by another
        # session. Legacy hook-only callers retain their explicit grant protocol.
        $sessionFilter.SessionKey = Get-AiSopWorkflowSessionKey -Agent $Agent -NativeSessionId (Get-AiSopInvocationSessionId $Agent) -WorkspacePath $ws
    }
    try {
        return Invoke-AiSopWorkflowCommandGrant `
            -Operation Find `
            -GrantOperation $Operation `
            -SpecDirectory $ResolvedSpecDirectory `
            -Feature $Feature `
            -Workflow $Workflow `
            -Agent $Agent `
            -OwnerId $OwnerId `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $WorkflowDeadlineUtc `
            -WorkspacePath $ws @sessionFilter
    } catch {
        if ($_.Exception.Message -ne "COMMAND_GRANT_NOT_FOUND") {
            throw
        }
        # Direct execution fallback (auto-bootstrap session & grant)
        if (
            [string]::IsNullOrWhiteSpace($Feature) -or
            [string]::IsNullOrWhiteSpace($Agent) -or
            [string]::IsNullOrWhiteSpace($Workflow) -or
            [string]::IsNullOrWhiteSpace($ResolvedSpecDirectory)
        ) {
            throw "COMMAND_GRANT_NOT_FOUND"
        }
        $nativeSessionId = Get-AiSopInvocationSessionId $Agent
        $invokingSessionKey = Get-AiSopWorkflowSessionKey -Agent $Agent -NativeSessionId $nativeSessionId -WorkspacePath $ws

        $currentOwner = Read-Owner -AllowMissing
        $sessionToUse = $null
        if (
            $Operation -in @("Validate", "Complete", "Suspend", "Cancel", "Checkpoint") -and
            $null -ne $currentOwner -and
            [string]$currentOwner.schemaVersion -eq "1.1" -and
            $null -ne $currentOwner.sessionBinding
        ) {
            $boundKey = [string]$currentOwner.sessionBinding.sessionKey
            if ($boundKey -cne $invokingSessionKey) { throw 'WORKFLOW_OWNER_SESSION_MISMATCH: Resume explicitly before writing from a different session' }
            try {
                $existingSession = Get-AiSopWorkflowSession `
                    -SessionKey $boundKey `
                    -AcceptedAt $AcceptedAt `
                    -DeadlineUtc $WorkflowDeadlineUtc `
                    -WorkspacePath $ws
                if (
                    $existingSession.EffectiveStatus -eq "ACTIVE" -and
                    [string]$existingSession.Record.agent -eq $Agent -and
                    ([string]$existingSession.Record.workspacePath).Equals($ws, [System.StringComparison]::OrdinalIgnoreCase)
                ) {
                    $sessionToUse = $existingSession
                }
            } catch {
                $sessionToUse = $null
            }
        }

        if ($null -eq $sessionToUse) {
            $sessionToUse = Invoke-AiSopWorkflowSession `
                -Operation Register `
                -Agent $Agent `
                -NativeSessionId $nativeSessionId `
                -WorkspacePath $ws `
                -LifecycleProof CONFIRMED `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $WorkflowDeadlineUtc
        }

        $canonicalCmd = "pwsh -NoProfile -File '.\.ai-sop\scripts\workflow-owner.ps1' -Operation '$Operation' -SpecDirectory '$ResolvedSpecDirectory' -Feature '$Feature' -Workflow '$Workflow' -Agent '$Agent' -OwnerId '$OwnerId'"
        $dedupKey = Get-AiSopWorkflowSha256 ("auto-grant-" + [guid]::NewGuid().ToString("N"))
        $txId = "auto-" + [guid]::NewGuid().ToString("N")

        $newGrant = Invoke-AiSopWorkflowCommandGrant `
            -Operation Issue `
            -CommandText $canonicalCmd `
            -SessionKey ([string]$sessionToUse.Record.sessionKey) `
            -SessionEpochId ([string]$sessionToUse.Record.sessionEpochId) `
            -DedupKey $dedupKey `
            -AcceptedAt $AcceptedAt `
            -TransactionId $txId `
            -GrantTtlSeconds 300 `
            -DeadlineUtc $WorkflowDeadlineUtc `
            -WorkspacePath $ws

        Write-Verbose "[INFO] Direct execution detected; auto-bootstrapped CommandGrant for session $($sessionToUse.Record.sessionKey)"
        return $newGrant
    }
}

function Get-GrantSession {
    param([object]$Grant)

    $session = Get-AiSopWorkflowSession `
        -SessionKey ([string]$Grant.Record.sessionKey) `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $WorkflowDeadlineUtc `
        -WorkspacePath (Get-OwnerWorkspacePath)
    if (
        [string]$session.Record.agent -cne $Agent -or
        -not ([string]$session.Record.workspacePath).Equals(
            (Get-OwnerWorkspacePath),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "SESSION_IDENTITY_MISMATCH"
    }
    return $session
}

function Assert-ActiveGrantSession {
    param(
        [object]$Grant,
        [object]$Session,
        [switch]$RequireUnbound
    )

    if (
        [string]$Session.EffectiveStatus -cne "ACTIVE" -or
        [string]$Session.Record.lifecycleProof -cne "CONFIRMED" -or
        [string]$Session.Record.sessionEpochId -cne
            [string]$Grant.Record.sessionEpochId
    ) {
        throw "SESSION_INACTIVE"
    }
    if (
        $RequireUnbound -and
        -not [string]::IsNullOrEmpty([string]$Session.Record.boundFeature)
    ) {
        throw "SESSION_ALREADY_BOUND"
    }
}

function Set-SessionBoundTuple {
    param(
        [System.Collections.IDictionary]$Session,
        [string]$SessionEpochId,
        [string]$TransactionId
    )

    $Session.boundFeature = $Feature
    $Session.boundWorkflow = "SUPERPOWERS"
    $Session.boundOwnerId = $OwnerId
    $Session.boundSessionEpochId = $SessionEpochId
    $Session.lastTransactionId = $TransactionId
}

function Clear-SessionBoundTuple {
    param(
        [System.Collections.IDictionary]$Session,
        [string]$TransactionId
    )

    $Session.boundFeature = ""
    $Session.boundWorkflow = ""
    $Session.boundOwnerId = ""
    $Session.boundSessionEpochId = ""
    $Session.lastTransactionId = $TransactionId
}

function Invoke-OwnerPausePoint {
    param([string]$Point)

    if ([string]$env:SERVER_NEW_WORKFLOW_OWNER_PAUSE_POINT -cne $Point) {
        return
    }
    $marker = [string]$env:SERVER_NEW_WORKFLOW_OWNER_PAUSE_MARKER
    $release = [string]$env:SERVER_NEW_WORKFLOW_OWNER_PAUSE_RELEASE
    if ([string]::IsNullOrWhiteSpace($marker) -or [string]::IsNullOrWhiteSpace($release)) {
        throw "WORKFLOW_OWNER_PAUSE_CONFIGURATION_INVALID"
    }
    [System.IO.Directory]::CreateDirectory(
        [System.IO.Path]::GetDirectoryName($marker)
    ) | Out-Null
    [System.IO.File]::WriteAllText($marker, $Point)
    while (-not [System.IO.File]::Exists($release)) {
        Assert-AiSopWorkflowDeadline $WorkflowDeadlineUtc
        Start-Sleep -Milliseconds 5
    }
}

function Invoke-LegacyOwnerOperation {
    param([System.Collections.IDictionary]$Owner)

    Assert-OwnerIdentity $Owner
    if ($Operation -eq "Validate") {
        if ([string]$Owner.status -ne "ACTIVE") {
            throw "WORKFLOW_OWNER_NOT_ACTIVE"
        }
        Write-Output "VALID"
        return
    }
    if ($Operation -ne "Complete") {
        throw "WORKFLOW_OWNER_LEGACY_OPERATION_DENIED"
    }
    if ([string]$Owner.status -eq "COMPLETE") {
        Write-OwnerMirror $Owner
        Write-Output $OwnerPath
        return
    }
    if ([string]$Owner.status -ne "ACTIVE") {
        throw "WORKFLOW_OWNER_NOT_ACTIVE"
    }
    $after = Copy-WorkflowRecord $Owner
    $after.status = "COMPLETE"
    $after.completedAt = $AcceptedAt.ToUniversalTime().ToString("o")
    $transactionId = "legacy-complete-$([guid]::NewGuid().ToString('N'))"
    $target = New-OwnerTarget `
        -Path $OwnerPath `
        -Kind OWNER `
        -SchemaId OWNER `
        -After $after `
        -BeforeExists $true `
        -Before $Owner
    Invoke-AiSopWorkflowTransaction `
        -Operation COMPLETE `
        -Feature $Feature `
        -OwnerPath $OwnerPath `
        -SessionKeys @() `
        -Targets @($target) `
        -TransactionId $transactionId `
        -DeadlineUtc $WorkflowDeadlineUtc `
        -WorkspacePath $ownerWs |
        Out-Null
    Write-OwnerMirror $after
    Write-Output $OwnerPath
}

function Invoke-OwnerValidate11 {
    param(
        [System.Collections.IDictionary]$Owner,
        [object]$Grant,
        [object]$Session
    )

    Assert-OwnerIdentity $Owner
    if (
        [string]$Owner.status -ne "ACTIVE" -or
        [string]$Session.EffectiveStatus -ne "ACTIVE" -or
        [string]$Session.Record.lifecycleProof -ne "CONFIRMED" -or
        [string]$Owner.sessionBinding.sessionKey -cne
            [string]$Grant.Record.sessionKey -or
        [string]$Owner.sessionBinding.sessionEpochId -cne
            [string]$Grant.Record.sessionEpochId -or
        [string]$Session.Record.sessionEpochId -cne
            [string]$Grant.Record.sessionEpochId -or
        [string]$Session.Record.boundFeature -cne $Feature -or
        [string]$Session.Record.boundWorkflow -cne $Workflow -or
        [string]$Session.Record.boundOwnerId -cne $OwnerId -or
        [string]$Session.Record.boundSessionEpochId -cne
            [string]$Grant.Record.sessionEpochId
    ) {
        throw "WORKFLOW_OWNER_SESSION_MISMATCH"
    }

    $grantTargets = @(
        [pscustomobject]@{
            kind = "COMMAND_GRANT"
            path = $Grant.GrantPath
        },
        [pscustomobject]@{
            kind = "COMMAND_GRANT"
            path = Get-AiSopWorkflowCommandGrantActiveIndexPath (
                [string]$Grant.Record.intentSha256
            )
        },
        [pscustomobject]@{
            kind = "COMMAND_GRANT"
            path = Get-AiSopWorkflowCommandGrantSessionIndexPath `
                -SessionKey ([string]$Grant.Record.sessionKey) `
                -SessionEpochId ([string]$Grant.Record.sessionEpochId)
        }
    )
    Invoke-OwnerPausePoint -Point "BEFORE_VALIDATE_FINAL_LOCK"
    $lockResult = Enter-AiSopWorkflowTransactionLocks `
        -SessionKeys @([string]$Grant.Record.sessionKey) `
        -OwnerPath $OwnerPath `
        -Targets $grantTargets `
        -DeadlineUtc $WorkflowDeadlineUtc `
        -WorkspacePath $ownerWs
    try {
        $lockedOwner = Read-Owner
        Assert-OwnerIdentity $lockedOwner
        $lockedSession = Read-AiSopWorkflowSessionRecord `
            -SessionPath $Session.SessionPath `
            -ExpectedSessionKey ([string]$Grant.Record.sessionKey)
        $lockedGrant = Read-AiSopWorkflowCommandGrantRecord `
            -GrantPath $Grant.GrantPath `
            -ExpectedGrantId ([string]$Grant.Record.grantId)
        $sessionExpiresAt = [DateTimeOffset]::Parse(
            [string]$lockedSession.expiresAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $grantExpiresAt = [DateTimeOffset]::Parse(
            [string]$lockedGrant.expiresAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $lockedNow = [DateTimeOffset]::UtcNow
        if (
            [string]$lockedOwner.schemaVersion -cne "1.1" -or
            [string]$lockedOwner.status -ne "ACTIVE" -or
            -not ([string]$lockedOwner.workspacePath).Equals(
                (Get-OwnerWorkspacePath),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            [string]$lockedGrant.status -ne "ISSUED" -or
            $lockedNow -ge $grantExpiresAt -or
            [string]$lockedGrant.sessionKey -cne
                [string]$lockedSession.sessionKey -or
            [string]$lockedGrant.sessionEpochId -cne
                [string]$lockedSession.sessionEpochId -or
            [string]$lockedGrant.operation -cne "Validate" -or
            [string]$lockedGrant.feature -cne $Feature -or
            [string]$lockedGrant.workflow -cne $Workflow -or
            [string]$lockedGrant.agent -cne $Agent -or
            [string]$lockedGrant.ownerId -cne $OwnerId -or
            [string]$lockedSession.status -cne "ACTIVE" -or
            [string]$lockedSession.lifecycleProof -cne "CONFIRMED" -or
            -not [string]::IsNullOrEmpty([string]$lockedSession.endedAt) -or
            $lockedNow -ge $sessionExpiresAt -or
            [string]$lockedSession.agent -cne $Agent -or
            -not ([string]$lockedSession.workspacePath).Equals(
                (Get-OwnerWorkspacePath),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            [string]$lockedOwner.sessionBinding.sessionKey -cne
                [string]$lockedSession.sessionKey -or
            [string]$lockedOwner.sessionBinding.sessionEpochId -cne
                [string]$lockedSession.sessionEpochId -or
            [string]$lockedSession.boundFeature -cne $Feature -or
            [string]$lockedSession.boundWorkflow -cne $Workflow -or
            [string]$lockedSession.boundOwnerId -cne $OwnerId -or
            [string]$lockedSession.boundSessionEpochId -cne
                [string]$lockedSession.sessionEpochId
        ) {
            throw "WORKFLOW_OWNER_SESSION_MISMATCH"
        }
        $transactionId = "validate-$([guid]::NewGuid().ToString('N'))"
        $grantAfter = New-AiSopWorkflowCommandGrantAfterConsume `
            -Grant $lockedGrant `
            -AcceptedAt $AcceptedAt `
            -TransactionId $transactionId
        $targets = @(
            New-OwnerTarget `
                -Path $Session.SessionPath `
                -Kind SESSION `
                -SchemaId SESSION `
                -After $lockedSession `
                -BeforeExists $true `
                -Before $lockedSession
            New-OwnerTarget `
                -Path $OwnerPath `
                -Kind OWNER `
                -SchemaId OWNER `
                -After $lockedOwner `
                -BeforeExists $true `
                -Before $lockedOwner
            New-OwnerTarget `
                -Path $Grant.GrantPath `
                -Kind COMMAND_GRANT `
                -SchemaId COMMAND_GRANT `
                -After $grantAfter `
                -BeforeExists $true `
                -Before $lockedGrant
        )
        foreach ($transition in @(
            Get-AiSopWorkflowCommandGrantIndexTransitions `
                -Grant $lockedGrant `
                -Active $false
        )) {
            $targets += New-OwnerTarget `
                -Path $transition.Path `
                -Kind COMMAND_GRANT `
                -SchemaId COMMAND_GRANT `
                -After $transition.After `
                -BeforeExists $true `
                -Before $transition.Before
        }
        Invoke-AiSopWorkflowTransaction `
            -Operation VALIDATE `
            -Feature $Feature `
            -OwnerPath $OwnerPath `
            -SessionKeys @([string]$lockedSession.sessionKey) `
            -Targets $targets `
            -TransactionId $transactionId `
            -DeadlineUtc $WorkflowDeadlineUtc `
            -LocksAlreadyHeld `
            -WorkspacePath $ownerWs |
            Out-Null
        Write-Output "VALID"
    } finally {
        Exit-AiSopWorkflowLocks $lockResult.Locks
    }
}

Assert-CanonicalSpecDirectory
Invoke-AiSopWorkflowTransactionRecovery `
    -DeadlineUtc $WorkflowDeadlineUtc `
    -WorkspacePath $ownerWs |
    Out-Null
$existingOwner = Read-Owner -AllowMissing

if (
    $null -ne $existingOwner -and
    [string]$existingOwner.schemaVersion -eq "1.0" -and
    $Operation -in @("Validate", "Complete")
) {
    Invoke-LegacyOwnerOperation $existingOwner
    exit 0
}

if ($Operation -in @("Claim", "BindSession", "RebindSession", "Transfer")) {
    Assert-NewOwnerPair
}
if ($Operation -in @("Validate", "Complete", "Suspend", "Cancel", "Checkpoint") -and $null -eq $existingOwner) {
    throw "WORKFLOW_OWNER_NOT_FOUND"
}

$transactionId = "$($Operation.ToLowerInvariant())-$([guid]::NewGuid().ToString('N'))"

# Recovery is an explicit repair, not a successful completion or an inherited
# permission. ForceRelease remains the compatibility spelling for forced repair.
if ($Operation -in @('ForceRelease','Recover')) {
    if ($QuarantineInvalidEvidence -and [string]::IsNullOrWhiteSpace($RecoveryReason)) { throw 'QUARANTINE_REASON_REQUIRED' }
    $quarantined=@()
    $forced = $ForceRecovery -or $Operation -eq 'ForceRelease'
    if ($Operation -eq 'ForceRelease' -and ($null -eq $existingOwner -or $existingOwner.status -ne 'ACTIVE')) { throw 'WORKFLOW_OWNER_NOT_ACTIVE' }
    if (-not $TaskId -and $existingOwner.taskId) { $TaskId = $existingOwner.taskId }
    if ($Operation -eq 'Recover' -and -not $TaskId) { throw 'TASK_REQUIRED' }
    $targets = @(); $sessionKeys = @(); $releasedOwner = $null
    $recoveryOwner = $existingOwner
    if ($existingOwner -and $existingOwner.status -ne 'ACTIVE' -and ($existingOwner.taskId -cne $TaskId -or $existingOwner.ownerId -cne $OwnerId)) {
        # Preserve unrelated historical ownership, but include a no-op CAS so a
        # concurrent new Claim cannot slip into recovery while locks are acquired.
        $targets += New-OwnerTarget -Path $OwnerPath -Kind OWNER -SchemaId OWNER -After $existingOwner -BeforeExists $true -Before $existingOwner
        $recoveryOwner = $null
    }
    if ($recoveryOwner) {
        if ($existingOwner.feature -cne $Feature -or $existingOwner.workflow -cne $Workflow -or
            $existingOwner.ownerId -cne $OwnerId -or $existingOwner.specDirectory -cne $ResolvedSpecDirectory -or
            ($TaskId -and $existingOwner.taskId -cne $TaskId)) { throw 'WORKFLOW_OWNER_IDENTITY_MISMATCH' }
        $releasedOwner = Copy-WorkflowRecord $existingOwner
        $releasedOwner.status = 'RELEASED'
        $releasedOwner.completedAt = $AcceptedAt.ToString('o')
        if ($releasedOwner.schemaVersion -eq '1.1') { $releasedOwner.lastTransactionId = $transactionId }
        $targets += New-OwnerTarget -Path $OwnerPath -Kind OWNER -SchemaId OWNER -After $releasedOwner -BeforeExists $true -Before $existingOwner
    }
    if ($TaskId) {
        $recoveryTaskPath = Get-AiSopTaskPath $ResolvedSpecDirectory $TaskId
        $recoveryTask = Read-AiSopTask $ResolvedSpecDirectory $TaskId
        if ($recoveryTask.ownerId -cne $OwnerId -or $recoveryTask.status -notin @('ACTIVE','PAUSED')) { throw 'TASK_NOT_RECOVERABLE' }
        $recoveredTask = Copy-WorkflowRecord $recoveryTask
        foreach ($run in @($recoveredTask.verifications | Where-Object { $_.outcome -eq 'RUNNING' })) {
            $activity = Get-AiSopRunActivity $run $ownerWs
            if ($activity -eq 'RUNNING') { throw 'RUN_STILL_ACTIVE: stop or wait for the verification process before recovery' }
            if ($activity -in @('REMOTE_UNKNOWN','UNCONFIRMED') -and -not $forced) { throw 'REMOTE_RUN_UNCONFIRMED: confirm original execution stopped, then use ForceRecovery' }
            $pendingPath = Get-AiSopRunEvidencePath $ResolvedSpecDirectory $TaskId $run.runId
            if ($activity -eq 'INTERRUPTED' -and [IO.File]::Exists($pendingPath)) {
                try {
                    $pendingResult = ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($pendingPath)) -AsHashtable
                    # Validate the entire task shape as well as execution identity.
                    $probe=Copy-WorkflowRecord $recoveryTask
                    $probe.verifications=@($pendingResult)
                    Assert-AiSopWorkflowJsonSchema -Json (ConvertTo-AiSopWorkflowCanonicalJson $probe) -SchemaId TASK
                    if ($pendingResult.outcome -eq 'RUNNING') {
                        if ((ConvertTo-AiSopWorkflowCanonicalJson $pendingResult) -cne (ConvertTo-AiSopWorkflowCanonicalJson $run)) { throw 'RUN_PENDING_IDENTITY_MISMATCH' }
                    } else {
                        Assert-AiSopRunEvidence -Evidence $pendingResult -Previous $run -Task $recoveryTask -WorkspacePath $ownerWs -Retry
                        $recoveredTask.verifications = @($recoveredTask.verifications | ForEach-Object { if ($_.runId -ceq $run.runId) { $pendingResult } else { $_ } })
                        continue
                    }
                } catch {
                    if (-not $QuarantineInvalidEvidence) { throw "PENDING_EVIDENCE_INVALID: $pendingPath; $($_.Exception.Message); inspect with Task InspectRecovery, then Recover -QuarantineInvalidEvidence -Reason if the result cannot be trusted" }
                    $quarantined += Save-AiSopInvalidEvidence $pendingPath $ownerWs $Feature $TaskId $run.runId $_.Exception.Message
                }
            }
            $run.outcome = 'INTERRUPTED'; $run.exitCode = -2; $run.inputsStable = $false
        }
        $recoveredTask.status = 'PAUSED'; $recoveredTask.updatedAt = $AcceptedAt.ToString('o')
        $recoveredTask['lastRecovery'] = @{ at=$AcceptedAt.ToString('o'); reason=$(if ($Notes) { $Notes } else { 'Explicit ownership recovery' }); forced=[bool]$forced }
        if ($quarantined.Count) { $recoveredTask.lastRecovery.quarantinedEvidence=$quarantined; $recoveredTask.lastRecovery.reason=$RecoveryReason }
        $targets += New-OwnerTarget -Path $recoveryTaskPath -Kind TASK -SchemaId TASK -After $recoveredTask -BeforeExists $true -Before $recoveryTask
    }
    # Include orphaned local session bindings even when the owner file was lost.
    foreach ($file in @(Get-ChildItem -LiteralPath (Get-AiSopWorkflowSessionRegistryRoot -WorkspacePath $ownerWs) -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        # An unrelated corrupt session must not block recovery of this task.
        # The owner's exact session, and any matching orphan, remain strict.
        if (-not $recoveryOwner.sessionBinding -or $file.BaseName -cne $recoveryOwner.sessionBinding.sessionKey) {
            try { $candidate = ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($file.FullName)) -AsHashtable } catch { continue }
            if ($candidate.workspacePath -cne $ownerWs -or $candidate.boundFeature -cne $Feature -or $candidate.boundOwnerId -cne $OwnerId) { continue }
        }
        $bound = Read-AiSopWorkflowSessionRecord -SessionPath $file.FullName
        if ($bound.workspacePath -cne $ownerWs -or $bound.boundFeature -cne $Feature -or $bound.boundOwnerId -cne $OwnerId) { continue }
        $effective = Get-AiSopWorkflowSessionEffectiveStatus -Record $bound -AcceptedAt $AcceptedAt
        if ($effective -in @('ACTIVE','IDLE') -and -not $forced) { throw 'SESSION_MAY_BE_ACTIVE: confirm handoff or use ForceRecovery after stopping the old agent' }
        $after = Copy-WorkflowRecord $bound
        Clear-SessionBoundTuple -Session $after -TransactionId $transactionId
        $targets += New-OwnerTarget -Path $file.FullName -Kind SESSION -SchemaId SESSION -After $after -BeforeExists $true -Before $bound
        $sessionKeys += $bound.sessionKey
    }
    $WorkflowDeadlineUtc = [DateTimeOffset]::UtcNow.AddMilliseconds($ownerDeadlineMs)
    if ($null -ne $DeadlineUtc -and $DeadlineUtc -lt $WorkflowDeadlineUtc) { $WorkflowDeadlineUtc = [DateTimeOffset]$DeadlineUtc }
    $recoveryLocks = Enter-AiSopWorkflowTransactionLocks -SessionKeys $sessionKeys -OwnerPath $OwnerPath -Targets $targets -DeadlineUtc $WorkflowDeadlineUtc -WorkspacePath $ownerWs
    try {
        # Absence is checked while holding the owner lock as well as task CAS.
        if (-not $existingOwner -and (Test-Path -LiteralPath $OwnerPath)) { throw 'WORKFLOW_TRANSACTION_PRECONDITION_FAILED' }
        Invoke-AiSopWorkflowTransaction -Operation RECOVER -Feature $Feature -OwnerPath $OwnerPath -SessionKeys $sessionKeys -Targets $targets -TransactionId $transactionId -DeadlineUtc $WorkflowDeadlineUtc -WorkspacePath $ownerWs -LocksAlreadyHeld | Out-Null
    } finally { Exit-AiSopWorkflowLocks $recoveryLocks.Locks }
    foreach ($entry in $quarantined) {
        $original=Resolve-AiSopWorkspaceChild $ownerWs $entry.originalPath
        $backup=Resolve-AiSopWorkspaceChild $ownerWs $entry.backupPath
        if ([IO.File]::Exists($original) -and [IO.File]::Exists($backup) -and
            (Get-FileHash -LiteralPath $original).Hash.ToLowerInvariant() -ceq $entry.sha256 -and
            (Get-FileHash -LiteralPath $backup).Hash.ToLowerInvariant() -ceq $entry.sha256) { Remove-Item -LiteralPath $original }
    }
    if ($releasedOwner) { Write-OwnerMirror $releasedOwner }
    Write-Output 'TASK_RECOVERED: paused; Resume establishes local execution ownership'
    exit 0
}

$grant = Get-ExactGrant
$session = Get-GrantSession $grant

if ($Operation -eq "Validate") {
    if ($TaskId -and $existingOwner.taskId -cne $TaskId) { throw "TASK_IDENTITY_MISMATCH" }
    if ([string]$existingOwner.schemaVersion -ne "1.1") {
        throw "WORKFLOW_OWNER_LEGACY_OPERATION_DENIED"
    }
    Invoke-OwnerValidate11 `
        -Owner $existingOwner `
        -Grant $grant `
        -Session $session
    exit 0
}

if ($Operation -ne 'Claim' -and $existingOwner.taskId) {
    if ($TaskId -and $TaskId -cne $existingOwner.taskId) { throw 'TASK_IDENTITY_MISMATCH' }
    $TaskId = [string]$existingOwner.taskId
}
$taskBefore = $null
$taskAfter = $null
$taskPath = $null
if ($TaskId) {
    $taskPath = Get-AiSopTaskPath $ResolvedSpecDirectory $TaskId
    if (Test-Path -LiteralPath $taskPath) {
        if ($CreateTaskOnly) { throw 'TASK_ALREADY_EXISTS: Start creates a new TaskId; use Resume to continue the existing task' }
        $taskBefore = Read-AiSopTask $ResolvedSpecDirectory $TaskId
        if ($taskBefore.ownerId -cne $OwnerId) { throw 'TASK_OWNER_MISMATCH' }
        if ($Operation -eq 'Claim' -and $taskBefore.status -ne 'PAUSED') { throw 'TASK_NOT_RESUMABLE' }
        if ($Operation -ne 'Claim' -and $taskBefore.status -ne 'ACTIVE') { throw 'TASK_NOT_ACTIVE' }
        $taskAfter = Copy-WorkflowRecord $taskBefore
        if ($PSBoundParameters.ContainsKey('Tier') -and $Tier -cne $taskBefore.tier) { throw 'TASK_TIER_CHANGE_REQUIRES_EXPLICIT_OPERATION: use Task ChangeTier with the human request' }
        $Tier = [string]$taskBefore.tier
    } elseif ($Operation -eq 'Transfer' -and -not $existingOwner.taskId -and $Objective) {
        $taskAfter = [ordered]@{
            schemaVersion='1.0'; taskId=$TaskId; feature=$Feature; ownerId=$OwnerId; tier=$Tier; objective=$Objective
            status='ACTIVE'; nextAction=$NextAction; notes=$Notes; createdAt=$AcceptedAt.ToString('o'); updatedAt=$AcceptedAt.ToString('o')
            requiredCaseIds=@(); verifications=@()
        }
    } elseif ($Operation -ne 'Claim') { throw 'TASK_NOT_FOUND' }
}
if ($taskBefore -and $Operation -notin @('Checkpoint')) {
    if (@($taskBefore.verifications | Where-Object { $_.outcome -eq 'RUNNING' }).Count) { throw 'RUN_UNFINISHED: inspect Status; wait for the run or Recover after it stops' }
}
if ($Operation -in @('Suspend','Cancel','Checkpoint') -and -not $taskPath) { throw 'TASK_REQUIRED: adopt legacy ownership using Resume first' }
$transactionId = "$($Operation.ToLowerInvariant())-$([guid]::NewGuid().ToString('N'))"
$grantAfter = New-AiSopWorkflowCommandGrantAfterConsume `
    -Grant $grant.Record `
    -AcceptedAt $AcceptedAt `
    -TransactionId $transactionId
$targets = @()
$sessionKeys = @()
$ownerAfter = $null

function Get-VcsBaselineRevision {
    param([string]$StartPath)
    if ([string]::IsNullOrWhiteSpace($StartPath)) { return $null }
    $cur = if (Test-Path -LiteralPath $StartPath -PathType Container) { [System.IO.Path]::GetFullPath($StartPath) } else { Split-Path -Parent ([System.IO.Path]::GetFullPath($StartPath)) }
    while (-not [string]::IsNullOrWhiteSpace($cur)) {
        if (Test-Path -LiteralPath (Join-Path $cur ".git")) {
            try {
                $headSha = (& git -C $cur rev-parse HEAD 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0 -and $headSha -match '^[0-9a-fA-F]{7,64}$') {
                    return $headSha
                }
            } catch {}
            break
        }
        if (Test-Path -LiteralPath (Join-Path $cur ".svn")) {
            try {
                $svnRev = (& svn info --show-item revision $cur 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0 -and $svnRev -match '^\d+$') {
                    return $svnRev
                }
                $svnInfo = (& svn info $cur 2>&1 | Out-String)
                if ($svnInfo -match '(?m)^Revision:\s*(\d+)') {
                    return $Matches[1]
                }
            } catch {}
            break
        }
        $parent = Split-Path -Parent $cur
        if ($parent -eq $cur) { break }
        $cur = $parent
    }
    return $null
}

function Get-GitTrunkForkPoint {
    param([AllowEmptyString()][AllowNull()][string]$WorkspacePath = $null)
    if ([string]::IsNullOrWhiteSpace($WorkspacePath)) { return $null }

    $trunkRefs = @("origin/main", "origin/master", "main", "master")
    foreach ($trunk in $trunkRefs) {
        & git -C $WorkspacePath rev-parse --verify --quiet "$trunk^{commit}" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $fp = (& git -C $WorkspacePath merge-base HEAD "$trunk" 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $fp -match '^[0-9a-fA-F]{40,64}$') {
                & git -C $WorkspacePath cat-file -e "$fp^{commit}" 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    return $fp
                }
            }
        }
    }
    return $null
}

function Resolve-AuthoritativeVcsBaseline {
    param(
        [AllowEmptyString()][AllowNull()][string]$WorkspacePath = $null,
        [AllowEmptyString()][AllowNull()][string]$ProposedBaseline = $null,
        [AllowEmptyString()][AllowNull()][string]$SpecDirectory = $null
    )
    if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
        $WorkspacePath = Get-OwnerWorkspacePath
    }
    if ([string]::IsNullOrWhiteSpace($WorkspacePath) -and -not [string]::IsNullOrWhiteSpace($SpecDirectory)) {
        $WorkspacePath = Resolve-AiSopWorkspaceRoot -StartPath $SpecDirectory
    }
    
    $isGit = -not [string]::IsNullOrWhiteSpace($WorkspacePath) -and (Test-Path -LiteralPath (Join-Path $WorkspacePath ".git"))
    $isSvn = -not [string]::IsNullOrWhiteSpace($WorkspacePath) -and (Test-Path -LiteralPath (Join-Path $WorkspacePath ".svn"))

    if ($isGit) {
        $forkPoint = Get-GitTrunkForkPoint -WorkspacePath $WorkspacePath

        if (-not [string]::IsNullOrWhiteSpace($ProposedBaseline)) {
            & git -C $WorkspacePath cat-file -e "$ProposedBaseline^{commit}" 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "INVALID_BASELINE: Git baseline commit '$ProposedBaseline' does not exist in repository '$WorkspacePath'."
            }
            & git -C $WorkspacePath merge-base --is-ancestor "$ProposedBaseline" HEAD 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "INVALID_BASELINE: Git baseline commit '$ProposedBaseline' is not an ancestor of current HEAD in '$WorkspacePath'."
            }
            if (-not [string]::IsNullOrWhiteSpace($forkPoint) -and $forkPoint.ToLowerInvariant() -ne $ProposedBaseline.ToLowerInvariant()) {
                & git -C $WorkspacePath merge-base --is-ancestor "$forkPoint" "$ProposedBaseline" 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    & git -C $WorkspacePath merge-base --is-ancestor "$ProposedBaseline" "$forkPoint" 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "BASELINE_MUTATION_DETECTED: Proposed baseline '$ProposedBaseline' is ahead of branch fork-point '$forkPoint'. Narrowing review scope is prohibited."
                    }
                }
            }
            return $ProposedBaseline
        }

        # Default path (no -Baseline passed): MUST resolve to the branch fork-point if available
        if (-not [string]::IsNullOrWhiteSpace($forkPoint)) {
            return $forkPoint
        }
        
        # Check if HEAD is the initial root commit (only commit in repo)
        $rootCommit = (& git -C $WorkspacePath rev-list --max-parents=0 HEAD 2>$null | Out-String).Trim()
        $headCommit = (& git -C $WorkspacePath rev-parse HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($rootCommit) -and $rootCommit.ToLowerInvariant() -eq $headCommit.ToLowerInvariant()) {
            return $rootCommit
        }

        throw "BASELINE_MISSING: Unable to resolve authoritative Git trunk fork-point in '$WorkspacePath'. A trunk branch (main/master) is required."
    }

    if ($isSvn) {
        if (-not [string]::IsNullOrWhiteSpace($ProposedBaseline)) {
            $svnNum = $ProposedBaseline -replace '^(?:rev|r)', ''
            if ($svnNum -notmatch '^\d+$') {
                throw "INVALID_BASELINE: Proposed SVN baseline '$ProposedBaseline' is not a valid revision number."
            }
            return $svnNum
        }
        $infoRev = (& svn info --non-interactive --show-item revision $WorkspacePath 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $infoRev -match '^\d+$') {
            return $infoRev
        }
        throw "SVN_INFO_FAILED: Unable to resolve SVN baseline revision in '$WorkspacePath'."
    }

    if (-not [string]::IsNullOrWhiteSpace($ProposedBaseline)) {
        return $ProposedBaseline
    }
    $vcsStartPath = if (-not [string]::IsNullOrWhiteSpace($SpecDirectory)) { $SpecDirectory } else { $WorkspacePath }
    $vcsRev = Get-VcsBaselineRevision -StartPath $vcsStartPath
    if (-not [string]::IsNullOrWhiteSpace($vcsRev)) {
        return $vcsRev
    }
    return "0"
}

switch ($Operation) {
    "Claim" {
        Assert-ActiveGrantSession -Grant $grant -Session $session -RequireUnbound
        if (
            $null -ne $existingOwner -and
            [string]$existingOwner.status -eq "ACTIVE"
        ) {
            throw "WORKFLOW_OWNER_ALREADY_ACTIVE"
        }
        $detectedBaseline = if ($null -ne $existingOwner -and -not [string]::IsNullOrWhiteSpace($existingOwner.baseline)) {
            if ($PSBoundParameters.ContainsKey("Baseline") -and -not [string]::IsNullOrWhiteSpace($Baseline) -and $Baseline.ToLowerInvariant() -ne $existingOwner.baseline.ToLowerInvariant()) {
                throw "BASELINE_MUTATION_DETECTED: Specified baseline '$Baseline' does not match existing owner baseline '$($existingOwner.baseline)'."
            }
            [string]$existingOwner.baseline
        } else {
            $passedBaseline = if ($PSBoundParameters.ContainsKey("Baseline") -and -not [string]::IsNullOrWhiteSpace($Baseline)) { $Baseline } else { $null }
            Resolve-AuthoritativeVcsBaseline -WorkspacePath (Get-OwnerWorkspacePath) -ProposedBaseline $passedBaseline -SpecDirectory $ResolvedSpecDirectory
        }
        if ($TaskId -and $null -eq $taskAfter) {
            if ([string]::IsNullOrWhiteSpace($Objective)) { throw "TASK_OBJECTIVE_REQUIRED" }
            $taskAfter = [ordered]@{
                schemaVersion = '1.0'; taskId = $TaskId; feature = $Feature; ownerId = $OwnerId
                tier = $Tier; objective = $Objective; status = 'ACTIVE'; nextAction = $NextAction; notes = $Notes
                createdAt = $AcceptedAt.ToString('o'); updatedAt = $AcceptedAt.ToString('o')
                requiredCaseIds = @(); verifications = @()
            }
        }
        $sessionAfter = Copy-WorkflowRecord $session.Record
        Set-SessionBoundTuple `
            -Session $sessionAfter `
            -SessionEpochId ([string]$grant.Record.sessionEpochId) `
            -TransactionId $transactionId
        $ownerAfter = [ordered]@{
            schemaVersion = "1.1"
            feature = $Feature
            workflow = "SUPERPOWERS"
            agent = $Agent
            ownerId = $OwnerId
            specDirectory = $ResolvedSpecDirectory
            workspacePath = Get-OwnerWorkspacePath
            status = "ACTIVE"
            startedAt = $AcceptedAt.ToUniversalTime().ToString("o")
            completedAt = ""
            sessionBinding = [ordered]@{
                sessionKey = [string]$grant.Record.sessionKey
                sessionEpochId = [string]$grant.Record.sessionEpochId
                boundAt = $AcceptedAt.ToUniversalTime().ToString("o")
            }
            lastTransactionId = $transactionId
        }
        if ($TaskId) { $ownerAfter["taskId"] = $TaskId }
        if (-not [string]::IsNullOrWhiteSpace($detectedBaseline)) {
            $ownerAfter["baseline"] = $detectedBaseline
        } else {
            $ownerAfter["baseline"] = "0"
        }
        $targets += New-OwnerTarget `
            -Path $session.SessionPath `
            -Kind SESSION `
            -SchemaId SESSION `
            -After $sessionAfter `
            -BeforeExists $true `
            -Before $session.Record
        $sessionKeys += [string]$grant.Record.sessionKey
    }
    "BindSession" {
        if (
            $null -eq $existingOwner -or
            [string]$existingOwner.schemaVersion -ne "1.0" -or
            [string]$existingOwner.status -ne "ACTIVE" -or
            [string]$existingOwner.workflow -ne "SUPERPOWERS"
        ) {
            throw "WORKFLOW_OWNER_BIND_DENIED"
        }
        Assert-OwnerIdentity $existingOwner
        Assert-ActiveGrantSession -Grant $grant -Session $session -RequireUnbound
        $sessionAfter = Copy-WorkflowRecord $session.Record
        Set-SessionBoundTuple `
            -Session $sessionAfter `
            -SessionEpochId ([string]$grant.Record.sessionEpochId) `
            -TransactionId $transactionId
        $ownerAfter = [ordered]@{
            schemaVersion = "1.1"
            feature = $Feature
            workflow = "SUPERPOWERS"
            agent = $Agent
            ownerId = $OwnerId
            specDirectory = $ResolvedSpecDirectory
            workspacePath = Get-OwnerWorkspacePath
            status = "ACTIVE"
            startedAt = [string]$existingOwner.startedAt
            completedAt = ""
            sessionBinding = [ordered]@{
                sessionKey = [string]$grant.Record.sessionKey
                sessionEpochId = [string]$grant.Record.sessionEpochId
                boundAt = $AcceptedAt.ToUniversalTime().ToString("o")
            }
            lastTransactionId = $transactionId
        }
        $detectedBaseline = if ($null -ne $existingOwner -and -not [string]::IsNullOrWhiteSpace($existingOwner.baseline)) {
            if ($PSBoundParameters.ContainsKey("Baseline") -and -not [string]::IsNullOrWhiteSpace($Baseline) -and $Baseline.ToLowerInvariant() -ne $existingOwner.baseline.ToLowerInvariant()) {
                throw "BASELINE_MUTATION_DETECTED: Specified baseline '$Baseline' does not match existing owner baseline '$($existingOwner.baseline)'."
            }
            [string]$existingOwner.baseline
        } else {
            $passedBaseline = if ($PSBoundParameters.ContainsKey("Baseline") -and -not [string]::IsNullOrWhiteSpace($Baseline)) { $Baseline } else { $null }
            Resolve-AuthoritativeVcsBaseline -WorkspacePath (Get-OwnerWorkspacePath) -ProposedBaseline $passedBaseline -SpecDirectory $ResolvedSpecDirectory
        }
        if (-not [string]::IsNullOrWhiteSpace($detectedBaseline)) {
            $ownerAfter["baseline"] = $detectedBaseline
        } else {
            $ownerAfter["baseline"] = "0"
        }
        $targets += New-OwnerTarget `
            -Path $session.SessionPath `
            -Kind SESSION `
            -SchemaId SESSION `
            -After $sessionAfter `
            -BeforeExists $true `
            -Before $session.Record
        $sessionKeys += [string]$grant.Record.sessionKey
    }
    "RebindSession" {
        if (
            $null -eq $existingOwner -or
            [string]$existingOwner.schemaVersion -ne "1.1" -or
            [string]$existingOwner.status -ne "ACTIVE"
        ) {
            throw "WORKFLOW_OWNER_REBIND_DENIED"
        }
        Assert-OwnerIdentity $existingOwner
        $oldSession = Get-AiSopWorkflowSession `
            -SessionKey ([string]$existingOwner.sessionBinding.sessionKey) `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $WorkflowDeadlineUtc `
            -WorkspacePath (Get-OwnerWorkspacePath)
        if (
            [string]$oldSession.Record.sessionEpochId -cne
                [string]$existingOwner.sessionBinding.sessionEpochId -or
            [string]$oldSession.Record.boundFeature -cne
                [string]$existingOwner.feature -or
            [string]$oldSession.Record.boundWorkflow -cne
                [string]$existingOwner.workflow -or
            [string]$oldSession.Record.boundOwnerId -cne
                [string]$existingOwner.ownerId -or
            [string]$oldSession.Record.boundSessionEpochId -cne
                [string]$existingOwner.sessionBinding.sessionEpochId -or
            [string]$oldSession.EffectiveStatus -notin @("ENDED", "EXPIRED")
        ) {
            throw "WORKFLOW_OWNER_REBIND_DENIED"
        }

        if (
            [string]$oldSession.Record.sessionKey -ceq
                [string]$session.Record.sessionKey
        ) {
            if (
                [string]$oldSession.EffectiveStatus -notin @("ENDED", "EXPIRED") -or
                [string]$grant.Record.sessionEpochId -ceq
                    [string]$oldSession.Record.sessionEpochId
            ) {
                throw "WORKFLOW_OWNER_REBIND_DENIED"
            }
            $newSessionAfter = Copy-WorkflowRecord $oldSession.Record
            $newSessionAfter.sessionEpochId =
                [string]$grant.Record.sessionEpochId
            $newSessionAfter.lifecycleProof = "CONFIRMED"
            $newSessionAfter.status = "ACTIVE"
            $newSessionAfter.firstSeenAt =
                $AcceptedAt.ToUniversalTime().ToString("o")
            $newSessionAfter.lastSeenAt =
                $AcceptedAt.ToUniversalTime().ToString("o")
            $newSessionAfter.stateChangedAt =
                $AcceptedAt.ToUniversalTime().ToString("o")
            $newSessionAfter.expiresAt =
                $AcceptedAt.AddMinutes(30).ToUniversalTime().ToString("o")
            $newSessionAfter.endedAt = ""
            Set-SessionBoundTuple `
                -Session $newSessionAfter `
                -SessionEpochId ([string]$grant.Record.sessionEpochId) `
                -TransactionId $transactionId
            $targets += New-OwnerTarget `
                -Path $oldSession.SessionPath `
                -Kind SESSION `
                -SchemaId SESSION `
                -After $newSessionAfter `
                -BeforeExists $true `
                -Before $oldSession.Record
            $sessionKeys += [string]$oldSession.Record.sessionKey
        } else {
            Assert-ActiveGrantSession `
                -Grant $grant `
                -Session $session `
                -RequireUnbound
            $oldSessionAfter = Copy-WorkflowRecord $oldSession.Record
            Clear-SessionBoundTuple `
                -Session $oldSessionAfter `
                -TransactionId $transactionId
            $newSessionAfter = Copy-WorkflowRecord $session.Record
            Set-SessionBoundTuple `
                -Session $newSessionAfter `
                -SessionEpochId ([string]$grant.Record.sessionEpochId) `
                -TransactionId $transactionId
            $targets += New-OwnerTarget `
                -Path $oldSession.SessionPath `
                -Kind SESSION `
                -SchemaId SESSION `
                -After $oldSessionAfter `
                -BeforeExists $true `
                -Before $oldSession.Record
            $targets += New-OwnerTarget `
                -Path $session.SessionPath `
                -Kind SESSION `
                -SchemaId SESSION `
                -After $newSessionAfter `
                -BeforeExists $true `
                -Before $session.Record
            $sessionKeys += @(
                [string]$oldSession.Record.sessionKey,
                [string]$session.Record.sessionKey
            )
        }
        $ownerAfter = Copy-WorkflowRecord $existingOwner
        $ownerAfter.sessionBinding.sessionKey =
            [string]$grant.Record.sessionKey
        $ownerAfter.sessionBinding.sessionEpochId =
            [string]$grant.Record.sessionEpochId
        $ownerAfter.sessionBinding.boundAt =
            $AcceptedAt.ToUniversalTime().ToString("o")
        $ownerAfter.lastTransactionId = $transactionId
    }
    { $_ -in @("Complete", "Suspend", "Cancel", "Checkpoint") } {
        if (
            [string]$existingOwner.schemaVersion -ne "1.1" -or
            [string]$existingOwner.status -ne "ACTIVE"
        ) {
            throw "WORKFLOW_OWNER_NOT_ACTIVE"
        }
        Assert-OwnerIdentity $existingOwner
        Assert-ActiveGrantSession -Grant $grant -Session $session
        if (
            [string]$existingOwner.sessionBinding.sessionKey -cne
                [string]$session.Record.sessionKey -or
            [string]$existingOwner.sessionBinding.sessionEpochId -cne
                [string]$session.Record.sessionEpochId -or
            [string]$session.Record.boundFeature -cne $Feature -or
            [string]$session.Record.boundOwnerId -cne $OwnerId
        ) {
            throw "WORKFLOW_OWNER_SESSION_MISMATCH"
        }

        # Verify completion before releasing ownership. Production ignores
        # AI_SOP_SKIP_COMPLETION_VERIFY unless AI_SOP_TEST_HOOKS=1 (test suites only).
        $skipRequested = ($env:AI_SOP_SKIP_COMPLETION_VERIFY -eq "1" -or $env:AI_SOP_SKIP_COMPLETION_VERIFY -eq "true")
        $testHooks = ($env:AI_SOP_TEST_HOOKS -eq "1" -or $env:AI_SOP_TEST_HOOKS -eq "true")
        $skipVerify = $skipRequested -and $testHooks
        if (-not $skipVerify -and $Operation -eq "Complete") {
            $stateScript = Join-Path $PSScriptRoot "workflow-state.ps1"
            if (Test-Path -LiteralPath $stateScript -PathType Leaf) {
                $workflowStatePath = Join-Path $ResolvedSpecDirectory "00_workflow_state.json"
                if (-not (Test-Path -LiteralPath $workflowStatePath -PathType Leaf)) {
                    $workflowStatePath = Join-Path $ResolvedSpecDirectory "workflow-state.json"
                }
                $verifyArgs = @{}
                if ($TaskId) { $verifyArgs.TaskId = $TaskId }
                $verifyOutput = & $stateScript -Operation VerifyCompletion -Path $workflowStatePath @verifyArgs 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $verifyMsg = ($verifyOutput | Out-String).Trim()
                    throw "WORKFLOW_COMPLETION_VERIFICATION_FAILED: Cannot Complete owner lock because VerifyCompletion failed.`n$verifyMsg"
                }
            }
        }

        $sessionAfter = Copy-WorkflowRecord $session.Record
        if ($Operation -ne 'Checkpoint') {
            Clear-SessionBoundTuple -Session $sessionAfter -TransactionId $transactionId
        } else {
            # A checkpoint renews only the already validated session/epoch. The
            # session CAS in the transaction fences End, Transfer and recovery.
            [void](Set-AiSopWorkflowSessionHeartbeat -Record $sessionAfter -AcceptedAt $AcceptedAt)
        }
        $ownerAfter = Copy-WorkflowRecord $existingOwner
        $ownerAfter.status = if ($Operation -eq 'Complete') { 'COMPLETE' } elseif ($Operation -eq 'Checkpoint') { 'ACTIVE' } else { 'RELEASED' }
        $ownerAfter.completedAt = if ($Operation -eq "Checkpoint") { "" } else { $AcceptedAt.ToUniversalTime().ToString("o") }
        $ownerAfter.lastTransactionId = $transactionId
        $targets += New-OwnerTarget `
            -Path $session.SessionPath `
            -Kind SESSION `
            -SchemaId SESSION `
            -After $sessionAfter `
            -BeforeExists $true `
            -Before $session.Record
        $sessionKeys += [string]$session.Record.sessionKey
    }
    "Transfer" {
        if (
            $null -eq $existingOwner -or
            [string]$existingOwner.schemaVersion -ne "1.1" -or
            [string]$existingOwner.status -ne "ACTIVE"
        ) {
            throw "WORKFLOW_OWNER_NOT_ACTIVE"
        }
        # Verify identity EXCEPT agent (Transfer intentionally changes agent).
        if (
            [string]$existingOwner.feature -cne $Feature -or
            [string]$existingOwner.workflow -cne $Workflow -or
            [string]$existingOwner.ownerId -cne $OwnerId -or
            -not ([string]$existingOwner.specDirectory).Equals(
                $ResolvedSpecDirectory,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            -not ([string]$existingOwner.workspacePath).Equals(
                (Get-OwnerWorkspacePath),
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw "WORKFLOW_OWNER_IDENTITY_MISMATCH"
        }
        if ($existingOwner.sessionBinding.sessionKey -cne $session.Record.sessionKey) {
            $oldSessionPath = Get-AiSopWorkflowSessionPath -SessionKey $existingOwner.sessionBinding.sessionKey -WorkspacePath (Get-OwnerWorkspacePath)
            if (Test-Path -LiteralPath $oldSessionPath) {
                $oldRecord = Read-AiSopWorkflowSessionRecord -SessionPath $oldSessionPath -ExpectedSessionKey $existingOwner.sessionBinding.sessionKey
                if ((Get-AiSopWorkflowSessionEffectiveStatus -Record $oldRecord -AcceptedAt $AcceptedAt) -in @('ACTIVE','IDLE') -and -not $ConfirmTakeover) {
                    throw 'SESSION_MAY_BE_ACTIVE: intentional handoff requires -ConfirmTakeover after confirming the old agent stopped'
                }
                if ($oldRecord.boundOwnerId -ceq $OwnerId -and $oldRecord.boundFeature -ceq $Feature) {
                    $oldAfter = Copy-WorkflowRecord $oldRecord
                    Clear-SessionBoundTuple -Session $oldAfter -TransactionId $transactionId
                    $targets += New-OwnerTarget -Path $oldSessionPath -Kind SESSION -SchemaId SESSION -After $oldAfter -BeforeExists $true -Before $oldRecord
                    $sessionKeys += $oldRecord.sessionKey
                }
            }
        }
        # Reuse the immutable ownerId. Same-session legacy adoption is allowed
        # only when the existing session is already bound to this exact owner.
        $sameTransferSession = $existingOwner.sessionBinding.sessionKey -ceq $session.Record.sessionKey
        if ($sameTransferSession -and ($session.Record.boundFeature -cne $Feature -or $session.Record.boundOwnerId -cne $OwnerId -or $session.Record.boundSessionEpochId -cne $session.Record.sessionEpochId)) { throw 'WORKFLOW_OWNER_SESSION_MISMATCH' }
        Assert-ActiveGrantSession -Grant $grant -Session $session -RequireUnbound:(-not $sameTransferSession)
        $sessionAfter = Copy-WorkflowRecord $session.Record
        Set-SessionBoundTuple `
            -Session $sessionAfter `
            -SessionEpochId ([string]$grant.Record.sessionEpochId) `
            -TransactionId $transactionId
        $ownerAfter = Copy-WorkflowRecord $existingOwner
        $ownerAfter.agent = $Agent
        if ($TaskId) { $ownerAfter["taskId"] = $TaskId }
        $ownerAfter.sessionBinding.sessionKey =
            [string]$grant.Record.sessionKey
        $ownerAfter.sessionBinding.sessionEpochId =
            [string]$grant.Record.sessionEpochId
        $ownerAfter.sessionBinding.boundAt =
            $AcceptedAt.ToUniversalTime().ToString("o")
        $ownerAfter.lastTransactionId = $transactionId
        $targets += New-OwnerTarget `
            -Path $session.SessionPath `
            -Kind SESSION `
            -SchemaId SESSION `
            -After $sessionAfter `
            -BeforeExists $true `
            -Before $session.Record
        $sessionKeys += [string]$session.Record.sessionKey
    }
}

if ($null -ne $taskAfter) {
    $taskAfter.status = switch ($Operation) { 'Complete' { 'DONE' } 'Suspend' { 'PAUSED' } 'Cancel' { 'CANCELLED' } default { 'ACTIVE' } }
    $taskAfter.updatedAt = $AcceptedAt.ToString('o')
    if ($PSBoundParameters.ContainsKey('NextAction')) { $taskAfter.nextAction = $NextAction }
    if ($PSBoundParameters.ContainsKey('Notes')) { $taskAfter.notes = $Notes }
    if ($Operation -eq 'Transfer' -and $ConfirmTakeover) {
        $taskAfter.notes = ($taskAfter.notes + "`nConfirmed takeover at $($AcceptedAt.ToString('o')); session=$($session.Record.sessionKey)").Trim()
    }
    if (-not $taskBefore -and -not $taskAfter.baseline) {
        Initialize-AiSopTaskStart -Task $taskAfter -WorkspacePath $ownerWs -TransactionId $transactionId -NewStart:($Operation -eq 'Claim') -CaptureBaseline:$CaptureBaseline
    }
    if ($TaskUpdateJson) {
        if ($Operation -ne 'Checkpoint' -or $EvidencePath -or $ImpactReviewed) { throw 'TASK_UPDATE_REQUIRES_SEPARATE_CHECKPOINT' }
        $policyUpdate = ConvertFrom-AiSopWorkflowJson $TaskUpdateJson -AsHashtable
        $related = Update-AiSopTaskPolicy -Task $taskAfter -Update $policyUpdate -SpecDirectory $ResolvedSpecDirectory -WorkspacePath $ownerWs -At $AcceptedAt.ToString('o')
        if ($related) { $targets += New-OwnerTarget -Path $related.path -Kind TASK -SchemaId TASK -After $related.after -BeforeExists $true -Before $related.before }
    }
    $taskChanges=$null
    if ($ImpactReviewed) {
        if ($Operation -ne 'Checkpoint') { throw 'IMPACT_REQUIRES_CHECKPOINT' }
        $impactPath = Join-Path $ResolvedSpecDirectory '04_change_impact.json'
        if (-not [IO.File]::Exists($impactPath)) { throw "IMPACT_ARTIFACT_MISSING: $impactPath; write and review the impact analysis before ReviewImpact" }
        $impactRaw = Get-Content -LiteralPath $impactPath -Raw
        if (-not ($impactRaw | Test-Json -SchemaFile (Join-Path $ClaudeRoot 'schemas/change-impact.schema.json'))) { throw 'IMPACT_SCHEMA_INVALID' }
        $taskChanges=$null
        if ($taskAfter.tier -eq 'T3') {
            $impact=ConvertFrom-AiSopWorkflowJson $impactRaw -AsHashtable
            $taskChanges=Assert-AiSopTaskImpactBinding $taskAfter $impact $ownerWs
            Save-AiSopTaskChangeManifest $taskChanges $ownerWs | Out-Null
        }
        $taskAfter['impactReview'] = @{
            artifactHash=(Get-AiSopImpactArtifactHash $impactPath 'sha256-text-lf-v1')
            hashAlgorithm='sha256-text-lf-v1'
            inputDigest=$(if ($taskChanges) { $taskChanges.inputDigest } else { (Get-AiSopInputSnapshot (Get-OwnerWorkspacePath)).digest })
            reviewedAt=$AcceptedAt.ToString('o')
        }
    }
    if ($taskChanges) { $taskAfter.impactReview.changeSetDigest=$taskChanges.changeSetDigest }
    if ($EvidencePath) {
        if ($Operation -ne 'Checkpoint') { throw 'EVIDENCE_REQUIRES_CHECKPOINT' }
        $evidence = ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($EvidencePath)) -AsHashtable
        $expectedEvidencePath = Get-AiSopRunEvidencePath $ResolvedSpecDirectory $TaskId $evidence.runId
        if ((Resolve-PhysicalPathIdentity $EvidencePath) -cne $expectedEvidencePath) { throw 'EVIDENCE_PATH_INVALID: use the run pending result in its task directory' }
        $pending = @($taskAfter.verifications | Where-Object { $_.outcome -eq 'RUNNING' })
        $matches = @($taskAfter.verifications | Where-Object { $evidence.runId -and $_.runId -ceq $evidence.runId })
        if ($matches.Count -gt 1) { throw 'RUN_IDENTITY_MISMATCH' }
        $previous = if ($matches.Count) { $matches[0] } else { $null }
        Assert-AiSopRunEvidence -Evidence $evidence -Previous $previous -Task $taskAfter -WorkspacePath $ownerWs -SessionBinding $existingOwner.sessionBinding -Retry:$RetryEvidence
        if ($matches.Count) {
            $taskAfter.verifications = @($taskAfter.verifications | ForEach-Object { if ($_.runId -ceq $evidence.runId) { $evidence } else { $_ } })
        } else {
            if ($pending.Count) { throw 'RUN_UNFINISHED: only one verification may run per task' }
            $taskAfter.verifications = @($taskAfter.verifications) + @($evidence)
        }
    }
    $targets += New-OwnerTarget -Path $taskPath -Kind TASK -SchemaId TASK -After $taskAfter -BeforeExists ($null -ne $taskBefore) -Before $taskBefore
}

$targets += New-OwnerTarget `
    -Path $OwnerPath `
    -Kind OWNER `
    -SchemaId OWNER `
    -After $ownerAfter `
    -BeforeExists ($null -ne $existingOwner) `
    -Before $existingOwner
$targets += New-OwnerTarget `
    -Path $grant.GrantPath `
    -Kind COMMAND_GRANT `
    -SchemaId COMMAND_GRANT `
    -After $grantAfter `
    -BeforeExists $true `
    -Before $grant.Record
foreach ($transition in @(
    Get-AiSopWorkflowCommandGrantIndexTransitions `
        -Grant $grant.Record `
        -Active $false
)) {
    $targets += New-OwnerTarget `
        -Path $transition.Path `
        -Kind COMMAND_GRANT `
        -SchemaId COMMAND_GRANT `
        -After $transition.After `
        -BeforeExists $true `
        -Before $transition.Before
}

$transactionOperation = switch ($Operation) {
    "Claim" { "CLAIM" }
    "Validate" { "VALIDATE" }
    "BindSession" { "BIND_SESSION" }
    "RebindSession" { "REBIND_SESSION" }
    "Complete" { "COMPLETE" }
    "Transfer" { "TRANSFER" }
    "Suspend" { "SUSPEND" }
    "Cancel" { "CANCEL" }
    "Checkpoint" { "CHECKPOINT" }
}
if ($TaskId) { $WorkflowDeadlineUtc = [DateTimeOffset]::UtcNow.AddMilliseconds($ownerDeadlineMs) }
if ($null -ne $DeadlineUtc -and $DeadlineUtc -lt $WorkflowDeadlineUtc) { $WorkflowDeadlineUtc = [DateTimeOffset]$DeadlineUtc }
$claimLocks=$null
try {
    if ($Operation -eq 'Claim') {
        Invoke-AiSopWorkflowTransactionRecovery -DeadlineUtc $WorkflowDeadlineUtc -WorkspacePath $ownerWs | Out-Null
        $claimLocks=Enter-AiSopWorkflowTransactionLocks -SessionKeys $sessionKeys -OwnerPath $OwnerPath -Targets $targets -DeadlineUtc $WorkflowDeadlineUtc -WorkspacePath $ownerWs
        Assert-AiSopNoOtherActiveTask $ResolvedSpecDirectory $TaskId
    }
    Invoke-AiSopWorkflowTransaction `
        -Operation $transactionOperation `
        -Feature $Feature `
        -OwnerPath $OwnerPath `
        -SessionKeys $sessionKeys `
        -Targets $targets `
        -TransactionId $transactionId `
        -DeadlineUtc $WorkflowDeadlineUtc `
        -WorkspacePath $ownerWs `
        -LocksAlreadyHeld:($null -ne $claimLocks) |
        Out-Null
} finally {
    if ($claimLocks) { Exit-AiSopWorkflowLocks $claimLocks.Locks }
}

if ($Operation -eq 'Cancel' -and $TaskId) { Write-AiSopCancelledFollowUpReminder $ResolvedSpecDirectory $TaskId }

if (-not [string]::IsNullOrWhiteSpace($ResolvedSpecDirectory)) {
    $specLockPath = Join-Path $ResolvedSpecDirectory ".workflow-mutation.lock"
    $specLockStream = $null
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            [System.IO.Directory]::CreateDirectory($ResolvedSpecDirectory) | Out-Null
            $specLockStream = [System.IO.File]::Open(
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
    if ($null -eq $specLockStream) {
        throw "Timed out acquiring spec mutation lock: $specLockPath"
    }
    try {
        Write-OwnerMirror $ownerAfter

        # Auto-initialize or sync feature-state.json projection on successful Claim
        if ($Operation -eq "Claim" -and -not $TaskId) {
            try {
                $featStateFile = Join-Path $ResolvedSpecDirectory "feature-state.json"
                $effectiveTier = if (-not [string]::IsNullOrWhiteSpace($Tier)) { $Tier } else { "T2" }
                $isoNow = $AcceptedAt.ToUniversalTime().ToString("o")
                $utf8NoBomEnc = New-Object System.Text.UTF8Encoding($false)
                $detectedBaseline = if ($null -ne $ownerAfter -and -not [string]::IsNullOrWhiteSpace($ownerAfter.baseline)) {
                    [string]$ownerAfter.baseline
                } else {
                    Get-VcsBaselineRevision -StartPath $ResolvedSpecDirectory
                }
                if (-not (Test-Path -LiteralPath $featStateFile -PathType Leaf)) {
                    $initialState = [ordered]@{
                        schemaVersion = "1.0"
                        feature = $Feature
                        tier = $effectiveTier
                        phase = "CLAIMED"
                        ownerSession = [ordered]@{
                            agent = $Agent
                            ownerId = $OwnerId
                        }
                        completedSteps = @("CLAIM")
                        nextAction = if ($effectiveTier -eq "T3") { "brainstorming / requirement draft" } else { "implementation" }
                        updatedAt = $isoNow
                    }
                    if (-not [string]::IsNullOrWhiteSpace($detectedBaseline)) {
                        $initialState["baseline"] = $detectedBaseline
                    }
                    $jsonStr = $initialState | ConvertTo-Json -Depth 10
                    [System.IO.File]::WriteAllText($featStateFile, $jsonStr, $utf8NoBomEnc)
                } else {
                    try {
                        $existingRaw = [System.IO.File]::ReadAllText($featStateFile)
                        $existingContent = $existingRaw | ConvertFrom-Json
                        $existingDict = [ordered]@{}
                        foreach ($p in $existingContent.psobject.Properties) {
                            $existingDict[$p.Name] = $p.Value
                        }
                        if ($PSBoundParameters.ContainsKey("Tier") -and -not [string]::IsNullOrWhiteSpace($Tier)) {
                            $existingDict["tier"] = $Tier
                        }
                        $existingDict["ownerSession"] = [ordered]@{
                            agent = $Agent
                            ownerId = $OwnerId
                        }
                        if (-not $existingDict.Contains("baseline") -or [string]::IsNullOrWhiteSpace($existingDict["baseline"])) {
                            if (-not [string]::IsNullOrWhiteSpace($detectedBaseline)) {
                                $existingDict["baseline"] = $detectedBaseline
                            }
                        }
                        $existingDict["updatedAt"] = $isoNow
                        $jsonStr = $existingDict | ConvertTo-Json -Depth 10
                        [System.IO.File]::WriteAllText($featStateFile, $jsonStr, $utf8NoBomEnc)
                    } catch {
                        Write-Warning "Failed to update existing feature-state.json: $_"
                    }
                }
                $hasReq = Test-Path -LiteralPath (Join-Path $ResolvedSpecDirectory "01_server_rules.md") -PathType Leaf
                $hasDes = Test-Path -LiteralPath (Join-Path $ResolvedSpecDirectory "06_design_contract.md") -PathType Leaf
                if (
                    ($hasReq -or $hasDes) -and
                    $effectiveTier -ne "T3"
                ) {
                    Write-Warning "SPEC_HAS_DESIGN_ARTIFACTS: this legacy owner still uses feature-level approval gates. Use Task Resume to adopt it, or Start an independent task after releasing it; do not create another feature merely to select T1/T2."
                }
            } catch {
                Write-Warning "Failed to sync feature-state.json: $_"
            }
        }
    } finally {
        if ($null -ne $specLockStream) {
            $specLockStream.Dispose()
        }
    }
} else {
    Write-OwnerMirror $ownerAfter
}

Write-Output $OwnerPath
exit 0
