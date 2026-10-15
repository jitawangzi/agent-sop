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
    [ValidateSet("Install", "Doctor", "Update", "Verify", "Status", "Task", "Help", "")]
    [string]$Action = "Help",

    [string]$Feature = "",
    [string]$SpecDirectory = "",
    [string]$Operation = 'Discover',
    [string]$TaskId,
    [ValidateSet('T1','T2','T3')][string]$Tier = 'T2',
    [string]$Objective,
    [string]$Agent,
    [string]$NextAction,
    [string]$Notes,
    [string]$Kind,
    [string]$Batch = 'main',
    [string]$Executable,
    [string[]]$Arguments = @(),
    [string[]]$CaseIds = @(),
    [string]$Profile,
    [ValidateRange(0,86400)][int]$TimeoutSeconds = 0,
    [switch]$ForceRecovery,
    [switch]$ConfirmTakeover,
    [string]$RunId,
    [string]$Reason,
    [string]$UserRequest,
    [string]$Documentation,
    [string]$Tests,
    [string]$Summary,
    [string]$Applicability,
    [string]$FollowUpId,
    [string]$FollowUpKind,
    [string[]]$Scope = @(),
    [string]$SourceTaskId,
    [string]$Disposition,
    [string]$Resolution,
    [switch]$Json,
    [ValidateSet('Human','JsonLines')][string]$OutputFormat = 'Human',
    [switch]$IncludeHistory
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
    $statusArgs = @{ Operation='Status'; WorkspacePath=$WorkspaceRoot; Json=$Json; OutputFormat=$OutputFormat; IncludeHistory=$IncludeHistory }
    if ($FeatureName) { $statusArgs.Feature=$FeatureName }
    if ($SpecDir) { $statusArgs.SpecDirectory=$SpecDir }
    if ($TaskId) { $statusArgs.TaskId=$TaskId }
    & (Join-Path $WorkspaceRoot '.ai-sop/scripts/workflow-task.ps1') @statusArgs
    exit $LASTEXITCODE
}

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
  Status     Show task, ownership, execution evidence and suggested next action.
  Task       Task discovery, independent changes, handoff and verification.
             Task -Operation Discover
             Task -Operation Start -Feature X -TaskId fix-1 -Tier T2 -Objective "Fix existing behaviour" -Agent CODEX
             Task -Operation Resume -Feature X -TaskId fix-1 -Agent CODEX
             Task -Operation Run -Feature X -TaskId fix-1 -Agent CODEX -Kind compile -Executable pwsh -Arguments ...
             Operations: Discover, Status, Start, Resume, Recover, Checkpoint, Suspend, Cancel, Run, RetryEvidence, ReviewImpact, Verify, Complete.
             Run accepts -Profile <name> and -TimeoutSeconds <seconds>.
             A changed batch command/case scope requires -Reason; previous attempts remain visible.
             RetryEvidence -RunId <id> saves a pending terminal result without rerunning the command.
             Resume -ConfirmTakeover records an intentional handoff from a potentially live session.
             Default tier: T2. ChangeTier requires -Tier, -Reason and -UserRequest.
             RecordSync -Documentation UPDATED|UNCHANGED -Tests UPDATED|UNCHANGED|NOT_APPLICABLE -Summary ...
             FollowUps lists non-blocking pending documentation/tests/verification work.
             AddFollowUp / CloseFollowUp record or resolve an item using the active task owner.
             SetApplicability records a concrete reason when compile/test is not applicable (T1/T2 only).
             Recover pauses orphaned tasks; -ForceRecovery confirms the old agent has stopped.
  Help       Show this help.

Options:
  -Json                   Status/Discover: one versioned JSON object with tasks[] and warnings[].
  -OutputFormat JsonLines Legacy status output, one JSON object per task.
  -IncludeHistory         Include completed/cancelled tasks without pending follow-ups.
  -Feature <Name>         Feature name (for Status).
  -SpecDirectory <path>   Spec dir (default: .ai-workspace/specs/features/<Feature>).

New users: run 'Doctor' first, then 'Install'.
"@
}

# --- Dispatch ---
if ($Action -in @('Task','Status') -and -not [IO.File]::Exists((Join-Path $WorkspaceRoot '.ai-sop/scripts/workflow-task.ps1'))) {
    throw 'TASK_ENGINE_MISSING: initialize/update .ai-sop, then run ai-sop.ps1 Install and Doctor before using Task or Status.'
}
switch ($Action) {
    "Task" {
        $taskArgs = @{ Operation=$Operation; WorkspacePath=$WorkspaceRoot }
        foreach ($name in @('Feature','SpecDirectory','TaskId','Tier','Objective','Agent','NextAction','Notes','Kind','Batch','Executable','Arguments','CaseIds','Profile','TimeoutSeconds','ForceRecovery','ConfirmTakeover','RunId','Reason','UserRequest','Documentation','Tests','Summary','Applicability','FollowUpId','FollowUpKind','Scope','SourceTaskId','Disposition','Resolution','Json','OutputFormat','IncludeHistory')) {
            if ($PSBoundParameters.ContainsKey($name)) { $taskArgs[$name] = $PSBoundParameters[$name] }
        }
        & (Join-Path $WorkspaceRoot '.ai-sop/scripts/workflow-task.ps1') @taskArgs
        exit $LASTEXITCODE
    }
    "Doctor" { Invoke-Doctor }
    "Install" { Invoke-Installer -Mode "Install" }
    "Update" { Invoke-Installer -Mode "Update" }
    "Verify" { Invoke-Installer -Mode "Verify" }
    "Status" { Invoke-Status -FeatureName $Feature -SpecDir $SpecDirectory }
    "Help" { Show-Help }
    default { Show-Help }
}
