#requires -Version 7.0

function Resolve-AiSopFeatureName {
    param([string]$WorkspacePath, [string]$Feature)
    if (-not $Feature) { return '' }
    if ($Feature -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$') { throw 'FEATURE_INVALID' }
    $root = Resolve-AiSopWorkspaceChild $WorkspacePath '.ai-workspace/specs/features'
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        if ($dir.Name.Equals($Feature, $comparison)) { return $dir.Name }
    }
    return $Feature
}

function Get-AiSopDeploymentWarnings {
    param([string]$WorkspacePath)
    $engine = Resolve-AiSopWorkspaceChild $WorkspacePath '.ai-sop'
    if (-not [IO.File]::Exists((Join-Path $engine 'scripts/workflow-task.ps1'))) { return }
    foreach ($name in @('ai-sop.ps1','AGENTS.md')) {
        $template = Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-sop/distribution/templates/root/$name"
        if (-not [IO.File]::Exists($template)) { continue }
        $target = Resolve-AiSopWorkspaceChild $WorkspacePath $name
        if (-not [IO.File]::Exists($target) -or (Get-FileHash -LiteralPath $template).Hash -cne (Get-FileHash -LiteralPath $target).Hash) {
            "DEPLOYMENT_PROJECTION_STALE: $name differs from the installed engine; run the installed tools/ai-sop/install-ai-sop.ps1 installer (-Action Install -Mode Auto) to refresh projections, then Doctor."
        }
    }
    $lockPath = Resolve-AiSopWorkspaceChild $WorkspacePath 'tools/ai-sop/ai-sop.lock.json'
    if ([IO.File]::Exists($lockPath) -and (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        try {
            $lock = ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($lockPath)) -AsHashtable
            $gitRoot = & git -C $engine rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and (Resolve-PhysicalPathIdentity ([string]$gitRoot)) -ceq $engine) {
                $head = & git -C $engine rev-parse HEAD 2>$null
                if ($LASTEXITCODE -eq 0 -and $lock.commit -and $lock.commit -cne [string]$head) { 'DEPLOYMENT_ENGINE_DRIFT: installed engine HEAD differs from the lock; run ai-sop.ps1 Verify and refresh the installation deliberately.' }
            }
        } catch { "DEPLOYMENT_LOCK_INVALID: $lockPath; $($_.Exception.Message)" }
    }
}

function Get-AiSopLegacyTaskSummary {
    param([string]$SpecDirectory, [string]$WorkspacePath)
    $feature = Split-Path -Leaf $SpecDirectory
    $result = @{ feature=$feature; taskId=$null; status='LEGACY'; tier='UNKNOWN'; phase='UNKNOWN'; recordedApprovals=(Get-AiSopRecordedApprovals $SpecDirectory); diagnostics=@(); suggestedAction='Legacy feature state is not an independent task. Use Start with a new TaskId for new work; use Resume explicitly to adopt unfinished ownership, preserving its tier.' }
    $path = Join-Path $SpecDirectory 'feature-state.json'
    if ([IO.File]::Exists($path)) {
        try {
            $state=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($path)) -AsHashtable
            $result.tier=[string]$state.tier; $result.phase=[string]$state.phase
        } catch { $result.diagnostics += "LEGACY_STATE_INVALID: $path; $($_.Exception.Message)" }
    }
    $ownerPath = Join-Path (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $WorkspacePath) ($feature.ToLowerInvariant() + '.json')
    $result.ownerStatus='MISSING'
    if ([IO.File]::Exists($ownerPath)) {
        try {
            $raw=[IO.File]::ReadAllText($ownerPath); Assert-AiSopWorkflowJsonSchema -Json $raw -SchemaId OWNER
            $owner=ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
            $result.ownerStatus=$owner.status; $result.ownerId=$owner.ownerId
        } catch { $result.ownerStatus='UNAVAILABLE'; $result.diagnostics += "LEGACY_OWNER_INVALID: $($_.Exception.Message)" }
    }
    return $result
}

function Write-AiSopTaskStatus {
    param($Items, [string]$WorkspacePath, [string]$Operation, [string]$Format, [string[]]$Warnings)
    if ($Format -eq 'Json') {
        # Exactly one JSON document; tasks is always an array (including zero).
        [ordered]@{ schemaVersion='1.0'; operation=$Operation; workspace=$WorkspacePath; tasks=@($Items); warnings=@($Warnings) } | ConvertTo-Json -Depth 20
    } elseif ($Format -eq 'JsonLines') {
        foreach ($item in $Items) { $item | ConvertTo-Json -Depth 20 -Compress }
        foreach ($warning in $Warnings) { Write-Warning $warning }
    } else {
        Write-Output "$Operation — $WorkspacePath"
        if (-not $Items.Count) { Write-Output 'No unfinished tasks or pending follow-ups. Use -IncludeHistory to inspect completed work.' }
        foreach ($item in $Items) {
            Write-Output "[$($item.status)] $($item.feature)/$($item.taskId) $($item.tier) — $($item.objective)"
            Write-Output "  owner=$($item.ownerStatus) session=$($item.sessionStatus) evidence=$($item.verification)"
            if ($item.nextAction) { Write-Output "  checkpoint: $($item.nextAction)" }
            Write-Output "  next: $($item.suggestedAction)"
            foreach ($run in $item.runs) { Write-Output "  run: $($run.kind)/$($run.batch) $($run.activity) log=$($run.logFile)" }
            foreach ($failed in $item.failedVerifications) { Write-Output "  failed verification: $($failed.kind)/$($failed.batch) exit=$($failed.exitCode) $($failed.outcome)" }
            foreach ($followUp in $item.pendingFollowUps) { Write-Output "  follow-up (non-blocking): $($followUp.id) $($followUp.summary)" }
            foreach ($diagnostic in @($item.diagnostics) + @($item.diagnostic) | Where-Object { $_ }) { Write-Output "  ! $diagnostic" }
        }
        foreach ($warning in $Warnings) { Write-Output "! $warning" }
    }
}
