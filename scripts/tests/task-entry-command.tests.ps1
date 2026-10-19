#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'path-identity.ps1')
. (Join-Path $scripts 'task-entry-command.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sop-task-entry-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Parse([string]$Command,[string]$Cwd=$fixture,[hashtable]$Arguments=@{}) {
    Get-AiSopTaskEntryCommand -CommandText $Command -WorkspacePath $fixture -Cwd $Cwd -Agent ANTIGRAVITY -NativeSessionId 'native-current' -ToolArguments $Arguments
}
try {
    [IO.Directory]::CreateDirectory((Join-Path $fixture '.ai-sop/scripts')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'other')) | Out-Null
    foreach($path in @('ai-sop.ps1','.ai-sop/scripts/workflow-task.ps1','other/ai-sop.ps1')) {
        [IO.File]::WriteAllText((Join-Path $fixture $path),'throw "解析测试不得执行脚本"')
    }
    $start="pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Start -Feature Example -TaskId fix -Objective '修改入口' -Agent ANTIGRAVITY"
    $parsed=Parse $start
    Assert ($parsed.operation -eq 'Start' -and $parsed.reasonCode -eq 'TASK_BOOTSTRAP_COMMAND') '默认 T2 建立入口被拒绝'
    Assert ((Parse ($start+' -NativeSessionId native-current')).operation -eq 'Start') '匹配当前 Hook 的会话参数应通过'
    Assert ($null -eq (Parse ($start+' -NativeSessionId another-session'))) '不得用引导入口冒用其他会话'
    Assert ((Parse ($start+" -Tier T1 -UserRequest '按 T1 执行' -CaptureBaseline")).operation -eq 'Start') '显式档位命令无法引导'
    Assert ((Parse 'pwsh -NoProfile -File ./ai-sop.ps1 Task').operation -eq 'Discover') '默认只读发现入口被拒绝'
    foreach($operation in @('Discover','Status','FollowUps','InspectRecovery','Changes')) {
        Assert ((Parse "pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation $operation -Feature Example -TaskId fix -Json -LogTailLines 5").operation -eq $operation) "只读入口被拒绝：$operation"
    }
    foreach($operation in @('Resume','Recover','Suspend','Cancel','ChangeTier')) {
        Assert ((Parse ($start.Replace('-Operation Start',"-Operation $operation"))).operation -eq $operation) "治理入口被拒绝：$operation"
    }
    Assert ((Parse "pwsh -NoProfile -File ./.ai-sop/scripts/workflow-task.ps1 -Operation Resume -Feature Example -TaskId fix -Agent ANTIGRAVITY -WorkspacePath '.' -SpecDirectory '.ai-workspace/specs/features/Example'").operation -eq 'Resume') '底层入口路径校验错误'
    $rejected=@(
        ($start+'; Set-Content src/x bad'),
        ($start+' | Out-File src/x'),
        ($start+' > src/x'),
        ($start+' && echo next'),
        ($start+' &'),
        ($start+' -Operation Run'),
        ($start+' -Executable pwsh'),
        ($start+' -Arguments @("-Command","exit 0")'),
        ($start+' -Objective $env:VALUE'),
        ($start+' -Notes $(Get-Content secret)'),
        ($start+' -Notes "$(Get-Content secret)"'),
        ($start+' -Notes "x`echo unintended`y"'),
        ($start+' -ForceRecovery:$true'),
        ($start.Replace('pwsh -NoProfile','pwsh -Command')),
        ($start.Replace('ANTIGRAVITY','CODEX')),
        ($start.Replace(' -Agent ANTIGRAVITY','')),
        ($start.Replace('./ai-sop.ps1','./other/ai-sop.ps1')),
        ($start.Replace('-Operation Start','-Operation Run')),
        ($start.Replace('-Operation Start','-Operation Complete')),
        ($start+' -SpecDirectory ../outside'),
        ($start+' -WorkspacePath ../outside'),
        ($start.Replace('-Feature Example','-Feature ../outside')),
        ($start.Replace('-TaskId fix','-TaskId ../outside')),
        ('& '+$start),
        ('trap { exit 0 }; '+$start)
    )
    foreach($command in $rejected) { Assert ($null -eq (Parse $command)) "引导入口错误放行：$command" }
    Assert ($null -eq (Parse $start -Cwd (Join-Path $fixture 'other'))) '不同当前目录借用了宿主入口'
    Assert ($null -eq (Parse $start -Arguments @{working_directory='other'})) '工具目录参数绕过了入口路径校验'
    Assert ((Parse $start -Arguments @{workdir=$fixture}).operation -eq 'Start') '显式宿主根目录被拒绝'
    Write-Output 'PASS: task bootstrap entry, recovery/read-only routing, identity/path binding and command injection rejection'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'sop-task-entry-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
