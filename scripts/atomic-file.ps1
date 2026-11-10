#requires -Version 7.0
# Windows MoveFileEx cannot replace an open target; ReplaceFile can expose a
# missing name. Use a single POSIX rename on Windows and the native rename used
# by File.Move(overwrite) on Unix. Never fall back to delete-then-move.
. (Join-Path $PSScriptRoot 'native-types.ps1')
Initialize-AiSopNativeTypes

function Move-AiSopWorkflowFileAtomic {
    param([string]$Source, [string]$Target)
    if ([OperatingSystem]::IsWindows()) { [AiSop.AtomicFile]::Publish($Source, $Target) }
    else { [IO.File]::Move($Source, $Target, $true) }
}
