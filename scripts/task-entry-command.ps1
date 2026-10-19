#requires -Version 7.0

# 只识别独立的任务管理命令，避免“先有任务才能建立任务”的引导循环。
function Get-AiSopTaskEntryCommand {
    [CmdletBinding()]
    param(
        [string]$CommandText,
        [string]$WorkspacePath,
        [string]$Cwd,
        [string]$Agent,
        [string]$NativeSessionId,
        [System.Collections.IDictionary]$ToolArguments
    )
    if ([string]::IsNullOrWhiteSpace($CommandText)) { return $null }
    # 同一工具入口可能使用不同 Shell；反引号在 Bash 中会执行命令替换。
    # 引导命令统一使用单行字面参数，避免把 PowerShell 转义当作跨 Shell 安全依据。
    if ($CommandText.Contains([char]96)) { return $null }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($CommandText,[ref]$tokens,[ref]$errors)
    if ($errors.Count -or $ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.CleanBlock -or
        $ast.UsingStatements.Count -or $ast.EndBlock.Traps.Count -or @($ast.EndBlock.Statements).Count -ne 1) { return $null }
    $statement=$ast.EndBlock.Statements[0]
    if ($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.Background -or
        $statement.PipelineElements.Count -ne 1) { return $null }
    $command=$statement.PipelineElements[0]
    if ($command -isnot [Management.Automation.Language.CommandAst] -or $command.Redirections.Count -or
        $command.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Unknown) { return $null }
    $parts=@($command.CommandElements)
    if ($parts.Count -lt 5 -or $parts[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
        $parts[0].Value -notin @('pwsh','pwsh.exe') -or
        $parts[1] -isnot [Management.Automation.Language.CommandParameterAst] -or $parts[1].ParameterName -ine 'NoProfile' -or $parts[1].Argument -or
        $parts[2] -isnot [Management.Automation.Language.CommandParameterAst] -or $parts[2].ParameterName -ine 'File' -or $parts[2].Argument -or
        $parts[3] -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return $null }

    $workspace=Resolve-PhysicalPathIdentity $WorkspacePath
    $comparison=if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $working=if ($Cwd) { Resolve-PhysicalPathIdentity $Cwd } else { $workspace }
    foreach ($name in @('cwd','workdir','working_directory','workingDirectory')) {
        if ($ToolArguments -and $ToolArguments.Contains($name)) {
            $value=$ToolArguments[$name]
            # Cursor 的空 cwd 表示沿用已规范化的调用目录，不表示另一个工作区。
            if ($Agent -ceq 'CURSOR' -and $name -ceq 'cwd' -and $value -is [string] -and $value.Length -eq 0) { continue }
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { return $null }
            $candidate=if ([IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $working $value }
            if (-not (Resolve-PhysicalPathIdentity $candidate).Equals($workspace,$comparison)) { return $null }
            $working=$workspace
        }
    }
    # 引导示例从宿主根执行；不猜测 Shell 在其他目录下如何解析同名入口。
    if (-not $working.Equals($workspace,$comparison)) { return $null }
    $scriptCandidate=if ([IO.Path]::IsPathRooted($parts[3].Value)) { $parts[3].Value } else { Join-Path $working $parts[3].Value }
    $scriptPath=Resolve-PhysicalPathIdentity $scriptCandidate
    $prefix=$workspace.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if (-not $scriptPath.StartsWith($prefix,$comparison)) { return $null }
    $rootEntry=Resolve-PhysicalPathIdentity (Join-Path $workspace 'ai-sop.ps1')
    $engineEntry=Resolve-PhysicalPathIdentity (Join-Path $workspace '.ai-sop/scripts/workflow-task.ps1')
    if (-not [IO.File]::Exists($scriptPath)) { return $null }
    $index=4
    if ($scriptPath.Equals($rootEntry,$comparison)) {
        if ($parts[$index] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $parts[$index].Value -ine 'Task') { return $null }
        $index++
    } elseif (-not $scriptPath.Equals($engineEntry,$comparison)) { return $null }

    $switches=@('Json','IncludeHistory','RecheckHistory','CaptureBaseline','ConfirmTakeover','ForceRecovery','QuarantineInvalidEvidence')
    $values=@('Operation','Feature','TaskId','Tier','Objective','Agent','NativeSessionId','WorkspacePath','SpecDirectory','NextAction','Notes','UserRequest','Reason','LogTailLines','OutputFormat','ChildNativeSessionId','DelegationMinutes')
    $parameters=@{}
    while ($index -lt $parts.Count) {
        $parameter=$parts[$index]
        if ($parameter -isnot [Management.Automation.Language.CommandParameterAst] -or $parameter.Argument) { return $null }
        $name=$parameter.ParameterName
        if ($parameters.ContainsKey($name)) { return $null }
        $index++
        if ($name -in $switches) { $parameters[$name]=$true; continue }
        if ($name -notin $values -or $index -ge $parts.Count) { return $null }
        $value=$parts[$index]
        if ($value -is [Management.Automation.Language.StringConstantExpressionAst]) { $parameters[$name]=$value.Value }
        elseif ($name -in @('LogTailLines','DelegationMinutes') -and $value -is [Management.Automation.Language.ConstantExpressionAst] -and $value.Value -is [int]) { $parameters[$name]=$value.Value }
        else { return $null }
        $index++
    }
    $readOperations=@('Discover','Status','FollowUps','InspectRecovery','Changes')
    $writeOperations=@('Start','Resume','Recover','Suspend','Cancel','ChangeTier','Join','Delegate','RevokeDelegation')
    $operation=if ($parameters.ContainsKey('Operation')) { $parameters.Operation } elseif ($scriptPath.Equals($rootEntry,$comparison)) { 'Discover' } else { '' }
    if ($operation -notin ($readOperations+$writeOperations)) { return $null }
    if ($parameters.ContainsKey('Agent') -and $parameters.Agent -cne $Agent) { return $null }
    if ($parameters.ContainsKey('NativeSessionId') -and (-not $NativeSessionId -or $parameters.NativeSessionId -cne $NativeSessionId)) { return $null }
    if ($operation -in $writeOperations -and -not $parameters.ContainsKey('Agent')) { return $null }
    if ($parameters.ContainsKey('Tier') -and $parameters.Tier -notin @('T1','T2','T3')) { return $null }
    if ($parameters.ContainsKey('WorkspacePath')) {
        if ($scriptPath.Equals($rootEntry,$comparison)) { return $null }
        $candidate=if ([IO.Path]::IsPathRooted($parameters.WorkspacePath)) { $parameters.WorkspacePath } else { Join-Path $workspace $parameters.WorkspacePath }
        if (-not (Resolve-PhysicalPathIdentity $candidate).Equals($workspace,$comparison)) { return $null }
    }
    if ($parameters.ContainsKey('Feature') -and $parameters.Feature -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$') { return $null }
    if ($parameters.ContainsKey('TaskId') -and $parameters.TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { return $null }
    if ($parameters.ContainsKey('SpecDirectory')) {
        if (-not $parameters.Feature) { return $null }
        $candidate=if ([IO.Path]::IsPathRooted($parameters.SpecDirectory)) { $parameters.SpecDirectory } else { Join-Path $workspace $parameters.SpecDirectory }
        $expected=Resolve-PhysicalPathIdentity (Join-Path $workspace ".ai-workspace/specs/features/$($parameters.Feature)")
        if (-not $expected.StartsWith($prefix,$comparison) -or -not (Resolve-PhysicalPathIdentity $candidate).Equals($expected,$comparison)) { return $null }
    }
    return @{ operation=$operation; reasonCode='TASK_BOOTSTRAP_COMMAND' }
}
