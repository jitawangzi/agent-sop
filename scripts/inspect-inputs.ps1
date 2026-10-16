#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$WorkspacePath=(Get-Location).Path,
    [string[]]$InputPath=@(),
    [string]$CandidatePolicy,
    [switch]$ExplainOnly,
    [switch]$Json
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'workflow-transaction.ps1')
. (Join-Path $PSScriptRoot 'verification-inputs.ps1')
. (Join-Path $PSScriptRoot 'input-diagnostics.ps1')
Write-AiSopInputInspection (Get-AiSopInputInspection $WorkspacePath $InputPath $CandidatePolicy -ExplainOnly:$ExplainOnly) -Json:$Json
exit 0
