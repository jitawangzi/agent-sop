#requires -Version 7.0

# 只解析字面只读命令，不执行待检查的文本；未知语法返回空，继续走原任务防护。
function Get-AiSopReadOnlyShellInput {
    param([string]$CommandText, [string]$WorkspacePath, [string]$Cwd,
        [System.Collections.IDictionary]$ToolArguments,
        [ValidateSet('CODEX','ANTIGRAVITY')][string]$Agent='CODEX')
    $nativeArguments=$ToolArguments
    if ($Agent -ceq 'ANTIGRAVITY') {
        # 原生命令只接受已知的前台执行参数，禁止借已有终端或后台进程绕过检查。
        if (-not $ToolArguments -or -not $ToolArguments.Contains('CommandLine') -or
            $ToolArguments.CommandLine -isnot [string] -or $ToolArguments.CommandLine -cne $CommandText) { return $null }
        foreach ($key in $ToolArguments.Keys) {
            if ($key -cnotin @('CommandLine','Cwd','WaitMsBeforeAsync','toolSummary','toolAction','IsDaemon','RunPersistent')) { return $null }
        }
        foreach ($key in @('IsDaemon','RunPersistent')) {
            if ($ToolArguments.Contains($key) -and ($ToolArguments[$key] -isnot [bool] -or $ToolArguments[$key])) { return $null }
        }
        if ($ToolArguments.Contains('WaitMsBeforeAsync') -and
            (($ToolArguments.WaitMsBeforeAsync -isnot [int] -and $ToolArguments.WaitMsBeforeAsync -isnot [long]) -or $ToolArguments.WaitMsBeforeAsync -lt 0)) { return $null }
        foreach ($key in @('toolSummary','toolAction')) {
            if ($ToolArguments.Contains($key) -and $ToolArguments[$key] -isnot [string]) { return $null }
        }
        $ToolArguments=[ordered]@{command=$CommandText}
        if ($nativeArguments.Contains('Cwd')) { $ToolArguments.cwd=$nativeArguments.Cwd }
    }
    $lexicalCheck=[regex]::Replace($CommandText,'(?<=^|\s)2>&1(?=\s|\||;|$)','')
    if ([string]::IsNullOrWhiteSpace($CommandText) -or $CommandText.Length -gt 32768 -or
        $lexicalCheck -match '[`$&<>%!]' -or $CommandText -match '\\["''\r\n]') { return $null }
    if (-not $ToolArguments -or @($ToolArguments.Keys | Where-Object { $_ -in @('command','cmd') }).Count -ne 1) { return $null }
    foreach ($key in $ToolArguments.Keys) {
        if ($key -notin @('command','cmd','description','workdir','cwd','shell','login','timeout','timeout_ms','yield_time_ms','max_output_tokens','tty')) { return $null }
    }
    if ($ToolArguments.Contains('shell') -and
        [IO.Path]::GetFileName([string]$ToolArguments.shell) -notin @('pwsh','pwsh.exe','powershell','powershell.exe','bash','sh','zsh')) { return $null }
    $powerShell=[OperatingSystem]::IsWindows()
    if ($ToolArguments.Contains('shell')) { $powerShell=[IO.Path]::GetFileName([string]$ToolArguments.shell) -in @('pwsh','pwsh.exe','powershell','powershell.exe') }
    $root=Resolve-PhysicalPathIdentity $WorkspacePath
    $comparison=if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix=$root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $working=if ($Cwd) { Resolve-PhysicalPathIdentity $Cwd } else { $root }
    foreach ($key in @('cwd','workdir')) {
        if ($ToolArguments.Contains($key)) {
            $value=$ToolArguments[$key]
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { return $null }
            $working=Resolve-PhysicalPathIdentity $(if ([IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $working $value })
        }
    }
    if (-not ($working.Equals($root,$comparison) -or $working.StartsWith($prefix,$comparison))) { return $null }
    function Test-ReadPath([string]$Value) {
        if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[*?\[\]]|^[-~]|::' -or
            $Value -match ':' -and $Value -notmatch '^[A-Za-z]:[/\\][^:]*$') { return $false }
        $physical=Resolve-PhysicalPathIdentity $(if ([IO.Path]::IsPathRooted($Value)) { $Value } else { Join-Path $working $Value })
        return $physical.Equals($root,$comparison) -or $physical.StartsWith($prefix,$comparison)
    }
    function Quote-ReadValue([string]$Value) { return "'"+$Value.Replace("'","''")+"'" }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($CommandText,[ref]$tokens,[ref]$errors)
    if ($errors.Count -or $ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.CleanBlock -or
        $ast.UsingStatements.Count -or $ast.EndBlock.Traps.Count -or -not $ast.EndBlock.Statements.Count) { return $null }
    $statements=[Collections.Generic.List[string]]::new()
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.Background) { return $null }
        $pipeline=[Collections.Generic.List[string]]::new()
        foreach ($command in $statement.PipelineElements) {
            if ($command -isnot [Management.Automation.Language.CommandAst] -or
                $command.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Unknown) { return $null }
            $hasStderrToStdout=$false
            foreach ($redir in $command.Redirections) {
                if ($redir -isnot [Management.Automation.Language.MergingRedirectionAst] -or
                    $redir.FromStream -ne [Management.Automation.Language.RedirectionStream]::Error -or
                    $redir.ToStream -ne [Management.Automation.Language.RedirectionStream]::Output) { return $null }
                $hasStderrToStdout=$true
            }
            $parts=@($command.CommandElements); $values=[Collections.Generic.List[string]]::new()
            foreach ($part in $parts) {
                if ($part -is [Management.Automation.Language.StringConstantExpressionAst]) {
                    # 内嵌单引号在不同 Shell 中转义规则不同，本轮不猜测其语义。
                    if ($part.Value.Contains("'") -or $part.Value -match '[&>]') { return $null }
                    $values.Add($part.Value)
                }
                elseif ($part -is [Management.Automation.Language.CommandParameterAst] -and -not $part.Argument) {
                    if ($part.Extent.Text -match '[&>]') { return $null }
                    $values.Add($part.Extent.Text)
                }
                elseif ($part -is [Management.Automation.Language.ConstantExpressionAst] -and $part.Value -is [int]) { $values.Add([string]$part.Value) }
                else { return $null }
            }
            if ($values.Count -eq 0) { return $null }
            $name=$values[0]; $argv=@($values | Select-Object -Skip 1); $isFilter=$pipeline.Count -gt 0
            $render=[Collections.Generic.List[string]]::new()
            if ($name -in @('git','git.exe')) {
                if ($isFilter -or $argv.Count -eq 0) { return $null }
                $index=0; $render.Add('git --no-pager --no-optional-locks -c core.fsmonitor=false -c log.showSignature=false')
                if ($argv[0] -ceq '-C') {
                    if ($argv.Count -lt 3 -or -not (Test-ReadPath $argv[1])) { return $null }
                    $render.Add('-C'); $render.Add((Quote-ReadValue $argv[1])); $index=2
                }
                $verb=$argv[$index++]; $render.Add($verb)
                if ($verb -cnotin @('status','diff','log','show','rev-parse','ls-files','remote','branch')) { return $null }
                if ($verb -ceq 'remote') {
                    # remote 仅列出本地配置或获取 URL；不接受修改配置、联网或执行远端助手。
                    $remaining=@($argv | Select-Object -Skip $index)
                    if ($remaining.Count -eq 0 -or ($remaining.Count -eq 1 -and $remaining[0] -cin @('-v','--verbose'))) {
                        foreach ($value in $remaining) { $render.Add((Quote-ReadValue $value)) }
                    } elseif ($remaining[0] -ceq 'get-url') {
                        $remoteNames=0; $seenRemoteFlags=@{}
                        foreach ($value in @($remaining | Select-Object -Skip 1)) {
                            if ($value -cin @('--all','--push') -and $remoteNames -eq 0 -and -not $seenRemoteFlags.ContainsKey($value)) { $seenRemoteFlags[$value]=$true }
                            elseif ($value -cmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' -and $remoteNames -eq 0) { $remoteNames++ }
                            else { return $null }
                        }
                        if ($remoteNames -ne 1) { return $null }
                        foreach ($value in $remaining) { $render.Add((Quote-ReadValue $value)) }
                    } else { return $null }
                    $rendered=$render -join ' '
                    if ($hasStderrToStdout) { $rendered += ' 2>&1' }
                    $pipeline.Add($rendered); continue
                }
                if ($verb -cin @('diff','log','show')) { $render.Add('--no-ext-diff --no-textconv') }
                $flags=switch -CaseSensitive ($verb) {
                    status { @('--short','-s','--branch','-b','--porcelain','--porcelain=v1','--porcelain=v2','--untracked-files=no','--untracked-files=normal','--untracked-files=all') }
                    diff { @('--stat','--numstat','--shortstat','--name-only','--name-status','--check','--cached','--staged','--summary','--patch','-p','--no-color','--no-ext-diff','--no-textconv','--no-renames') }
                    log { @('--oneline','--stat','--name-only','--name-status','--all','--decorate','--no-decorate','--no-color','-p','--patch','--no-ext-diff','--no-textconv') }
                    show { @('--stat','--name-only','--name-status','--oneline','--summary','--no-color','--no-ext-diff','--no-textconv') }
                    rev-parse { @('--show-toplevel','--show-prefix','--git-dir','--is-inside-work-tree','--verify','--short','--abbrev-ref') }
                    ls-files { @('--cached','--modified','--others','--exclude-standard','--stage','--deleted') }
                    branch { @('--show-current','--list','-a','--all','-r','--remotes','-v','-vv','--verbose','--no-color') }
                }
                $paths=$false
                while ($index -lt $argv.Count) {
                    $value=$argv[$index++]
                    if ($paths) { if (-not (Test-ReadPath $value)) { return $null } }
                    elseif ($value -ceq '--' -and $verb -cne 'branch') { $paths=$true }
                    elseif ($value -cin $flags) {}
                    elseif ($verb -ceq 'branch') { return $null }
                    elseif ($verb -cin @('log','show') -and $value -cin @('-n','--max-count')) {
                        if ($index -ge $argv.Count -or $argv[$index] -notmatch '^\d{1,6}$') { return $null }
                        $render.Add((Quote-ReadValue $value)); $value=$argv[$index++]
                    }
                    elseif ($value.StartsWith('-')) { return $null }
                    elseif ($verb -cin @('status','ls-files')) { if (-not (Test-ReadPath $value)) { return $null } }
                    elseif ($value -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_./~^:@{}-]*$') { return $null }
                    $render.Add((Quote-ReadValue $value))
                }
            } elseif ($name -in @('svn','svn.exe')) {
                if ($isFilter -or $argv.Count -eq 0) { return $null }
                $render.Add('svn --non-interactive')
                $rawVerb=$argv[0]
                $verb=switch -CaseSensitive ($rawVerb) {
                    { $_ -in @('status','st','stat') } { 'status' }
                    { $_ -in @('diff','di') } { 'diff' }
                    'log' { 'log' }
                    'info' { 'info' }
                    { $_ -in @('list','ls') } { 'list' }
                    'cat' { 'cat' }
                    { $_ -in @('propget','pg','pget') } { 'propget' }
                    { $_ -in @('proplist','pl','plist') } { 'proplist' }
                    { $_ -in @('blame','praise','annotate') } { 'blame' }
                    default { '' }
                }
                if (-not $verb) { return $null }
                $render.Add($rawVerb)
                $commonSvnFlags=@('--non-interactive','--no-auth-cache')
                $verbFlags=switch -CaseSensitive ($verb) {
                    status { @('-v','--verbose','-q','--quiet','-u','--show-updates','-N','--non-recursive','--no-ignore','--ignore-externals','--xml') }
                    diff { @('--summarize','--xml','--no-diff-added','--no-diff-deleted','--ignore-properties','--properties-only','-N','--non-recursive','--internal-diff','--git','--show-copies-as-adds','--notice-ancestry') }
                    log { @('-v','--verbose','-q','--quiet','--xml','--stop-on-copy','--use-merge-history','-g','--incremental','--with-all-revprops','--with-no-revprops') }
                    info { @('-R','--recursive','--xml') }
                    list { @('-R','--recursive','-v','--verbose','--xml','--incremental') }
                    cat { @() }
                    propget { @('-R','--recursive','-v','--verbose','--strict','--revprop','--xml') }
                    proplist { @('-R','--recursive','-v','--verbose','-q','--quiet','--revprop','--xml') }
                    blame { @('-v','--verbose','-g','--use-merge-history','--xml','--force') }
                }
                $flags=$commonSvnFlags + $verbFlags
                $revPattern='^(?:\d+|HEAD|BASE|COMMITTED|PREV|\{\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}Z?)?\})(?::(?:\d+|HEAD|BASE|COMMITTED|PREV|\{\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}Z?)?\}))?$'
                $paths=$false; $positionals=0; $index=1
                while ($index -lt $argv.Count) {
                    $value=$argv[$index++]
                    if ($paths) {
                        if ($verb -eq 'propget' -and $positionals -eq 0) {
                            if ($value -cnotmatch '^[A-Za-z0-9._:-]+$') { return $null }
                        } elseif (-not (Test-ReadPath $value)) { return $null }
                        $positionals++
                    }
                    elseif ($value -ceq '--') { $paths=$true }
                    elseif ($value -cin $flags) {}
                    elseif ($verb -cin @('diff','log','info','list','cat','propget','proplist','blame') -and $value -cin @('-r','--revision')) {
                        if ($index -ge $argv.Count -or $argv[$index] -cnotmatch $revPattern) { return $null }
                        $render.Add((Quote-ReadValue $value)); $value=$argv[$index++]
                    }
                    elseif ($verb -cin @('diff','log','info','list','cat','propget','proplist','blame') -and $value -cmatch '^(?:-r|--revision=)(.+)$') {
                        if ($Matches[1] -cnotmatch $revPattern) { return $null }
                    }
                    elseif ($verb -cin @('diff','log') -and $value -cin @('-c','--change')) {
                        if ($index -ge $argv.Count -or $argv[$index] -notmatch '^-?\d+(?:,-?\d+)*$') { return $null }
                        $render.Add((Quote-ReadValue $value)); $value=$argv[$index++]
                    }
                    elseif ($verb -cin @('diff','log') -and $value -cmatch '^(?:-c|--change=)(.+)$') {
                        if ($Matches[1] -notmatch '^-?\d+(?:,-?\d+)*$') { return $null }
                    }
                    elseif ($verb -eq 'log' -and $value -cin @('-l','--limit')) {
                        if ($index -ge $argv.Count -or $argv[$index] -notmatch '^\d{1,6}$') { return $null }
                        $render.Add((Quote-ReadValue $value)); $value=$argv[$index++]
                    }
                    elseif ($verb -eq 'log' -and $value -cmatch '^(?:-l|--limit=)(.+)$') {
                        if ($Matches[1] -notmatch '^\d{1,6}$') { return $null }
                    }
                    elseif ($verb -cin @('status','diff','info','list','propget','proplist') -and $value -ceq '--depth') {
                        if ($index -ge $argv.Count -or $argv[$index] -cnotin @('empty','files','immediates','infinity')) { return $null }
                        $render.Add((Quote-ReadValue $value)); $value=$argv[$index++]
                    }
                    elseif ($verb -cin @('status','diff','info','list','propget','proplist') -and $value -cmatch '^--depth=(.+)$') {
                        if ($Matches[1] -cnotin @('empty','files','immediates','infinity')) { return $null }
                    }
                    elseif ($verb -eq 'info' -and $value -ceq '--show-item') {
                        if ($index -ge $argv.Count -or $argv[$index] -cnotmatch '^[a-z-]+$') { return $null }
                        $render.Add((Quote-ReadValue $value)); $value=$argv[$index++]
                    }
                    elseif ($verb -eq 'info' -and $value -cmatch '^--show-item=(.+)$') {
                        if ($Matches[1] -cnotmatch '^[a-z-]+$') { return $null }
                    }
                    elseif ($verb -cin @('status','diff','info','propget','proplist') -and $value -cin @('--changelist','--cl')) {
                        if ($index -ge $argv.Count -or $argv[$index] -cnotmatch '^[A-Za-z0-9._-]+$') { return $null }
                        $render.Add((Quote-ReadValue $value)); $value=$argv[$index++]
                    }
                    elseif ($verb -cin @('status','diff','info','propget','proplist') -and $value -cmatch '^(?:--changelist|--cl)=(.+)$') {
                        if ($Matches[1] -cnotmatch '^[A-Za-z0-9._-]+$') { return $null }
                    }
                    elseif ($verb -eq 'log' -and $value -cin @('--search','--search-and')) {
                        if ($index -ge $argv.Count -or [string]::IsNullOrWhiteSpace($argv[$index]) -or $argv[$index].StartsWith('-')) { return $null }
                        $render.Add((Quote-ReadValue $value)); $value=$argv[$index++]
                    }
                    elseif ($verb -eq 'log' -and $value -cmatch '^(?:--search|--search-and)=(.+)$') {
                        if ([string]::IsNullOrWhiteSpace($Matches[1]) -or $Matches[1].StartsWith('-')) { return $null }
                    }
                    elseif ($value.StartsWith('-')) { return $null }
                    else {
                        if ($verb -eq 'propget' -and $positionals -eq 0) {
                            if ($value -cnotmatch '^[A-Za-z0-9._:-]+$') { return $null }
                        } elseif (-not (Test-ReadPath $value)) { return $null }
                        $positionals++
                    }
                    $render.Add((Quote-ReadValue $value))
                }
                if (($verb -in @('cat','propget','blame')) -and $positionals -eq 0) { return $null }
            } elseif ($name -in @('rg','rg.exe')) {
                # 禁用配置文件中的 --pre 等执行选项；只接受列出的只读选项。
                $render.Add('rg --no-config'); $positionals=0; $files=$argv -ccontains '--files'; $endOptions=$false
                for ($i=0;$i -lt $argv.Count;$i++) {
                    $value=$argv[$i]
                    if (-not $endOptions -and $value -ceq '--') { $endOptions=$true }
                    elseif (-not $endOptions -and $value -cin @('-n','-i','-l','-S','-F','-U','-c','--files','--hidden','--no-ignore','--line-number','--files-with-matches','--count','--fixed-strings','--ignore-case')) {}
                    elseif (-not $endOptions -and $value -cin @('-g','--glob','-t','--type','-A','-B','-C','--context','-m','--max-count','-e','--regexp')) {
                        $flag=$value; if (++$i -ge $argv.Count) { return $null }; $value=$argv[$i]
                        if ($flag -cin @('-A','-B','-C','--context','-m','--max-count') -and $value -notmatch '^\d{1,6}$') { return $null }
                        if ($flag -cin @('-e','--regexp')) { $positionals=1 }
                        $render.Add((Quote-ReadValue $flag))
                    }
                    elseif (-not $endOptions -and $value.StartsWith('-')) { return $null }
                    else {
                        if (($files -or $positionals -gt 0) -and ($isFilter -or -not (Test-ReadPath $value))) { return $null }
                        $positionals++
                    }
                    $render.Add((Quote-ReadValue $value))
                }
                if (-not $files -and $positionals -eq 0) { return $null }
            } elseif ($name -in @('cat','head','tail','sed','pwd') -and -not $powerShell) {
                $render.Add($name); $paths=0
                if ($name -eq 'pwd') { if ($argv.Count -or $isFilter) { return $null } }
                elseif ($name -eq 'sed') {
                    if ($argv.Count -lt 2 -or $argv[0] -cne '-n' -or $argv[1] -notmatch '^\d+(,\d+)?p$') { return $null }
                    $render.Add('-n'); $render.Add((Quote-ReadValue $argv[1])); $argv=@($argv | Select-Object -Skip 2)
                }
                for($i=0;$i -lt $argv.Count;$i++) {
                    $value=$argv[$i]
                    if ($name -in @('head','tail') -and $value -ceq '-n') {
                        if (++$i -ge $argv.Count -or $argv[$i] -notmatch '^\d{1,6}$') { return $null }
                        $render.Add('-n'); $value=$argv[$i]
                    } else { if ($isFilter -or -not (Test-ReadPath $value)) { return $null }; $paths++ }
                    $render.Add((Quote-ReadValue $value))
                }
                if ($name -ne 'pwd' -and -not $isFilter -and $paths -eq 0) { return $null }
            } else {
                if (-not $powerShell) { return $null }
                # PowerShell 的投影只接受固定参数，不接收脚本块、表达式或输出变量。
                $flags=@(); $takes=@(); $pathFlags=@(); $numeric=@(); $positionalPath=$false; $module='Microsoft.PowerShell.Utility'
                switch ($name.ToLowerInvariant()) {
                    'get-content' { $module='Microsoft.PowerShell.Management'; $flags=@('-Raw'); $takes=@('-Path','-LiteralPath','-TotalCount','-Tail','-Encoding'); $pathFlags=@('-Path','-LiteralPath'); $numeric=@('-TotalCount','-Tail'); $positionalPath=$true }
                    'get-childitem' { $module='Microsoft.PowerShell.Management'; $flags=@('-Recurse','-File','-Directory','-Force','-Name'); $takes=@('-Path','-LiteralPath','-Filter','-Depth'); $pathFlags=@('-Path','-LiteralPath'); $numeric=@('-Depth'); $positionalPath=$true }
                    'get-location' { $module='Microsoft.PowerShell.Management' }
                    'test-path' { $module='Microsoft.PowerShell.Management'; $takes=@('-Path','-LiteralPath','-PathType'); $pathFlags=@('-Path','-LiteralPath'); $positionalPath=$true }
                    'get-filehash' { $takes=@('-Path','-LiteralPath','-Algorithm'); $pathFlags=@('-Path','-LiteralPath'); $positionalPath=$true }
                    'select-string' { $flags=@('-SimpleMatch','-CaseSensitive','-List','-Quiet'); $takes=@('-Path','-LiteralPath','-Pattern','-Context'); $pathFlags=@('-Path','-LiteralPath'); $numeric=@('-Context') }
                    'select-object' { if (-not $isFilter) { return $null }; $takes=@('-First','-Last','-Skip'); $numeric=$takes }
                    'convertfrom-json' { if (-not $isFilter) { return $null }; $flags=@('-AsHashtable'); $takes=@('-Depth'); $numeric=$takes }
                    'convertto-json' { if (-not $isFilter) { return $null }; $flags=@('-Compress'); $takes=@('-Depth'); $numeric=$takes }
                    'measure-object' { if (-not $isFilter) { return $null }; $flags=@('-Line','-Word','-Character') }
                    'out-string' { if (-not $isFilter) { return $null }; $takes=@('-Width'); $numeric=$takes }
                    default { return $null }
                }
                if ($isFilter -and $name -notin @('Select-String','Select-Object','ConvertFrom-Json','ConvertTo-Json','Measure-Object','Out-String')) { return $null }
                $render.Add("$module\$name"); $pathCount=0; $hasPattern=$false; $seen=@{}
                for($i=0;$i -lt $argv.Count;$i++) {
                    $value=$argv[$i]
                    if ($value -in ($flags+$takes)) {
                        if ($seen.ContainsKey($value)) { return $null }; $seen[$value]=$true; $render.Add($value)
                        if ($value -in $flags) { continue }
                        $flag=$value; if (++$i -ge $argv.Count) { return $null }; $value=$argv[$i]
                        if ($flag -in $numeric -and $value -notmatch '^\d{1,6}$') { return $null }
                        if ($flag -in $pathFlags) { if ($isFilter -or -not (Test-ReadPath $value)) { return $null }; $pathCount++ }
                        if ($flag -eq '-Pattern') { $hasPattern=$true }
                        if ($flag -eq '-Encoding' -and $value -notin @('utf8','utf8BOM','utf8NoBOM','unicode','ascii','default','oem','bigendianunicode','utf32')) { return $null }
                        if ($flag -eq '-PathType' -and $value -notin @('Leaf','Container','Any')) { return $null }
                        if ($flag -eq '-Algorithm' -and $value -notin @('SHA256','SHA384','SHA512','SHA1','MD5')) { return $null }
                    } elseif ($positionalPath -and -not $isFilter -and (Test-ReadPath $value)) { $pathCount++ }
                    else { return $null }
                    $render.Add((Quote-ReadValue $value))
                }
                if ($pathCount -gt 1 -or ($positionalPath -and $name -ne 'Get-ChildItem' -and $pathCount -ne 1) -or
                    ($name -eq 'Select-String' -and (-not $hasPattern -or (-not $isFilter -and $pathCount -ne 1)))) { return $null }
            }
            $rendered=$render -join ' '
            if ($hasStderrToStdout) { $rendered += ' 2>&1' }
            $pipeline.Add($rendered)
        }
        $statements.Add(($pipeline -join ' | '))
    }
    $updated=[ordered]@{}
    if ($Agent -ceq 'ANTIGRAVITY') {
        foreach($key in $nativeArguments.Keys) { $updated[$key]=$nativeArguments[$key] }
        $updated.CommandLine=$statements -join '; '
        # 固定到已检查的工作目录，不能继承终端此前切换到的目录。
        $updated.Cwd=$working
        return $updated
    }
    foreach($key in $ToolArguments.Keys) { $updated[$key]=$ToolArguments[$key] }
    # Codex 的 Bash/exec Hook 协议要求 updatedInput.command。
    $updated.Remove('cmd'); $updated.command=$statements -join '; '
    return $updated
}
