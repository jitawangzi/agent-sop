#requires -Version 7.0

function Get-AiSopTaskPath {
    param([string]$SpecDirectory, [string]$TaskId)
    if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw 'TASK_ID_INVALID' }
    $root = Resolve-PhysicalPathIdentity -Path $SpecDirectory
    $path = Resolve-PhysicalPathIdentity -Path (Join-Path $root "tasks/$TaskId/task.json")
    $prefix = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $path.StartsWith($prefix, $comparison)) { throw 'TASK_PATH_ESCAPE' }
    return $path
}

function Read-AiSopTask {
    param([string]$SpecDirectory, [string]$TaskId)
    $path = Get-AiSopTaskPath $SpecDirectory $TaskId
    if (-not [IO.File]::Exists($path)) { throw "TASK_NOT_FOUND: $TaskId" }
    $raw = [IO.File]::ReadAllText($path)
    Assert-AiSopWorkflowJsonSchema -Json $raw -SchemaId TASK
    $task = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
    if ($task.taskId -cne $TaskId -or $task.feature -cne (Split-Path -Leaf $SpecDirectory)) { throw 'TASK_IDENTITY_MISMATCH' }
    return $task
}


# 同步的执行位置只用于区分任务来源；写权限仍由本地 owner/session 授予。
function Get-AiSopTaskExecutionLocality {
    param($Task, [string]$WorkspacePath)
    if (-not $Task.executionLocation) { return 'UNKNOWN' }
    if (-not ([string]$Task.executionLocation.machine).Equals([Environment]::MachineName,[StringComparison]::OrdinalIgnoreCase)) { return 'EXTERNAL' }
    $comparison=if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $recorded=Resolve-PhysicalPathIdentity ([string]$Task.executionLocation.workspace)
    $current=Resolve-PhysicalPathIdentity $WorkspacePath
    if ($recorded.Equals($current,$comparison)) { return 'LOCAL' }
    return 'EXTERNAL'
}

function Set-AiSopTaskExecutionLocation {
    param($Task, [string]$WorkspacePath, [string]$At)
    $Task.schemaVersion='1.1'
    $Task['executionLocation']=@{machine=[Environment]::MachineName;workspace=(Resolve-PhysicalPathIdentity $WorkspacePath);boundAt=$At}
}

function Get-AiSopTaskParallelProblems {
    param([string]$SpecDirectory, [string]$TaskId, [string]$WorkspacePath, [string]$Tier)
    $root=Resolve-PhysicalPathIdentity $SpecDirectory
    foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $root 'tasks') -Directory -ErrorAction SilentlyContinue)) {
        if ($entry.Name -ceq $TaskId) { continue }
        try {
            $path=Get-AiSopTaskPath $root $entry.Name
            if (-not [IO.File]::Exists($path)) { continue }
            $other=Read-AiSopTask $root $entry.Name
            if ($other.status -ne 'ACTIVE') { continue }
            $locality=Get-AiSopTaskExecutionLocality $other $WorkspacePath
        } catch { "TASK_INDEX_UNREADABLE:$($entry.Name):$($_.Exception.Message)"; continue }
        if ($locality -ne 'EXTERNAL') {
            "TASK_ACTIVE_CONFLICT:$($other.taskId): local or unknown execution location; Resume or Suspend/Recover this task before independent work. No old completion gates are required."
        } elseif ($Tier -eq 'T3' -and $other.tier -eq 'T3') {
            "TASK_PARALLEL_T3_UNSUPPORTED:$($other.taskId): another synchronized T3 is ACTIVE in $($other.executionLocation.workspace). Preserve both workspaces, Suspend one at its origin, sync that task record, then continue. See .ai-sop/docs/PARALLEL_TASKS.md."
        }
    }
}
