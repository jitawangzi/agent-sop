#requires -Version 7.0

# Persistent PREPARED/COMMITTED coordinator shared by Owner, session, and grant
# operations. Journals contain only canonical state snapshots and hashes.

$script:WorkflowClaudeRoot = Split-Path -Parent $PSScriptRoot
$script:WorkflowTransactionSchemaPath = Join-Path (
    $script:WorkflowClaudeRoot
) "schemas\workflow-transaction.schema.json"
$script:WorkflowStateSchemaPaths = @{
    SESSION = Join-Path $script:WorkflowClaudeRoot "schemas\workflow-session.schema.json"
    OWNER = Join-Path $script:WorkflowClaudeRoot "schemas\workflow-owner.schema.json"
    COMMAND_GRANT = Join-Path (
        $script:WorkflowClaudeRoot
    ) "schemas\workflow-command-grant.schema.json"
}
$script:WorkflowUtf8NoBom = [System.Text.UTF8Encoding]::new($false)

function ConvertFrom-AiSopWorkflowJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [switch]$AsHashtable
    )

    $parameters = @{
        InputObject = $Json
        Depth = 100
    }
    if ($AsHashtable) {
        $parameters.AsHashtable = $true
    }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")) {
        $parameters.DateKind = "String"
    }
    return ConvertFrom-Json @parameters
}

function Get-AiSopWorkflowSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
}

function ConvertTo-AiSopWorkflowCanonicalValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string] -or $Value -is [System.ValueType]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @(
            $Value.Keys | ForEach-Object { [string]$_ } | Sort-Object
        )) {
            $result[$key] = ConvertTo-AiSopWorkflowCanonicalValue $Value[$key]
        }
        return $result
    }
    if (
        $Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string]
    ) {
        $items = @(
            foreach ($item in $Value) {
                ConvertTo-AiSopWorkflowCanonicalValue $item
            }
        )
        Write-Output -NoEnumerate $items
        return
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties.Name | Sort-Object)) {
            $result[$property] = ConvertTo-AiSopWorkflowCanonicalValue (
                $Value.$property
            )
        }
        return $result
    }
    return $Value
}

function ConvertTo-AiSopWorkflowCanonicalJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    return (
        ConvertTo-AiSopWorkflowCanonicalValue $Value |
            ConvertTo-Json -Compress -Depth 100
    )
}

function Assert-AiSopWorkflowDeadline {
    param([Nullable[DateTimeOffset]]$DeadlineUtc)

    if (
        $null -ne $DeadlineUtc -and
        [DateTimeOffset]::UtcNow -ge ([DateTimeOffset]$DeadlineUtc)
    ) {
        throw "WORKFLOW_DEADLINE_EXCEEDED"
    }
}

function Get-AiSopWorkflowRemainingMilliseconds {
    param(
        [Nullable[DateTimeOffset]]$DeadlineUtc,
        [int]$DefaultMilliseconds = 750
    )

    if ($null -eq $DeadlineUtc) {
        $envMs = [string]$env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS
        if (
            -not [string]::IsNullOrWhiteSpace($envMs) -and
            [int]::TryParse($envMs, [ref]$envMs)
        ) {
            $DefaultMilliseconds = [int]$envMs
        }
        return [int64]$DefaultMilliseconds
    }
    $remaining = (
        ([DateTimeOffset]$DeadlineUtc) - [DateTimeOffset]::UtcNow
    ).TotalMilliseconds
    return [int64][Math]::Max(0, [Math]::Floor($remaining))
}

function Get-AiSopWorkflowBaseAppDataRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:AI_SOP_REGISTRY_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:AI_SOP_REGISTRY_ROOT)
    }
    
    $basePath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($basePath)) {
        $userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            $userProfile = $env:HOME
        }
        $basePath = Join-Path $userProfile ".local/share"
    }
    return Join-Path $basePath "AIWorkflow"
}

function Get-AiSopWorkspaceScopeKey {
    param([string]$WorkspacePath = $null)
    try {
        $p = if (-not [string]::IsNullOrWhiteSpace($WorkspacePath)) { $WorkspacePath } else { (Get-Location).Path }
        $norm = [System.IO.Path]::GetFullPath($p).ToLowerInvariant()
        $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($norm))
        return ([System.BitConverter]::ToString($hash) -replace "-", "").Substring(0, 12).ToLowerInvariant()
    } catch {
        return "default"
    }
}

function Get-AiSopWorkflowTransactionRegistryRoot {
    param([string]$WorkspacePath = $null)

    if (-not [string]::IsNullOrWhiteSpace($env:AI_SOP_TRANSACTION_REGISTRY)) {
        return [System.IO.Path]::GetFullPath($env:AI_SOP_TRANSACTION_REGISTRY)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY)) {
        return [System.IO.Path]::GetFullPath($env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY)
    }
    $scope = Get-AiSopWorkspaceScopeKey -WorkspacePath $WorkspacePath
    return Join-Path (Get-AiSopWorkflowBaseAppDataRoot) "Transactions/$scope"
}

function Get-AiSopWorkflowSessionRegistryRoot {
    param([string]$WorkspacePath = $null)

    if (-not [string]::IsNullOrWhiteSpace($env:AI_SOP_SESSION_REGISTRY)) {
        return [System.IO.Path]::GetFullPath($env:AI_SOP_SESSION_REGISTRY)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY)) {
        return [System.IO.Path]::GetFullPath($env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY)
    }
    $scope = Get-AiSopWorkspaceScopeKey -WorkspacePath $WorkspacePath
    return Join-Path (Get-AiSopWorkflowBaseAppDataRoot) "Sessions/$scope"
}

function Get-AiSopWorkflowCommandGrantRegistryRoot {
    param([string]$WorkspacePath = $null)

    if (-not [string]::IsNullOrWhiteSpace($env:AI_SOP_COMMAND_GRANT_REGISTRY)) {
        return [System.IO.Path]::GetFullPath($env:AI_SOP_COMMAND_GRANT_REGISTRY)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY)) {
        return [System.IO.Path]::GetFullPath($env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY)
    }
    $scope = Get-AiSopWorkspaceScopeKey -WorkspacePath $WorkspacePath
    return Join-Path (Get-AiSopWorkflowBaseAppDataRoot) "CommandGrants/$scope"
}

function Get-AiSopWorkflowOwnerRegistryRoot {
    param([string]$WorkspacePath = $null)

    if (-not [string]::IsNullOrWhiteSpace($env:AI_SOP_OWNER_REGISTRY)) {
        return [System.IO.Path]::GetFullPath($env:AI_SOP_OWNER_REGISTRY)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SERVER_NEW_WORKFLOW_REGISTRY)) {
        return [System.IO.Path]::GetFullPath($env:SERVER_NEW_WORKFLOW_REGISTRY)
    }
    $scope = Get-AiSopWorkspaceScopeKey -WorkspacePath $WorkspacePath
    return Join-Path (Get-AiSopWorkflowBaseAppDataRoot) "Owners/$scope"
}

function Get-AiSopWorkflowSchemaPath {
    param(
        [ValidateSet("SESSION", "OWNER", "COMMAND_GRANT")]
        [string]$SchemaId
    )

    $path = [string]$script:WorkflowStateSchemaPaths[$SchemaId]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "WORKFLOW_SCHEMA_INVALID"
    }
    return $path
}

function Assert-AiSopWorkflowJsonSchema {
    param(
        [string]$Json,
        [ValidateSet("SESSION", "OWNER", "COMMAND_GRANT", "TRANSACTION")]
        [string]$SchemaId
    )

    $schemaPath = if ($SchemaId -eq "TRANSACTION") {
        $script:WorkflowTransactionSchemaPath
    } else {
        Get-AiSopWorkflowSchemaPath $SchemaId
    }
    try {
        if (
            $SchemaId -eq "COMMAND_GRANT" -and
            $null -ne (
                Get-Command `
                    Assert-AiSopWorkflowCommandGrantIndex `
                    -ErrorAction SilentlyContinue
            )
        ) {
            $candidate = ConvertFrom-AiSopWorkflowJson `
                -Json $Json `
                -AsHashtable
            if (
                $candidate -is [System.Collections.IDictionary] -and
                $candidate.Contains("indexKind")
            ) {
                Assert-AiSopWorkflowCommandGrantIndex `
                    -Index $candidate `
                    -ExpectedKind ([string]$candidate.indexKind) `
                    -ExpectedIntentSha256 ([string]$candidate.intentSha256) `
                    -ExpectedSessionKey ([string]$candidate.sessionKey) `
                    -ExpectedSessionEpochId ([string]$candidate.sessionEpochId)
                return
            }
        }
        if (
            -not (
                $Json |
                    Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
            )
        ) {
            throw "WORKFLOW_SCHEMA_INVALID:$SchemaId"
        }
    } catch {
        if ($_.Exception.Message -like "WORKFLOW_SCHEMA_INVALID:*") {
            throw
        }
        throw "WORKFLOW_SCHEMA_INVALID:$SchemaId"
    }
}

function Write-AiSopWorkflowTextAtomic {
    param(
        [string]$Path,
        [string]$Text
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $temporaryPath = ""
    try {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $Text,
            $script:WorkflowUtf8NoBom
        )
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    } catch {
        throw "WORKFLOW_REGISTRY_IO_ERROR"
    } finally {
        if (
            -not [string]::IsNullOrEmpty($temporaryPath) -and
            [System.IO.File]::Exists($temporaryPath)
        ) {
            try {
                [System.IO.File]::Delete($temporaryPath)
            } catch {
                # A stale temp file never authorizes workflow state.
            }
        }
    }
}

function Read-AiSopWorkflowCanonicalState {
    param(
        [string]$Path,
        [ValidateSet("SESSION", "OWNER", "COMMAND_GRANT")]
        [string]$SchemaId
    )

    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        Assert-AiSopWorkflowJsonSchema -Json $raw -SchemaId $SchemaId
        $value = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
        return ConvertTo-AiSopWorkflowCanonicalJson $value
    } catch {
        if ($_.Exception.Message -like "WORKFLOW_SCHEMA_INVALID:*") {
            throw
        }
        throw "WORKFLOW_REGISTRY_IO_ERROR"
    }
}

function New-AiSopWorkflowSnapshot {
    param(
        [bool]$Exists,
        [AllowEmptyString()]
        [string]$CanonicalJson = ""
    )

    if (-not $Exists) {
        return [ordered]@{
            exists = $false
            sha256 = ""
            canonicalJsonBase64 = ""
        }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($CanonicalJson)
    return [ordered]@{
        exists = $true
        sha256 = Get-AiSopWorkflowSha256 $CanonicalJson
        canonicalJsonBase64 = [Convert]::ToBase64String($bytes)
    }
}

function Get-AiSopWorkflowSnapshotJson {
    param([object]$Snapshot)

    if (-not [bool]$Snapshot.exists) {
        return ""
    }
    try {
        $bytes = [Convert]::FromBase64String(
            [string]$Snapshot.canonicalJsonBase64
        )
        $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        throw "WORKFLOW_TRANSACTION_CORRUPT"
    }
    if ((Get-AiSopWorkflowSha256 $json) -cne [string]$Snapshot.sha256) {
        throw "WORKFLOW_TRANSACTION_CORRUPT"
    }
    return $json
}

function Get-AiSopWorkflowTargetSnapshot {
    param(
        [string]$Path,
        [ValidateSet("SESSION", "OWNER", "COMMAND_GRANT")]
        [string]$SchemaId
    )

    if (-not [System.IO.File]::Exists($Path)) {
        return New-AiSopWorkflowSnapshot -Exists $false
    }
    $canonical = Read-AiSopWorkflowCanonicalState `
        -Path $Path `
        -SchemaId $SchemaId
    return New-AiSopWorkflowSnapshot -Exists $true -CanonicalJson $canonical
}

function Test-AiSopWorkflowSnapshotEqual {
    param(
        [object]$Left,
        [object]$Right
    )

    return (
        [bool]$Left.exists -eq [bool]$Right.exists -and
        [string]$Left.sha256 -ceq [string]$Right.sha256 -and
        [string]$Left.canonicalJsonBase64 -ceq
            [string]$Right.canonicalJsonBase64
    )
}

function Set-AiSopWorkflowTargetSnapshot {
    param(
        [object]$Target,
        [object]$Snapshot,
        [switch]$SkipSchemaValidation
    )

    $path = [string]$Target.path
    if (-not [bool]$Snapshot.exists) {
        try {
            if ([System.IO.File]::Exists($path)) {
                [System.IO.File]::Delete($path)
            }
        } catch {
            throw "WORKFLOW_REGISTRY_IO_ERROR"
        }
        return
    }
    $json = Get-AiSopWorkflowSnapshotJson $Snapshot
    if (-not $SkipSchemaValidation) {
        Assert-AiSopWorkflowJsonSchema `
            -Json $json `
            -SchemaId ([string]$Target.schemaId)
    }
    Write-AiSopWorkflowTextAtomic -Path $path -Text $json
}

function Enter-AiSopWorkflowFileLock {
    param(
        [string]$LockPath,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $localDeadline = if ($null -ne $DeadlineUtc) {
        ([DateTimeOffset]$DeadlineUtc).ToUniversalTime()
    } else {
        $defaultMs = 750
        $envMs = [string]$env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS
        if (
            -not [string]::IsNullOrWhiteSpace($envMs) -and
            [int]::TryParse($envMs, [ref]$envMs)
        ) {
            $defaultMs = [int]$envMs
        }
        [DateTimeOffset]::UtcNow.AddMilliseconds($defaultMs)
    }
    try {
        [System.IO.Directory]::CreateDirectory(
            [System.IO.Path]::GetDirectoryName($LockPath)
        ) | Out-Null
    } catch {
        throw "WORKFLOW_REGISTRY_IO_ERROR"
    }
    while ([DateTimeOffset]::UtcNow -lt $localDeadline) {
        try {
            return [System.IO.File]::Open(
                $LockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 10
        } catch {
            throw "WORKFLOW_REGISTRY_IO_ERROR"
        }
    }
    throw "WORKFLOW_LOCK_TIMEOUT"
}

function Exit-AiSopWorkflowLocks {
    param([object[]]$Locks)

    for ($index = @($Locks).Count - 1; $index -ge 0; $index--) {
        $item = @($Locks)[$index]
        try {
            $item.Stream.Dispose()
        } catch {
            # Lock release is best effort after the authoritative action.
        }
        try {
            [System.IO.File]::Delete([string]$item.Path)
        } catch {
            # Empty lock files are not authorization state.
        }
    }
}

function Enter-AiSopWorkflowTransactionLocks {
    param(
        [string[]]$SessionKeys,
        [string]$OwnerPath,
        [object[]]$Targets,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $locks = @()
    $sessionOrder = @(
        $SessionKeys |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.ToLowerInvariant() } |
            Sort-Object -Unique
    )
    try {
        foreach ($sessionKey in $sessionOrder) {
            $sessionPath = Join-Path (
                Get-AiSopWorkflowSessionRegistryRoot
            ) "$sessionKey.json"
            $lockPath = "$sessionPath.lock"
            $locks += [pscustomobject]@{
                Path = $lockPath
                Stream = Enter-AiSopWorkflowFileLock `
                    -LockPath $lockPath `
                    -DeadlineUtc $DeadlineUtc
            }
        }
        $ownerLockPath = "$OwnerPath.lock"
        $locks += [pscustomobject]@{
            Path = $ownerLockPath
            Stream = Enter-AiSopWorkflowFileLock `
                -LockPath $ownerLockPath `
                -DeadlineUtc $DeadlineUtc
        }
        foreach ($grantPath in @(
            $Targets |
                Where-Object { [string]$_.kind -eq "COMMAND_GRANT" } |
                ForEach-Object { [string]$_.path } |
                Sort-Object -Unique
        )) {
            $grantLockPath = "$grantPath.lock"
            $locks += [pscustomobject]@{
                Path = $grantLockPath
                Stream = Enter-AiSopWorkflowFileLock `
                    -LockPath $grantLockPath `
                    -DeadlineUtc $DeadlineUtc
            }
        }
        return [pscustomobject]@{
            Locks = $locks
            SessionOrder = $sessionOrder
        }
    } catch {
        Exit-AiSopWorkflowLocks $locks
        throw
    }
}

function Write-AiSopWorkflowTransactionJournal {
    param(
        [string]$JournalPath,
        [System.Collections.IDictionary]$Journal
    )

    $json = ConvertTo-AiSopWorkflowCanonicalJson $Journal
    Assert-AiSopWorkflowJsonSchema -Json $json -SchemaId TRANSACTION
    Write-AiSopWorkflowTextAtomic -Path $JournalPath -Text $json
}

function Read-AiSopWorkflowTransactionJournal {
    param([string]$JournalPath)

    try {
        $raw = [System.IO.File]::ReadAllText($JournalPath)
        Assert-AiSopWorkflowJsonSchema -Json $raw -SchemaId TRANSACTION
        $journal = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
    } catch {
        if ($_.Exception.Message -like "WORKFLOW_SCHEMA_INVALID:*") {
            throw "WORKFLOW_TRANSACTION_CORRUPT"
        }
        throw "WORKFLOW_REGISTRY_IO_ERROR"
    }
    $expectedName = [System.IO.Path]::GetFileNameWithoutExtension($JournalPath)
    if ([string]$journal.transactionId -cne $expectedName) {
        throw "WORKFLOW_TRANSACTION_CORRUPT"
    }
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($target in @($journal.targets)) {
        if ([string]$target.kind -cne [string]$target.schemaId) {
            throw "WORKFLOW_TRANSACTION_CORRUPT"
        }
        try {
            $targetPath = [System.IO.Path]::GetFullPath(
                [string]$target.path
            )
        } catch {
            throw "WORKFLOW_TRANSACTION_CORRUPT"
        }
        if (-not $seenPaths.Add($targetPath)) {
            throw "WORKFLOW_TRANSACTION_CORRUPT"
        }
    }
    return $journal
}

function Invoke-AiSopWorkflowPausePoint {
    param([string]$Point)

    if (
        [string]$env:SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_POINT -cne $Point
    ) {
        return
    }
    $markerPath = $env:SERVER_NEW_WORKFLOW_TRANSACTION_PAUSE_MARKER
    if (-not [string]::IsNullOrWhiteSpace($markerPath)) {
        [System.IO.Directory]::CreateDirectory(
            [System.IO.Path]::GetDirectoryName($markerPath)
        ) | Out-Null
        [System.IO.File]::WriteAllText(
            $markerPath,
            $Point,
            $script:WorkflowUtf8NoBom
        )
    }
    Start-Sleep -Seconds 60
}

function Resolve-AiSopWorkflowTransactionJournal {
    param(
        [string]$JournalPath,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    Assert-AiSopWorkflowDeadline $DeadlineUtc
    $journal = Read-AiSopWorkflowTransactionJournal $JournalPath
    $lockResult = Enter-AiSopWorkflowTransactionLocks `
        -SessionKeys @($journal.sessionKeys) `
        -OwnerPath ([string]$journal.ownerPath) `
        -Targets @($journal.targets) `
        -DeadlineUtc $DeadlineUtc
    try {
        $rollForward = [string]$journal.phase -eq "COMMITTED"
        if ([string]$journal.phase -eq "PREPARED") {
            $currentStates = @()
            foreach ($target in @($journal.targets)) {
                Assert-AiSopWorkflowDeadline $DeadlineUtc
                try {
                    $current = Get-AiSopWorkflowTargetSnapshot `
                        -Path ([string]$target.path) `
                        -SchemaId ([string]$target.schemaId)
                } catch {
                    throw "WORKFLOW_TRANSACTION_INDETERMINATE"
                }
                $matchesBefore = Test-AiSopWorkflowSnapshotEqual `
                    -Left $current `
                    -Right $target.before
                $matchesAfter = Test-AiSopWorkflowSnapshotEqual `
                    -Left $current `
                    -Right $target.after
                if (-not $matchesBefore -and -not $matchesAfter) {
                    throw "WORKFLOW_TRANSACTION_INDETERMINATE"
                }
                $currentStates += [pscustomobject]@{
                    Before = $matchesBefore
                    After = $matchesAfter
                }
            }
            $rollForward = @(
                $currentStates | Where-Object { -not $_.After }
            ).Count -eq 0
            if ($rollForward) {
                $journal.phase = "COMMITTED"
                $journal.committedAt = [DateTimeOffset]::UtcNow.ToString("o")
                Write-AiSopWorkflowTransactionJournal `
                    -JournalPath $JournalPath `
                    -Journal $journal
            }
        }
        foreach ($target in @($journal.targets)) {
            Assert-AiSopWorkflowDeadline $DeadlineUtc
            $snapshot = if ($rollForward) {
                $target.after
            } else {
                $target.before
            }
            Set-AiSopWorkflowTargetSnapshot -Target $target -Snapshot $snapshot
        }
        foreach ($target in @($journal.targets)) {
            $expected = if ($rollForward) {
                $target.after
            } else {
                $target.before
            }
            $actual = Get-AiSopWorkflowTargetSnapshot `
                -Path ([string]$target.path) `
                -SchemaId ([string]$target.schemaId)
            if (-not (Test-AiSopWorkflowSnapshotEqual $actual $expected)) {
                throw "WORKFLOW_TRANSACTION_INDETERMINATE"
            }
        }
        try {
            [System.IO.File]::Delete($JournalPath)
        } catch {
            throw "WORKFLOW_REGISTRY_IO_ERROR"
        }
        return [pscustomobject]@{
            TransactionId = [string]$journal.transactionId
            Result = if ($rollForward) { "ROLLED_FORWARD" } else { "ROLLED_BACK" }
            SessionLockOrder = @($lockResult.SessionOrder)
        }
    } finally {
        Exit-AiSopWorkflowLocks $lockResult.Locks
    }
}

function Invoke-AiSopWorkflowTransactionRecovery {
    [CmdletBinding()]
    param(
        [Nullable[DateTimeOffset]]$DeadlineUtc,
        [int64]$RemainingMilliseconds = -1
    )

    if ($RemainingMilliseconds -eq 0) {
        throw "WORKFLOW_DEADLINE_EXCEEDED"
    }
    Assert-AiSopWorkflowDeadline $DeadlineUtc
    $root = Get-AiSopWorkflowTransactionRegistryRoot
    try {
        [System.IO.Directory]::CreateDirectory($root) | Out-Null
        $journals = @(
            [System.IO.Directory]::EnumerateFiles($root, "*.json") |
                Sort-Object
        )
    } catch {
        throw "WORKFLOW_REGISTRY_IO_ERROR"
    }
    $results = @()
    foreach ($journalPath in $journals) {
        Assert-AiSopWorkflowDeadline $DeadlineUtc
        $journalLockPath = "$journalPath.recovery.lock"
        $journalLock = Enter-AiSopWorkflowFileLock `
            -LockPath $journalLockPath `
            -DeadlineUtc $DeadlineUtc
        try {
            if ([System.IO.File]::Exists($journalPath)) {
                $results += Resolve-AiSopWorkflowTransactionJournal `
                    -JournalPath $journalPath `
                    -DeadlineUtc $DeadlineUtc
            }
        } finally {
            $journalLock.Dispose()
            try {
                [System.IO.File]::Delete($journalLockPath)
            } catch {
                # Lock-file cleanup is not authorization state.
            }
        }
    }
    return @($results)
}

function Invoke-AiSopWorkflowTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            "CLAIM",
            "BIND_SESSION",
            "REBIND_SESSION",
            "VALIDATE",
            "COMPLETE",
            "TRANSFER"
        )]
        [string]$Operation,

        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$")]
        [string]$Feature,

        [Parameter(Mandatory)]
        [string]$OwnerPath,

        [string[]]$SessionKeys = @(),

        [Parameter(Mandatory)]
        [object[]]$Targets,

        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9._:-]+$")]
        [string]$TransactionId,

        [Nullable[DateTimeOffset]]$DeadlineUtc,

        [switch]$LocksAlreadyHeld
    )

    Assert-AiSopWorkflowDeadline $DeadlineUtc
    if (-not $LocksAlreadyHeld) {
        Invoke-AiSopWorkflowTransactionRecovery -DeadlineUtc $DeadlineUtc |
            Out-Null
    }
    $root = Get-AiSopWorkflowTransactionRegistryRoot
    $journalPath = Join-Path $root "$TransactionId.json"
    if ([System.IO.File]::Exists($journalPath)) {
        throw "WORKFLOW_TRANSACTION_EXISTS"
    }

    $normalizedTargets = @()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($target in $Targets) {
        $path = [System.IO.Path]::GetFullPath([string]$target.path)
        if (-not $seenPaths.Add($path)) {
            throw "WORKFLOW_TRANSACTION_TARGET_DUPLICATE"
        }
        $kind = [string]$target.kind
        $schemaId = [string]$target.schemaId
        if (
            $kind -notin @("SESSION", "OWNER", "COMMAND_GRANT") -or
            $schemaId -notin @("SESSION", "OWNER", "COMMAND_GRANT") -or
            $kind -cne $schemaId
        ) {
            throw "WORKFLOW_TRANSACTION_TARGET_INVALID"
        }
        $afterValue = if ($target.afterJson -is [string]) {
            try {
                ConvertFrom-AiSopWorkflowJson `
                    -Json ([string]$target.afterJson) `
                    -AsHashtable
            } catch {
                throw "WORKFLOW_TRANSACTION_TARGET_INVALID"
            }
        } else {
            $target.afterJson
        }
        $afterJson = ConvertTo-AiSopWorkflowCanonicalJson $afterValue
        Assert-AiSopWorkflowJsonSchema -Json $afterJson -SchemaId $schemaId
        $hasExpectedBefore = if (
            $target -is [System.Collections.IDictionary]
        ) {
            $target.Contains("expectedBeforeExists")
        } else {
            $null -ne $target.PSObject.Properties["expectedBeforeExists"]
        }
        $expectedBefore = $null
        if ($hasExpectedBefore) {
            if ([bool]$target.expectedBeforeExists) {
                $expectedBeforeValue = if (
                    $target.expectedBeforeJson -is [string]
                ) {
                    try {
                        ConvertFrom-AiSopWorkflowJson `
                            -Json ([string]$target.expectedBeforeJson) `
                            -AsHashtable
                    } catch {
                        throw "WORKFLOW_TRANSACTION_TARGET_INVALID"
                    }
                } else {
                    $target.expectedBeforeJson
                }
                $expectedBeforeJson = ConvertTo-AiSopWorkflowCanonicalJson (
                    $expectedBeforeValue
                )
                $expectedBefore = New-AiSopWorkflowSnapshot `
                    -Exists $true `
                    -CanonicalJson $expectedBeforeJson
            } else {
                $expectedBefore = New-AiSopWorkflowSnapshot -Exists $false
            }
        }
        $normalizedTargets += [pscustomobject][ordered]@{
            path = $path
            kind = $kind
            schemaId = $schemaId
            afterJson = $afterJson
            hasExpectedBefore = $hasExpectedBefore
            expectedBefore = $expectedBefore
        }
    }
    if ($normalizedTargets.Count -eq 0) {
        throw "WORKFLOW_TRANSACTION_TARGET_INVALID"
    }

    $lockResult = if ($LocksAlreadyHeld) {
        [pscustomobject]@{
            Locks = @()
            SessionOrder = @($SessionKeys | Sort-Object -Unique)
        }
    } else {
        Enter-AiSopWorkflowTransactionLocks `
            -SessionKeys $SessionKeys `
            -OwnerPath ([System.IO.Path]::GetFullPath($OwnerPath)) `
            -Targets $normalizedTargets `
            -DeadlineUtc $DeadlineUtc
    }
    try {
        $journalTargets = @()
        foreach ($target in $normalizedTargets) {
            Assert-AiSopWorkflowDeadline $DeadlineUtc
            $before = Get-AiSopWorkflowTargetSnapshot `
                -Path $target.path `
                -SchemaId $target.schemaId
            if (
                $target.hasExpectedBefore -and
                -not (
                    Test-AiSopWorkflowSnapshotEqual `
                        -Left $before `
                        -Right $target.expectedBefore
                )
            ) {
                throw "WORKFLOW_TRANSACTION_PRECONDITION_FAILED"
            }
            $after = New-AiSopWorkflowSnapshot `
                -Exists $true `
                -CanonicalJson $target.afterJson
            $journalTargets += [ordered]@{
                path = $target.path
                kind = $target.kind
                schemaId = $target.schemaId
                before = $before
                after = $after
            }
        }
        $journal = [ordered]@{
            schemaVersion = "1.0"
            transactionId = $TransactionId
            operation = $Operation
            phase = "PREPARED"
            feature = $Feature
            ownerPath = [System.IO.Path]::GetFullPath($OwnerPath)
            sessionKeys = @($lockResult.SessionOrder)
            targets = $journalTargets
            createdAt = [DateTimeOffset]::UtcNow.ToString("o")
            committedAt = ""
        }
        Write-AiSopWorkflowTransactionJournal `
            -JournalPath $journalPath `
            -Journal $journal
        Invoke-AiSopWorkflowPausePoint "AFTER_PREPARED"

        $index = 0
        foreach ($target in @($journal.targets)) {
            Assert-AiSopWorkflowDeadline $DeadlineUtc
            Set-AiSopWorkflowTargetSnapshot `
                -Target $target `
                -Snapshot $target.after `
                -SkipSchemaValidation
            $index++
            Invoke-AiSopWorkflowPausePoint "AFTER_TARGET_$index"
        }
        Invoke-AiSopWorkflowPausePoint "BEFORE_COMMITTED"
        $journal.phase = "COMMITTED"
        $journal.committedAt = [DateTimeOffset]::UtcNow.ToString("o")
        Write-AiSopWorkflowTransactionJournal `
            -JournalPath $journalPath `
            -Journal $journal
        Invoke-AiSopWorkflowPausePoint "AFTER_COMMITTED"

        foreach ($target in @($journal.targets)) {
            $actual = Get-AiSopWorkflowTargetSnapshot `
                -Path ([string]$target.path) `
                -SchemaId ([string]$target.schemaId)
            if (-not (Test-AiSopWorkflowSnapshotEqual $actual $target.after)) {
                throw "WORKFLOW_TRANSACTION_INDETERMINATE"
            }
        }
        [System.IO.File]::Delete($journalPath)
        return [pscustomobject]@{
            TransactionId = $TransactionId
            Result = "COMMITTED"
            SessionLockOrder = @($lockResult.SessionOrder)
        }
    } finally {
        if (-not $LocksAlreadyHeld) {
            Exit-AiSopWorkflowLocks $lockResult.Locks
        }
    }
}

function Get-AiSopWorkflowTransactionProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9._:-]+$")]
        [string]$TransactionId,

        [Nullable[DateTimeOffset]]$DeadlineUtc,

        [int64]$RemainingMilliseconds = -1
    )

    if ($RemainingMilliseconds -eq 0) {
        return "INDETERMINATE"
    }
    try {
        Assert-AiSopWorkflowDeadline $DeadlineUtc
        $journalPath = Join-Path (
            Get-AiSopWorkflowTransactionRegistryRoot
        ) "$TransactionId.json"
        if ([System.IO.File]::Exists($journalPath)) {
            $journal = Read-AiSopWorkflowTransactionJournal $journalPath
            if ([string]$journal.phase -eq "COMMITTED") {
                return "APPLIED"
            }
            return "INDETERMINATE"
        }

        $registries = @(
            [pscustomobject]@{
                Root = Get-AiSopWorkflowSessionRegistryRoot
                SchemaId = "SESSION"
                Property = "lastTransactionId"
            },
            [pscustomobject]@{
                Root = Get-AiSopWorkflowOwnerRegistryRoot
                SchemaId = "OWNER"
                Property = "lastTransactionId"
            },
            [pscustomobject]@{
                Root = Get-AiSopWorkflowCommandGrantRegistryRoot
                SchemaId = "COMMAND_GRANT"
                Property = "transactionId"
            }
        )
        foreach ($registry in $registries) {
            Assert-AiSopWorkflowDeadline $DeadlineUtc
            if (-not [System.IO.Directory]::Exists($registry.Root)) {
                continue
            }
            foreach ($path in @(
                [System.IO.Directory]::EnumerateFiles($registry.Root, "*.json")
            )) {
                Assert-AiSopWorkflowDeadline $DeadlineUtc
                $json = Read-AiSopWorkflowCanonicalState `
                    -Path $path `
                    -SchemaId $registry.SchemaId
                $record = ConvertFrom-AiSopWorkflowJson `
                    -Json $json `
                    -AsHashtable
                if (
                    [string]$record[$registry.Property] -ceq $TransactionId
                ) {
                    return "APPLIED"
                }
            }
        }
        return "NOT_APPLIED"
    } catch {
        return "INDETERMINATE"
    }
}
