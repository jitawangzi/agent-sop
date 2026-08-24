#requires -Version 7.0
# Cross-Harness Native Tool Compatibility Matrix Tests
# Verifies that every supported agent harness (Claude Code, Antigravity, Cursor, Copilot, Pi)
# has all its native tool names and real argument shapes properly normalized and authorized.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$ClaudeRoot = Split-Path -Parent $ScriptsRoot
$NormalizerScript = Join-Path $ScriptsRoot "hook-event-normalizer.ps1"
$DispatcherScript = Join-Path $ScriptsRoot "hook-dispatcher.ps1"
$PolicyPath = Join-Path $ClaudeRoot "config\hook-tool-policy.json"

foreach ($f in @($NormalizerScript, $DispatcherScript, $PolicyPath)) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        throw "Required script missing: $f"
    }
}

. $NormalizerScript

$TestWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ("tool-matrix-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TestWorkspace -Force | Out-Null

$PassCount = 0
$FailCount = 0

function Assert-ToolAuthorized {
    param(
        [string]$AgentName,
        [string]$ToolName,
        [hashtable]$Arguments,
        [string]$ExpectedToolClass,
        [string]$TestDescription
    )

    $payload = [ordered]@{
        conversationId = "matrix-$AgentName"
        workspacePaths = @($TestWorkspace)
        toolCall = [ordered]@{
            name = $ToolName
            args = $Arguments
        }
    } | ConvertTo-Json -Compress -Depth 15

    try {
        $event = ConvertTo-AiSopHookEvent `
            -RawPayload $payload `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $TestWorkspace `
            -AcceptedAt ([DateTimeOffset]::UtcNow) `
            -ToolPolicyPath $PolicyPath

        if ($event.toolClass -ne $ExpectedToolClass) {
            throw "Expected toolClass '$ExpectedToolClass', got '$($event.toolClass)'"
        }
        $script:PassCount++
        Write-Host "  PASS  [$AgentName] $ToolName -> $ExpectedToolClass ($TestDescription)" -ForegroundColor Green
    } catch {
        $script:FailCount++
        Write-Host "  FAIL  [$AgentName] $ToolName ($TestDescription)" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

try {
    Write-Host "`n=== 1. Antigravity Native Tool Matrix ===" -ForegroundColor Cyan

    $targetFile = Join-Path $TestWorkspace "test-doc.md"

    # Antigravity File Creation / Write tools
    Assert-ToolAuthorized "ANTIGRAVITY" "write_to_file" @{
        TargetFile = $targetFile
        CodeContent = "# Title"
        Description = "Write file"
        Overwrite = $true
        toolAction = "Writing file"
        toolSummary = "Write file"
    } "FILE_EDIT" "write_to_file with PascalCase args"

    Assert-ToolAuthorized "ANTIGRAVITY" "WriteToFile" @{
        TargetFile = $targetFile
        CodeContent = "# Title"
        Description = "Write file"
        Overwrite = $true
        toolAction = "Writing file"
        toolSummary = "Write file"
    } "FILE_EDIT" "WriteToFile with PascalCase args"

    Assert-ToolAuthorized "ANTIGRAVITY" "Create" @{
        TargetFile = $targetFile
        CodeContent = "# Spec Rules"
        Description = "Create spec"
        Overwrite = $true
        ArtifactMetadata = @{ Summary = "Spec"; UserFacing = $true; RequestFeedback = $false }
    } "FILE_EDIT" "Create with ArtifactMetadata"

    # Antigravity File Edit tools
    Assert-ToolAuthorized "ANTIGRAVITY" "replace_file_content" @{
        TargetFile = $targetFile
        Instruction = "Update clause"
        Description = "Fix DC-01"
        TargetContent = "old text"
        ReplacementContent = "new text"
        StartLine = 1
        EndLine = 5
        AllowMultiple = $false
        toolAction = "Editing"
        toolSummary = "Edit"
    } "FILE_EDIT" "replace_file_content with TargetContent/ReplacementContent"

    Assert-ToolAuthorized "ANTIGRAVITY" "ReplaceFileContent" @{
        TargetFile = $targetFile
        Instruction = "Update clause"
        Description = "Fix DC-01"
        TargetContent = "old text"
        ReplacementContent = "new text"
        StartLine = 1
        EndLine = 5
        AllowMultiple = $false
    } "FILE_EDIT" "ReplaceFileContent PascalCase"

    Assert-ToolAuthorized "ANTIGRAVITY" "Edit" @{
        TargetFile = $targetFile
        Instruction = "Edit rule"
        Description = "Update"
        TargetContent = "A"
        ReplacementContent = "B"
        StartLine = 1
        EndLine = 2
    } "FILE_EDIT" "Edit PascalCase"

    # Antigravity Safe / Read / Exploration tools
    Assert-ToolAuthorized "ANTIGRAVITY" "view_file" @{
        AbsolutePath = $targetFile
        toolAction = "Viewing file"
        toolSummary = "View file"
    } "SAFE_NON_EDIT" "view_file with AbsolutePath"

    Assert-ToolAuthorized "ANTIGRAVITY" "ViewFile" @{
        AbsolutePath = $targetFile
        StartLine = 1
        EndLine = 100
    } "SAFE_NON_EDIT" "ViewFile PascalCase"

    Assert-ToolAuthorized "ANTIGRAVITY" "list_dir" @{
        DirectoryPath = $TestWorkspace
        toolAction = "Listing dir"
        toolSummary = "List dir"
    } "SAFE_NON_EDIT" "list_dir with DirectoryPath"

    Assert-ToolAuthorized "ANTIGRAVITY" "ListDir" @{
        DirectoryPath = $TestWorkspace
    } "SAFE_NON_EDIT" "ListDir PascalCase"

    Assert-ToolAuthorized "ANTIGRAVITY" "find_by_name" @{
        SearchDirectory = $TestWorkspace
        Pattern = "*.md"
        toolAction = "Searching"
        toolSummary = "Search"
    } "SAFE_NON_EDIT" "find_by_name"

    Assert-ToolAuthorized "ANTIGRAVITY" "grep_search" @{
        SearchPath = $TestWorkspace
        Query = "DC-01"
    } "SAFE_NON_EDIT" "grep_search"

    Assert-ToolAuthorized "ANTIGRAVITY" "ask_question" @{
        questions = @(@{ question = "Confirm?"; options = @("Yes", "No") })
    } "SAFE_NON_EDIT" "ask_question"

    Assert-ToolAuthorized "ANTIGRAVITY" "AskQuestion" @{
        questions = @(@{ question = "Confirm?"; options = @("Yes", "No") })
    } "SAFE_NON_EDIT" "AskQuestion PascalCase"

    Assert-ToolAuthorized "ANTIGRAVITY" "invoke_subagent" @{
        Subagents = @(@{ TypeName = "research"; Role = "Reviewer"; Prompt = "Check" })
    } "SAFE_NON_EDIT" "invoke_subagent"

    Assert-ToolAuthorized "ANTIGRAVITY" "Read" @{
        path = $targetFile
    } "SAFE_NON_EDIT" "Read PascalCase"

    Assert-ToolAuthorized "ANTIGRAVITY" "Find" @{
        pattern = "*.java"
    } "SAFE_NON_EDIT" "Find PascalCase"

    Assert-ToolAuthorized "ANTIGRAVITY" "Agent" @{
        prompt = "Review"
    } "SAFE_NON_EDIT" "Agent PascalCase"

    Write-Host "`n=== 2. Claude Code Native Tool Matrix ===" -ForegroundColor Cyan
    $claudePayload = [ordered]@{
        session_id = "claude-session-001"
        cwd = $TestWorkspace
        hook_event_name = "PreToolUse"
        timestamp = [DateTimeOffset]::UtcNow.ToString("o")
        tool_name = "Write"
        tool_input = [ordered]@{
            file_path = $targetFile
            content = "# Claude Content"
        }
    } | ConvertTo-Json -Compress -Depth 10

    $claudeEv = ConvertTo-AiSopHookEvent `
        -RawPayload $claudePayload `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $TestWorkspace `
        -AcceptedAt ([DateTimeOffset]::UtcNow) `
        -ToolPolicyPath $PolicyPath

    if ($claudeEv.toolClass -eq "FILE_EDIT") {
        $PassCount++
        Write-Host "  PASS  [CLAUDE_CODE] Write -> FILE_EDIT" -ForegroundColor Green
    } else {
        $FailCount++
        Write-Host "  FAIL  [CLAUDE_CODE] Write" -ForegroundColor Red
    }

    Write-Host "`n=== 3. Cursor Native Tool Matrix ===" -ForegroundColor Cyan
    $cursorPayload = [ordered]@{
        conversation_id = "cursor-conv-001"
        generation_id = "gen-001"
        hook_event_name = "preToolUse"
        cwd = $TestWorkspace
        workspace_roots = @($TestWorkspace)
        tool_name = "write_file"
        tool_input = [ordered]@{
            path = $targetFile
            content = "# Cursor Content"
        }
    } | ConvertTo-Json -Compress -Depth 10

    try {
        $cursorEv = ConvertTo-AiSopHookEvent `
            -RawPayload $cursorPayload `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $TestWorkspace `
            -AcceptedAt ([DateTimeOffset]::UtcNow) `
            -ToolPolicyPath $PolicyPath

        if ($cursorEv.toolClass -eq "FILE_EDIT") {
            $PassCount++
            Write-Host "  PASS  [CURSOR] write_file -> FILE_EDIT" -ForegroundColor Green
        } else {
            $FailCount++
            Write-Host "  FAIL  [CURSOR] write_file (got $($cursorEv.toolClass))" -ForegroundColor Red
        }
    } catch {
        $FailCount++
        Write-Host "  FAIL  [CURSOR] write_file: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`n=== 4. Copilot Native Tool Matrix ===" -ForegroundColor Cyan
    $copilotPayload = [ordered]@{
        sessionId = "copilot-session-001"
        timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        cwd = $TestWorkspace
        toolName = "edit"
        toolArgs = [ordered]@{
            path = $targetFile
            oldText = "A"
            newText = "B"
        }
    } | ConvertTo-Json -Compress -Depth 10

    $copilotEv = ConvertTo-AiSopHookEvent `
        -RawPayload $copilotPayload `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $TestWorkspace `
        -AcceptedAt ([DateTimeOffset]::UtcNow) `
        -ToolPolicyPath $PolicyPath

    if ($copilotEv.toolClass -eq "FILE_EDIT") {
        $PassCount++
        Write-Host "  PASS  [COPILOT] edit -> FILE_EDIT" -ForegroundColor Green
    } else {
        $FailCount++
        Write-Host "  FAIL  [COPILOT] edit" -ForegroundColor Red
    }

} finally {
    Remove-Item -LiteralPath $TestWorkspace -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=========================================="
Write-Host "Tool Matrix Tests: $PassCount passed, $FailCount failed"
if ($FailCount -gt 0) {
    exit 1
}
exit 0
