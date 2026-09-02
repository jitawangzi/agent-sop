#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$SyncScript = Join-Path $ScriptsRoot "sync-defect-memory.ps1"

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-defect-memory-tests-" + [guid]::NewGuid().ToString("N"))
$SpecDir = Join-Path $TestRoot ".ai-workspace\specs\features\ShopFeature"
[System.IO.Directory]::CreateDirectory($SpecDir) | Out-Null
$ContextDir = Join-Path $TestRoot ".ai-workspace\context"
[System.IO.Directory]::CreateDirectory($ContextDir) | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

try {
    Write-Host "Running Defect Memory Sync Tests..." -ForegroundColor Cyan

    # 1. Create a dummy review-mailbox.json with historical rejected issues
    $mailboxPath = Join-Path $SpecDir "review-mailbox.json"
    $mailboxData = [ordered]@{
        schemaVersion = "1.0"
        feature = "ShopFeature"
        round = 2
        maxRounds = 4
        status = "WAITING_DEV"
        devAgent = "ANTIGRAVITY"
        reviewerAgent = "COPILOT"
        updatedAt = "2026-08-28T10:00:00Z"
        currentDevSubmission = $null
        currentReviewVerdict = $null
        history = @(
            [ordered]@{
                round = 1
                devSubmission = [ordered]@{
                    submittedAt = "2026-08-28T09:00:00Z"
                    summary = "Initial shop item exchange implementation"
                    changedFiles = @("src/com/game/ShopService.java")
                    testGateStatus = "PASS"
                    testOutput = "5 passed"
                    gitDiffDigest = "diff"
                }
                reviewVerdict = [ordered]@{
                    reviewedAt = "2026-08-28T09:30:00Z"
                    verdict = "REJECTED"
                    highestSeverity = "HIGH"
                    summary = "Rejected due to state mutation without persistence and static import"
                    issues = @(
                        [ordered]@{
                            file = "src/com/game/ShopService.java"
                            lineRange = "45-50"
                            severity = "HIGH"
                            problem = "Player gold was deducted via costGold without update(player) persistence call"
                            fixSuggestion = "Add player.update() after costGold"
                        },
                        [ordered]@{
                            file = "src/com/game/ShopService.java"
                            lineRange = "5-6"
                            severity = "MEDIUM"
                            problem = "Used import static java.lang.Math.max which violates Rule 101"
                            fixSuggestion = "Use fully qualified Math.max"
                        }
                    )
                    nextPromptForDev = "Fix persistence and remove static import"
                }
            }
        )
    }

    [System.IO.File]::WriteAllText($mailboxPath, ($mailboxData | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    # 2. Run sync-defect-memory.ps1
    $outputFile = Join-Path $ContextDir "defect-patterns.md"
    $rawOut = & pwsh -NoProfile -File $SyncScript `
        -WorkspaceRoot $TestRoot `
        -MailboxPath $mailboxPath `
        -OutputMemoryFile $outputFile `
        -Json 2>&1 | Out-String

    Assert-True (Test-Path -LiteralPath $outputFile) "defect-patterns.md should be created"
    
    $res = $rawOut | ConvertFrom-Json
    Assert-Equal $res.TotalPatternsFound 2 "Total patterns found should be 2"
    Assert-Equal $res.UniqueCategories 2 "Unique categories should be 2"
    Assert-True ($res.Categories -contains "MUTATION_WITHOUT_PERSISTENCE") "Should contain MUTATION_WITHOUT_PERSISTENCE"
    Assert-True ($res.Categories -contains "STATIC_IMPORT_DISALLOWED") "Should contain STATIC_IMPORT_DISALLOWED"

    $mdText = [System.IO.File]::ReadAllText($outputFile, [System.Text.Encoding]::UTF8)
    Assert-True ($mdText -match "MUTATION_WITHOUT_PERSISTENCE") "Markdown output should mention MUTATION_WITHOUT_PERSISTENCE"
    Assert-True ($mdText -match "STATIC_IMPORT_DISALLOWED") "Markdown output should mention STATIC_IMPORT_DISALLOWED"
    Assert-True ($mdText -match "<!-- context-meta") "Markdown output should include context metadata header"

    Write-Host "All defect memory sync tests passed successfully." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
