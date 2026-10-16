#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'workflow-vcs.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function Fails([scriptblock]$action,[string]$pattern) {
    $failure=''; try { & $action | Out-Null } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $pattern) "Expected $pattern; got $failure"
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-vcs-'+[guid]::NewGuid().ToString('N'))
$probeBody=(Get-Command Invoke-AiSopMetadataProbe).ScriptBlock
try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    # Load the real state helpers, excluding the CLI dispatcher and mutations.
    $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'workflow-state.ps1'),[ref]$null,[ref]$parseErrors)
    Assert (-not $parseErrors) 'State script does not parse'
    $functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)
    foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
    $native=$ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('git','svn')},$true)
    Assert (-not $native.Count) 'Unbounded Git/SVN call remains in workflow-state'
    $script:TaskValidationContext=New-AiSopValidationContext
    & git -C $root init --quiet -b main
    [IO.File]::WriteAllText((Join-Path $root 'sample.txt'),'before')
    & git -C $root add sample.txt
    & git -C $root -c user.name=Test -c user.email=test@example.invalid commit --quiet -m initial
    $baseline=[string](& git -C $root rev-parse HEAD)
    [IO.File]::WriteAllText((Join-Path $root 'sample.txt'),'after')
    $script:WorkflowVcsContext=New-AiSopWorkflowVcsContext
    $status=Invoke-AiSopWorkflowVcs $script:WorkflowVcsContext git @('-C',$root,'status','--porcelain')
    Assert ($status.lines[0] -ceq ' M sample.txt') 'Leading porcelain status whitespace was lost'
    $digest=Get-ChangeSetDigest $root $baseline
    Assert ($digest -match '^[a-f0-9]{64}$') 'Real diff digest failed'
    $missing=Invoke-AiSopWorkflowVcs $script:WorkflowVcsContext git @('-C',$root,'rev-parse','--verify','--quiet','missing^{commit}') -AllowNonZero
    Assert ($missing.exitCode -ne 0 -and -not $missing.lines.Count) 'Expected missing ref was treated as successful metadata'

    # A real stalled child times out even when nonzero exits are allowed.
    function Invoke-AiSopMetadataProbe {
        param($FilePath,$ArgumentList,$TimeoutSeconds,[switch]$PreserveWhitespace)
        & $probeBody -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep 60') -TimeoutSeconds $TimeoutSeconds -PreserveWhitespace:$PreserveWhitespace
    }
    $context=New-AiSopWorkflowVcsContext -TimeoutSeconds 1
    $timer=[Diagnostics.Stopwatch]::StartNew()
    Fails { Invoke-AiSopWorkflowVcs $context git @('status') -AllowNonZero } 'VCS_PROBE_UNAVAILABLE.*PROCESS_TIMED_OUT'
    Assert ($timer.Elapsed.TotalSeconds -lt 12) 'Stalled VCS did not return within timeout plus cleanup budget'
    $timer.Restart()
    Fails { Invoke-AiSopWorkflowVcs $context git @('status') } 'circuit open'
    Assert ($timer.Elapsed.TotalSeconds -lt 1) 'Second probe spent another timeout'

    function Invoke-AiSopMetadataProbe {
        param($FilePath,$ArgumentList,$TimeoutSeconds,[switch]$PreserveWhitespace)
        $script:probeCalls++
        return $script:probeResult
    }
    $script:probeCalls=0
    $script:probeResult=@{exitCode=0;output=" M sample.txt`n`n+ keep whitespace  `n";stderr='warning: stderr is not a change';diagnostic=''}
    $context=New-AiSopWorkflowVcsContext
    $result=Invoke-AiSopWorkflowVcs $context git @('status')
    Assert ($result.lines.Count -eq 3 -and $result.lines[1] -ceq '' -and $result.lines[2] -ceq '+ keep whitespace  ' -and ($result.lines -join '') -notmatch 'warning') 'Diff whitespace/stream isolation changed'
    $context.elapsedMs=$context.budgetSeconds*1000
    $callsBefore=$script:probeCalls
    Fails { Invoke-AiSopWorkflowVcs $context git @('status') } 'total VCS time budget exhausted'
    Assert ($script:probeCalls -eq $callsBefore) 'Spent another probe after total budget expired'

    foreach ($fault in @(
        @{exitCode=124;output='';stderr='';diagnostic='PROCESS_TIMED_OUT: fixture'},
        @{exitCode=128;output='';stderr='fatal: cannot read repository';diagnostic=''}
    )) {
        $script:probeResult=$fault
        $script:WorkflowVcsContext=New-AiSopWorkflowVcsContext
        Fails { Get-ChangeSetDigest $root } 'VCS_PROBE_UNAVAILABLE|VCS_COMMAND_FAILED'
        $script:WorkflowVcsContext=New-AiSopWorkflowVcsContext
        Fails { Get-WorkspaceChangedRelativePaths $root HEAD } 'VCS_PROBE_UNAVAILABLE|VCS_COMMAND_FAILED'
        $script:WorkflowVcsContext=New-AiSopWorkflowVcsContext
        $risk=Get-SemanticRiskAssessment $root -Baseline HEAD -DeclaredTier T2
        Assert ('VCS_ERROR' -in $risk.TriggersHit -and $risk.HasHighRisk) 'Failed VCS became a no-risk verdict'
        Assert (($risk.Details -join ';') -match 'VCS_PROBE_UNAVAILABLE|VCS_COMMAND_FAILED') 'Risk diagnosis lost the VCS failure'
    }
    # Circuit state belongs to the invocation, never a process-global cache.
    Set-Item Function:\Invoke-AiSopMetadataProbe -Value $probeBody
    $context=New-AiSopWorkflowVcsContext
    Assert ((Invoke-AiSopWorkflowVcs $context git @('-C',$root,'status','--porcelain')).exitCode -eq 0) 'Fresh invocation inherited a failed circuit'
    Write-Output 'PASS: bounded VCS, circuit/time budget, whitespace, nonzero exits and conservative state consumers'
} finally {
    Set-Item Function:\Invoke-AiSopMetadataProbe -Value $probeBody
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
