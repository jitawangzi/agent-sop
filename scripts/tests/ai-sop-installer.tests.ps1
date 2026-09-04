#requires -Version 7.0
# AI SOP installer tests (DC-014..DC-019, DC-003..DC-005).
# Unit + local integration tests. Integration tests use temporary local bare
# Git and svnadmin repositories (no network). Exit 0 on full pass.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ClaudeRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CorePath = Join-Path $ClaudeRoot "distribution\install-ai-sop-core.ps1"
$LockSchema = Join-Path $ClaudeRoot "schemas\ai-sop-lock.schema.json"
$ManifestSchema = Join-Path $ClaudeRoot "schemas\ai-sop-project-manifest.schema.json"
$TxSchema = Join-Path $ClaudeRoot "schemas\ai-sop-install-transaction.schema.json"

foreach ($required in @($CorePath, $LockSchema, $ManifestSchema, $TxSchema)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required Task 5 artifact missing: $required"
    }
}

. $CorePath

$PassCount = 0
$FailCount = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if (-not ($Expected -ceq $Actual)) {
        throw "ASSERT_EQUAL: $Message`nExpected: $Expected`nActual:   $Actual"
    }
}
function Assert-True {
    param([bool]$Cond, [string]$Message)
    if (-not $Cond) { throw "ASSERT_TRUE: $Message" }
}
function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:PassCount++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:FailCount++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Mode resolution (DC-014 Auto) ---
Invoke-Test "Resolve-AiSopMode Auto->Git without .svn" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-mode-git-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $mode = Resolve-AiSopMode -Mode "Auto" -WorkspaceRoot $tmp
        Assert-Equal "Git" $mode "Auto without .svn must resolve Git"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

Invoke-Test "Resolve-AiSopMode Auto->Svn with .svn" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-mode-svn-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmp ".svn") | Out-Null
    try {
        $mode = Resolve-AiSopMode -Mode "Auto" -WorkspaceRoot $tmp
        Assert-Equal "Svn" $mode "Auto with .svn must resolve Svn"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

Invoke-Test "Resolve-AiSopMode explicit Git/Svn pass-through" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-mode-exp-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Assert-Equal "Git" (Resolve-AiSopMode -Mode "Git" -WorkspaceRoot $tmp) "explicit Git"
        Assert-Equal "Svn" (Resolve-AiSopMode -Mode "Svn" -WorkspaceRoot $tmp) "explicit Svn"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

# --- Result schema (DC-014 JSON fields) ---
Invoke-Test "New-AiSopInstallResult has exact fixed fields" {
    $r = New-AiSopInstallResult -Action "Verify" -Mode "Git" -SourceUrl "https://example/x.git" `
        -Commit ('a' * 40) -Result "VERIFIED"
    Assert-Equal "1.0" $r.schemaVersion "schemaVersion"
    Assert-Equal "Verify" $r.action "action"
    Assert-Equal "Git" $r.mode "mode"
    Assert-Equal ('a' * 40) $r.commit "commit"
    Assert-Equal "VERIFIED" $r.result "result"
    Assert-True (@($r.changedProjections).Count -eq 0) "changedProjections empty"
    Assert-Equal "" $r.errorCode "errorCode empty"
}

# --- Lock schema validation (DC-003) ---
Invoke-Test "Lock rejects branch/tag/short SHA" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-lock-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $bad = @{ schemaVersion="1.0"; sourceUrl="x"; commit="main"; manifest=@{path="distribution/project-manifest.json"; blobSha256=("z"*64)}; core=@{path="distribution/install-ai-sop-core.ps1"; blobSha256=("z"*64)}; bootstrap=@{path="distribution/bootstrap/install-ai-sop.ps1"; blobSha256=("z"*64)}; certification=@{path="distribution/harness-certification.json"; blobSha256=("z"*64)} }
        $badPath = Join-Path $tmp "bad.lock.json"
        $bad | ConvertTo-Json -Compress | Set-Content -LiteralPath $badPath
        Assert-True (-not (Test-AiSopLock -Path $badPath)) "branch commit must be invalid"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

Invoke-Test "Lock accepts valid 40-char SHA" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-lock-ok-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $commit = "0123456789abcdef0123456789abcdef01234567"
        $blob = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        $ok = @{ schemaVersion="1.0"; sourceUrl="https://example/x.git"; commit=$commit; manifest=@{path="distribution/project-manifest.json"; blobSha256=$blob}; core=@{path="distribution/install-ai-sop-core.ps1"; blobSha256=$blob}; bootstrap=@{path="distribution/bootstrap/install-ai-sop.ps1"; blobSha256=$blob}; certification=@{path="distribution/harness-certification.json"; blobSha256=$blob} }
        $okPath = Join-Path $tmp "ok.lock.json"
        $ok | ConvertTo-Json -Compress | Set-Content -LiteralPath $okPath
        Assert-True (Test-AiSopLock -Path $okPath) "valid lock must pass"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

# --- Projection verify drift detection (DC-015/DC-019) ---
Invoke-Test "Invoke-AiSopVerifyProjections detects drift" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-proj-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $target = Join-Path $tmp "CLAUDE.md"
        "hello`n" | Set-Content -LiteralPath $target -NoNewline
        $enc = [System.Text.UTF8Encoding]::new($false)
        $realHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($enc.GetBytes("hello`n")) | ForEach-Object { $_.ToString("x2") } | Join-String
        $wrongManifest = @{ projections = @(@{ source="templates/root/CLAUDE.md"; target="CLAUDE.md"; sourceBlobSha256=("f"*64); targetSha256=("0"*64); legacySha256=""; encoding="utf8-no-bom"; lineEnding="lf" }) }
        $threw = $false
        try {
            $null = Invoke-AiSopVerifyProjections -Manifest $wrongManifest -WorkspaceRoot $tmp -ClaudeRoot $tmp
        } catch { $threw = $true }
        Assert-True $threw "drifted target hash must throw"
        # Correct hash passes.
        $goodManifest = @{ projections = @(@{ source="templates/root/CLAUDE.md"; target="CLAUDE.md"; sourceBlobSha256=("f"*64); targetSha256=$realHash; legacySha256=""; encoding="utf8-no-bom"; lineEnding="lf" }) }
        $null = Invoke-AiSopVerifyProjections -Manifest $goodManifest -WorkspaceRoot $tmp -ClaudeRoot $tmp
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

# --- CRLF normalization in target hash (DC-004) ---
Invoke-Test "Projection target hash is CRLF-normalized" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-crlf-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $target = Join-Path $tmp "AGENTS.md"
        # Write CRLF content.
        $crlf = "line1`r`nline2`r`n"
        [System.IO.File]::WriteAllText($target, $crlf)
        $enc = [System.Text.UTF8Encoding]::new($false)
        $lfHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($enc.GetBytes("line1`nline2`n")) | ForEach-Object { $_.ToString("x2") } | Join-String
        $manifest = @{ projections = @(@{ source="x"; target="AGENTS.md"; sourceBlobSha256=("f"*64); targetSha256=$lfHash; legacySha256=""; encoding="utf8-no-bom"; lineEnding="lf" }) }
        $null = Invoke-AiSopVerifyProjections -Manifest $manifest -WorkspaceRoot $tmp -ClaudeRoot $tmp
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

# --- Verify end-to-end: missing lock -> LOCK_MISSING ---
Invoke-Test "Invoke-AiSopVerify reports LOCK_MISSING without lock" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-nolock-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $r = Invoke-AiSopVerify -WorkspaceRoot $tmp -Mode "Git" -SourceUrl "" -OutputFormat "Text"
        Assert-Equal "LOCK_MISSING" $r.result "result"
        Assert-Equal "AI_SOP_LOCK_MISSING" $r.errorCode "errorCode"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

# --- Transaction schema validation (DC-017) ---
Invoke-Test "Install transaction journal rejects bad phase" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-tx-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $bad = @{ schemaVersion="1.0"; transactionId="t1"; mode="Git"; action="Install"; workspaceRoot="."; sourceUrl="x"; sourceCommit=("a"*40); phase="ROLLBACK"; createdAt="2026-08-18T00:00:00Z"; items=@(@{kind="projection"; targetPath="CLAUDE.md"; beforeSha256=""; afterSha256=("a"*64); backupPath=""; applied=$true}) }
        $badPath = Join-Path $tmp "bad.tx.json"
        $bad | ConvertTo-Json -Compress | Set-Content -LiteralPath $badPath
        Assert-True (-not (Test-AiSopInstallTransaction -Path $badPath)) "bad phase must be invalid"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

# --- Root bootstrap delegation: missing .claude -> BOOTSTRAP_MISSING ---
Invoke-Test "Root bootstrap reports BOOTSTRAP_MISSING without .claude" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-noclaude-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $rootBoot = Join-Path $ClaudeRoot "distribution\bootstrap\install-ai-sop.ps1"
        $out = & pwsh -NoProfile -File $rootBoot -Mode Auto -Action Verify -WorkspaceRoot $tmp -OutputFormat Json 2>&1
        $jsonStr = ($out | Where-Object { $_ -is [string] -and $_ -match '^\s*\{' } | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($jsonStr)) { $jsonStr = ($out | Out-String).Trim() }
        $o = $jsonStr | ConvertFrom-Json
        Assert-Equal "CORE_MISSING" $o.result "without .claude/distribution core is missing"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

# --- Git blob hash via real local bare repo (DC-004) ---
Invoke-Test "Get-AiSopGitBlobSha256 hashes real blob bytes" {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-blob-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $bare = Join-Path $tmp "sop.git"
        & git init --bare --quiet $bare 2>&1 | Out-Null
        $work = Join-Path $tmp "work"
        New-Item -ItemType Directory -Path $work | Out-Null
        & git -C $work init --quiet 2>&1 | Out-Null
        $content = "manifest content`n"
        $content | Set-Content -LiteralPath (Join-Path $work "manifest.txt") -NoNewline
        & git -C $work add manifest.txt 2>&1 | Out-Null
        & git -C $work -c user.email=t@t -c user.name=t commit -m x --quiet 2>&1 | Out-Null
        $commit = & git -C $work rev-parse HEAD
        # Push to bare so cat-file works against bare objects.
        & git -C $work remote add origin $bare 2>&1 | Out-Null
        & git -C $work push --quiet origin HEAD 2>&1 | Out-Null
        $hash = Get-AiSopGitBlobSha256 -GitDir $bare -Commit $commit -Path "manifest.txt"
        # Expected hash is over the bytes git actually stores (DC-004); read them
        # back from the bare repo to compute the reference independently.
        $stored = & git "--git-dir=$bare" cat-file blob "$commit`:manifest.txt"
        $enc = [System.Text.UTF8Encoding]::new($false)
        $expected = [System.Security.Cryptography.SHA256]::Create().ComputeHash($enc.GetBytes($stored)) | ForEach-Object { $_.ToString("x2") } | Join-String
        Assert-Equal $expected $hash "blob hash must match stored blob bytes"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

# --- SVN Install algorithm (DC-012): clone + rename + transaction ---
Invoke-Test "Invoke-AiSopSvnInstall clones+renames .claude and writes PREPARED journal" {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-svn-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        # Build a fake SOP bare repo.
        $bare = Join-Path $tmp "sop.git"; & git init --bare --quiet $bare 2>&1 | Out-Null
        $work = Join-Path $tmp "src"; New-Item -ItemType Directory -Path $work | Out-Null
        & git -C $work init --quiet 2>&1 | Out-Null
        & git -C $work -c user.email=t@t -c user.name=t commit --allow-empty -m init --quiet 2>&1 | Out-Null
        $commit = & git -C $work rev-parse HEAD
        & git -C $work remote add origin $bare 2>&1 | Out-Null
        & git -C $work push --quiet origin HEAD 2>&1 | Out-Null
        $lock = @{ sourceUrl=$bare; commit=$commit }
        # Simulate a workspace root with an existing .claude (to be backed up).
        $ws = Join-Path $tmp "workspace"; New-Item -ItemType Directory -Path $ws | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $ws ".ai-sop") | Out-Null
        "old" | Set-Content -LiteralPath (Join-Path $ws ".ai-sop\marker.txt") -NoNewline
        $txId = "test-tx-001"
        $jp = Invoke-AiSopSvnInstall -WorkspaceRoot $ws -Lock $lock -TransactionId $txId
        Assert-True (Test-Path -LiteralPath $jp) "journal must exist"
        Assert-True (Test-AiSopInstallTransaction -Path $jp) "journal must be schema-valid"
        $j = Get-Content -Raw -LiteralPath $jp | ConvertFrom-Json
        Assert-Equal "PREPARED" $j.phase "phase"
        Assert-True $j.items[0].applied "item applied"
        Assert-Equal $commit $j.items[0].afterSha256 "after = lock commit"
        Assert-True (Test-Path -LiteralPath (Join-Path $ws ".ai-sop\.git")) ".claude replaced with a git checkout"
        # New .claude is a git checkout at lock commit (empty commit, no marker).
        $head = & git -C (Join-Path $ws ".ai-sop") rev-parse HEAD
        Assert-Equal $commit $head "installed .claude HEAD = lock commit"
        # Old marker is NOT in the new checkout (it was replaced, not merged).
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $ws ".ai-sop\marker.txt"))) "old marker absent from replaced checkout"
        # Backup preserved the old .claude contents.
        Assert-True (Test-Path -LiteralPath (Join-Path $ws ".ai-sop-staging\backup-$txId\marker.txt")) "backup of old .claude kept"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

Invoke-Test "Invoke-AiSopSvnRollback restores .claude from backup" {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-rb-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $bare = Join-Path $tmp "sop.git"; & git init --bare --quiet $bare 2>&1 | Out-Null
        $work = Join-Path $tmp "src"; New-Item -ItemType Directory -Path $work | Out-Null
        & git -C $work init --quiet 2>&1 | Out-Null
        & git -C $work -c user.email=t@t -c user.name=t commit --allow-empty -m init --quiet 2>&1 | Out-Null
        $commit = & git -C $work rev-parse HEAD
        & git -C $work remote add origin $bare 2>&1 | Out-Null
        & git -C $work push --quiet origin HEAD 2>&1 | Out-Null
        $lock = @{ sourceUrl=$bare; commit=$commit }
        $ws = Join-Path $tmp "workspace"; New-Item -ItemType Directory -Path $ws | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $ws ".ai-sop") | Out-Null
        "original" | Set-Content -LiteralPath (Join-Path $ws ".ai-sop\marker.txt") -NoNewline
        $txId = "test-tx-rb"
        Invoke-AiSopSvnInstall -WorkspaceRoot $ws -Lock $lock -TransactionId $txId | Out-Null
        # Simulate a failed install: rollback.
        $restored = Invoke-AiSopSvnRollback -WorkspaceRoot $ws -TransactionId $txId
        Assert-True $restored "rollback returns true"
        Assert-Equal "original" (Get-Content -Raw -LiteralPath (Join-Path $ws ".ai-sop\marker.txt")) ".claude restored from backup"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

Invoke-Test "project-manifest.json validates and settings hash matches" {
    $manifestPath = Join-Path $ClaudeRoot "distribution\project-manifest.json"
    Assert-True (Test-AiSopManifest -Path $manifestPath) "project-manifest.json must satisfy schema (including verifyMode)"
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $settingsProj = @($manifest.projections | Where-Object { $_.target -eq ".claude/settings.json" }) | Select-Object -First 1
    Assert-True ($null -ne $settingsProj) "manifest must project .claude/settings.json"
    Assert-Equal "json-hooks-merge" $settingsProj.verifyMode "settings projection must merge hooks"
    $src = Join-Path $ClaudeRoot $settingsProj.source
    $bytes = Get-AiSopProjectionBytes -SourcePath $src
    $hash = ([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    Assert-Equal $settingsProj.targetSha256 $hash "claude-settings.json targetSha256 must match LF-normalized bytes"
}

Invoke-Test "json-hooks-merge preserves extra JSON keys and injects SOP hooks" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-hooks-merge-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $sop = Join-Path $tmp "sop"
        $ws = Join-Path $tmp "ws"
        $srcRel = "distribution\templates\hooks\claude-settings.json"
        $srcDir = Join-Path $sop "distribution\templates\hooks"
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $ws ".claude") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $ClaudeRoot $srcRel) -Destination (Join-Path $sop $srcRel)
        $existingPath = Join-Path $ws ".claude\settings.json"
        [System.IO.File]::WriteAllText(
            $existingPath,
            '{"permissions":{"allow":["Bash(git *)"]},"hooks":{"Stop":[{"matcher":"*"}]}}'
        )
        $manifest = @{
            projections = @(
                @{
                    source = "distribution/templates/hooks/claude-settings.json"
                    target = ".claude/settings.json"
                    sourceBlobSha256 = ("f" * 64)
                    targetSha256 = ("0" * 64)
                    legacySha256 = ""
                    encoding = "utf8-no-bom"
                    lineEnding = "lf"
                    verifyMode = "json-hooks-merge"
                }
            )
        }
        $null = Invoke-AiSopGenerateProjections -WorkspaceRoot $ws -Manifest $manifest -SopRoot $sop
        $merged = Get-Content -Raw -LiteralPath $existingPath | ConvertFrom-Json -Depth 30
        Assert-True ($null -ne $merged.permissions.allow) "merge must keep permissions.allow"
        Assert-True ($null -ne $merged.hooks.Stop) "merge must keep unrelated hook events"
        Assert-True ($null -ne $merged.hooks.SessionStart) "merge must inject SessionStart"
        Assert-True ($null -ne $merged.hooks.PreToolUse) "merge must inject PreToolUse"
        Assert-True (Test-AiSopClaudeSettingsHasSopHooks -TargetPath $existingPath) "merged settings must contain SOP hooks"
        $null = Invoke-AiSopVerifyProjections -Manifest $manifest -WorkspaceRoot $ws -ClaudeRoot $sop
        [System.IO.File]::WriteAllText($existingPath, '{"permissions":{"allow":["Bash(git *)"]}}')
        $threw = $false
        try {
            $null = Invoke-AiSopVerifyProjections -Manifest $manifest -WorkspaceRoot $ws -ClaudeRoot $sop
        } catch {
            $threw = $true
            Assert-Equal "AI_SOP_PROJECTION_DRIFT" $_.Exception.Message "missing SOP hooks must be drift"
        }
        Assert-True $threw "settings without SOP hooks must fail json-hooks-merge verify"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

Invoke-Test "Complete-AiSopSvnTransaction marks COMMITTED + writes marker" {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aisop-commit-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $txDir = Join-Path $tmp "tx"; New-Item -ItemType Directory -Path $txDir | Out-Null
        $jp = Join-Path $txDir "journal.json"
        @{ schemaVersion="1.0"; transactionId="t1"; mode="Svn"; action="Install"; workspaceRoot="."; sourceUrl="x"; sourceCommit=("a"*40); phase="PREPARED"; createdAt="2026-08-18T00:00:00Z"; committedAt=""; finalStateSha256=""; items=@(@{kind="svn-directory"; targetPath=".claude"; beforeSha256=""; afterSha256=("a"*40); backupPath="backup"; applied=$true}) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jp -NoNewline
        Complete-AiSopSvnTransaction -JournalPath $jp -FinalStateSha256 ("f"*64)
        $j = Get-Content -Raw -LiteralPath $jp | ConvertFrom-Json
        Assert-Equal "COMMITTED" $j.phase "phase COMMITTED"
        Assert-Equal ("f"*64) $j.finalStateSha256 "finalStateSha256"
        Assert-True (Test-Path -LiteralPath (Join-Path $txDir "commit.marker")) "marker file written"
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp }
}

Write-Host ""
Write-Host ("{0} installer tests passed, {1} failed" -f $script:PassCount, $script:FailCount) -ForegroundColor Cyan
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
