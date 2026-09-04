#requires -Version 7.0

# Machine-local lifecycle registry. Native session identifiers are hashed before
# persistence; no token, command, payload, or transcript is stored.

$script:WorkflowSessionClaudeRoot = Split-Path -Parent $PSScriptRoot
$script:WorkflowSessionSchemaPath = Join-Path (
    $script:WorkflowSessionClaudeRoot
) "schemas\workflow-session.schema.json"
$script:WorkflowTransactionScriptPath = Join-Path (
    $PSScriptRoot
) "workflow-transaction.ps1"
$script:WorkflowPathIdentityScriptPath = Join-Path $PSScriptRoot "path-identity.ps1"

if (-not (Get-Command Get-AiSopWorkflowSha256 -ErrorAction SilentlyContinue)) {
    . $script:WorkflowTransactionScriptPath
}
if (-not (Get-Command Resolve-PhysicalPathIdentity -ErrorAction SilentlyContinue)) {
    . $script:WorkflowPathIdentityScriptPath
}

function Get-AiSopWorkflowSessionKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR", "PI")]
        [string]$Agent,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NativeSessionId,

        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )

    try {
        $physicalWorkspace = Resolve-PhysicalPathIdentity -Path $WorkspacePath
    } catch {
        throw "SESSION_WORKSPACE_INVALID"
    }
    return Get-AiSopWorkflowSha256 (
        $Agent + [char]0 + $NativeSessionId + [char]0 + $physicalWorkspace
    )
}

function Get-AiSopWorkflowSessionPath {
    param(
        [string]$SessionKey,
        [string]$WorkspacePath = $null
    )

    if ($SessionKey -notmatch "^[0-9a-f]{64}$") {
        throw "SESSION_IDENTITY_INVALID"
    }
    return Join-Path (
        Get-AiSopWorkflowSessionRegistryRoot -WorkspacePath $WorkspacePath
    ) "$SessionKey.json"
}

function Read-AiSopWorkflowSessionRecord {
    param(
        [string]$SessionPath,
        [AllowEmptyString()]
        [string]$ExpectedSessionKey = ""
    )

    if (-not [System.IO.File]::Exists($SessionPath)) {
        throw "SESSION_NOT_FOUND"
    }
    try {
        $raw = [System.IO.File]::ReadAllText($SessionPath)
        if (-not (
            $raw |
                Test-Json `
                    -SchemaFile $script:WorkflowSessionSchemaPath `
                    -ErrorAction SilentlyContinue
        )) {
            throw "SESSION_REGISTRY_CORRUPT"
        }
        $record = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
    } catch {
        if ($_.Exception.Message -eq "SESSION_REGISTRY_CORRUPT") {
            throw
        }
        throw "SESSION_REGISTRY_IO_ERROR"
    }
    if (
        -not [string]::IsNullOrEmpty($ExpectedSessionKey) -and
        [string]$record.sessionKey -cne $ExpectedSessionKey
    ) {
        throw "SESSION_REGISTRY_CORRUPT"
    }
    return $record
}

function Write-AiSopWorkflowSessionRecord {
    param(
        [string]$SessionPath,
        [System.Collections.IDictionary]$Record
    )

    $json = ConvertTo-AiSopWorkflowCanonicalJson $Record
    try {
        if (-not (
            $json |
                Test-Json `
                    -SchemaFile $script:WorkflowSessionSchemaPath `
                    -ErrorAction SilentlyContinue
        )) {
            throw "SESSION_REGISTRY_CORRUPT"
        }
        Write-AiSopWorkflowTextAtomic -Path $SessionPath -Text $json
    } catch {
        if ($_.Exception.Message -eq "SESSION_REGISTRY_CORRUPT") {
            throw
        }
        if ($_.Exception.Message -eq "WORKFLOW_REGISTRY_IO_ERROR") {
            throw "SESSION_REGISTRY_IO_ERROR"
        }
        throw
    }
}

function Get-AiSopWorkflowSessionEffectiveStatus {
    param(
        [System.Collections.IDictionary]$Record,
        [DateTimeOffset]$AcceptedAt
    )

    if ([string]$Record.status -eq "ENDED") {
        return "ENDED"
    }
    try {
        $expiresAt = [DateTimeOffset]::Parse(
            [string]$Record.expiresAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "SESSION_REGISTRY_CORRUPT"
    }
    if ($AcceptedAt -ge $expiresAt) {
        return "EXPIRED"
    }
    if ([string]$Record.lifecycleProof -eq "PENDING") {
        return "PENDING"
    }
    return [string]$Record.status
}

function Set-AiSopWorkflowSessionHeartbeat {
    param(
        [System.Collections.IDictionary]$Record,
        [DateTimeOffset]$AcceptedAt
    )

    try {
        $lastSeenAt = [DateTimeOffset]::Parse(
            [string]$Record.lastSeenAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $stateChangedAt = [DateTimeOffset]::Parse(
            [string]$Record.stateChangedAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "SESSION_REGISTRY_CORRUPT"
    }
    # Accepted-event order can differ from lock-acquisition order across hook
    # processes. Heartbeats therefore advance only monotonically and never
    # predate the latest lifecycle state transition.
    if ($AcceptedAt -le $lastSeenAt -or $AcceptedAt -lt $stateChangedAt) {
        return $false
    }
    $Record.lastSeenAt = $AcceptedAt.ToUniversalTime().ToString("o")
    $Record.expiresAt =
        $AcceptedAt.AddMinutes(30).ToUniversalTime().ToString("o")
    return $true
}

function Set-AiSopWorkflowSessionState {
    param(
        [System.Collections.IDictionary]$Record,
        [ValidateSet("ACTIVE", "IDLE", "ENDED")]
        [string]$TargetStatus,
        [DateTimeOffset]$AcceptedAt
    )

    try {
        $stateChangedAt = [DateTimeOffset]::Parse(
            [string]$Record.stateChangedAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "SESSION_REGISTRY_CORRUPT"
    }
    # Lifecycle state uses a clock independent from heartbeat ordering. Equal
    # targets are idempotent and equal conflicts or older events write nothing.
    if ($AcceptedAt -le $stateChangedAt) {
        return $false
    }
    $Record.status = $TargetStatus
    $Record.stateChangedAt = $AcceptedAt.ToUniversalTime().ToString("o")
    if ($TargetStatus -ceq "ENDED") {
        $Record.endedAt = $AcceptedAt.ToUniversalTime().ToString("o")
    }
    return $true
}

function Assert-AiSopWorkflowSessionIdentity {
    param(
        [System.Collections.IDictionary]$Record,
        [string]$SessionKey,
        [string]$Agent,
        [string]$NativeSessionIdSha256,
        [string]$WorkspacePath
    )

    if (
        [string]$Record.sessionKey -cne $SessionKey -or
        [string]$Record.agent -cne $Agent -or
        [string]$Record.nativeSessionIdSha256 -cne $NativeSessionIdSha256 -or
        -not ([string]$Record.workspacePath).Equals(
            $WorkspacePath,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "SESSION_IDENTITY_MISMATCH"
    }
}

function New-AiSopWorkflowSessionRecord {
    param(
        [string]$SessionKey,
        [string]$Agent,
        [string]$NativeSessionIdSha256,
        [string]$WorkspacePath,
        [ValidateSet("PENDING", "CONFIRMED")]
        [string]$LifecycleProof,
        [DateTimeOffset]$AcceptedAt
    )

    return [ordered]@{
        schemaVersion = "1.0"
        sessionKey = $SessionKey
        sessionEpochId = [guid]::NewGuid().ToString("N")
        agent = $Agent
        nativeSessionIdSha256 = $NativeSessionIdSha256
        workspacePath = $WorkspacePath
        lifecycleProof = $LifecycleProof
        lifecycleNativeSessionIdSha256 = $NativeSessionIdSha256
        status = "ACTIVE"
        firstSeenAt = $AcceptedAt.ToUniversalTime().ToString("o")
        lastSeenAt = $AcceptedAt.ToUniversalTime().ToString("o")
        stateChangedAt = $AcceptedAt.ToUniversalTime().ToString("o")
        expiresAt = $AcceptedAt.AddMinutes(30).ToUniversalTime().ToString("o")
        endedAt = ""
        lastGrantId = ""
        lastGrantIntentSha256 = ""
        boundFeature = ""
        boundWorkflow = ""
        boundOwnerId = ""
        boundSessionEpochId = ""
        lastTransactionId = ""
    }
}

function New-AiSopWorkflowSessionResult {
    param(
        [System.Collections.IDictionary]$Record,
        [string]$EffectiveStatus,
        [bool]$Mutated,
        [string]$SessionPath
    )

    return [pscustomobject][ordered]@{
        Record = [pscustomobject]$Record
        EffectiveStatus = $EffectiveStatus
        Mutated = $Mutated
        SessionPath = $SessionPath
    }
}

function Get-AiSopWorkflowSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[0-9a-f]{64}$")]
        [string]$SessionKey,

        [DateTimeOffset]$AcceptedAt = [DateTimeOffset]::UtcNow,

        [Nullable[DateTimeOffset]]$DeadlineUtc,

        [string]$WorkspacePath = $null
    )

    Invoke-AiSopWorkflowTransactionRecovery `
        -DeadlineUtc $DeadlineUtc `
        -WorkspacePath $WorkspacePath |
        Out-Null
    $sessionPath = Get-AiSopWorkflowSessionPath `
        -SessionKey $SessionKey `
        -WorkspacePath $WorkspacePath
    $lockPath = "$sessionPath.lock"
    $lock = Enter-AiSopWorkflowFileLock `
        -LockPath $lockPath `
        -DeadlineUtc $DeadlineUtc
    try {
        $record = Read-AiSopWorkflowSessionRecord `
            -SessionPath $sessionPath `
            -ExpectedSessionKey $SessionKey
        $effective = Get-AiSopWorkflowSessionEffectiveStatus `
            -Record $record `
            -AcceptedAt $AcceptedAt
        return New-AiSopWorkflowSessionResult `
            -Record $record `
            -EffectiveStatus $effective `
            -Mutated $false `
            -SessionPath $sessionPath
    } finally {
        $lock.Dispose()
        Remove-AiSopWorkflowLockFile -LockPath $lockPath
    }
}

function Invoke-AiSopWorkflowSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Register", "Touch", "End", "Idle")]
        [string]$Operation,

        [Parameter(Mandatory)]
        [ValidateSet("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR", "PI")]
        [string]$Agent,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NativeSessionId,

        [Parameter(Mandatory)]
        [string]$WorkspacePath,

        [ValidateSet("PENDING", "CONFIRMED")]
        [string]$LifecycleProof = "CONFIRMED",

        [Parameter(Mandatory)]
        [DateTimeOffset]$AcceptedAt,

        [switch]$IsDuplicate,

        [switch]$AllowIdleRecovery,

        [Nullable[bool]]$FullyIdle,

        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    Assert-AiSopWorkflowDeadline $DeadlineUtc
    try {
        $physicalWorkspace = Resolve-PhysicalPathIdentity -Path $WorkspacePath
    } catch {
        throw "SESSION_WORKSPACE_INVALID"
    }
    Invoke-AiSopWorkflowTransactionRecovery `
        -DeadlineUtc $DeadlineUtc `
        -WorkspacePath $physicalWorkspace |
        Out-Null
    $nativeSessionIdSha256 = Get-AiSopWorkflowSha256 $NativeSessionId
    $sessionKey = Get-AiSopWorkflowSessionKey `
        -Agent $Agent `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $physicalWorkspace
    $sessionPath = Get-AiSopWorkflowSessionPath `
        -SessionKey $sessionKey `
        -WorkspacePath $physicalWorkspace
    $lockPath = "$sessionPath.lock"
    $lock = Enter-AiSopWorkflowFileLock `
        -LockPath $lockPath `
        -DeadlineUtc $DeadlineUtc
    $expireGrants = $false
    try {
        $record = $null
        if ([System.IO.File]::Exists($sessionPath)) {
            $record = Read-AiSopWorkflowSessionRecord `
                -SessionPath $sessionPath `
                -ExpectedSessionKey $sessionKey
            Assert-AiSopWorkflowSessionIdentity `
                -Record $record `
                -SessionKey $sessionKey `
                -Agent $Agent `
                -NativeSessionIdSha256 $nativeSessionIdSha256 `
                -WorkspacePath $physicalWorkspace
        }

        if ($null -eq $record) {
            if ($Operation -ne "Register") {
                throw "SESSION_NOT_FOUND"
            }
            $record = New-AiSopWorkflowSessionRecord `
                -SessionKey $sessionKey `
                -Agent $Agent `
                -NativeSessionIdSha256 $nativeSessionIdSha256 `
                -WorkspacePath $physicalWorkspace `
                -LifecycleProof $LifecycleProof `
                -AcceptedAt $AcceptedAt
            Write-AiSopWorkflowSessionRecord `
                -SessionPath $sessionPath `
                -Record $record
            $effective = Get-AiSopWorkflowSessionEffectiveStatus `
                -Record $record `
                -AcceptedAt $AcceptedAt
            return New-AiSopWorkflowSessionResult `
                -Record $record `
                -EffectiveStatus $effective `
                -Mutated $true `
                -SessionPath $sessionPath
        }

        $effective = Get-AiSopWorkflowSessionEffectiveStatus `
            -Record $record `
            -AcceptedAt $AcceptedAt
        if (
            $IsDuplicate -and
            ($Operation -cne "End" -or $effective -cne "ENDED")
        ) {
            return New-AiSopWorkflowSessionResult `
                -Record $record `
                -EffectiveStatus $effective `
                -Mutated $false `
                -SessionPath $sessionPath
        }

        $mutated = $false
        switch ($Operation) {
            "Register" {
                if ($effective -eq "ENDED") {
                    break
                }
                if ($effective -eq "EXPIRED") {
                    if (
                        [string]::IsNullOrEmpty([string]$record.boundFeature) -and
                        $LifecycleProof -eq "CONFIRMED"
                    ) {
                        $record = New-AiSopWorkflowSessionRecord `
                            -SessionKey $sessionKey `
                            -Agent $Agent `
                            -NativeSessionIdSha256 $nativeSessionIdSha256 `
                            -WorkspacePath $physicalWorkspace `
                            -LifecycleProof CONFIRMED `
                            -AcceptedAt $AcceptedAt
                        $mutated = $true
                    }
                    break
                }
                if (
                    [string]$record.lifecycleProof -eq "PENDING" -and
                    $LifecycleProof -eq "CONFIRMED"
                ) {
                    $record.lifecycleProof = "CONFIRMED"
                    $record.lifecycleNativeSessionIdSha256 =
                        $nativeSessionIdSha256
                    [void](Set-AiSopWorkflowSessionState `
                        -Record $record `
                        -TargetStatus ACTIVE `
                        -AcceptedAt $AcceptedAt)
                    [void](Set-AiSopWorkflowSessionHeartbeat `
                        -Record $record `
                        -AcceptedAt $AcceptedAt)
                    $mutated = $true
                } elseif (
                    [string]$record.lifecycleProof -eq "CONFIRMED" -and
                    [string]$record.status -eq "ACTIVE"
                ) {
                    $stateChanged = Set-AiSopWorkflowSessionState `
                        -Record $record `
                        -TargetStatus ACTIVE `
                        -AcceptedAt $AcceptedAt
                    $heartbeatChanged = Set-AiSopWorkflowSessionHeartbeat `
                        -Record $record `
                        -AcceptedAt $AcceptedAt
                    $mutated = $stateChanged -or $heartbeatChanged
                }
            }
            "Touch" {
                if ($effective -eq "ACTIVE") {
                    $mutated = Set-AiSopWorkflowSessionHeartbeat `
                        -Record $record `
                        -AcceptedAt $AcceptedAt
                } elseif (
                    $effective -eq "IDLE" -and
                    $AllowIdleRecovery
                ) {
                    $stateChanged = Set-AiSopWorkflowSessionState `
                        -Record $record `
                        -TargetStatus ACTIVE `
                        -AcceptedAt $AcceptedAt
                    if ($stateChanged) {
                        [void](Set-AiSopWorkflowSessionHeartbeat `
                            -Record $record `
                            -AcceptedAt $AcceptedAt)
                        $mutated = $true
                    }
                }
            }
            "Idle" {
                if ($Agent -ne "ANTIGRAVITY" -or $null -eq $FullyIdle) {
                    throw "SESSION_TRANSITION_INVALID"
                }
                if ([bool]$FullyIdle) {
                    if ($effective -in @("ACTIVE", "IDLE")) {
                        $mutated = Set-AiSopWorkflowSessionState `
                            -Record $record `
                            -TargetStatus IDLE `
                            -AcceptedAt $AcceptedAt
                    }
                } elseif ($effective -in @("ACTIVE", "IDLE")) {
                    $stateChanged = Set-AiSopWorkflowSessionState `
                        -Record $record `
                        -TargetStatus ACTIVE `
                        -AcceptedAt $AcceptedAt
                    if ($stateChanged) {
                        [void](Set-AiSopWorkflowSessionHeartbeat `
                            -Record $record `
                            -AcceptedAt $AcceptedAt)
                        $mutated = $true
                    }
                }
            }
            "End" {
                if ($IsDuplicate -and [string]$record.status -ceq "ENDED") {
                    $expireGrants = $true
                    break
                }
                $mutated = Set-AiSopWorkflowSessionState `
                    -Record $record `
                    -TargetStatus ENDED `
                    -AcceptedAt $AcceptedAt
                $expireGrants = $mutated -or (
                    [string]$record.status -ceq "ENDED"
                )
            }
        }
        if ($mutated) {
            Write-AiSopWorkflowSessionRecord `
                -SessionPath $sessionPath `
                -Record $record
        }
        $effective = Get-AiSopWorkflowSessionEffectiveStatus `
            -Record $record `
            -AcceptedAt $AcceptedAt
        $result = New-AiSopWorkflowSessionResult `
            -Record $record `
            -EffectiveStatus $effective `
            -Mutated $mutated `
            -SessionPath $sessionPath
    } finally {
        $lock.Dispose()
        Remove-AiSopWorkflowLockFile -LockPath $lockPath
    }

    if ($expireGrants) {
        $grantScript = Join-Path $PSScriptRoot "workflow-command-grant.ps1"
        if (
            -not (
                Get-Command Expire-AiSopWorkflowCommandGrantsForSession `
                    -ErrorAction SilentlyContinue
            ) -and
            [System.IO.File]::Exists($grantScript)
        ) {
            . $grantScript
        }
        if (
            Get-Command Expire-AiSopWorkflowCommandGrantsForSession `
                -ErrorAction SilentlyContinue
        ) {
            Expire-AiSopWorkflowCommandGrantsForSession `
                -SessionKey $sessionKey `
                -SessionEpochId ([string]$result.Record.sessionEpochId) `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc |
                Out-Null
        }
    }
    return $result
}

function Set-AiSopWorkflowSessionGrantMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[0-9a-f]{64}$")]
        [string]$SessionKey,

        [Parameter(Mandatory)]
        [ValidatePattern("^[0-9a-f]{64}$")]
        [string]$GrantId,

        [Parameter(Mandatory)]
        [ValidatePattern("^[0-9a-f]{64}$")]
        [string]$IntentSha256,

        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9._:-]+$")]
        [string]$TransactionId,

        [Nullable[DateTimeOffset]]$DeadlineUtc,

        [string]$WorkspacePath = $null
    )

    $sessionPath = Get-AiSopWorkflowSessionPath `
        -SessionKey $SessionKey `
        -WorkspacePath $WorkspacePath
    $lockPath = "$sessionPath.lock"
    $lock = Enter-AiSopWorkflowFileLock `
        -LockPath $lockPath `
        -DeadlineUtc $DeadlineUtc
    try {
        $record = Read-AiSopWorkflowSessionRecord `
            -SessionPath $sessionPath `
            -ExpectedSessionKey $SessionKey
        $record.lastGrantId = $GrantId
        $record.lastGrantIntentSha256 = $IntentSha256
        $record.lastTransactionId = $TransactionId
        Write-AiSopWorkflowSessionRecord `
            -SessionPath $sessionPath `
            -Record $record
        return [pscustomobject]$record
    } finally {
        $lock.Dispose()
        Remove-AiSopWorkflowLockFile -LockPath $lockPath
    }
}
