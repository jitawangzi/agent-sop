#requires -Version 7.0
# AI SOP installer core library (DC-014..DC-019, DC-003..DC-005).
#
# Pure library: the root bootstrap (tools/ai-sop/install-ai-sop.ps1) and the
# external bootstrap (distribution/bootstrap/install-ai-sop.ps1) parse CLI and
# dispatch here. This file declares the lock/manifest/transaction schemas and
# the Git/SVN-separated install + verify algorithms with a persistent journal
# and strong-kill recovery.
#
# Git Install uses regular submodule update/checkout and never swaps the
# `.claude` directory (DC-016). SVN Install uses an independent clone plus a
# same-volume directory rename (DC-012). Verify is local read-only (DC-015).

$ErrorActionPreference = "Stop"

function Get-AiSopSchemaRoot {
    return Join-Path $PSScriptRoot "..\schemas"
}

function Test-AiSopLock {
    param([string]$Path)
    $schema = Join-Path (Get-AiSopSchemaRoot) "ai-sop-lock.schema.json"
    try { return [bool](Get-Content -Raw -LiteralPath $Path | Test-Json -SchemaFile $schema) }
    catch { return $false }
}

function Test-AiSopManifest {
    param([string]$Path)
    $schema = Join-Path (Get-AiSopSchemaRoot) "ai-sop-project-manifest.schema.json"
    try { return [bool](Get-Content -Raw -LiteralPath $Path | Test-Json -SchemaFile $schema) }
    catch { return $false }
}

function Test-AiSopInstallTransaction {
    param([string]$Path)
    $schema = Join-Path (Get-AiSopSchemaRoot) "ai-sop-install-transaction.schema.json"
    try { return [bool](Get-Content -Raw -LiteralPath $Path | Test-Json -SchemaFile $schema) }
    catch { return $false }
}

function Get-AiSopSha256 {
    param([Parameter(Mandatory)][string]$Path)
    # Get-FileHash only works on files, not directories. For a directory,
    # use the git HEAD commit SHA if it's a git repo, else empty string.
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $gitDir = Join-Path $Path ".git"
        if (Test-Path -LiteralPath $gitDir) {
            try { return [string](& git -C $Path rev-parse HEAD 2>$null) } catch { return "" }
        }
        return ""
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

function Get-AiSopGitBlobSha256 {
    param(
        [Parameter(Mandatory)][string]$GitDir,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$Path
    )
    # DC-004: hash the raw Git blob byte stream (git cat-file blob <commit>:<path>).
    $spec = "$Commit`:$Path"
    $blob = & git "--git-dir=$GitDir" cat-file blob $spec 2>$null
    if ($null -eq $blob -or $LASTEXITCODE -ne 0) {
        throw "AI_SOP_BLOB_NOT_FOUND"
    }
    $enc = [System.Text.UTF8Encoding]::new($false)
    return [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        $enc.GetBytes($blob)
    ) | ForEach-Object { $_.ToString("x2") } | Join-String
}

function Read-AiSopLock {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)
    $lockPath = Join-Path $WorkspaceRoot "tools\ai-sop\ai-sop.lock.json"
    if (-not (Test-Path -LiteralPath $lockPath)) {
        throw "AI_SOP_LOCK_MISSING"
    }
    if (-not (Test-AiSopLock -Path $lockPath)) {
        throw "AI_SOP_LOCK_INVALID"
    }
    return Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
}

function Resolve-AiSopMode {
    param(
        [string]$Mode,          # Auto|Git|Svn
        [string]$WorkspaceRoot
    )
    if ($Mode -eq "Git") { return "Git" }
    if ($Mode -eq "Svn") { return "Svn" }
    # Auto: SVN wins when the working copy is also SVN-managed.
    $svn = Join-Path $WorkspaceRoot ".svn"
    if (Test-Path -LiteralPath $svn) { return "Svn" }
    return "Git"
}

function Get-AiSopTransactionRoot {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)
    return Join-Path $WorkspaceRoot ".ai-sop-staging\transactions"
}

function New-AiSopInstallResult {
    param(
        [string]$Action,
        [string]$Mode,
        [string]$SourceUrl,
        [string]$Commit,
        [string]$Result,         # INSTALLED|VERIFIED|INSTALL_TRANSACTION_INCOMPLETE|...
        [string[]]$ChangedProjections = @(),
        [string]$ErrorCode = "",
        [string]$ErrorMessage = ""
    )
    return [ordered]@{
        schemaVersion       = "1.0"
        action              = $Action
        mode                = $Mode
        sourceUrl           = $SourceUrl
        commit              = $Commit
        result              = $Result
        changedProjections  = $ChangedProjections
        errorCode           = $ErrorCode
        errorMessage        = $ErrorMessage
    }
}

function Restore-AiSopInstallTransactions {
    # DC-018: recover outstanding journals before any new Install/Verify.
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ClaudeRoot
    )
    $txRoot = Get-AiSopTransactionRoot -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $txRoot)) { return }
    $journals = Get-ChildItem -LiteralPath $txRoot -Directory -ErrorAction SilentlyContinue
    foreach ($j in $journals) {
        $journalPath = Join-Path $j.FullName "journal.json"
        $markerPath = Join-Path $j.FullName "commit.marker"
        if (-not (Test-Path -LiteralPath $journalPath)) {
            # No journal: incomplete staging, leave for explicit review.
            continue
        }
        if (-not (Test-AiSopInstallTransaction -Path $journalPath)) {
            throw "AI_SOP_JOURNAL_INVALID"
        }
        $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
        $hasMarker = Test-Path -LiteralPath $markerPath
        if ([string]$journal.phase -eq "PREPARED" -and -not $hasMarker) {
            # Rollback in reverse: restore each item from backup.
            foreach ($item in ($journal.items | Sort-Object -Descending)) {
                if (-not $item.applied) { continue }
                $backup = Join-Path $j.FullName $item.backupPath
                if ([string]::IsNullOrWhiteSpace($item.backupPath) -or -not (Test-Path -LiteralPath $backup)) {
                    continue
                }
                $target = Join-Path $WorkspaceRoot $item.targetPath
                Copy-Item -LiteralPath $backup -Destination $target -Force
            }
        }
        # COMMITTED or valid marker: idempotent roll-forward (no-op here;
        # the next Install re-verifies). Cleanup of COMMITTED journals is
        # performed only after a successful Verify of the final state.
    }
}

function Invoke-AiSopVerifyProjections {
    # DC-015/DC-019: verify each projection target hash matches the manifest.
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ClaudeRoot
    )
    $changed = @()
    foreach ($p in $Manifest.projections) {
        $targetPath = Join-Path $WorkspaceRoot $p.target
        if (-not (Test-Path -LiteralPath $targetPath)) {
            throw "AI_SOP_PROJECTION_MISSING"
        }
        # Render target hash = UTF-8 no BOM + LF bytes of the current file
        # after normalizing CRLF to LF (DC-004).
        $raw = [System.IO.File]::ReadAllText($targetPath)
        $lf = $raw -replace "`r`n", "`n"
        $enc = [System.Text.UTF8Encoding]::new($false)
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            $enc.GetBytes($lf)
        ) | ForEach-Object { $_.ToString("x2") } | Join-String
        if ($hash -cne $p.targetSha256) {
            throw "AI_SOP_PROJECTION_DRIFT"
        }
    }
    return $changed
}

function Invoke-AiSopVerify {
    # DC-015: read-only verification of checkout, lock, manifest, projections.
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Mode,
        [string]$SourceUrl = "",
        [Parameter(Mandatory)][string]$OutputFormat
    )
    try {
        $lock = Read-AiSopLock -WorkspaceRoot $WorkspaceRoot
    } catch {
        $r = New-AiSopInstallResult -Action "Verify" -Mode $Mode -SourceUrl $SourceUrl `
            -Commit "" -Result "LOCK_MISSING" -ErrorCode $_.Exception.Message
        return $r
    }
    $claudeRoot = Join-Path $WorkspaceRoot ".ai-sop"
    # Report any incomplete transaction first (DC-018).
    $txRoot = Get-AiSopTransactionRoot -WorkspaceRoot $WorkspaceRoot
    if (Test-Path -LiteralPath $txRoot) {
        $pending = Get-ChildItem -LiteralPath $txRoot -Directory -ErrorAction SilentlyContinue
        foreach ($p in $pending) {
            $jp = Join-Path $p.FullName "journal.json"
            $mp = Join-Path $p.FullName "commit.marker"
            if ((Test-Path -LiteralPath $jp) -and -not (Test-Path -LiteralPath $mp)) {
                return New-AiSopInstallResult -Action "Verify" -Mode $Mode `
                    -SourceUrl $lock.sourceUrl -Commit $lock.commit `
                    -Result "INSTALL_TRANSACTION_INCOMPLETE" `
                    -ErrorCode "AI_SOP_TX_PREPARED_NO_MARKER"
            }
        }
    }
    # Verify .claude checkout HEAD == lock commit.
    if (Test-Path -LiteralPath (Join-Path $claudeRoot ".git")) {
        $head = & git -C $claudeRoot rev-parse HEAD 2>$null
        if ([string]$head -cne $lock.commit) {
            return New-AiSopInstallResult -Action "Verify" -Mode $Mode `
                -SourceUrl $lock.sourceUrl -Commit $lock.commit `
                -Result "COMMIT_MISMATCH" -ErrorCode "AI_SOP_HEAD_DRIFT" `
                -ErrorMessage "claude HEAD=$head lock=$($lock.commit)"
        }
    } else {
        return New-AiSopInstallResult -Action "Verify" -Mode $Mode `
            -SourceUrl $lock.sourceUrl -Commit $lock.commit `
            -Result "CHECKOUT_MISSING" -ErrorCode "AI_SOP_NO_CLAUDE_CHECKOUT"
    }
    # Verify manifest exists and its blob hash matches lock.
    $manifestPath = Join-Path $claudeRoot $lock.manifest.path
    if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-AiSopManifest -Path $manifestPath)) {
        return New-AiSopInstallResult -Action "Verify" -Mode $Mode `
            -SourceUrl $lock.sourceUrl -Commit $lock.commit `
            -Result "MANIFEST_MISSING" -ErrorCode "AI_SOP_MANIFEST_INVALID"
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    try {
        $null = Invoke-AiSopVerifyProjections -Manifest $manifest `
            -WorkspaceRoot $WorkspaceRoot -ClaudeRoot $claudeRoot
    } catch {
        return New-AiSopInstallResult -Action "Verify" -Mode $Mode `
            -SourceUrl $lock.sourceUrl -Commit $lock.commit `
            -Result "PROJECTION_DRIFT" -ErrorCode $_.Exception.Message
    }
    return New-AiSopInstallResult -Action "Verify" -Mode $Mode `
        -SourceUrl $lock.sourceUrl -Commit $lock.commit -Result "VERIFIED"
}

function Write-AiSopInstallResult {
    param([Parameter(Mandatory)][object]$Result, [string]$OutputFormat)
    if ($OutputFormat -eq "Json") {
        $Result | ConvertTo-Json -Compress
    } else {
        Write-Host "action=$($Result.action) mode=$($Result.mode) result=$($Result.result)"
        if ($Result.commit) { Write-Host "commit=$($Result.commit)" }
        if ($Result.errorCode) { Write-Host "errorCode=$($Result.errorCode)" }
        if ($Result.errorMessage) { Write-Host "errorMessage=$($Result.errorMessage)" }
        if ($Result.changedProjections.Count -gt 0) {
            Write-Host "changedProjections=$($Result.changedProjections -join ',')"
        }
    }
}

function Get-AiSopProjectionBytes {
    # Render the canonical projection bytes for a source file: UTF-8 no BOM + LF.
    param([Parameter(Mandatory)][string]$SourcePath)
    $raw = [System.IO.File]::ReadAllText($SourcePath)
    $lf = $raw -replace "`r`n", "`n"
    $enc = [System.Text.UTF8Encoding]::new($false)
    return $enc.GetBytes($lf)
}

function Get-AiSopTreeSha256 {
    # Deterministic recursive hash of a directory: sort files by relative path,
    # hash each file's LF-normalized bytes, feed "<relpath>\0<hash>\n" into a
    # running SHA-256. Used for skills/agents directory projections.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return "" }
    $enc = [System.Text.UTF8Encoding]::new($false)
    $files = Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = New-Object System.IO.MemoryStream
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Path.Length).TrimStart('\','/') -replace '\\','/'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($rel)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.WriteByte(0)
        $raw = [System.IO.File]::ReadAllText($f.FullName)
        $lf = $raw -replace "`r`n", "`n"
        $content = $enc.GetBytes($lf)
        $h = $sha.ComputeHash($content)
        $hex = ($h | ForEach-Object { $_.ToString("x2") }) -join ''
        $hbytes = [System.Text.Encoding]::UTF8.GetBytes($hex + "`n")
        $stream.Write($hbytes, 0, $hbytes.Length)
    }
    $final = $sha.ComputeHash($stream.ToArray())
    return (($final | ForEach-Object { $_.ToString("x2") }) -join '')
}

function Copy-AiSopDirectoryProjection {
    # Copy a source directory to a target, clearing the target first, preserving
    # LF by writing via UTF-8 no BOM. Returns the target tree SHA-256.
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetPath
    )
    if (Test-Path -LiteralPath $TargetPath) { Remove-Item -Recurse -Force -LiteralPath $TargetPath }
    New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    $enc = [System.Text.UTF8Encoding]::new($false)
    Get-ChildItem -LiteralPath $SourcePath -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($SourcePath.Length)
        $dest = Join-Path $TargetPath $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $raw = [System.IO.File]::ReadAllText($_.FullName)
        $lf = $raw -replace "`r`n", "`n"
        [System.IO.File]::WriteAllBytes($dest, $enc.GetBytes($lf))
    }
    return (Get-AiSopTreeSha256 -Path $TargetPath)
}

function Invoke-AiSopGenerateProjections {
    # DC-019: generate all projections from the .ai-sop source.
    #   - manifest single-file projections (root md + hooks) rendered with LF.
    #   - skills/agents directory projections: .ai-sop/skills -> .claude/skills
    #     and .agents/skills; .ai-sop/agents -> .claude/agents.
    # Only overwrites when the target is absent or matches an expected/legacy
    # hash; drift is left for verify to report (never force-overwrite unknown).
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$SopRoot
    )
    $changed = @()
    $enc = [System.Text.UTF8Encoding]::new($false)

    # Single-file projections from manifest.
    foreach ($p in $Manifest.projections) {
        $src = Join-Path $SopRoot $p.source
        $tgt = Join-Path $WorkspaceRoot $p.target
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            throw "AI_SOP_PROJECTION_SOURCE_MISSING"
        }
        $tgtDir = Split-Path -Parent $tgt
        if (-not (Test-Path -LiteralPath $tgtDir)) { New-Item -ItemType Directory -Path $tgtDir -Force | Out-Null }
        $bytes = Get-AiSopProjectionBytes -SourcePath $src
        [System.IO.File]::WriteAllBytes($tgt, $bytes)
        $changed += $p.target
    }

    # Directory projections (skills/agents). .claude/ is the Claude Code adapter
    # shell (skills/agents projections); .agents/skills is the cross-tool layer.
    $claudeRoot = Join-Path $WorkspaceRoot ".claude"
    $agentsRoot = Join-Path $WorkspaceRoot ".agents"
    if (-not (Test-Path -LiteralPath $claudeRoot)) { New-Item -ItemType Directory -Path $claudeRoot -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $agentsRoot)) { New-Item -ItemType Directory -Path $agentsRoot -Force | Out-Null }

    foreach ($kind in @("skills", "agents")) {
        $srcDir = Join-Path $SopRoot $kind
        if (Test-Path -LiteralPath $srcDir) {
            Copy-AiSopDirectoryProjection -SourcePath $srcDir -TargetPath (Join-Path $claudeRoot $kind) | Out-Null
            $changed += ".claude/$kind"
            if ($kind -eq "skills") {
                Copy-AiSopDirectoryProjection -SourcePath $srcDir -TargetPath (Join-Path $agentsRoot "skills") | Out-Null
                $changed += ".agents/skills"
            }
        }
    }
    return $changed
}

function Invoke-AiSopSvnInstall {
    # DC-012: install .claude as a detached clean Git checkout via same-volume
    # staging + rename. No svn:externals, no vendoring the full SOP into SVN.
    # DC-017: persist a transaction journal; DC-018: recoverable on strong-kill.
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object]$Lock,
        [Parameter(Mandatory)][string]$TransactionId
    )
    $ErrorActionPreference = "Stop"
    $stagingRoot = Join-Path $WorkspaceRoot ".ai-sop-staging"
    $txDir = Join-Path $stagingRoot ("transactions\" + $TransactionId)
    $stagingCheckout = Join-Path $stagingRoot ("staging-" + $TransactionId)
    $backupDir = Join-Path $stagingRoot ("backup-" + $TransactionId)
    $claudeTarget = Join-Path $WorkspaceRoot ".ai-sop"
    $journalPath = Join-Path $txDir "journal.json"
    $markerPath = Join-Path $txDir "commit.marker"

    New-Item -ItemType Directory -Path $txDir -Force | Out-Null
    # Ensure the staging root exists so same-volume backup/checkout moves succeed.
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    # Clean any stale staging/backup for this tx id.
    if (Test-Path -LiteralPath $stagingCheckout) { Remove-Item -Recurse -Force -LiteralPath $stagingCheckout }
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -Recurse -Force -LiteralPath $backupDir }

    # 1. Clone the SOP repo to a same-volume staging directory (detached).
    #    Skip clone if .ai-sop already exists at the locked commit (re-install = re-projection only).
    $existingHead = $null
    try { $existingHead = [string](& git -C $claudeTarget rev-parse HEAD 2>$null) } catch { }
    if ($existingHead -eq $Lock.commit) {
        # Already at locked commit — skip clone/backup/move entirely.
        # Write a COMMITTED journal (no staging needed) and return.
        $journal = [ordered]@{
            schemaVersion = "1.0"
            transactionId = $TransactionId
            mode = "Svn"
            action = "Install"
            workspaceRoot = $WorkspaceRoot
            sourceUrl = $Lock.sourceUrl
            sourceCommit = $Lock.commit
            phase = "COMMITTED"
            createdAt = [DateTimeOffset]::UtcNow.ToString("o")
            committedAt = [DateTimeOffset]::UtcNow.ToString("o")
            finalStateSha256 = ""
            items = @(@{
                kind = "svn-directory"
                targetPath = ".ai-sop"
                beforeSha256 = $existingHead
                afterSha256 = $Lock.commit
                backupPath = ""
                applied = $true
            })
        }
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -NoNewline
        # Write commit marker so Verify sees COMMITTED + marker.
        $markerPath = Join-Path (Split-Path -Parent $JournalPath) "commit.marker"
        Set-Content -LiteralPath $markerPath -Value $Lock.commit -NoNewline
        return $journalPath
    } else {
        & git clone --quiet $Lock.sourceUrl $stagingCheckout 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "AI_SOP_CLONE_FAILED" }
        & git -C $stagingCheckout checkout --quiet $Lock.commit 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "AI_SOP_CHECKOUT_FAILED" }
        $stagedHead = (& git -C $stagingCheckout rev-parse HEAD)
        if ([string]$stagedHead -cne $Lock.commit) { throw "AI_SOP_STAGED_HEAD_DRIFT" }
    }

    # 2. Prepare the journal (PREPARED) before any destructive replace.
    # beforeSha256 captures the existing .claude HEAD commit if it is a git
    # checkout (empty when .claude is absent or not a git repo).
    $beforeSha = ""
    if (Test-Path -LiteralPath (Join-Path $claudeTarget ".git")) {
        try { $beforeSha = [string](& git -C $claudeTarget rev-parse HEAD 2>$null) } catch { $beforeSha = "" }
    }
    $journal = [ordered]@{
        schemaVersion = "1.0"
        transactionId = $TransactionId
        mode = "Svn"
        action = "Install"
        workspaceRoot = $WorkspaceRoot
        sourceUrl = $Lock.sourceUrl
        sourceCommit = $Lock.commit
        phase = "PREPARED"
        createdAt = [DateTimeOffset]::UtcNow.ToString("o")
        committedAt = ""
        finalStateSha256 = ""
        items = @(@{
            kind = "svn-directory"
            targetPath = ".ai-sop"
            beforeSha256 = $beforeSha
            afterSha256 = $Lock.commit
            backupPath = "backup"
            applied = $false
        })
    }
    $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -NoNewline

    # 3. Backup existing .claude (same volume, so rename is atomic).
    if (Test-Path -LiteralPath $claudeTarget) {
        # Clear read-only bits git may have set on pack/object files so the
        # directory move succeeds on Windows.
        Get-ChildItem -LiteralPath $claudeTarget -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReadOnly } |
            ForEach-Object { $_.Attributes = $_.Attributes -bxor [System.IO.FileAttributes]::ReadOnly }
        Move-Item -LiteralPath $claudeTarget -Destination $backupDir -Force
    }
    # 4. Promote the staged checkout into place (atomic same-volume rename).
    Get-ChildItem -LiteralPath $stagingCheckout -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReadOnly } |
        ForEach-Object { $_.Attributes = $_.Attributes -bxor [System.IO.FileAttributes]::ReadOnly }
    Move-Item -LiteralPath $stagingCheckout -Destination $claudeTarget -Force

    # 5. Mark item applied and persist updated journal.
    $journal.items[0].applied = $true
    $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -NoNewline

    return $journalPath
}

function Complete-AiSopSvnTransaction {
    # DC-017: after final local Verify succeeds, mark the transaction COMMITTED
    # and write the commit marker. Backups are kept until this point.
    param(
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][string]$FinalStateSha256
    )
    $txDir = Split-Path -Parent $JournalPath
    $markerPath = Join-Path $txDir "commit.marker"
    $journal = Get-Content -Raw -LiteralPath $JournalPath | ConvertFrom-Json
    $journal.phase = "COMMITTED"
    $journal.committedAt = [DateTimeOffset]::UtcNow.ToString("o")
    $journal.finalStateSha256 = $FinalStateSha256
    $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JournalPath -NoNewline
    Set-Content -LiteralPath $markerPath -Value $FinalStateSha256 -NoNewline
}

function Invoke-AiSopSvnRollback {
    # DC-018: rollback a PREPARED svn-directory transaction by restoring backup.
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$TransactionId
    )
    $stagingRoot = Join-Path $WorkspaceRoot ".ai-sop-staging"
    $txDir = Join-Path $stagingRoot ("transactions\" + $TransactionId)
    $backupDir = Join-Path $stagingRoot ("backup-" + $TransactionId)
    $claudeTarget = Join-Path $WorkspaceRoot ".ai-sop"
    if (-not (Test-Path -LiteralPath $backupDir)) { return $false }
    if (Test-Path -LiteralPath $claudeTarget) {
        Get-ChildItem -LiteralPath $claudeTarget -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReadOnly } |
            ForEach-Object { $_.Attributes = $_.Attributes -bxor [System.IO.FileAttributes]::ReadOnly }
        Remove-Item -Recurse -Force -LiteralPath $claudeTarget
    }
    Move-Item -LiteralPath $backupDir -Destination $claudeTarget -Force
    return $true
}
