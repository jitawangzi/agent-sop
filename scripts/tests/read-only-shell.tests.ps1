#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../path-identity.ps1')
. (Join-Path $PSScriptRoot '../read-only-shell.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sop-read-only-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $fixture 'workspace'
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Parse([string]$Text,[hashtable]$Extra=@{}) {
    $argsMap=@{command=$Text;shell='pwsh';workdir=$workspace}
    foreach($key in $Extra.Keys) { $argsMap[$key]=$Extra[$key] }
    Get-AiSopReadOnlyShellInput -CommandText $Text -WorkspacePath $workspace -Cwd $workspace -ToolArguments $argsMap
}
try {
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'src')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'src/probe.txt'), "BEFORE`n")
    [IO.File]::WriteAllText((Join-Path $workspace 'data.json'), '{"value":1}')
    $allowed=@(
        'Get-Content -LiteralPath src/probe.txt -Raw',
        'Get-Content src/probe.txt | Select-Object -Skip 0 -First 1',
        'Get-Content data.json | ConvertFrom-Json | ConvertTo-Json -Compress',
        'Get-ChildItem -LiteralPath src -Recurse -File',
        'Get-Location; Get-Content src/probe.txt -TotalCount 1',
        'Test-Path -LiteralPath src/probe.txt -PathType Leaf',
        'Select-String -LiteralPath src/probe.txt -Pattern BEFORE -Context 1',
        'Get-FileHash src/probe.txt -Algorithm SHA256',
        'rg -n -g "*.txt" BEFORE src',
        'rg --files src',
        'git status --short',
        'git diff -- src/probe.txt',
        'git log --oneline -n 3',
        'git show HEAD:src/probe.txt',
        'git -C . ls-files -- src/probe.txt',
        'git rev-parse --show-toplevel',
        'git rev-parse --abbrev-ref HEAD',
        'git remote -v',
        'git remote get-url origin',
        'git remote get-url --all --push origin',
        'git branch',
        'git branch --show-current',
        'git branch -a -vv'
    )
    foreach($text in $allowed) { Assert ($null -ne (Parse $text)) "合法读取被拒绝：$text" }
    $denied=@(
        'Get-Content src/probe.txt; Set-Content src/probe.txt CHANGED',
        'Get-Content src/probe.txt | Set-Content src/new.txt',
        'Get-Content src/probe.txt > src/new.txt',
        'Get-Content src/probe.txt 2>> src/new.txt',
        'Get-Content src/probe.txt && Remove-Item src/probe.txt',
        'Get-Content src/probe.txt &',
        'Get-Content $(Set-Content src/probe.txt CHANGED)',
        'Get-Content "$(Set-Content src/probe.txt CHANGED)"',
        'Get-Content $env:FILE',
        'Get-Content src/probe.txt -OutVariable saved',
        'Get-Content src/probe.txt | ForEach-Object { Set-Content src/probe.txt $_ }',
        'Get-Content src/probe.txt | Select-Object @{n="x";e={Set-Content src/probe.txt x}}',
        '[IO.File]::WriteAllText("src/probe.txt","x")',
        '& Get-Content src/probe.txt',
        '. ./reader.ps1',
        'pwsh -Command Get-Content src/probe.txt',
        'python -c "print(1)"',
        'Get-Content ../outside.txt',
        'Get-Content Env:PATH',
        'Get-Content src/probe.txt:stream',
        'Get-Content src/*.txt',
        'Get-Content src/probe.txt -Raw:$true',
        'rg --pre helper BEFORE src',
        'rg --pre=helper BEFORE src',
        'rg --files --follow src',
        'rg -n BEFORE ../outside',
        'git -c core.fsmonitor=helper status',
        'git diff --output=src/probe.txt',
        'git diff --ext-diff',
        'git show --textconv HEAD:src/probe.txt',
        'git log --show-signature',
        'git remote add new https://example.invalid/repo',
        'git remote set-url origin https://example.invalid/repo',
        'git remote show origin',
        'git remote update',
        'git branch new-branch',
        'git branch -- new-branch',
        'git branch -D main',
        'git branch --set-upstream-to=origin/main',
        'git reset --hard',
        'git checkout -- src/probe.txt',
        'git clean -fd',
        'git -C ../ status',
        'git diff -- ../outside',
        'rg "a`touch marker`" src',
        'git status %OPTIONS%',
        'Get-Content src/probe.txt; function f { Set-Content src/probe.txt x }'
    )
    foreach($text in $denied) { Assert ($null -eq (Parse $text)) "危险或未知命令被放行：$text" }
    foreach($text in $allowed + $denied) {
        $native=@{CommandLine=$text;Cwd=$workspace;WaitMsBeforeAsync=1000;toolSummary='只读检查';IsDaemon=$false}
        $result=Get-AiSopReadOnlyShellInput -CommandText $text -WorkspacePath $workspace -Cwd $workspace -ToolArguments $native -Agent ANTIGRAVITY
        Assert (($null -ne $result) -eq ($text -in $allowed)) "Antigravity 命令分类错误：$text"
        if ($result) {
            Assert ($result.CommandLine -ceq (Parse $text).command) '两端必须使用相同的安全化命令'
            Assert ($result.Cwd -ceq (Resolve-PhysicalPathIdentity $workspace)) '原生工作目录必须固定到已检查路径'
            Assert (-not $result.Contains('command')) 'Antigravity 不能返回 Codex 专有字段'
        }
    }
    foreach ($extra in @(
        @{IsDaemon=$true}, @{IsDaemon='false'}, @{RunPersistent=$true}, @{RequestedTerminalID='old-terminal'},
        @{WaitMsBeforeAsync=-1}, @{WaitMsBeforeAsync='1'}, @{toolSummary=@{}}, @{Cwd=$fixture},
        @{command='Set-Content src/probe.txt BAD'}, @{env=@{}}, @{shell='cmd.exe'}
    )) {
        $native=@{CommandLine='git status'}
        foreach($key in $extra.Keys) { $native[$key]=$extra[$key] }
        Assert ($null -eq (Get-AiSopReadOnlyShellInput -CommandText 'git status' -WorkspacePath $workspace -Cwd $workspace -ToolArguments $native -Agent ANTIGRAVITY)) '未知、后台或歧义原生参数不得获豁免'
    }
    Assert ($null -eq (Parse 'git status' @{env=@{GIT_EXTERNAL_DIFF='helper'}})) '环境覆盖不得绕过只读选项'
    Assert ($null -eq (Parse 'git status' @{workdir=$fixture})) '工作目录越界'
    Assert ($null -eq (Parse 'git status' @{cmd='Set-Content src/probe.txt x'})) '歧义命令字段'
    Assert ($null -eq (Parse 'git status' @{shell='cmd.exe'})) '未支持的解释器'
    foreach($text in @('cat src/probe.txt','head -n 1 src/probe.txt','sed -n ''1,3p'' src/probe.txt','pwd')) {
        Assert ($null -ne (Parse $text @{shell='bash'})) "POSIX 字面读取被拒绝：$text"
    }
    Assert ($null -eq (Parse 'sed -i s/A/B/ src/probe.txt' @{shell='bash'})) 'sed 写入不得放行'
    $outside=Join-Path $fixture 'outside.txt'; [IO.File]::WriteAllText($outside,'outside')
    # 目录链接进入外部目录时，也必须按物理目标拒绝。
    $link=Join-Path $workspace 'escape'
    $linkType=if ([OperatingSystem]::IsWindows()) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $link -Target $fixture | Out-Null
    Assert ($null -eq (Parse 'Get-Content escape/outside.txt')) '读取链接逃逸'
    Remove-Item -LiteralPath $link -Force

    & git -C $workspace init --quiet
    & git -C $workspace remote add origin https://example.invalid/readonly-fixture.git
    & git -C $workspace add .
    & git -C $workspace -c user.name=Fixture -c user.email=fixture@localhost commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Git 测试基线创建失败' }
    [IO.File]::WriteAllText((Join-Path $workspace 'src/probe.txt'), "BEFORE`nCHANGED`n")
    $marker=Join-Path $fixture 'unexpected-helper'
    $helper=Join-Path $fixture 'helper.ps1'
    [IO.File]::WriteAllText($helper,"[IO.File]::WriteAllText('$($marker.Replace("'","''"))','BAD')")
    $helperCommand="pwsh -NoProfile -File `"$helper`""
    & git -C $workspace config core.fsmonitor $helperCommand
    & git -C $workspace config diff.external $helperCommand
    & git -C $workspace config diff.probe.textconv $helperCommand
    [IO.File]::WriteAllText((Join-Path $workspace '.gitattributes'),'*.txt diff=probe')
    $rgConfig=Join-Path $fixture 'rg.config'; [IO.File]::WriteAllText($rgConfig,"--pre`n$helperCommand")
    $oldConfig=$env:RIPGREP_CONFIG_PATH; $env:RIPGREP_CONFIG_PATH=$rgConfig
    $oldLocation=Get-Location
    try {
        Set-Location $workspace
        foreach($text in $allowed) {
            $input=Parse $text
            # 仅运行已经通过解析的输出，验证原生命令和危险助手配置的隔离。
            $output=& pwsh -NoProfile -Command $input.command 2>&1
            Assert ($LASTEXITCODE -eq 0) "只读命令实际执行失败：$text $output"
            Assert (-not (Test-Path $marker)) "只读命令启动了外部助手：$text"
        }
    } finally { Set-Location $oldLocation; $env:RIPGREP_CONFIG_PATH=$oldConfig }
    Write-Output 'PASS: literal reads, safe pipelines, git/rg helper suppression, command injection and physical path rejection'
} finally {
    $physical=Resolve-PhysicalPathIdentity $fixture
    $temp=(Resolve-PhysicalPathIdentity ([IO.Path]::GetTempPath())).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ($physical.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $physical) -like 'sop-read-only-*') {
        Remove-Item -LiteralPath $physical -Recurse -Force
    }
}
