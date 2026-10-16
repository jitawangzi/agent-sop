#requires -Version 7.0
# Optional report mapping. This validates report freshness and observed results,
# not the trustworthiness of a local process that can manufacture XML itself.
function Get-AiSopJUnitConfiguration {
    param([string]$WorkspacePath, [string[]]$Reports, [string]$CaseMap)
    if (-not $Reports.Count -and -not $CaseMap) { return $null }
    if (-not $Reports.Count -or -not $CaseMap) { throw 'JUNIT_CONFIGURATION_REQUIRED: provide both JUnitReports and CaseMap' }
    $mapPath=Resolve-AiSopWorkspaceChild $WorkspacePath $CaseMap
    try {
        $raw=[IO.File]::ReadAllText($mapPath)
        if (-not (Test-Json -Json $raw -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/junit-case-map.schema.json') -ErrorAction Stop)) { throw 'schema mismatch' }
        $map=ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
    } catch { throw "JUNIT_MAP_INVALID: $mapPath; $($_.Exception.Message)" }
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($case in $map.cases) { if (-not $ids.Add($case.id)) { throw "JUNIT_MAP_DUPLICATE_CASE:$($case.id)" } }
    $paths=[Collections.Generic.HashSet[string]]::new($(if ([OperatingSystem]::IsWindows()) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    foreach ($report in $Reports) {
        $path=Resolve-AiSopWorkspaceChild $WorkspacePath $report
        if (-not $paths.Add($path)) { throw 'JUNIT_REPORT_DUPLICATE' }
    }
    $map.cases=@($map.cases | Sort-Object id -CaseSensitive)
    return @{ bindingVersion='junit-map-v1'; mapPath=[IO.Path]::GetRelativePath($WorkspacePath,$mapPath).Replace('\','/'); reports=@($paths | ForEach-Object { [IO.Path]::GetRelativePath($WorkspacePath,$_).Replace('\','/') } | Sort-Object -CaseSensitive); cases=@($map.cases); mapDigest=(Get-AiSopWorkflowSha256 (ConvertTo-AiSopWorkflowCanonicalJson $map)) }
}

function Get-AiSopJUnitFileIdentity {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return 'MISSING' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() + ':' + [IO.File]::GetLastWriteTimeUtc($Path).Ticks
}

function Assert-AiSopJUnitResult {
    param($Record)
    if (-not $Record.context.junitConfiguration) {
        if ($Record.reportEvidence) { throw 'JUNIT_CONFIGURATION_REQUIRED' }
        return
    }
    if ($Record.kind -ne 'test') { throw 'JUNIT_TEST_ONLY' }
    if ($Record.outcome -ne 'PASSED') { return }
    $configuration=ConvertFrom-AiSopWorkflowJson $Record.context.junitConfiguration -AsHashtable
    $result=$Record.reportEvidence
    if (-not $result -or $result.format -cne 'JUNIT') { throw 'JUNIT_RESULT_REQUIRED' }
    foreach ($ids in @(@{values=$configuration.cases.id}, @{values=$result.passedCaseIds})) {
        if ((ConvertTo-AiSopWorkflowCanonicalJson @($ids.values | Sort-Object -CaseSensitive -Unique)) -cne
            (ConvertTo-AiSopWorkflowCanonicalJson @($Record.caseIds | Sort-Object -CaseSensitive -Unique))) { throw 'JUNIT_CASE_SCOPE_MISMATCH' }
    }
    if ((ConvertTo-AiSopWorkflowCanonicalJson @($configuration.reports | Sort-Object -CaseSensitive)) -cne
        (ConvertTo-AiSopWorkflowCanonicalJson @($result.reports.path | Sort-Object -CaseSensitive))) { throw 'JUNIT_REPORT_SCOPE_MISMATCH' }
    if (@($result.reports | Where-Object { $_.failed -ne 0 }).Count) { throw 'JUNIT_REPORT_FAILED' }
}

function Read-AiSopJUnitEvidence {
    param($Configuration, $Before, [string]$WorkspacePath)
    $observed=[Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::Ordinal)
    $reports=@(); $anyFailed=$false
    foreach ($relative in $Configuration.reports) {
        $path=Resolve-AiSopWorkspaceChild $WorkspacePath $relative
        $identity=Get-AiSopJUnitFileIdentity $path
        if ($identity -eq 'MISSING') { throw "JUNIT_REPORT_MISSING:$relative" }
        if ($identity -ceq $Before[$relative]) { throw "JUNIT_REPORT_STALE:$relative; the command must write a fresh report" }
        $settings=[Xml.XmlReaderSettings]::new(); $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit; $settings.XmlResolver=$null
        $reader=$null
        try {
            $reader=[Xml.XmlReader]::Create($path,$settings)
            $doc=[Xml.XmlDocument]::new(); $doc.XmlResolver=$null; $doc.Load($reader)
            if ($doc.DocumentElement.LocalName -notin @('testsuite','testsuites')) { throw 'expected testsuite or testsuites' }
        } catch { throw "JUNIT_REPORT_INVALID:${relative}:$($_.Exception.Message)" } finally { if ($reader) { $reader.Dispose() } }
        $failed=0; $skipped=0; $count=0
        $summaries=@()
        foreach ($suite in $doc.SelectNodes("//*[local-name()='testsuite' or local-name()='testsuites']")) {
            $declared=@{}
            foreach ($key in @('tests','failures','errors','skipped')) {
                if (-not $suite.HasAttribute($key)) { continue }
                $number=$suite.GetAttribute($key)
                $parsed=0L
                if ($number -notmatch '^[0-9]+$' -or -not [long]::TryParse($number,[ref]$parsed)) { throw "JUNIT_REPORT_INVALID:${relative}:invalid $key" }
                $declared[$key]=$parsed
                if ($key -in @('failures','errors') -and $parsed -gt 0) { $anyFailed=$true }
            }
            $summaries+=@{suite=$suite;declared=$declared}
        }
        foreach ($test in $doc.SelectNodes("//*[local-name()='testcase']")) {
            $count++
            $hasFailure=$null -ne $test.SelectSingleNode("*[local-name()='failure' or local-name()='error']")
            $hasSkip=$null -ne $test.SelectSingleNode("*[local-name()='skipped']") -or $test.GetAttribute('status') -in @('disabled','skipped','notrun')
            if ($hasFailure) { $failed++; $anyFailed=$true }
            if ($hasSkip) { $skipped++ }
            $key=ConvertTo-AiSopWorkflowCanonicalJson @($test.GetAttribute('classname'),$test.GetAttribute('name'))
            $passed=-not $hasFailure -and -not $hasSkip
            if ($observed.ContainsKey($key)) { $observed[$key]=$observed[$key] -and $passed } else { $observed[$key]=$passed }
        }
        # Suite totals describe descendant cases, including nested suites. Never
        # sum parent and child totals into report counts. Missing totals are OK;
        # supplied totals must agree before a report can become PASSED evidence.
        if (-not $anyFailed) {
            foreach ($summary in $summaries) {
                $cases=@($summary.suite.SelectNodes(".//*[local-name()='testcase']"))
                $actual=@{tests=$cases.Count;failures=0;errors=0;skipped=0}
                foreach ($case in $cases) {
                    if ($null -ne $case.SelectSingleNode("*[local-name()='skipped']") -or $case.GetAttribute('status') -in @('disabled','skipped','notrun')) { $actual.skipped++ }
                }
                foreach ($key in $summary.declared.Keys) {
                    if ($summary.declared[$key] -ne $actual[$key]) {
                        throw "JUNIT_REPORT_INVALID:${relative}:summary $key=$($summary.declared[$key]) disagrees with testcase details ($($actual[$key]))"
                    }
                }
            }
        }
        if ((Get-AiSopJUnitFileIdentity $path) -cne $identity) { throw "JUNIT_REPORT_CHANGED_DURING_READ:$relative" }
        $reports+=@{ path=$relative; sha256=$identity.Split(':')[0]; testCount=$count; failed=$failed; skipped=$skipped }
    }
    if ($anyFailed) { throw 'JUNIT_REPORT_FAILED: report contains failures/errors even if the process exited zero' }
    $passedCases=@()
    foreach ($case in $Configuration.cases) {
        $key=ConvertTo-AiSopWorkflowCanonicalJson @($case.className,$case.name)
        if (-not $observed.ContainsKey($key) -or -not $observed[$key]) { throw "JUNIT_CASE_NOT_PASSED:$($case.id); exact classname/name missing or skipped" }
        $passedCases += $case.id
    }
    return @{ format='JUNIT'; passedCaseIds=@($passedCases | Sort-Object -CaseSensitive -Unique); reports=$reports }
}
