#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$WorkspacePath=(Get-Location).Path,
    [string]$Feature,
    [string]$TaskId,
    [string]$TargetEnginePath,
    [switch]$IncludeHistory,
    [switch]$Json
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'task-context.ps1')
. (Join-Path $PSScriptRoot 'workflow-session.ps1')
. (Join-Path $PSScriptRoot 'handoff-preflight.ps1')
Write-AiSopHandoffPreflight (Get-AiSopHandoffPreflight $WorkspacePath $Feature $TaskId $TargetEnginePath -IncludeHistory:$IncludeHistory) -Json:$Json
exit 0
