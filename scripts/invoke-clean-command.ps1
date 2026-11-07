#requires -Version 7.0
# Child wrapper keeps working-directory changes and command exit status isolated.
param([Parameter(Mandatory)][string]$ManifestFile,[Parameter(Mandatory)][string]$WorkingDirectory)
$ErrorActionPreference='Stop'
$manifest=Get-Content -LiteralPath $ManifestFile -Raw|ConvertFrom-Json
Push-Location -LiteralPath $WorkingDirectory
try {
    $global:LASTEXITCODE=0
    & $manifest.command.executable @($manifest.command.arguments)
    $succeeded=$?
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
    if(-not $succeeded){exit 1}
    exit $LASTEXITCODE
} finally {Pop-Location}
