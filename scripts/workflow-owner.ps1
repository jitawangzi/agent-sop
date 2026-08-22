#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "Claim",
        "BindSession",
        "RebindSession",
        "Validate",
        "Complete",
        "Transfer",
        "ForceRelease"
    )]
    [string]$Operation,

    [Parameter(Mandatory = $true)]
    [string]$SpecDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$")]
    [string]$Feature,

    [Parameter(Mandatory = $true)]
    [ValidateSet("CUSTOM_SKILLS", "SUPERPOWERS")]
    [string]$Workflow,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "CLAUDE_CODE",
        "COPILOT",
        "ANTIGRAVITY",
        "CURSOR",
        "GEMINI",
        "PI"
    )]
    [string]$Agent,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[A-Za-z0-9._:-]+$")]
    [string]$OwnerId
)

$ErrorActionPreference = "Stop"

$ClaudeRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "path-identity.ps1")
. (Join-Path $PSScriptRoot "workflow-transaction.ps1")
. (Join-Path $PSScriptRoot "workflow-session.ps1")
. (Join-Path $PSScriptRoot "workflow-command-grant.ps1")
$SchemaPath = Join-Path $ClaudeRoot "schemas\workflow-owner.schema.json"
$ResolvedSpecDirectory = Resolve-PhysicalPathIdentity -Path $SpecDirectory
$MirrorPath = Join-Path $ResolvedSpecDirectory ".workflow-owner.json"
$RegistryRoot = Get-AiSopWorkflowOwnerRegistryRoot
$OwnerPath = Join-Path $RegistryRoot ($Feature.ToLowerInvariant() + ".json")
$AcceptedAt = [DateTimeOffset]::UtcNow
# Production budget is 750ms. Strong-kill recovery tests spawn this script as a
# cold subprocess under CPU contention; the pause-point marker must be written
# before the deadline, so the deadline is overridable for those tests only.
$ownerDeadlineMs = 750
$ownerDeadlineEnv = [string]$env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS
if (
    -not [string]::IsNullOrWhiteSpace($ownerDeadlineEnv) -and
    [int]::TryParse($ownerDeadlineEnv, [ref]$ownerDeadlineEnv)
) {
    $ownerDeadlineMs = [int]$ownerDeadlineEnv
}
$WorkflowDeadlineUtc = $AcceptedAt.AddMilliseconds($ownerDeadlineMs)

function Assert-OwnerSchema {
    param([string]$Json)

    if (
        -not (
            $Json |
                Test-Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue
        )
    ) {
        throw "WORKFLOW_OWNER_CORRUPT"
    }
}

function Assert-CanonicalSpecDirectory {
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
    $featuresDirectory = Split-Path -Parent $ResolvedSpecDirectory
    $specsDirectory = Split-Path -Parent $featuresDirectory
    $claudeDirectory = Split-Path -Parent $specsDirectory
    return Resolve-PhysicalPathIdentity -Path (
        Split-Path -Parent $claudeDirectory
    )
}

function Read-Owner {
    param([switch]$AllowMissing)

    if (-not [System.IO.File]::Exists($OwnerPath)) {
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
        [System.IO.Directory]::CreateDirectory($ResolvedSpecDirectory) |
            Out-Null
        $json = ConvertTo-AiSopWorkflowCanonicalJson $Owner
        Write-AiSopWorkflowTextAtomic -Path $MirrorPath -Text $json
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

function Assert-NewOwnerPair {
    if (
        $Workflow -cne "SUPERPOWERS" -or
        $Agent -notin @("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR", "PI")
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
        [ValidateSet("SESSION", "OWNER", "COMMAND_GRANT")]
        [string]$Kind,
        [ValidateSet("SESSION", "OWNER", "COMMAND_GRANT")]
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
            -DeadlineUtc $WorkflowDeadlineUtc
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
        $ws = Get-OwnerWorkspacePath
        $nativeSessionId = if (-not [string]::IsNullOrWhiteSpace($env:ANTIGRAVITY_SESSION_ID)) {
            $env:ANTIGRAVITY_SESSION_ID
        } elseif (-not [string]::IsNullOrWhiteSpace($env:AI_SESSION_ID)) {
            $env:AI_SESSION_ID
        } elseif (-not [string]::IsNullOrWhiteSpace($env:SESSION_ID)) {
            $env:SESSION_ID
        } else {
            "cli-session-$PID"
        }

        $currentOwner = Read-Owner -AllowMissing
        $sessionToUse = $null
        if (
            $Operation -in @("Validate", "Complete") -and
            $null -ne $currentOwner -and
            [string]$currentOwner.schemaVersion -eq "1.1" -and
            $null -ne $currentOwner.sessionBinding
        ) {
            try {
                $boundKey = [string]$currentOwner.sessionBinding.sessionKey
                $existingSession = Get-AiSopWorkflowSession `
                    -SessionKey $boundKey `
                    -AcceptedAt $AcceptedAt `
                    -DeadlineUtc $WorkflowDeadlineUtc
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
            -DeadlineUtc $WorkflowDeadlineUtc

        Write-Output "[INFO] Direct execution detected; auto-bootstrapped CommandGrant for session $($sessionToUse.Record.sessionKey)"
        return $newGrant
    }
}

function Get-GrantSession {
    param([object]$Grant)

    $session = Get-AiSopWorkflowSession `
        -SessionKey ([string]$Grant.Record.sessionKey) `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $WorkflowDeadlineUtc
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
        -DeadlineUtc $WorkflowDeadlineUtc |
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
        -DeadlineUtc $WorkflowDeadlineUtc
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
            -LocksAlreadyHeld |
            Out-Null
        Write-Output "VALID"
    } finally {
        Exit-AiSopWorkflowLocks $lockResult.Locks
    }
}

Assert-CanonicalSpecDirectory
Invoke-AiSopWorkflowTransactionRecovery `
    -DeadlineUtc $WorkflowDeadlineUtc |
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
if ($Operation -in @("Validate", "Complete") -and $null -eq $existingOwner) {
    throw "WORKFLOW_OWNER_NOT_FOUND"
}

# ForceRelease: emergency recovery for an orphaned ACTIVE owner (previous session
# crashed/exited without Complete). Does NOT require a live session/grant (the
# session is gone). Requires exact Feature+OwnerId to prevent theft. Marks the
# owner RELEASED so a new Claim can proceed.
if ($Operation -eq "ForceRelease") {
    if (
        $null -eq $existingOwner -or
        [string]$existingOwner.status -ne "ACTIVE"
    ) {
        throw "WORKFLOW_OWNER_NOT_ACTIVE"
    }
    if (
        [string]$existingOwner.feature -cne $Feature -or
        [string]$existingOwner.workflow -cne $Workflow -or
        [string]$existingOwner.ownerId -cne $OwnerId -or
        -not ([string]$existingOwner.specDirectory).Equals(
            $ResolvedSpecDirectory,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "WORKFLOW_OWNER_IDENTITY_MISMATCH"
    }
    $releasedOwner = Copy-WorkflowRecord $existingOwner
    $releasedOwner.status = "RELEASED"
    $releasedOwner.completedAt =
        $AcceptedAt.ToUniversalTime().ToString("o")
    $releasedOwner.lastTransactionId = "force-release-" + $transactionId
    Write-OwnerAtomic -Path $OwnerPath -Owner $releasedOwner
    Write-OwnerMirror $releasedOwner
    Write-Output $OwnerPath
    exit 0
}

$grant = Get-ExactGrant
$session = Get-GrantSession $grant

if ($Operation -eq "Validate") {
    if ([string]$existingOwner.schemaVersion -ne "1.1") {
        throw "WORKFLOW_OWNER_LEGACY_OPERATION_DENIED"
    }
    Invoke-OwnerValidate11 `
        -Owner $existingOwner `
        -Grant $grant `
        -Session $session
    exit 0
}

$transactionId = "$($Operation.ToLowerInvariant())-$([guid]::NewGuid().ToString('N'))"
$grantAfter = New-AiSopWorkflowCommandGrantAfterConsume `
    -Grant $grant.Record `
    -AcceptedAt $AcceptedAt `
    -TransactionId $transactionId
$targets = @()
$sessionKeys = @()
$ownerAfter = $null

switch ($Operation) {
    "Claim" {
        Assert-ActiveGrantSession -Grant $grant -Session $session -RequireUnbound
        if (
            $null -ne $existingOwner -and
            [string]$existingOwner.status -eq "ACTIVE"
        ) {
            throw "WORKFLOW_OWNER_ALREADY_ACTIVE"
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
            -DeadlineUtc $WorkflowDeadlineUtc
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
    "Complete" {
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
        $sessionAfter = Copy-WorkflowRecord $session.Record
        Clear-SessionBoundTuple `
            -Session $sessionAfter `
            -TransactionId $transactionId
        $ownerAfter = Copy-WorkflowRecord $existingOwner
        $ownerAfter.status = "COMPLETE"
        $ownerAfter.completedAt =
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
        # Reuse the immutable ownerId; only the agent changes.
        Assert-ActiveGrantSession -Grant $grant -Session $session -RequireUnbound
        $sessionAfter = Copy-WorkflowRecord $session.Record
        Set-SessionBoundTuple `
            -Session $sessionAfter `
            -SessionEpochId ([string]$grant.Record.sessionEpochId) `
            -TransactionId $transactionId
        $ownerAfter = Copy-WorkflowRecord $existingOwner
        $ownerAfter.agent = $Agent
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
    "BindSession" { "BIND_SESSION" }
    "RebindSession" { "REBIND_SESSION" }
    "Complete" { "COMPLETE" }
    "Transfer" { "TRANSFER" }
}
Invoke-AiSopWorkflowTransaction `
    -Operation $transactionOperation `
    -Feature $Feature `
    -OwnerPath $OwnerPath `
    -SessionKeys $sessionKeys `
    -Targets $targets `
    -TransactionId $transactionId `
    -DeadlineUtc $WorkflowDeadlineUtc |
    Out-Null

Write-OwnerMirror $ownerAfter
Write-Output $OwnerPath
