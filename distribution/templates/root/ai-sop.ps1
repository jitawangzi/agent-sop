#requires -Version 7.0

# AI SOP unified entry point. Use this instead of remembering multiple script paths.
#
# Usage:
#   pwsh -NoProfile -File ./ai-sop.ps1 Install          # install/refresh projections + self-check
#   pwsh -NoProfile -File ./ai-sop.ps1 Doctor            # env self-check (runs even if .ai-sop missing)
#   pwsh -NoProfile -File ./ai-sop.ps1 Update            # same as Install but re-generates projections
#   pwsh -NoProfile -File ./ai-sop.ps1 Verify            # read-only verification
#   pwsh -NoProfile -File ./ai-sop.ps1 Status -Feature X # feature gate/phase status
#
# New users: run 'Doctor' first (works even before .ai-sop submodule is initialized).

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("Install", "Doctor", "Update", "Verify", "Status", "Help", "")]
    [string]$Action = "Help",

    [string]$Feature = "",
    [string]$SpecDirectory = ""
)

$ErrorActionPreference = "Stop"
$WorkspaceRoot = $PSScriptRoot
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- Doctor (works even if .ai-sop submodule not initialized) ---
function Invoke-Doctor {
    $doctorScript = Join-Path $WorkspaceRoot ".ai-sop/scripts/doctor.ps1"
    if (Test-Path -LiteralPath $doctorScript -PathType Leaf) {
        $doctorArgs = @{}
        if (-not [string]::IsNullOrWhiteSpace($Feature)) { $doctorArgs.Feature = $Feature }
        if (-not [string]::IsNullOrWhiteSpace($SpecDirectory)) { $doctorArgs.SpecDirectory = $SpecDirectory }
        & $doctorScript @doctorArgs
        exit $LASTEXITCODE
    }
    # Submodule not initialized — run a minimal self-check that doesn't depend on .ai-sop.
    Write-Host "=== AI SOP Doctor (minimal — .ai-sop submodule not initialized) ===" -ForegroundColor Yellow
    $checks = [System.Collections.Generic.List[pscustomobject]]::new()
    function Add-Check { param([string]$N, [bool]$P, [string]$D) $checks.Add([pscustomobject]@{Name=$N;Pass=$P;Detail=$D}) }

    # PowerShell version
    Add-Check "PowerShell 7+" ($PSVersionTable.PSVersion.Major -ge 7) $PSVersionTable.PSVersion.ToString()

    # Git
    try { $g = (git --version 2>&1) | Out-String; Add-Check "Git CLI" $true $g.Trim() }
    catch { Add-Check "Git CLI" $false "not found" }

    # SVN
    try { $s = (svn --version --quiet 2>&1) | Out-String; Add-Check "SVN CLI" (-not [string]::IsNullOrWhiteSpace($s)) $s.Trim() }
    catch { Add-Check "SVN CLI" $false "not found" }

    # JDK 8
    $jh = [string]$env:JAVA_HOME
    $jok = $false; $jd = "JAVA_HOME not set"
    if (-not [string]::IsNullOrWhiteSpace($jh) -and (Test-Path -LiteralPath $jh)) {
        try { $jo = (& "$jh\bin\java" -version 2>&1) | Out-String; if ($jo -match "1\.8") { $jok=$true; $jd="JDK 1.8 at $jh" } else { $jd="not JDK 8: $jo".Trim() } }
        catch { $jd = "java not runnable: $_" }
    }
    Add-Check "JDK 8" $jok $jd

    # Submodule init
    $disp = Join-Path $WorkspaceRoot ".ai-sop/scripts/hook-dispatcher.ps1"
    Add-Check "Submodule init" (Test-Path -LiteralPath $disp -PathType Leaf) $disp

    # Hook injection
    $ah = Join-Path $WorkspaceRoot ".agents/hooks.json"
    $cs = Join-Path $WorkspaceRoot ".claude/settings.json"
    Add-Check "Hook injected" ((Test-Path -LiteralPath $ah) -or (Test-Path -LiteralPath $cs)) ".agents/hooks.json or .claude/settings.json"

    # Lock file
    $lock = Join-Path $WorkspaceRoot "tools/ai-sop/ai-sop.lock.json"
    Add-Check "Lock file" (Test-Path -LiteralPath $lock) $lock

    # Report
    $pc = @($checks | Where-Object { $_.Pass }).Count
    foreach ($r in $checks) { $m = if ($r.Pass) {"✅"} else {"❌"}; Write-Host ("{0} {1,-22} {2}" -f $m,$r.Name,$r.Detail) }
    Write-Host ""
    $c = if ($pc -eq $checks.Count) {"Green"} else {"Yellow"}
    Write-Host ("{0}/{1} checks passed" -f $pc,$checks.Count) -ForegroundColor $c
    if ($pc -lt $checks.Count) { Write-Host "Fix failing checks, then run: pwsh -NoProfile -File ./ai-sop.ps1 Install" -ForegroundColor Cyan }
    if ($pc -eq $checks.Count) { exit 0 } else { exit 1 }
}

# --- Status (feature gate + phase) ---
function Invoke-Status {
    param([string]$FeatureName, [string]$SpecDir)
    if (-not $FeatureName -and -not $SpecDir) {
        $featuresBase = Join-Path $WorkspaceRoot ".ai-workspace/specs/features"
        if (Test-Path -LiteralPath $featuresBase -PathType Container) {
            $featureDirs = Get-ChildItem -LiteralPath $featuresBase -Directory
            if ($featureDirs.Count -gt 0) {
                Write-Host "=== Active Features Overview ===" -ForegroundColor Cyan
                $table = [System.Collections.Generic.List[PSCustomObject]]::new()
                foreach ($f in $featureDirs) {
                    $featName = $f.Name
                    $featStateFile = Join-Path $f.FullName "feature-state.json"
                    $approvalFile = Join-Path $f.FullName "00_workflow_state.json"
                    $tier = "-"
                    $phase = "NO_STATE"
                    $owner = "-"
                    $updated = "-"
                    if (Test-Path -LiteralPath $featStateFile -PathType Leaf) {
                        try {
                            $fs = Get-Content -LiteralPath $featStateFile -Raw | ConvertFrom-Json
                            $tier = if ($fs.tier) { [string]$fs.tier } else { "-" }
                            $phase = if ($fs.phase) { [string]$fs.phase } else { "-" }
                            $owner = if ($fs.ownerSession -and $fs.ownerSession.ownerId) { "$([string]$fs.ownerSession.agent)/$([string]$fs.ownerSession.ownerId)" } else { "-" }
                            $updated = if ($fs.updatedAt) { [string]$fs.updatedAt } else { "-" }
                        } catch {}
                    } elseif (Test-Path -LiteralPath $approvalFile -PathType Leaf) {
                        $phase = "APPROVED_GATES"
                        $tier = "T3"
                    }
                    $table.Add([PSCustomObject]@{
                        Feature = $featName
                        Tier = $tier
                        Phase = $phase
                        Owner = $owner
                        LastUpdated = $updated
                    })
                }
                $sortedTable = $table | Sort-Object -Property @{
                    Expression = {
                        if ($_.Phase -in @("CLAIMED", "IMPLEMENTING", "IMPLEMENTATION", "QA_PLAN", "TEST_PLAN_AUDIT", "REVIEW", "PLANNING")) { 0 }
                        elseif ($_.Phase -eq "APPROVED_GATES") { 1 }
                        elseif ($_.Phase -in @("DONE", "DELIVERED")) { 3 }
                        else { 2 }
                    }
                    Ascending = $true
                }, @{
                    Expression = { $_.LastUpdated }
                    Descending = $true
                }
                $sortedTable | Format-Table -AutoSize
                Write-Host "[INFO] 提示: 运行 'ai-sop.ps1 Status -Feature <Name>' 查看单个功能的详细门禁与进度。" -ForegroundColor Yellow
                return
            }
        }
        Write-Host "Usage: ai-sop.ps1 Status -Feature <Name> [-SpecDirectory <dir>]"
        Write-Host "  Shows gate approval state + feature-state.json progress."
        return
    }
    if (-not $SpecDir) { $SpecDir = Join-Path $WorkspaceRoot ".ai-workspace/specs/features/$FeatureName" }
    $approvalPath = Join-Path $SpecDir "00_workflow_state.json"
    $stateScript = Join-Path $WorkspaceRoot ".ai-sop/scripts/workflow-state.ps1"
    $featStateScript = Join-Path $WorkspaceRoot ".ai-sop/scripts/feature-state.ps1"

    Write-Host "=== Gate Approval State ===" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $stateScript -PathType Leaf) {
        if (Test-Path -LiteralPath $approvalPath -PathType Leaf) {
            & $stateScript -Operation Status -Path $approvalPath
        } else {
            Write-Host "  NO_STATE: 00_workflow_state.json not found at $approvalPath"
        }
    } else {
        Write-Host "  .ai-sop submodule not initialized — run 'ai-sop.ps1 Install' first." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "=== Feature Progress (feature-state.json) ===" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $featStateScript -PathType Leaf) {
        & $featStateScript -Operation Get -Feature $FeatureName -SpecDirectory $SpecDir
    } else {
        Write-Host "  feature-state.ps1 not found — run 'ai-sop.ps1 Install' first." -ForegroundColor Yellow
    }

    # Conventions one-line status (matches AGENTS.md required reply format).
    $featStatePath = Join-Path $SpecDir "feature-state.json"
    $hasApproval = Test-Path -LiteralPath $approvalPath -PathType Leaf
    $hasFeatState = Test-Path -LiteralPath $featStatePath -PathType Leaf
    if ($hasFeatState) {
        try {
            $fs = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json
            $tier = [string]$fs.tier
            $phase = [string]$fs.phase
            $next = if ($fs.nextAction) { [string]$fs.nextAction } else { "?" }
            $owner = if ($fs.ownerSession -and $fs.ownerSession.ownerId) { [string]$fs.ownerSession.ownerId } else { "none" }
            Write-Host ""
            Write-Host "档位=$tier | 阶段=$phase | 下一步=$next | owner=$owner" -ForegroundColor Green
        } catch { }
    } elseif ($hasApproval) {
        try {
            $st = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json
            $reqStat = $st.requirement.status
            $desStat = $st.design.status
            $mode = if ($st.gateMode) { [string]$st.gateMode } else { "DUAL" }
            Write-Host ""
            Write-Host "档位=T3 | 阶段=GATES($($mode): 需求=$reqStat, 设计=$desStat) | 下一步=推进计划与实现 | owner=none" -ForegroundColor Green
        } catch { }
    } else {
        Write-Host ""
        Write-Host "[HINT] Feature '$FeatureName' 尚未初始化。可通过在 AI 聊天框输入 `"开发新功能 $FeatureName`" 开始任务。" -ForegroundColor Yellow
    }

    # VCS summary
    try {
        if (Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".svn") -PathType Container) {
            $svnStatus = & svn status --ignore-externals $WorkspaceRoot 2>&1
            if ($LASTEXITCODE -eq 0) {
                $modCount = @($svnStatus | Where-Object { $_ -match '^[MADRC]' }).Count
                $untrackedCount = @($svnStatus | Where-Object { $_ -match '^\?' }).Count
                $missingCount = @($svnStatus | Where-Object { $_ -match '^\!' }).Count
                Write-Host "VCS=SVN | $modCount 个已修改, $untrackedCount 个未跟踪, $missingCount 个丢失未标记删除" -ForegroundColor Gray
            }
        } elseif (Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git") -PathType Container) {
            $gitStatus = & git -C $WorkspaceRoot status --porcelain 2>&1
            if ($LASTEXITCODE -eq 0) {
                $modCount = @($gitStatus | Where-Object { $_ -notmatch '^\?\?' }).Count
                $untrackedCount = @($gitStatus | Where-Object { $_ -match '^\?\?' }).Count
                Write-Host "VCS=Git | $modCount 个已修改, $untrackedCount 个未跟踪" -ForegroundColor Gray
            }
        }
    } catch { }
}

# --- Install/Update/Verify (delegate to installer) ---
function Invoke-Installer {
    param([string]$Mode)  # Install / Update / Verify
    $installerAction = if ($Mode -eq "Verify") { "Verify" } else { "Install" }
    $installer = Join-Path $WorkspaceRoot "tools/ai-sop/install-ai-sop.ps1"
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        $fallback = Join-Path $WorkspaceRoot ".ai-sop/distribution/bootstrap/install-ai-sop.ps1"
        if (Test-Path -LiteralPath $fallback -PathType Leaf) {
            $installer = $fallback
        } else {
            Write-Host "Installer not found: $installer" -ForegroundColor Red
            Write-Host "This directory may not be an AI SOP workspace root." -ForegroundColor Red
            exit 1
        }
    }
    # Initialize .ai-sop submodule if missing (fresh clone/checkout).
    $sopDir = Join-Path $WorkspaceRoot ".ai-sop"
    $dispExists = Test-Path -LiteralPath (Join-Path $sopDir "scripts/hook-dispatcher.ps1") -PathType Leaf
    if (-not $dispExists) {
        if (Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git")) {
            # Git workspace: init submodule.
            Write-Host "Initializing .ai-sop submodule..." -ForegroundColor Cyan
            & git -C $WorkspaceRoot submodule update --init --recursive 2>&1 | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "git submodule update failed. Try: git submodule update --init --recursive" -ForegroundColor Red
                exit 1
            }
        } else {
            # No .git — could be SVN checkout or pure SVN workspace.
            # Don't exit! Delegate to installer which will use -Mode Auto -> Svn
            # and clone the SOP repo via lock's sourceUrl+commit.
            Write-Host "No .ai-sop and no .git — attempting Svn install (clone from lock sourceUrl)..." -ForegroundColor Yellow
        }
    }
    & $installer -Mode Auto -Action $installerAction -WorkspaceRoot $WorkspaceRoot
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    # Run Doctor after Install (help says 'install + self-check').
    if ($installerAction -eq "Install" -and $code -eq 0) {
        $postDoctor = Join-Path $WorkspaceRoot ".ai-sop/scripts/doctor.ps1"
        if (Test-Path -LiteralPath $postDoctor -PathType Leaf) {
            Write-Host ""
            Write-Host "=== Post-install self-check ===" -ForegroundColor Cyan
            & $postDoctor
            $code = $LASTEXITCODE
            if ($null -eq $code) { $code = 0 }
        }
        if ($code -eq 0) {
            Write-Host ""
            Write-Host "==================================================================" -ForegroundColor Green
            Write-Host "  ✅ AI SOP 安装完成。" -ForegroundColor Green
            Write-Host "  👉 下一步：在你的 AI 工具中输入 ""开发新功能 <FeatureName>"" 开始任务。" -ForegroundColor Cyan
            Write-Host "  📖 完整手册：.ai-sop/SUPERPOWERS_MANUAL.md" -ForegroundColor Gray
            Write-Host "  🩺 环境自检：pwsh -NoProfile -File ./ai-sop.ps1 Doctor" -ForegroundColor Gray
            Write-Host "==================================================================" -ForegroundColor Green
            Write-Host ""
        }
    }
    exit $code
}

# --- Help ---
function Show-Help {
    Write-Host @"
AI SOP unified entry point.

Usage:
  pwsh -NoProfile -File ./ai-sop.ps1 <Action> [options]

Actions:
  Install    Initialize submodule + generate projections + self-check.
  Doctor     Environment self-check (runs even if .ai-sop not initialized).
  Update     Re-generate projections (same as Install).
  Verify     Read-only verification of projections vs lock.
  Status     Show gate approval state + feature progress for a feature.
  Help       Show this help.

Options:
  -Feature <Name>         Feature name (for Status).
  -SpecDirectory <path>   Spec dir (default: .ai-workspace/specs/features/<Feature>).

New users: run 'Doctor' first, then 'Install'.
"@
}

# --- Dispatch ---
switch ($Action) {
    "Doctor" { Invoke-Doctor }
    "Install" { Invoke-Installer -Mode "Install" }
    "Update" { Invoke-Installer -Mode "Update" }
    "Verify" { Invoke-Installer -Mode "Verify" }
    "Status" { Invoke-Status -FeatureName $Feature -SpecDir $SpecDirectory }
    "Help" { Show-Help }
    default { Show-Help }
}
