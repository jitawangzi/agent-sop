#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$SessionScript = Join-Path $ScriptsRoot "workflow-session.ps1"
$SessionSchema = Join-Path (
    Split-Path -Parent $ScriptsRoot
) "schemas\workflow-session.schema.json"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "workflow-session-tests-" + [guid]::NewGuid().ToString("N")
)
$Workspace = Join-Path $TestRoot "workspace"
$env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = Join-Path $TestRoot "sessions"
$env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY = Join-Path $TestRoot "grants"
$env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY = Join-Path $TestRoot "transactions"

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage,
        [string]$Message
    )

    $actualMessage = ""
    try {
        & $Action | Out-Null
    } catch {
        $actualMessage = $_.Exception.Message
    }
    Assert-Equal $actualMessage $ExpectedMessage $Message
}

function Read-SessionRecord {
    param([string]$SessionPath)

    $raw = [System.IO.File]::ReadAllText($SessionPath)
    Assert-True ($raw | Test-Json -SchemaFile $SessionSchema) (
        "Session record does not satisfy schema: $SessionPath"
    )
    return ConvertFrom-AiSopWorkflowJson -Json $raw
}

function Assert-StaleIdleRecoveryBarrier {
    param(
        [ValidateSet("Touch", "Idle")]
        [string]$RecoveryOperation,
        [string]$NativeSessionId,
        [DateTimeOffset]$BaseTime
    )

    $session = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent ANTIGRAVITY `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $BaseTime
    $newestHeartbeat = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent ANTIGRAVITY `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $Workspace `
        -AcceptedAt $BaseTime.AddMinutes(10)
    $bound = Read-SessionRecord $session.SessionPath
    $bound.boundFeature = "IdleBarrier$RecoveryOperation"
    $bound.boundWorkflow = "SUPERPOWERS"
    $bound.boundOwnerId = "idle-barrier-owner-$($RecoveryOperation.ToLowerInvariant())"
    $bound.boundSessionEpochId = $bound.sessionEpochId
    [System.IO.File]::WriteAllText(
        $session.SessionPath,
        ($bound | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    $caseName = $RecoveryOperation.ToLowerInvariant()
    $workerPath = Join-Path $TestRoot "idle-recovery-$caseName-worker.ps1"
    $markerPath = Join-Path $TestRoot "idle-recovery-$caseName.marker"
    $releasePath = Join-Path $TestRoot "idle-recovery-$caseName.release"
    $stdoutPath = Join-Path $TestRoot "idle-recovery-$caseName.out"
    $stderrPath = Join-Path $TestRoot "idle-recovery-$caseName.err"
    [System.IO.File]::WriteAllText(
        $workerPath,
        @'
param(
    [string]$SessionScript,
    [string]$Workspace,
    [string]$NativeSessionId,
    [string]$RecoveryOperation,
    [string]$AcceptedAt,
    [string]$Marker,
    [string]$Release
)
$ErrorActionPreference = "Stop"
[System.IO.File]::WriteAllText($Marker, "accepted")
while (-not [System.IO.File]::Exists($Release)) {
    Start-Sleep -Milliseconds 5
}
. $SessionScript
if ($RecoveryOperation -ceq "Touch") {
    Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent ANTIGRAVITY `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $Workspace `
        -AcceptedAt ([DateTimeOffset]::Parse($AcceptedAt)) `
        -AllowIdleRecovery |
        Out-Null
} else {
    Invoke-AiSopWorkflowSession `
        -Operation Idle `
        -Agent ANTIGRAVITY `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $Workspace `
        -AcceptedAt ([DateTimeOffset]::Parse($AcceptedAt)) `
        -FullyIdle $false |
        Out-Null
}
'@,
        [System.Text.UTF8Encoding]::new($false)
    )

    $worker = $null
    try {
        $worker = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -WindowStyle Hidden `
            -ArgumentList @(
                "-NoProfile",
                "-File",
                $workerPath,
                "-SessionScript",
                $SessionScript,
                "-Workspace",
                $Workspace,
                "-NativeSessionId",
                $NativeSessionId,
                "-RecoveryOperation",
                $RecoveryOperation,
                "-AcceptedAt",
                $BaseTime.AddMinutes(11).ToString("o"),
                "-Marker",
                $markerPath,
                "-Release",
                $releasePath
            ) `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
        $barrierLimit = [DateTimeOffset]::UtcNow.AddSeconds(5)
        while (
            -not (Test-Path -LiteralPath $markerPath) -and
            -not $worker.HasExited -and
            [DateTimeOffset]::UtcNow -lt $barrierLimit
        ) {
            Start-Sleep -Milliseconds 10
            $worker.Refresh()
        }
        Assert-True (Test-Path -LiteralPath $markerPath) (
            "Stale $RecoveryOperation recovery did not reach its barrier."
        )
        $newerIdle = Invoke-AiSopWorkflowSession `
            -Operation Idle `
            -Agent ANTIGRAVITY `
            -NativeSessionId $NativeSessionId `
            -WorkspacePath $Workspace `
            -AcceptedAt $BaseTime.AddMinutes(12) `
            -FullyIdle $true
        Assert-Equal $newerIdle.Record.status "IDLE" (
            "Newer Idle(true) did not commit before stale $RecoveryOperation."
        )
        Assert-Equal $newerIdle.Record.stateChangedAt (
            $BaseTime.AddMinutes(12).ToUniversalTime().ToString("o")
        ) "Idle(true) did not advance stateChangedAt."
        [System.IO.File]::WriteAllText(
            $releasePath,
            "release",
            [System.Text.UTF8Encoding]::new($false)
        )
        $worker.WaitForExit()
        Assert-Equal $worker.ExitCode 0 (
            "Stale $RecoveryOperation worker failed: " +
            (Get-Content -LiteralPath $stderrPath -Raw `
                -ErrorAction SilentlyContinue)
        )
    } finally {
        if (-not (Test-Path -LiteralPath $releasePath)) {
            [System.IO.File]::WriteAllText(
                $releasePath,
                "release",
                [System.Text.UTF8Encoding]::new($false)
            )
        }
        if ($null -ne $worker -and -not $worker.HasExited) {
            Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue
            $worker.WaitForExit()
        }
    }

    $after = Read-SessionRecord $session.SessionPath
    Assert-Equal $after.status "IDLE" (
        "Stale $RecoveryOperation recovery overrode newer Idle(true)."
    )
    Assert-Equal $after.stateChangedAt (
        $BaseTime.AddMinutes(12).ToUniversalTime().ToString("o")
    ) "Stale $RecoveryOperation recovery changed stateChangedAt."
    Assert-Equal $after.lastSeenAt $newestHeartbeat.Record.lastSeenAt (
        "Stale $RecoveryOperation recovery changed lastSeenAt."
    )
    Assert-Equal $after.expiresAt $newestHeartbeat.Record.expiresAt (
        "Stale $RecoveryOperation recovery changed expiresAt."
    )
    foreach ($field in @(
        "sessionEpochId",
        "boundFeature",
        "boundWorkflow",
        "boundOwnerId",
        "boundSessionEpochId"
    )) {
        Assert-Equal $after.$field $bound.$field (
            "Stale $RecoveryOperation recovery changed $field."
        )
    }

    $newerAcceptedAt = $BaseTime.AddMinutes(13)
    if ($RecoveryOperation -ceq "Touch") {
        $newerRecovery = Invoke-AiSopWorkflowSession `
            -Operation Touch `
            -Agent ANTIGRAVITY `
            -NativeSessionId $NativeSessionId `
            -WorkspacePath $Workspace `
            -AcceptedAt $newerAcceptedAt `
            -AllowIdleRecovery
    } else {
        $newerRecovery = Invoke-AiSopWorkflowSession `
            -Operation Idle `
            -Agent ANTIGRAVITY `
            -NativeSessionId $NativeSessionId `
            -WorkspacePath $Workspace `
            -AcceptedAt $newerAcceptedAt `
            -FullyIdle $false
    }
    Assert-Equal $newerRecovery.Record.status "ACTIVE" (
        "Newer $RecoveryOperation recovery did not reactivate IDLE."
    )
    Assert-Equal $newerRecovery.Record.stateChangedAt (
        $newerAcceptedAt.ToUniversalTime().ToString("o")
    ) "Newer $RecoveryOperation recovery did not advance stateChangedAt."
    Assert-Equal $newerRecovery.Record.lastSeenAt (
        $newerAcceptedAt.ToUniversalTime().ToString("o")
    ) "Newer $RecoveryOperation recovery did not advance lastSeenAt."
    Assert-Equal $newerRecovery.Record.expiresAt (
        $newerAcceptedAt.AddMinutes(30).ToUniversalTime().ToString("o")
    ) "Newer $RecoveryOperation recovery did not renew expiresAt."

    $equalSameTarget = Invoke-AiSopWorkflowSession `
        -Operation Idle `
        -Agent ANTIGRAVITY `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $Workspace `
        -AcceptedAt $newerAcceptedAt `
        -FullyIdle $false
    Assert-Equal $equalSameTarget.Mutated $false (
        "Equal-time same-target Stop(false) rewrote session state."
    )
    $equalConflict = Invoke-AiSopWorkflowSession `
        -Operation Idle `
        -Agent ANTIGRAVITY `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $Workspace `
        -AcceptedAt $newerAcceptedAt `
        -FullyIdle $true
    Assert-Equal $equalConflict.Record.status "ACTIVE" (
        "Equal-time conflicting Idle(true) changed ACTIVE state."
    )
    Assert-Equal $equalConflict.Mutated $false (
        "Equal-time conflicting Idle(true) rewrote session state."
    )
    foreach ($field in @(
        "stateChangedAt",
        "lastSeenAt",
        "expiresAt",
        "sessionEpochId",
        "boundFeature",
        "boundWorkflow",
        "boundOwnerId",
        "boundSessionEpochId"
    )) {
        Assert-Equal $equalConflict.Record.$field $newerRecovery.Record.$field (
            "Equal-time conflict changed $field."
        )
    }
}

try {
    if (-not (Test-Path -LiteralPath $SessionScript -PathType Leaf)) {
        throw "Required Task 3 artifact does not exist: $SessionScript"
    }
    if (-not (Test-Path -LiteralPath $SessionSchema -PathType Leaf)) {
        throw "Required Task 3 artifact does not exist: $SessionSchema"
    }

    . $SessionScript
    foreach ($functionName in @(
        "Get-AiSopWorkflowSessionKey",
        "Get-AiSopWorkflowSession",
        "Invoke-AiSopWorkflowSession"
    )) {
        Assert-True ($null -ne (Get-Command $functionName -ErrorAction SilentlyContinue)) (
            "Session API is missing $functionName."
        )
    }

    [System.IO.Directory]::CreateDirectory($Workspace) | Out-Null
    $t0 = [DateTimeOffset]::Parse("2026-08-17T10:00:00.0000000Z")
    $sessionSchemaDocument = ConvertFrom-Json `
        -InputObject ([System.IO.File]::ReadAllText($SessionSchema)) `
        -AsHashtable
    Assert-True (
        @($sessionSchemaDocument.required) -ccontains "stateChangedAt"
    ) "Session schema does not require stateChangedAt."
    Assert-True (
        $sessionSchemaDocument.properties.Contains("stateChangedAt")
    ) "Session schema does not define stateChangedAt."

    Assert-StaleIdleRecoveryBarrier `
        -RecoveryOperation Idle `
        -NativeSessionId "stop-idle-recovery-barrier" `
        -BaseTime $t0
    Assert-StaleIdleRecoveryBarrier `
        -RecoveryOperation Touch `
        -NativeSessionId "touch-idle-recovery-barrier" `
        -BaseTime $t0

    $pending = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CURSOR `
        -NativeSessionId "cursor-session-A" `
        -WorkspacePath $Workspace `
        -LifecycleProof PENDING `
        -AcceptedAt $t0
    Assert-Equal $pending.Record.lifecycleProof "PENDING" (
        "Cursor tool-first registration must remain PENDING."
    )
    Assert-Equal $pending.EffectiveStatus "PENDING" (
        "Cursor PENDING effective state mismatch."
    )
    Assert-Equal $pending.Mutated $true "First registration did not mutate."
    foreach ($field in @("firstSeenAt", "lastSeenAt", "stateChangedAt")) {
        Assert-Equal $pending.Record.$field $t0.ToUniversalTime().ToString("o") (
            "First registration did not initialize $field from acceptedAt."
        )
    }
    $pendingRecord = Read-SessionRecord $pending.SessionPath
    $pendingEpoch = $pendingRecord.sessionEpochId
    $pendingExpiry = $pendingRecord.expiresAt

    $pendingDuplicate = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CURSOR `
        -NativeSessionId "cursor-session-A" `
        -WorkspacePath $Workspace `
        -LifecycleProof PENDING `
        -AcceptedAt $t0.AddSeconds(1) `
        -IsDuplicate
    Assert-Equal $pendingDuplicate.Mutated $false (
        "A duplicate lifecycle event must not mutate or renew the session."
    )
    Assert-Equal $pendingDuplicate.Record.expiresAt $pendingExpiry (
        "A duplicate lifecycle event renewed the session TTL."
    )

    $confirmed = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CURSOR `
        -NativeSessionId "cursor-session-A" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0.AddSeconds(2)
    Assert-Equal $confirmed.Record.lifecycleProof "CONFIRMED" (
        "Matching Cursor lifecycle did not confirm PENDING session."
    )
    Assert-Equal $confirmed.Record.sessionEpochId $pendingEpoch (
        "PENDING to CONFIRMED created an unexpected new epoch."
    )
    Assert-Equal $confirmed.EffectiveStatus "ACTIVE" (
        "Confirmed Cursor session is not ACTIVE."
    )

    # Heartbeats are monotonic under the session lock. An event accepted earlier
    # may acquire the lock after a newer event and must not shorten the TTL.
    $registerMonotonic = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent COPILOT `
        -NativeSessionId "register-monotonic" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $registerNewest = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent COPILOT `
        -NativeSessionId "register-monotonic" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0.AddMinutes(10)
    Assert-Equal $registerNewest.Record.stateChangedAt (
        $t0.AddMinutes(10).ToUniversalTime().ToString("o")
    ) "Newer Register did not advance stateChangedAt."
    foreach ($staleAcceptedAt in @($t0.AddMinutes(5), $t0.AddMinutes(10))) {
        $registerStale = Invoke-AiSopWorkflowSession `
            -Operation Register `
            -Agent COPILOT `
            -NativeSessionId "register-monotonic" `
            -WorkspacePath $Workspace `
            -LifecycleProof CONFIRMED `
            -AcceptedAt $staleAcceptedAt
        Assert-Equal $registerStale.Record.lastSeenAt (
            $registerNewest.Record.lastSeenAt
        ) "Older/equal Register regressed lastSeenAt."
        Assert-Equal $registerStale.Record.expiresAt (
            $registerNewest.Record.expiresAt
        ) "Older/equal Register regressed expiresAt."
        Assert-Equal $registerStale.Record.stateChangedAt (
            $registerNewest.Record.stateChangedAt
        ) "Older/equal Register changed stateChangedAt."
    }
    $pendingMonotonic = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CURSOR `
        -NativeSessionId "pending-register-monotonic" `
        -WorkspacePath $Workspace `
        -LifecycleProof PENDING `
        -AcceptedAt $t0.AddMinutes(10)
    $pendingConfirmedStale = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CURSOR `
        -NativeSessionId "pending-register-monotonic" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0.AddMinutes(5)
    Assert-Equal $pendingConfirmedStale.Record.lifecycleProof "CONFIRMED" (
        "Stale PENDING-to-CONFIRMED Register did not confirm lifecycle proof."
    )
    Assert-Equal $pendingConfirmedStale.Record.lastSeenAt (
        $pendingMonotonic.Record.lastSeenAt
    ) "Stale PENDING-to-CONFIRMED Register regressed lastSeenAt."
    Assert-Equal $pendingConfirmedStale.Record.expiresAt (
        $pendingMonotonic.Record.expiresAt
    ) "Stale PENDING-to-CONFIRMED Register regressed expiresAt."
    Assert-Equal $pendingConfirmedStale.Record.stateChangedAt (
        $pendingMonotonic.Record.stateChangedAt
    ) "Stale PENDING-to-CONFIRMED Register changed stateChangedAt."

    $touchMonotonic = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CLAUDE_CODE `
        -NativeSessionId "touch-monotonic" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $touchNewest = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent CLAUDE_CODE `
        -NativeSessionId "touch-monotonic" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(10)
    Assert-Equal $touchNewest.Record.stateChangedAt (
        $touchMonotonic.Record.stateChangedAt
    ) "Ordinary heartbeat changed stateChangedAt."
    foreach ($staleAcceptedAt in @($t0.AddMinutes(5), $t0.AddMinutes(10))) {
        $touchStale = Invoke-AiSopWorkflowSession `
            -Operation Touch `
            -Agent CLAUDE_CODE `
            -NativeSessionId "touch-monotonic" `
            -WorkspacePath $Workspace `
            -AcceptedAt $staleAcceptedAt
        Assert-Equal $touchStale.Record.lastSeenAt (
            $touchNewest.Record.lastSeenAt
        ) "Older/equal Touch regressed lastSeenAt."
        Assert-Equal $touchStale.Record.expiresAt (
            $touchNewest.Record.expiresAt
        ) "Older/equal Touch regressed expiresAt."
    }

    $idleMonotonic = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent ANTIGRAVITY `
        -NativeSessionId "idle-monotonic" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $idleNewest = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent ANTIGRAVITY `
        -NativeSessionId "idle-monotonic" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(10)
    foreach ($staleAcceptedAt in @($t0.AddMinutes(11), $t0.AddMinutes(12))) {
        Invoke-AiSopWorkflowSession `
            -Operation Idle `
            -Agent ANTIGRAVITY `
            -NativeSessionId "idle-monotonic" `
            -WorkspacePath $Workspace `
            -FullyIdle $true `
            -AcceptedAt $t0.AddMinutes(12) |
            Out-Null
        $idleRecovery = Invoke-AiSopWorkflowSession `
            -Operation Idle `
            -Agent ANTIGRAVITY `
            -NativeSessionId "idle-monotonic" `
            -WorkspacePath $Workspace `
            -FullyIdle $false `
            -AcceptedAt $staleAcceptedAt
        Assert-Equal $idleRecovery.Record.status "IDLE" (
            "Older/equal Idle(false) recovery overrode newer IDLE state."
        )
        Assert-Equal $idleRecovery.Record.lastSeenAt (
            $idleNewest.Record.lastSeenAt
        ) "Older/equal IDLE recovery regressed lastSeenAt."
        Assert-Equal $idleRecovery.Record.expiresAt (
            $idleNewest.Record.expiresAt
        ) "Older/equal IDLE recovery regressed expiresAt."
        Assert-Equal $idleRecovery.Record.stateChangedAt (
            $t0.AddMinutes(12).ToUniversalTime().ToString("o")
        ) "Older/equal IDLE recovery changed stateChangedAt."
    }
    $touchIdleMonotonic = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent ANTIGRAVITY `
        -NativeSessionId "touch-idle-monotonic" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $touchIdleNewest = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent ANTIGRAVITY `
        -NativeSessionId "touch-idle-monotonic" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(10)
    Invoke-AiSopWorkflowSession `
        -Operation Idle `
        -Agent ANTIGRAVITY `
        -NativeSessionId "touch-idle-monotonic" `
        -WorkspacePath $Workspace `
        -FullyIdle $true `
        -AcceptedAt $t0.AddMinutes(12) |
        Out-Null
    $touchIdleRecovery = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent ANTIGRAVITY `
        -NativeSessionId "touch-idle-monotonic" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(11) `
        -AllowIdleRecovery
    Assert-Equal $touchIdleRecovery.Record.status "IDLE" (
        "Stale allowed Touch recovery overrode newer IDLE state."
    )
    Assert-Equal $touchIdleRecovery.Record.lastSeenAt (
        $touchIdleNewest.Record.lastSeenAt
    ) "Stale Touch IDLE recovery regressed lastSeenAt."
    Assert-Equal $touchIdleRecovery.Record.expiresAt (
        $touchIdleNewest.Record.expiresAt
    ) "Stale Touch IDLE recovery regressed expiresAt."
    Assert-Equal $touchIdleRecovery.Record.stateChangedAt (
        $t0.AddMinutes(12).ToUniversalTime().ToString("o")
    ) "Stale Touch IDLE recovery changed stateChangedAt."

    # End is ordered by stateChangedAt. A stale/equal conflicting End cannot
    # overwrite a newer IDLE, while an equal duplicate End remains state-idempotent.
    $endMonotonic = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent ANTIGRAVITY `
        -NativeSessionId "end-monotonic" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $endHeartbeat = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent ANTIGRAVITY `
        -NativeSessionId "end-monotonic" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(10)
    $endIdle = Invoke-AiSopWorkflowSession `
        -Operation Idle `
        -Agent ANTIGRAVITY `
        -NativeSessionId "end-monotonic" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(12) `
        -FullyIdle $true
    foreach ($conflictingEndAt in @($t0.AddMinutes(11), $t0.AddMinutes(12))) {
        $conflictingEnd = Invoke-AiSopWorkflowSession `
            -Operation End `
            -Agent ANTIGRAVITY `
            -NativeSessionId "end-monotonic" `
            -WorkspacePath $Workspace `
            -AcceptedAt $conflictingEndAt
        Assert-Equal $conflictingEnd.Record.status "IDLE" (
            "Older/equal conflicting End overwrote newer IDLE."
        )
        Assert-Equal $conflictingEnd.Mutated $false (
            "Older/equal conflicting End rewrote session state."
        )
        Assert-Equal $conflictingEnd.Record.stateChangedAt (
            $endIdle.Record.stateChangedAt
        ) "Older/equal conflicting End changed stateChangedAt."
        Assert-Equal $conflictingEnd.Record.lastSeenAt (
            $endHeartbeat.Record.lastSeenAt
        ) "Older/equal conflicting End changed lastSeenAt."
        Assert-Equal $conflictingEnd.Record.expiresAt (
            $endHeartbeat.Record.expiresAt
        ) "Older/equal conflicting End changed expiresAt."
        Assert-Equal $conflictingEnd.Record.endedAt "" (
            "Older/equal conflicting End populated endedAt."
        )
    }
    $newerEndAt = $t0.AddMinutes(13)
    $newerEnd = Invoke-AiSopWorkflowSession `
        -Operation End `
        -Agent ANTIGRAVITY `
        -NativeSessionId "end-monotonic" `
        -WorkspacePath $Workspace `
        -AcceptedAt $newerEndAt
    Assert-Equal $newerEnd.Record.status "ENDED" (
        "Newer End did not enter ENDED."
    )
    Assert-Equal $newerEnd.Record.stateChangedAt (
        $newerEndAt.ToUniversalTime().ToString("o")
    ) "Newer End did not advance stateChangedAt."
    Assert-Equal $newerEnd.Record.endedAt (
        $newerEndAt.ToUniversalTime().ToString("o")
    ) "Newer End did not persist acceptedAt as endedAt."
    $equalDuplicateEnd = Invoke-AiSopWorkflowSession `
        -Operation End `
        -Agent ANTIGRAVITY `
        -NativeSessionId "end-monotonic" `
        -WorkspacePath $Workspace `
        -AcceptedAt $newerEndAt `
        -IsDuplicate
    Assert-Equal $equalDuplicateEnd.Mutated $false (
        "Equal duplicate End rewrote session state."
    )
    foreach ($field in @(
        "status",
        "stateChangedAt",
        "lastSeenAt",
        "expiresAt",
        "endedAt",
        "sessionEpochId"
    )) {
        Assert-Equal $equalDuplicateEnd.Record.$field $newerEnd.Record.$field (
            "Equal duplicate End changed $field."
        )
    }

    # Hold an older accepted event behind a barrier while a newer event commits.
    # The bound epoch must retain both its tuple and the newer heartbeat.
    $boundRace = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CURSOR `
        -NativeSessionId "bound-monotonic-race" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $boundRaceRecord = Read-SessionRecord $boundRace.SessionPath
    $boundRaceRecord.boundFeature = "BoundMonotonic"
    $boundRaceRecord.boundWorkflow = "SUPERPOWERS"
    $boundRaceRecord.boundOwnerId = "bound-monotonic-owner"
    $boundRaceRecord.boundSessionEpochId = $boundRaceRecord.sessionEpochId
    [System.IO.File]::WriteAllText(
        $boundRace.SessionPath,
        ($boundRaceRecord | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )
    $monotonicWorker = Join-Path $TestRoot "session-monotonic-worker.ps1"
    $monotonicMarker = Join-Path $TestRoot "session-monotonic.marker"
    $monotonicRelease = Join-Path $TestRoot "session-monotonic.release"
    $monotonicOut = Join-Path $TestRoot "session-monotonic.out"
    $monotonicErr = Join-Path $TestRoot "session-monotonic.err"
    [System.IO.File]::WriteAllText(
        $monotonicWorker,
        @'
param(
    [string]$SessionScript,
    [string]$Workspace,
    [string]$Marker,
    [string]$Release
)
$ErrorActionPreference = "Stop"
[System.IO.File]::WriteAllText($Marker, "accepted")
while (-not [System.IO.File]::Exists($Release)) {
    Start-Sleep -Milliseconds 5
}
. $SessionScript
Invoke-AiSopWorkflowSession `
    -Operation Touch `
    -Agent CURSOR `
    -NativeSessionId "bound-monotonic-race" `
    -WorkspacePath $Workspace `
    -AcceptedAt ([DateTimeOffset]::Parse("2026-08-17T10:05:00Z")) |
    Out-Null
'@,
        [System.Text.UTF8Encoding]::new($false)
    )
    $monotonicProcess = Start-Process -FilePath (Get-Process -Id $PID).Path `
        -WindowStyle Hidden `
        -ArgumentList @(
            "-NoProfile",
            "-File",
            $monotonicWorker,
            "-SessionScript",
            $SessionScript,
            "-Workspace",
            $Workspace,
            "-Marker",
            $monotonicMarker,
            "-Release",
            $monotonicRelease
        ) `
        -RedirectStandardOutput $monotonicOut `
        -RedirectStandardError $monotonicErr `
        -PassThru
    $monotonicLimit = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while (
        -not (Test-Path -LiteralPath $monotonicMarker) -and
        -not $monotonicProcess.HasExited -and
        [DateTimeOffset]::UtcNow -lt $monotonicLimit
    ) {
        Start-Sleep -Milliseconds 10
        $monotonicProcess.Refresh()
    }
    Assert-True (Test-Path -LiteralPath $monotonicMarker) (
        "Older heartbeat worker did not reach the ordering barrier."
    )
    $boundNewest = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent CURSOR `
        -NativeSessionId "bound-monotonic-race" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(10)
    [System.IO.File]::WriteAllText(
        $monotonicRelease,
        "release",
        [System.Text.UTF8Encoding]::new($false)
    )
    $monotonicProcess.WaitForExit()
    Assert-Equal $monotonicProcess.ExitCode 0 (
        "Older heartbeat worker failed: " +
        (Get-Content -LiteralPath $monotonicErr -Raw -ErrorAction SilentlyContinue)
    )
    $boundAfterRace = Read-SessionRecord $boundRace.SessionPath
    Assert-Equal $boundAfterRace.lastSeenAt $boundNewest.Record.lastSeenAt (
        "Lock-order inversion regressed the bound epoch lastSeenAt."
    )
    Assert-Equal $boundAfterRace.expiresAt $boundNewest.Record.expiresAt (
        "Lock-order inversion regressed the bound epoch expiresAt."
    )
    Assert-Equal $boundAfterRace.boundSessionEpochId (
        $boundRaceRecord.sessionEpochId
    ) "Lock-order inversion changed the bound epoch."

    $dedupTouch = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent CURSOR `
        -NativeSessionId "cursor-session-A" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(20) `
        -IsDuplicate
    Assert-Equal $dedupTouch.Mutated $false "Dedup Touch mutated the session."
    Assert-Equal $dedupTouch.Record.expiresAt $confirmed.Record.expiresAt (
        "Dedup Touch renewed the session TTL."
    )

    $beforeBoundary = [DateTimeOffset]::Parse($confirmed.Record.expiresAt).AddMilliseconds(-1)
    $renewed = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent CURSOR `
        -NativeSessionId "cursor-session-A" `
        -WorkspacePath $Workspace `
        -AcceptedAt $beforeBoundary
    Assert-Equal $renewed.EffectiveStatus "ACTIVE" (
        "acceptedAt=expiresAt-1ms did not remain ACTIVE."
    )
    Assert-Equal (
        [DateTimeOffset]::Parse($renewed.Record.expiresAt)
    ) $beforeBoundary.AddMinutes(30) (
        "ACTIVE Touch did not use the fixed 30 minute sliding TTL."
    )

    $atExpiry = [DateTimeOffset]::Parse($renewed.Record.expiresAt)
    $expired = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent CURSOR `
        -NativeSessionId "cursor-session-A" `
        -WorkspacePath $Workspace `
        -AcceptedAt $atExpiry
    Assert-Equal $expired.EffectiveStatus "EXPIRED" (
        "acceptedAt=expiresAt did not derive EXPIRED."
    )
    Assert-Equal $expired.Mutated $false "Expired Touch rewrote the session."
    Assert-Equal $expired.Record.expiresAt $renewed.Record.expiresAt (
        "Expired Touch renewed the session."
    )

    # A bound expired epoch is never revived by late lifecycle or tool events.
    $bound = Read-SessionRecord $renewed.SessionPath
    $bound.boundFeature = "FixtureFeature"
    $bound.boundWorkflow = "SUPERPOWERS"
    $bound.boundOwnerId = "fixture-owner"
    $bound.boundSessionEpochId = $bound.sessionEpochId
    [System.IO.File]::WriteAllText(
        $renewed.SessionPath,
        ($bound | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )
    $lateLifecycle = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CURSOR `
        -NativeSessionId "cursor-session-A" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $atExpiry.AddSeconds(1)
    Assert-Equal $lateLifecycle.EffectiveStatus "EXPIRED" (
        "A bound expired epoch was revived without RebindSession."
    )
    Assert-Equal $lateLifecycle.Record.sessionEpochId $pendingEpoch (
        "Late lifecycle silently replaced a bound expired epoch."
    )

    # An unbound expired session may start a fresh epoch on valid lifecycle.
    $unboundStart = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent COPILOT `
        -NativeSessionId "copilot-session-A" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $unboundRestart = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent COPILOT `
        -NativeSessionId "copilot-session-A" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt ([DateTimeOffset]::Parse($unboundStart.Record.expiresAt))
    Assert-Equal $unboundRestart.EffectiveStatus "ACTIVE" (
        "An unbound expired session did not start a new epoch."
    )
    Assert-True (
        $unboundRestart.Record.sessionEpochId -cne
            $unboundStart.Record.sessionEpochId
    ) "An unbound expired session reused the old epoch."

    $antigravity = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent ANTIGRAVITY `
        -NativeSessionId "antigravity-session-A" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $idle = Invoke-AiSopWorkflowSession `
        -Operation Idle `
        -Agent ANTIGRAVITY `
        -NativeSessionId "antigravity-session-A" `
        -WorkspacePath $Workspace `
        -FullyIdle $true `
        -AcceptedAt $t0.AddMinutes(1)
    Assert-Equal $idle.Record.status "IDLE" "Stop(true) did not enter IDLE."
    Assert-Equal $idle.Record.stateChangedAt (
        $t0.AddMinutes(1).ToUniversalTime().ToString("o")
    ) "Stop(true) did not advance stateChangedAt."
    Assert-Equal $idle.Record.expiresAt $antigravity.Record.expiresAt (
        "Stop(true) renewed the session TTL."
    )
    $idleTool = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent ANTIGRAVITY `
        -NativeSessionId "antigravity-session-A" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(2)
    Assert-Equal $idleTool.Record.status "IDLE" (
        "PreToolUse incorrectly reactivated IDLE session."
    )
    Assert-Equal $idleTool.Mutated $false "IDLE PreToolUse mutated the session."
    $activeAgain = Invoke-AiSopWorkflowSession `
        -Operation Idle `
        -Agent ANTIGRAVITY `
        -NativeSessionId "antigravity-session-A" `
        -WorkspacePath $Workspace `
        -FullyIdle $false `
        -AcceptedAt $t0.AddMinutes(3)
    Assert-Equal $activeAgain.Record.status "ACTIVE" (
        "Stop(false) did not reactivate an unexpired IDLE session."
    )
    Assert-Equal $activeAgain.Record.stateChangedAt (
        $t0.AddMinutes(3).ToUniversalTime().ToString("o")
    ) "Stop(false) did not advance stateChangedAt."
    Assert-Equal (
        [DateTimeOffset]::Parse($activeAgain.Record.expiresAt)
    ) $t0.AddMinutes(33) "Stop(false) did not renew TTL."

    $ended = Invoke-AiSopWorkflowSession `
        -Operation End `
        -Agent ANTIGRAVITY `
        -NativeSessionId "antigravity-session-A" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(4)
    Assert-Equal $ended.Record.status "ENDED" "SessionEnd did not enter ENDED."
    Assert-True (
        -not [string]::IsNullOrWhiteSpace($ended.Record.endedAt)
    ) "SessionEnd did not persist endedAt."
    Assert-Equal $ended.Record.stateChangedAt (
        $t0.AddMinutes(4).ToUniversalTime().ToString("o")
    ) "SessionEnd did not advance stateChangedAt."
    $postEnd = Invoke-AiSopWorkflowSession `
        -Operation Touch `
        -Agent ANTIGRAVITY `
        -NativeSessionId "antigravity-session-A" `
        -WorkspacePath $Workspace `
        -AcceptedAt $t0.AddMinutes(5)
    Assert-Equal $postEnd.EffectiveStatus "ENDED" (
        "A tool event revived an ENDED session."
    )
    Assert-Equal $postEnd.Mutated $false "ENDED session was rewritten."

    # Two lifecycle threads accepted at the exact old expiry serialize to one
    # replacement epoch; neither may revive or fork the expired epoch.
    $raceStart = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent COPILOT `
        -NativeSessionId "copilot-expiry-race" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $raceAcceptedAt = [DateTimeOffset]::Parse($raceStart.Record.expiresAt)
    $raceWorker = Join-Path $TestRoot "session-expiry-worker.ps1"
    [System.IO.File]::WriteAllText(
        $raceWorker,
        @'
param(
    [string]$SessionScript,
    [string]$Workspace,
    [string]$AcceptedAt
)
$ErrorActionPreference = "Stop"
. $SessionScript
$result = Invoke-AiSopWorkflowSession `
    -Operation Register `
    -Agent COPILOT `
    -NativeSessionId "copilot-expiry-race" `
    -WorkspacePath $Workspace `
    -LifecycleProof CONFIRMED `
    -AcceptedAt ([DateTimeOffset]::Parse($AcceptedAt))
$result.Record | ConvertTo-Json -Compress
'@,
        [System.Text.UTF8Encoding]::new($false)
    )
    $raceProcesses = @()
    for ($index = 1; $index -le 2; $index++) {
        $raceProcesses += [pscustomobject]@{
            Out = Join-Path $TestRoot "session-expiry-$index.out"
            Err = Join-Path $TestRoot "session-expiry-$index.err"
        }
        $raceProcesses[$index - 1] | Add-Member -NotePropertyName Process `
            -NotePropertyValue (
                Start-Process -FilePath (Get-Process -Id $PID).Path `
                    -WindowStyle Hidden `
                    -ArgumentList @(
                        "-NoProfile",
                        "-File",
                        $raceWorker,
                        "-SessionScript",
                        $SessionScript,
                        "-Workspace",
                        $Workspace,
                        "-AcceptedAt",
                        $raceAcceptedAt.ToString("o")
                    ) `
                    -RedirectStandardOutput $raceProcesses[$index - 1].Out `
                    -RedirectStandardError $raceProcesses[$index - 1].Err `
                    -PassThru
            )
    }
    foreach ($entry in $raceProcesses) {
        $entry.Process.WaitForExit()
        Assert-Equal $entry.Process.ExitCode 0 (
            "Exact-expiry session worker failed: " +
            (Get-Content -LiteralPath $entry.Err -Raw -ErrorAction SilentlyContinue)
        )
    }
    $raceRecords = @(
        $raceProcesses |
            ForEach-Object {
                Get-Content -LiteralPath $_.Out -Raw | ConvertFrom-Json
            }
    )
    Assert-True (
        $raceRecords[0].sessionEpochId -cne $raceStart.Record.sessionEpochId
    ) "Exact-expiry race reused the expired epoch."
    Assert-Equal $raceRecords[0].sessionEpochId $raceRecords[1].sessionEpochId (
        "Exact-expiry threads forked replacement session epochs."
    )
    Assert-Equal $raceRecords[0].stateChangedAt (
        $raceAcceptedAt.ToUniversalTime().ToString("o")
    ) "Replacement epoch did not initialize stateChangedAt."

    # P0 has no published legacy session schema. Missing stateChangedAt is
    # schema-invalid and must fail closed without inferring it from lastSeenAt.
    $missingState = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent CLAUDE_CODE `
        -NativeSessionId "missing-state-changed-at" `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $t0
    $missingRecord = ConvertFrom-AiSopWorkflowJson `
        -Json ([System.IO.File]::ReadAllText($missingState.SessionPath)) `
        -AsHashtable
    [void]$missingRecord.Remove("stateChangedAt")
    $missingJson = ConvertTo-AiSopWorkflowCanonicalJson $missingRecord
    Assert-True (-not (
        $missingJson |
            Test-Json -SchemaFile $SessionSchema -ErrorAction SilentlyContinue
    )) (
        "Session schema accepted a record without stateChangedAt."
    )
    [System.IO.File]::WriteAllText(
        $missingState.SessionPath,
        $missingJson,
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-Throws {
        Get-AiSopWorkflowSession `
            -SessionKey $missingState.Record.sessionKey `
            -AcceptedAt $t0.AddMinutes(1)
    } "SESSION_REGISTRY_CORRUPT" (
        "Session read did not fail closed without stateChangedAt."
    )
    Assert-Throws {
        Invoke-AiSopWorkflowSession `
            -Operation Register `
            -Agent CLAUDE_CODE `
            -NativeSessionId "missing-state-changed-at" `
            -WorkspacePath $Workspace `
            -LifecycleProof CONFIRMED `
            -AcceptedAt $t0.AddMinutes(1)
    } "SESSION_REGISTRY_CORRUPT" (
        "Lifecycle guessed a migration for missing stateChangedAt."
    )
    Assert-Equal (
        [System.IO.File]::ReadAllText($missingState.SessionPath)
    ) $missingJson "Missing-field rejection rewrote the invalid record."
    [System.IO.File]::Delete($missingState.SessionPath)

    foreach ($recordPath in @(
        Get-ChildItem -LiteralPath $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY `
            -Filter *.json -File
    )) {
        $raw = [System.IO.File]::ReadAllText($recordPath.FullName)
        Assert-True ($raw | Test-Json -SchemaFile $SessionSchema) (
            "Session registry contains invalid schema: $($recordPath.FullName)"
        )
        Assert-True (
            $raw -notmatch
                "cursor-session-A|copilot-session-A|antigravity-session-A|token|secret"
        ) "Session registry persisted native session identity or a secret."
    }

    Write-Output "All workflow session tests passed."
} finally {
    Remove-Item Env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY -ErrorAction SilentlyContinue
    Remove-Item Env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY -ErrorAction SilentlyContinue
    Remove-Item Env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
