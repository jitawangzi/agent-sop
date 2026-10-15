#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-junit-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'; $spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
$entry=Join-Path $scripts 'workflow-task.ps1'; $saved=@{}
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS','CODEX_SESSION_ID')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function Fails([scriptblock]$action,[string]$pattern) {
    $failure=''; try { & $action | Out-Null; if ($LASTEXITCODE -ne 0) { $failure="exit=$LASTEXITCODE" } } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $pattern) "Expected $pattern; got $failure"
}
function Task([string]$op,[hashtable]$extra=@{}) {
    & $entry -Operation $op -WorkspacePath $workspace -Feature Example -TaskId junit -Agent CODEX @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY",(Join-Path $root $kind)) }
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'; $env:CODEX_SESSION_ID='junit-session'
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'build')) | Out-Null
    $mapPath=Join-Path $workspace 'case-map.json'; $reportPath=Join-Path $workspace 'build/result.xml'
    [IO.File]::WriteAllText($mapPath,'{"schemaVersion":"1.0","cases":[{"id":"TC-ONE","className":"example.Check","name":"works"}]}')
    $configuration=Get-AiSopJUnitConfiguration $workspace @('build/result.xml') 'case-map.json'
    $before=@{'build/result.xml'='MISSING'}
    Fails { Read-AiSopJUnitEvidence $configuration $before $workspace } 'JUNIT_REPORT_MISSING'
    Fails { Get-AiSopJUnitConfiguration $workspace @('../outside.xml') 'case-map.json' } 'WORKSPACE_PATH_ESCAPE'
    Fails { Get-AiSopJUnitConfiguration $workspace @('build/result.xml') '' } 'JUNIT_CONFIGURATION_REQUIRED'
    $valid='<testsuites><testsuite tests="1" failures="0"><testcase classname="example.Check" name="works"/></testsuite></testsuites>'
    [IO.File]::WriteAllText($reportPath,$valid)
    $result=Read-AiSopJUnitEvidence $configuration $before $workspace
    Assert ($result.passedCaseIds[0] -ceq 'TC-ONE') 'JUnit passed case not mapped'
    Fails { Read-AiSopJUnitEvidence $configuration @{'build/result.xml'=(Get-AiSopJUnitFileIdentity $reportPath)} $workspace } 'JUNIT_REPORT_STALE'
    [IO.File]::WriteAllText($reportPath,'<testsuite><testcase classname="example.Check" name="works"><skipped/></testcase></testsuite>')
    Fails { Read-AiSopJUnitEvidence $configuration $before $workspace } 'JUNIT_CASE_NOT_PASSED'
    [IO.File]::WriteAllText($reportPath,'<testsuite failures="1"><testcase classname="example.Check" name="works"/></testsuite>')
    Fails { Read-AiSopJUnitEvidence $configuration $before $workspace } 'JUNIT_REPORT_FAILED'
    [IO.File]::WriteAllText($reportPath,'<testsuite><testcase classname="other.Check" name="works"/></testsuite>')
    Fails { Read-AiSopJUnitEvidence $configuration $before $workspace } 'JUNIT_CASE_NOT_PASSED'
    [IO.File]::WriteAllText($reportPath,'<!DOCTYPE testsuite [<!ENTITY test "unsafe">]><testsuite/>')
    Fails { Read-AiSopJUnitEvidence $configuration $before $workspace } 'JUNIT_REPORT_INVALID'
    [IO.File]::WriteAllText($reportPath,'<testsuite><testcase classname="example.Check" name="works"/><testcase classname="example.Check" name="works"><skipped/></testcase></testsuite>')
    Fails { Read-AiSopJUnitEvidence $configuration $before $workspace } 'JUNIT_CASE_NOT_PASSED'
    # Real Run integration: process zero must not override stale/failing reports.
    Task Start @{Tier='T2';Objective='Map observed JUnit results'} | Out-Null
    $run=@{Kind='test';Batch='mapped';Executable='pwsh';Arguments=@('-NoProfile','-Command',"[IO.File]::WriteAllText('build/result.xml','$valid')");JUnitReports=@('build/result.xml');CaseMap='case-map.json'}
    Task Run $run | Out-Null
    $record=(Read-AiSopTask $spec junit).verifications[-1]
    Assert ($record.outcome -eq 'PASSED' -and $record.reportEvidence.passedCaseIds[0] -ceq 'TC-ONE') 'Run did not persist report-derived result'
    $record.Remove('reportEvidence'); Fails { Assert-AiSopJUnitResult $record } 'JUNIT_RESULT_REQUIRED'
    $run.Arguments=@('-NoProfile','-Command','exit 0'); $run.Reason='Exercise stale report detection'
    Fails { Task Run $run } 'Task Run failed'
    $record=(Read-AiSopTask $spec junit).verifications[-1]
    Assert ($record.outcome -eq 'FAILED' -and $record.diagnostic -match 'JUNIT_REPORT_STALE') 'Stale report silently passed'
    $run.Arguments=@('-NoProfile','-Command',"[IO.File]::WriteAllText('build/result.xml','<testsuite errors=`"1`"/>')"); $run.Reason='Exercise report failure despite exit zero'
    Fails { Task Run $run } 'Task Run failed'
    Assert ((Read-AiSopTask $spec junit).verifications[-1].diagnostic -match 'JUNIT_REPORT_FAILED') 'XML failures hidden by exit zero'
    $run.CaseIds=@('TC-UNOBSERVED')
    Fails { Task Run $run } 'JUNIT_CASE_IDS_FROM_MAP'
    # A blocked log path must fail before RUNNING registration.
    $beforeCount=(Read-AiSopTask $spec junit).verifications.Count
    $blocked=Join-Path $workspace '.ai-workspace/.runtime/verification/Example/blocked'
    [IO.File]::WriteAllText($blocked,'file prevents directory creation')
    Task Cancel | Out-Null
    & $entry -Operation Start -WorkspacePath $workspace -Feature Example -TaskId blocked -Tier T1 -Objective 'Blocked log path' -Agent CODEX | Out-Null
    Fails { & $entry -Operation Run -WorkspacePath $workspace -Feature Example -TaskId blocked -Kind compile -Executable pwsh -Arguments @('-NoProfile','-Command','exit 0') -Agent CODEX } 'RUN_LOG_UNAVAILABLE'
    Assert ((Read-AiSopTask $spec blocked).verifications.Count -eq 0) 'Log I/O failure left phantom RUNNING attempt'
    Write-Output 'PASS: optional JUnit exact mapping, fresh reports, skipped/failing results, secure XML and log setup failure'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
