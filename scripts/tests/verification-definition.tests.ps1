#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-definition-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'; $spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
$entry=Join-Path $scripts 'workflow-task.ps1'; $taskId='definition'; $saved=@{}
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','CODEX_SESSION_ID')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function Fails([scriptblock]$action,[string]$pattern) {
    $failure=''; try { & $action | Out-Null } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $pattern) "Expected $pattern; got $failure"
}
function Task([string]$op,[hashtable]$extra=@{}) {
    & $entry -Operation $op -WorkspacePath $workspace -Feature Example -TaskId $taskId -Agent CODEX @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
function SaveConfig { [IO.File]::WriteAllText($configPath,(ConvertTo-AiSopWorkflowCanonicalJson $config)) }
function Problems { @(Get-AiSopTaskProblems (Read-AiSopTask $spec $taskId) $workspace $spec) }
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY",(Join-Path $root $kind)) }
    $env:CODEX_SESSION_ID='definition-session'
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace '.ai-workspace/context')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'build')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'input.txt'),'valid')
    $configPath=Join-Path $workspace '.ai-workspace/context/verification-commands.json'
    $mapRelative='.ai-workspace/context/custom-map.json'; $mapPath=Join-Path $workspace $mapRelative
    $map='{"schemaVersion":"1.0","cases":[{"id":"TC-B","className":"Checks","name":"b"},{"id":"TC-A","className":"Checks","name":"a"}]}'
    [IO.File]::WriteAllText($mapPath,$map)
    $check="if ([IO.File]::ReadAllText('input.txt') -ne 'valid') { exit 3 }"
    $xml='<testsuite tests="2"><testcase classname="Checks" name="a"/><testcase classname="Checks" name="b"/></testsuite>'
    $config=@{schemaVersion='1.0';commands=@{
        build=@{kind='compile';executable='pwsh';arguments=@('-NoProfile','-Command',$check)}
        test=@{kind='test';executable='pwsh';arguments=@('-NoProfile','-Command',"$check; [IO.File]::WriteAllText('build/results.xml','$xml')");junitReports=@('build/results.xml');caseMap=$mapRelative}
        unrelated=@{kind='compile';executable='pwsh';arguments=@('-NoProfile','-Command','exit 0')}
    }}
    SaveConfig
    Task Start @{Tier='T2';Objective='Verify command definitions'} | Out-Null
    Task RecordSync @{Documentation='UNCHANGED';Tests='UNCHANGED';Summary='Existing fixture requirements and regression remain applicable'} | Out-Null
    # 复现真实 pwsh -File 误传数组：拒绝发生在创建 RUNNING/失败批次之前。
    $taskBefore=[IO.File]::ReadAllText((Get-AiSopTaskPath $spec $taskId))
    $badArguments="'/d','/c','echo','unreachable'"
    $nativeOutput=& (Get-Process -Id $PID).Path -NoProfile -File $entry -Operation Run -WorkspacePath $workspace -Feature Example -TaskId $taskId -Agent CODEX -Kind test -Batch malformed -Executable cmd.exe -Arguments $badArguments 2>&1 | Out-String
    Assert ($LASTEXITCODE -ne 0 -and $nativeOutput -match 'RUN_ARGUMENT_ARRAY_LITERAL') 'Native -File argument error was not explained before execution'
    Assert ([IO.File]::ReadAllText((Get-AiSopTaskPath $spec $taskId)) -ceq $taskBefore) 'Rejected array literal left a failed batch or changed the task'
    Assert (-not (Test-Path (Join-Path $workspace '.ai-workspace/.runtime/verification/Example/definition'))) 'Rejected array literal started verification logging'
    # 正常脚本数据中的引号、逗号以及完整的 -Command 文本不应被拆分或拒绝。
    Assert-AiSopRunArgumentShape pwsh @('-NoProfile','-Command',"Write-Output 'a,b'")
    Assert-AiSopRunArgumentShape cmd.exe @('/d','/c','echo','a,b')
    Task Run @{Profile='build'} | Out-Null
    Task Run @{Profile='test'} | Out-Null
    Task Verify | Out-Null
    $records=(Read-AiSopTask $spec $taskId).verifications
    Assert ($records[0].context.profileDigestAlgorithm -ceq 'profile-command-v2') 'Run omitted current selected-profile binding version'
    $config.commands.unrelated.arguments=@('-NoProfile','-Command','exit 4')
    SaveConfig
    [IO.File]::WriteAllText($configPath,($config | ConvertTo-Json -Depth 10))
    $reordered=ConvertFrom-Json $map -AsHashtable; $reordered.cases=@($reordered.cases | Sort-Object id)
    [IO.File]::WriteAllText($mapPath,($reordered | ConvertTo-Json -Depth 8))
    Assert (@(Problems).Count -eq 0) 'Formatting, map case order or sibling profile invalidated evidence'
    $oldProfile=Get-AiSopVerificationProfile $workspace test 'profile-command-v1'
    $v1=@{kind='test';batch='test';context=@{profile='test';profileDigestAlgorithm='profile-command-v1';profileDigest=$oldProfile.digest}}
    $v1Raw=ConvertTo-AiSopWorkflowCanonicalJson $v1
    Assert (@(Get-AiSopRunDefinitionProblems $v1 $workspace).Count -eq 0) 'Unchanged v1 evidence was invalidated by the engine upgrade'
    $config.commands.test.caseMap='./'+$mapRelative
    $config.commands.test.junitReports=@('./build/results.xml')
    if ([OperatingSystem]::IsWindows()) {
        $config.commands.test.caseMap=$config.commands.test.caseMap.Replace('/','\').ToUpperInvariant()
        $config.commands.test.junitReports=@('.\BUILD\RESULTS.XML')
    }
    SaveConfig
    Assert (@(Problems).Count -eq 0) 'Equivalent workspace path spelling invalidated v2 evidence'
    Assert ((Get-AiSopRunDefinitionProblems $v1 $workspace) -match 'STALE_PROFILE_EVIDENCE') 'v1 was silently reinterpreted using v2 path rules'
    Task Run @{Profile='test'} | Out-Null # Same effective paths need no Reason.
    Assert ((Read-AiSopTask $spec $taskId).verifications[-1].outcome -eq 'PASSED') 'Equivalent path run failed'
    Assert ((ConvertTo-AiSopWorkflowCanonicalJson $v1) -ceq $v1Raw) 'Reading a legacy record rewrote it'
    $config.commands.test.caseMap='../outside.json'; SaveConfig
    Assert ((Problems) -match 'PROFILE_DEFINITION_UNAVAILABLE:.*WORKSPACE_PATH_ESCAPE') 'New path normalization accepted escape'
    $config.commands.test.caseMap=$mapRelative; $config.commands.test.junitReports=@('build/results.xml'); SaveConfig
    Assert (@(Get-AiSopRunDefinitionProblems $v1 $workspace).Count -eq 0) 'Restored original v1 definition stopped validating'
    Task Run @{Profile='build'} | Out-Null # Same batch needs no Reason.
    $config.commands.build.timeoutSeconds=12; SaveConfig
    Assert ((Problems) -match 'STALE_PROFILE_EVIDENCE:compile:build') 'Selected profile drift passed verification'
    Fails { Task Verify } 'Task Verify failed'
    Fails { Task Run @{Profile='build'} } 'BATCH_DEFINITION_CHANGED'
    $config.commands.build.Remove('timeoutSeconds'); SaveConfig
    $config.commands.Remove('build'); SaveConfig
    Assert ((Problems) -match 'PROFILE_DEFINITION_UNAVAILABLE:compile:build:PROFILE_NOT_FOUND') 'Deleted profile was accepted'
    $config.commands.build=@{kind='compile';executable='pwsh';arguments=@('-NoProfile','-Command',$check)}; SaveConfig
    [IO.File]::WriteAllText($configPath,'{broken')
    Assert ((Problems) -match 'PROFILE_DEFINITION_UNAVAILABLE:compile:build') 'Corrupt configuration was accepted'
    SaveConfig
    $reordered.cases[0].name='different'; [IO.File]::WriteAllText($mapPath,(ConvertTo-AiSopWorkflowCanonicalJson $reordered))
    Assert ((Problems) -match 'STALE_JUNIT_MAP_EVIDENCE:test:test') 'Mapping changes under ignored context were accepted'
    Fails { Task Verify } 'Task Verify failed'
    [IO.File]::Delete($mapPath)
    Assert ((Problems) -match 'JUNIT_DEFINITION_UNAVAILABLE:test:test') 'Missing mapping was accepted'
    [IO.File]::WriteAllText($mapPath,$map)
    # Old definitions remain readable without rewriting their original digest.
    $legacy=ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $records[0]) -AsHashtable
    $legacy.context.Remove('profileDigestAlgorithm'); $legacy.context.profileDigest=(Get-AiSopVerificationProfile $workspace build).legacyDigest
    Assert (@(Get-AiSopRunDefinitionProblems $legacy $workspace).Count -eq 0) 'Legacy raw profile binding was not supported'
    [IO.File]::AppendAllText($configPath,"`n")
    Assert ((Get-AiSopRunDefinitionProblems $legacy $workspace) -match 'STALE_PROFILE_EVIDENCE') 'Legacy whole-file digest was silently reinterpreted'
    SaveConfig
    $legacyMap=ConvertFrom-AiSopWorkflowJson $records[1].context.junitConfiguration -AsHashtable
    $legacyMap.Remove('mapPath'); $legacyMap.Remove('bindingVersion')
    $legacy.context=@{junitConfiguration=(ConvertTo-AiSopWorkflowCanonicalJson $legacyMap)}
    Assert ((Get-AiSopRunDefinitionProblems $legacy $workspace) -match 'JUNIT_MAP_SOURCE_UNBOUND') 'Legacy missing map provenance was silently trusted'
    Task Complete | Out-Null
    $config.commands.build.arguments=@('-NoProfile','-Command','exit 9'); SaveConfig
    $history=Task Status @{Json=$true} | ConvertFrom-Json
    Assert ($history.tasks[0].verification -eq 'HISTORICAL_NOT_RECHECKED' -and $history.tasks[0].verificationScope -eq 'NOT_CHECKED') 'DONE history was rechecked against current profiles'
    # Mutating a selected definition during a zero-exit run must persist failure.
    $taskId='during'
    $mutate=@'
$path='.ai-workspace/context/verification-commands.json'
$c=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
$c.commands.mutate.timeoutSeconds=17
[IO.File]::WriteAllText($path,($c | ConvertTo-Json -Depth 10))
'@
    $config.commands.mutate=@{kind='compile';executable='pwsh';arguments=@('-NoProfile','-Command',$mutate)}; SaveConfig
    Task Start @{Tier='T1'; UserRequest='本测试明确选择 T1';Objective='Detect definition mutation during execution'} | Out-Null
    Fails { Task Run @{Profile='mutate'} } 'INPUTS_CHANGED_DURING_RUN'
    $last=(Read-AiSopTask $spec $taskId).verifications[-1]
    Assert ($last.outcome -eq 'FAILED' -and -not $last.inputsStable -and $last.diagnostic -match 'STALE_PROFILE_EVIDENCE') 'Definition mutation lost the persisted failure'
    $mutateMap=@'
$path='.ai-workspace/context/custom-map.json'
$m=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
$m.cases[0].name='changed-during-run'
[IO.File]::WriteAllText($path,($m | ConvertTo-Json -Depth 10))
[IO.File]::WriteAllText('build/results.xml','<testsuite tests="2"><testcase classname="Checks" name="a"/><testcase classname="Checks" name="b"/></testsuite>')
'@
    Fails { Task Run @{Kind='test';Executable='pwsh';Arguments=@('-NoProfile','-Command',$mutateMap);JUnitReports=@('build/results.xml');CaseMap=$mapRelative} } 'INPUTS_CHANGED_DURING_RUN'
    $last=(Read-AiSopTask $spec $taskId).verifications[-1]
    Assert ($last.outcome -eq 'FAILED' -and $last.diagnostic -match 'STALE_JUNIT_MAP_EVIDENCE') 'Direct JUnit mapping mutation was accepted'
    Task Cancel | Out-Null
    Write-Output 'verification-definition.tests PASS'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'sop-definition-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
