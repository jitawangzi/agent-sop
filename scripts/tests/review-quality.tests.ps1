#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot fixtures/boundary-cases.ps1)
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'review-paths.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('review-quality-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function JsonFile([string]$Path,$Value){[IO.Directory]::CreateDirectory((Split-Path -Parent $Path))|Out-Null;[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30))}
function Export([switch]$Current,[string]$SelectedScope='src',[string]$Previous='',[string]$Attachments=''){
    $raw=& (Join-Path $scripts 'export-review.ps1') -WorkspacePath $workspace -Feature Example -TaskId change -RepositoryPaths @('.') -Scope $SelectedScope -CheckCurrent:$Current -PreviousReview $Previous -AttachmentsManifest $Attachments
    $text=$raw|Out-String
    Assert (-not $text.Contains('TOP_SECRET_TEST')) 'Command secret leaked'
    return ($text|ConvertFrom-Json)
}
try {
    $workspace=Join-Path $root workspace;$taskPath=Join-Path $workspace '.ai-workspace/specs/features/Example/tasks/change/task.json'
    [IO.Directory]::CreateDirectory((Join-Path $workspace src))|Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'src/input.txt'),'before')
    $snapshot=Get-AiSopInputSnapshot $workspace;$ref=Save-AiSopInputManifest $snapshot $workspace
    $run=@{kind='test';batch='behavior';command='TOP_SECRET_TEST';exitCode=1;executedAt='2026-01-01T00:00:00Z';inputDigest=$snapshot.digest;inputsRef=$ref;inputsStable=$true;caseIds=@();runId=('1'*32);outcome='FAILED';context=@{}}
    $pass=$run.Clone();$pass.exitCode=0;$pass.outcome='PASSED';$pass.runId='2'*32
    $compile=$pass.Clone();$compile.kind='compile';$compile.batch='compile';$compile.runId='3'*32
    $task=@{schemaVersion='1.0';taskId='change';feature='Example';ownerId='fixture';tier='T2';objective='Review fixture';status='DONE';nextAction='';notes='';createdAt='2026-01-01T00:00:00Z';updatedAt='2026-01-01T00:00:00Z';requiredCaseIds=@();verifications=@($run,$pass,$compile)}
    JsonFile $taskPath $task
    $finding=@{schemaVersion='1.0';id='CHECK-1';severity='P2';status='OPEN';title='Unresolved resource';scope=@('src');trigger='cleanup fails';impact='resource remains';source=@{repository='fixture';revision='before';path='src/input.txt'};history=@(@{status='OPEN';reason='observed'})}
    JsonFile (Join-Path $workspace '.ai-workspace/specs/features/Example/findings/CHECK-1.json') $finding
    JsonFile (Join-Path (Split-Path -Parent $taskPath) evidence.json) @{scope=@{rawLog='TOP_SECRET_TEST'};limitations=@{command='TOP_SECRET_TEST'};cleanup=@{outcome='FAILED';environment=@{password='TOP_SECRET_TEST'}}}
    $before=(Get-FileHash $taskPath).Hash
    $report=Export
    Assert ($report.incremental.status -eq 'NOT_REQUESTED') 'Incremental review became mandatory'
    Assert ($report.finalization.documents -eq 'NOT_REQUESTED' -and $report.finalization.remote -eq 'NOT_CHECKED') 'Optional finalization became a gate or invented remote facts'
    Assert ($report.finalization.attention.items.code -contains 'CLEANUP_FAILED' -and $report.finalization.attention.items.code -contains 'RELATED_FINDINGS_UNRESOLVED' -and -not $report.finalization.attention.blocking) 'Summary hid unresolved finding/cleanup or added a gate'
    Assert ($report.finalization.attention.items.code -contains 'RUN_EVIDENCE_NOT_RECORDED') 'Unrecorded run evidence omitted from summary'
    $manifestRelative='.ai-workspace/specs/features/Example/tasks/change/attachments.json'
    '["missing-review.md"]'|Set-Content (Join-Path $workspace $manifestRelative)
    $withHints=Export -Attachments $manifestRelative
    Assert ($withHints.finalization.documents -eq 'NEEDS_ATTENTION' -and $withHints.history.Count -eq 3 -and -not $withHints.blocking) 'Missing document interrupted full export'
    $documentRelative='.ai-workspace/specs/features/Example/tasks/change/coverage.md'
    "[outside](https://example.invalid/?TOP_SECRET_TEST)`n[missing](missing.md)"|Set-Content (Join-Path $workspace $documentRelative)
    ConvertTo-Json -InputObject @($documentRelative)|Set-Content (Join-Path $workspace $manifestRelative)
    $withCoverage=Export -Attachments $manifestRelative
    $observed=$withCoverage.finalization.references[0]
    Assert ($observed.linkCoverage.checkedLinks -eq 1 -and $observed.linkCoverage.skippedByReason.EXTERNAL_SCHEME -eq 1 -and $observed.links[0].line -eq 2) 'Full export lost link coverage or original location'
    Assert ($withCoverage.history.Count -eq 3 -and -not $withCoverage.blocking) 'Coverage summary changed histories or completion policy'
    $priorRelative='.ai-workspace/specs/features/Example/tasks/change/invalid-prior.json'
    'null'|Set-Content (Join-Path $workspace $priorRelative)
    $partial=Export -Previous $priorRelative
    Assert ($partial.incremental.status -eq 'UNAVAILABLE' -and $partial.history.Count -eq 3 -and $partial.findings.Count -eq 1) 'Bad previous review interrupted full export'
    Assert ($report.latest.Count -eq 2 -and $report.history.Count -eq 3) 'Batch histories collapsed'
    Assert ($report.findings[0].declaredStatus -eq 'OPEN' -and $report.taskStatus -eq 'DONE') 'Task PASS closed finding'
    Assert ($report.cleanup.value.outcome -eq 'FAILED') 'Cleanup failure hidden'
    $evidencePath=Join-Path (Split-Path -Parent $taskPath) evidence.json
    $originalEvidence=[IO.File]::ReadAllText($evidencePath)
    $invalidObjects=@(Get-AiSopJsonBoundaryCases Object|Where-Object {-not $_.accepted}|Select-Object -ExpandProperty json)
    foreach($invalid in (@('[{"cleanup":{"outcome":"PASSED"}}]','"text"','42','{"broken":')+$invalidObjects)){
        [IO.File]::WriteAllText($evidencePath,$invalid)
        $invalidHash=(Get-FileHash $evidencePath).Hash
        $partial=Export
        Assert ($partial.finalization.attention.items.code -contains 'SUPPLEMENTAL_EVIDENCE_UNREADABLE' -and $partial.finalization.attention.items.code -contains 'CLEANUP_UNCONFIRMED') 'Summary hid malformed supplement'
        Assert ($partial.diagnostics -contains 'SUPPLEMENTAL_EVIDENCE_UNREADABLE') 'Invalid supplement diagnostic missing'
        Assert ($partial.cleanup.source.status -eq 'UNAVAILABLE' -and $partial.unverifiedScope.source.status -eq 'UNAVAILABLE') 'Invalid supplement presented as available'
        Assert ($partial.cleanup.status -eq 'NOT_RECORDED' -and $partial.unverifiedScope.status -eq 'NOT_RECORDED' -and -not $partial.cleanup.value.outcome) 'Invalid supplement invented facts'
        Assert ($partial.history.Count -eq 3 -and $partial.latest.Count -eq 2 -and $partial.findings[0].id -eq 'CHECK-1') 'Invalid supplement discarded other evidence'
        Assert ((Get-FileHash $evidencePath).Hash -eq $invalidHash -and (Get-FileHash $taskPath).Hash -eq $before) 'Read-only export changed evidence'
    }
    [IO.File]::WriteAllText($evidencePath,$originalEvidence)
    $report=Export
    Assert ($report.latest[0].currentInputs -eq 'NOT_CHECKED') 'Implicit current-input claim'
    Assert ($report.preparation.hints -contains 'CHECK_CURRENT_INPUTS_BEFORE_SELECTING_VERIFICATION' -and -not $report.preparation.blocking -and -not $report.preparation.observedInputDigest) 'Preparation invented a current snapshot or gate'
    Assert ((Export -SelectedScope 'src\child\file.java').findings.Count -eq 1) 'Windows scope separator mismatch'
    Assert ((Export -SelectedScope 'src-other').findings.Count -eq 0) 'Same-prefix unrelated scope matched'
    if([OperatingSystem]::IsWindows()){Assert ((Export -SelectedScope 'SRC/child').findings.Count -eq 1) 'Windows scope case mismatch'}
    Assert ((Export -SelectedScope '../unknown').findingCoverage -eq 'INCOMPLETE') 'Unknown scope silently excluded findings'
    $report=Export -Current
    Assert (@($report.latest|Where-Object currentInputs -ne MATCH).Count -eq 0) 'Current input comparison missing'
    Assert ($report.preparation.observedInputDigest -eq $report.latest[0].inputDigest) 'Observed input digest lost'
    [IO.File]::WriteAllText((Join-Path $workspace 'src/input.txt'),'after')
    $report=Export -Current
    Assert (@($report.latest|Where-Object currentInputs -ne STALE).Count -eq 0) 'Stale input not detected'
    Assert ($report.preparation.hints -contains 'STALE_BATCHES_REQUIRE_REVIEW') 'Preparation hid stale results'
    Assert ((Get-FileHash $taskPath).Hash -eq $before) 'Read-only export changed task'
    $manifest=Get-AiSopInputManifestPath $workspace $ref
    [IO.File]::WriteAllText($manifest,'{}')
    $report=Export -Current
    Assert ($report.latest[0].inputIntegrity -eq 'UNAVAILABLE') 'Corrupt manifest accepted'
    $finding.status='CLOSED'
    JsonFile (Join-Path $workspace '.ai-workspace/specs/features/Example/findings/CHECK-1.json') $finding
    $report=Export
    Assert (@($report.diagnostics|Where-Object {$_ -like 'FINDING_UNREADABLE:*'}).Count -eq 1) 'Unsupported closure hidden'
    Assert ($report.finalization.tests -eq 'RECORDED_PASSES' -and $report.finalization.attention.items.code -contains 'FINDING_UNREADABLE' -and $report.finalization.attention.items.code -contains 'FINDING_COVERAGE_INCOMPLETE') 'Passing tests concealed unreadable closure'
    Assert ($report.finalization.attention.items.code -contains 'PACKAGE_NOT_CONFIRMED' -and $report.finalization.attention.items.code -contains 'REMOTE_NOT_CONFIRMED') 'Summary invented package/remote verification'
    $failed=$false
    try {& (Join-Path $scripts 'export-review.ps1') -WorkspacePath $workspace -Feature Example -TaskId '../escape'|Out-Null}catch{$failed=$true}
    Assert $failed 'Task path escape accepted'

    $repo=Join-Path $root repository;[IO.Directory]::CreateDirectory($repo)|Out-Null
    & git -C $repo init -q
    & git -C $repo config user.name fixture
    & git -C $repo config user.email fixture@example.invalid
    [IO.File]::WriteAllText((Join-Path $repo input.txt),'committed')
    [IO.File]::WriteAllText((Join-Path $repo build.ps1),'if ((Get-Content input.txt -Raw) -cne "committed" -or (Test-Path untracked.txt)) { exit 3 }; exit 0')
    & git -C $repo add -- input.txt build.ps1
    & git -C $repo commit -qm fixture
    Assert ($LASTEXITCODE -eq 0) 'Fixture commit failed'
    $revision=(& git -C $repo rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $repo input.txt),'dirty')
    [IO.File]::WriteAllText((Join-Path $repo untracked.txt),'must not copy')
    $buildManifest=Join-Path $root build.json
    $definition=@{schemaVersion='1.0';repositories=@(@{path='.';source=$repo;revision=$revision});command=@{executable=(Get-Process -Id $PID).Path;arguments=@('-NoProfile','-File','./build.ps1');timeoutSeconds=30};environmentNotes='fixture'}
    JsonFile $buildManifest $definition
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $scripts verify-clean-checkout.ps1) -ManifestFile $buildManifest -Destination (Join-Path $root success)
    Assert ($LASTEXITCODE -eq 0) 'Fresh checkout build failed'
    $result=Get-Content (Join-Path $root success/evidence/result.json) -Raw|ConvertFrom-Json
    Assert ($result.outcome -eq 'PASSED' -and $result.repositories[0].revision -eq $revision) 'Build revision unbound'
    [IO.File]::WriteAllText((Join-Path $repo build.ps1),'if (-not (Test-Path untracked.txt)) { exit 37 }; exit 0')
    & git -C $repo add -- build.ps1
    & git -C $repo commit -qm missing-dependency
    $definition.repositories[0].revision=(& git -C $repo rev-parse HEAD).Trim();JsonFile $buildManifest $definition
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $scripts verify-clean-checkout.ps1) -ManifestFile $buildManifest -Destination (Join-Path $root failure)
    Assert ($LASTEXITCODE -eq 1) 'Untracked source dependency falsely passed'
    Assert (Test-Path (Join-Path $root failure/evidence/result.json)) 'Failed build evidence lost'
    $failure=Get-Content (Join-Path $root failure/evidence/result.json) -Raw|ConvertFrom-Json
    Assert ($failure.exitCode -eq 37) 'Native exit code collapsed'

    # Replace the external manifest after capture and before command launch.
    $definition.repositories[0].revision=$revision
    $definition.command.arguments=@('-NoProfile','-File','./build.ps1')
    JsonFile $buildManifest $definition
    $boundHash=(Get-FileHash $buildManifest).Hash.ToLowerInvariant()
    $mutatorPath=Join-Path $root mutate.ps1
    [IO.File]::WriteAllText($mutatorPath,@'
param($Snapshot,$External,$Ready)
[IO.File]::WriteAllText($Ready,'ready')
$until=[DateTime]::UtcNow.AddSeconds(15)
while(-not [IO.File]::Exists($Snapshot)){if([DateTime]::UtcNow -gt $until){exit 5};Start-Sleep -Milliseconds 1}
[IO.File]::WriteAllText($External,'changed')
exit 0
'@)
    $ready=Join-Path $root mutator-ready
    $mutator=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$mutatorPath,'-Snapshot',(Join-Path $root bound/evidence/manifest.json),'-External',$buildManifest,'-Ready',$ready) -TimeoutSeconds 20 -PassThru
    try {
        $until=[DateTime]::UtcNow.AddSeconds(10)
        while(-not(Test-Path $ready)){if([DateTime]::UtcNow -gt $until){throw 'MUTATOR_NOT_READY'};Start-Sleep -Milliseconds 10}
        & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $scripts verify-clean-checkout.ps1) -ManifestFile $buildManifest -Destination (Join-Path $root bound)
        Assert ($LASTEXITCODE -eq 0) 'Bound manifest invocation failed'
        $mutator.WaitForExit();Assert ($mutator.ExitCode -eq 0) 'Manifest mutation did not execute'
    } finally {$mutator.Dispose()}
    $bound=Get-Content (Join-Path $root bound/evidence/result.json) -Raw|ConvertFrom-Json
    Assert ($bound.manifestSha256 -eq $boundHash -and (Get-FileHash (Join-Path $root bound/evidence/manifest.json)).Hash.ToLowerInvariant() -eq $boundHash) 'Captured manifest identity lost'
    Assert ([IO.File]::ReadAllText($buildManifest) -ceq 'changed') 'External manifest unchanged during clone'

    & git -C $repo update-index --add --cacheinfo "160000,$revision,dependency"
    & git -C $repo commit -qm gitlink
    Assert ($LASTEXITCODE -eq 0) 'Gitlink fixture commit failed'
    $definition.repositories=@(@{path='.';source=$repo;revision=(& git -C $repo rev-parse HEAD).Trim()},@{path='dependency';source=$repo;revision=$revision})
    $definition.command.arguments=@('-NoProfile','-Command','if ((Get-Content dependency/input.txt -Raw) -cne "committed") { exit 9 }; exit 0')
    JsonFile $buildManifest $definition
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $scripts verify-clean-checkout.ps1) -ManifestFile $buildManifest -Destination (Join-Path $root gitlink)
    Assert ($LASTEXITCODE -eq 0) 'Pinned gitlink placeholder unsupported'

    # Intermediate links followed by an existing directory must never escape containment.
    $outside=Join-Path $root outside;[IO.Directory]::CreateDirectory((Join-Path $outside existing))|Out-Null
    $link=Join-Path $workspace alias
    $linkKind=if([OperatingSystem]::IsWindows()){'Junction'}else{'SymbolicLink'}
    New-Item -ItemType $linkKind -Path $link -Target $outside|Out-Null
    try {
        $rejected=$false
        try {Resolve-AiSopReviewChild $workspace 'alias/existing/new'|Out-Null}catch{$rejected=$true}
        Assert $rejected 'Intermediate link escaped review root'
    } finally {Remove-Item -LiteralPath $link -Force}
    Write-Output 'PASS: derived review histories, stale/corrupt inputs, nonblocking findings, readonly boundary, fresh committed checkout and missing dependency detection'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'review-quality-*'){throw 'FIXTURE_CLEANUP_ESCAPE'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
