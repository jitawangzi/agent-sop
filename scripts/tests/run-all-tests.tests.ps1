#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$RunnerScript = Join-Path $ScriptsRoot "run-all-tests.ps1"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "runner-tests-" + [guid]::NewGuid().ToString("N")
)
$TestsDir = Join-Path $TestRoot "tests"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function New-FakeSuite {
    param([string]$Name, [string]$Body)

    $path = Join-Path $TestsDir "$Name.tests.ps1"
    [System.IO.File]::WriteAllText($path, $Body, $Utf8NoBom)
}

function Clear-FakeSuites {
    Get-ChildItem -LiteralPath $TestsDir -Filter *.tests.ps1 -File -ErrorAction SilentlyContinue |
        Remove-Item -Force
}

function Invoke-Runner {
    param([string]$SuiteFilter = "")

    $argList = @("-NoProfile", "-File", $RunnerScript, "-TestsRoot", $TestsDir, "-Quiet")
    if ($SuiteFilter) {
        $argList += @("-Suite", $SuiteFilter)
    }
    & {
        $ErrorActionPreference = 'Continue'
        & pwsh @argList *> $null
    }
    return $LASTEXITCODE
}

function Assert-ExitZero {
    param([string]$Message, [scriptblock]$Action)

    & $Action | Out-Null
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "Expected exit 0: $Message ; got exit $code"
    }
}

function Assert-ExitNonZero {
    param([string]$Message, [scriptblock]$Action)

    & $Action | Out-Null
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        throw "Expected non-zero exit: $Message ; got exit 0"
    }
}

try {
    [System.IO.Directory]::CreateDirectory($TestsDir) | Out-Null

    # 1. 单个通过的 suite -> exit 0
    Clear-FakeSuites
    New-FakeSuite "aaa-pass" 'Write-Output "All aaa-pass tests passed."'
    Assert-ExitZero -Message "single passing suite exits 0" -Action {
        Invoke-Runner
    }

    # 2. 一个通过 + 一个失败 -> exit 非零
    New-FakeSuite "bbb-fail" 'throw "boom"'
    Assert-ExitNonZero -Message "mixed pass/fail suites exit non-zero" -Action {
        Invoke-Runner
    }

    # 3. -Suite 过滤到通过的 suite -> exit 0
    Assert-ExitZero -Message "Suite filter to passing suite exits 0" -Action {
        Invoke-Runner -SuiteFilter "aaa-pass"
    }

    # 4. -Suite 过滤到失败的 suite -> exit 非零
    Assert-ExitNonZero -Message "Suite filter to failing suite exits non-zero" -Action {
        Invoke-Runner -SuiteFilter "bbb-fail"
    }

    # 5. 空测试目录 -> exit 0
    Clear-FakeSuites
    Assert-ExitZero -Message "empty tests dir exits 0" -Action {
        Invoke-Runner
    }

    # 6. 不存在的 TestsRoot -> exit 0 (无可运行项)
    $missingDir = Join-Path $TestRoot "does-not-exist"
    $argList = @("-NoProfile", "-File", $RunnerScript, "-TestsRoot", $missingDir, "-Quiet")
    & {
        $ErrorActionPreference = 'Continue'
        & pwsh @argList *> $null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Expected exit 0 for missing tests root; got exit $LASTEXITCODE"
    }

    Write-Output "All run-all-tests tests passed."
} finally {
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
