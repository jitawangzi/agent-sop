#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$GuardCodeQualityScript = Join-Path $ScriptsRoot "guard-code-quality.ps1"

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("guard-code-quality-tests-" + [guid]::NewGuid().ToString("N"))
[System.IO.Directory]::CreateDirectory($TestRoot) | Out-Null

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

function Invoke-QualityGuard {
    param([Parameter(ValueFromRemainingArguments = $true)]$Args)
    $output = & pwsh -NoProfile -File $GuardCodeQualityScript -WorkspaceRoot $TestRoot -Json @Args
    if ($output) {
        return ($output | Out-String | ConvertFrom-Json)
    }
    return $null
}

try {
    Write-Host "Running Code Quality Guard Unit Tests..." -ForegroundColor Cyan

    $srcDir = Join-Path $TestRoot "src\main\java\com\example"
    $testDir = Join-Path $TestRoot "src\test\java\com\example"
    [System.IO.Directory]::CreateDirectory($srcDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($testDir) | Out-Null

    # Test 1: Clean file passes with no violations
    $cleanFile = Join-Path $srcDir "CleanService.java"
    @'
package com.example;

import java.util.List;
import com.example.model.Player;

public class CleanService {
    public void processPlayer(Player player) {
        player.costOneBaseRes(1, 100);
        player.update();
    }

    public Response handleAction(Request req) {
        if (req == null) {
            return Response.fail(ErrorCode.PARAM_NULL);
        }
        if (req.getCount() <= 0) {
            return Response.fail(ErrorCode.INVALID_COUNT);
        }
        return Response.ok();
    }
}
'@ | Set-Content -LiteralPath $cleanFile -Encoding utf8

    $res1 = Invoke-QualityGuard -Files @($cleanFile)
    Assert-True ($res1.IsValid) "Clean Java file should have IsValid=True"
    Assert-Equal $res1.Violations.Count 0 "Clean Java file should have 0 violations"

    # Test 2: Rule 101 - Static Import detection in Java
    $staticImportFile = Join-Path $srcDir "StaticImportService.java"
    @'
package com.example;

import static com.example.Constants.MAX_COUNT;
import java.util.List;

public class StaticImportService {
    public int getMax() {
        return MAX_COUNT;
    }
}
'@ | Set-Content -LiteralPath $staticImportFile -Encoding utf8

    $res2 = Invoke-QualityGuard -Files @($staticImportFile)
    Assert-True (-not $res2.IsValid) "File with static import should be invalid"
    Assert-True ($res2.Violations.Count -ge 1) "Should detect Rule 101 violation"
    Assert-True ($res2.Violations[0].RuleId -eq "RULE_101" -or $res2.Violations[0].RuleId -eq "JAVA_NO_STATIC_IMPORT") "Violation should be Rule 101"

    # Test 3: Inline comment exemptions across multiple comment styles
    # 3a. Java // style exemption
    $exemptJavaFile = Join-Path $srcDir "ExemptJava.java"
    @'
package com.example;

import static com.example.Constants.MAX_COUNT; // ai-sop-lint-disable: RULE_101 [legacy constant]

public class ExemptJava {
    public int getMax() {
        return MAX_COUNT;
    }
}
'@ | Set-Content -LiteralPath $exemptJavaFile -Encoding utf8

    $res3a = Invoke-QualityGuard -Files @($exemptJavaFile)
    Assert-True ($res3a.IsValid) "Java // exemption should suppress Rule 101 violation"

    # 3b. Python # style exemption
    $pythonFile = Join-Path $TestRoot "script.py"
    @'
import static_module # ai-sop-lint-disable: RULE_101 [python test]
def do_something():
    pass
'@ | Set-Content -LiteralPath $pythonFile -Encoding utf8
    $res3b = Invoke-QualityGuard -Files @($pythonFile)
    Assert-True ($res3b.IsValid) "Python # exemption should work"

    # 3c. XML <!-- --> style exemption
    $xmlFile = Join-Path $TestRoot "config.xml"
    @'
<config>
    <!-- ai-sop-lint-disable: RULE_104 [raw payload config] -->
    <map raw="true" />
</config>
'@ | Set-Content -LiteralPath $xmlFile -Encoding utf8
    $res3c = Invoke-QualityGuard -Files @($xmlFile)
    Assert-True ($res3c.IsValid) "XML <!-- --> exemption should work"

    # 3d. SQL -- style exemption
    $sqlFile = Join-Path $TestRoot "query.sql"
    @'
-- ai-sop-lint-disable: RULE_102 [read only]
SELECT * FROM player;
'@ | Set-Content -LiteralPath $sqlFile -Encoding utf8
    $res3d = Invoke-QualityGuard -Files @($sqlFile)
    Assert-True ($res3d.IsValid) "SQL -- exemption should work"

    # Test 4: Rule 102 - Mutation without Persistence
    $noPersistFile = Join-Path $srcDir "NoPersistService.java"
    @'
package com.example;

public class NoPersistService {
    public void deductGold(Player player, int amount) {
        player.costOneBaseRes(1, amount);
        // missing update(player) or updateAirData
    }
}
'@ | Set-Content -LiteralPath $noPersistFile -Encoding utf8

    $res4 = Invoke-QualityGuard -Files @($noPersistFile)
    Assert-True (-not $res4.IsValid) "Mutation without update/persistence must be flagged"
    $r102 = @($res4.Violations | Where-Object { $_.RuleId -match "102" -or $_.RuleId -match "MUTATION" })
    Assert-True ($r102.Count -gt 0) "Must report Rule 102 violation"

    # Test 5: Rule 103 - Duplicate Failure Error Codes in same method
    $dupErrorCodeFile = Join-Path $srcDir "DupErrorCodeService.java"
    @'
package com.example;

public class DupErrorCodeService {
    public Response checkParams(Request req) {
        if (req == null) {
            return Response.fail(ErrorCode.PARAM_ERROR);
        }
        if (req.getId() <= 0) {
            return Response.fail(ErrorCode.PARAM_ERROR); // Duplicate error code!
        }
        return Response.ok();
    }
}
'@ | Set-Content -LiteralPath $dupErrorCodeFile -Encoding utf8

    $res5 = Invoke-QualityGuard -Files @($dupErrorCodeFile)
    Assert-True (-not $res5.IsValid) "Method with duplicate failure error code must be flagged"
    $r103 = @($res5.Violations | Where-Object { $_.RuleId -match "103" -or $_.RuleId -match "DUPLICATE" })
    Assert-True ($r103.Count -gt 0) "Must report Rule 103 violation"

    # Test 6: Rule 104 - Invalid Protocol Response Structure (Raw Naked Map)
    $nakedMapFile = Join-Path $srcDir "ProtocolHandler.java"
    @'
package com.example;

import java.util.HashMap;
import java.util.Map;

public class ProtocolHandler {
    public Map<String, Object> handleProtocol() {
        Map<String, Object> resp = new HashMap<>();
        resp.put("code", 0);
        return resp;
    }
}
'@ | Set-Content -LiteralPath $nakedMapFile -Encoding utf8

    $res6 = Invoke-QualityGuard -Files @($nakedMapFile)
    Assert-True (-not $res6.IsValid) "Naked map protocol response must be flagged"
    $r104 = @($res6.Violations | Where-Object { $_.RuleId -match "104" -or $_.RuleId -match "PROTOCOL" })
    Assert-True ($r104.Count -gt 0) "Must report Rule 104 violation"

    # Test 7: Test Directory Path Whitelist
    $testFile = Join-Path $testDir "ServiceTest.java"
    @'
package com.example;

import static org.junit.Assert.assertEquals;

public class ServiceTest {
    public void testPlayerMutation() {
        Player player = new Player();
        player.costOneBaseRes(1, 100);
        // Test class doesn't require production update(player)
    }
}
'@ | Set-Content -LiteralPath $testFile -Encoding utf8

    $res7 = Invoke-QualityGuard -Files @($testFile)
    Assert-True ($res7.IsValid) "Test directory files should be exempt from production persistence/static import rules"

    # Test 8: CLI Exit Code
    & pwsh -NoProfile -File $GuardCodeQualityScript -WorkspaceRoot $TestRoot -Files @($staticImportFile) 2>&1 | Out-Null
    Assert-Equal $LASTEXITCODE 1 "Exit code should be 1 when violations found"

    & pwsh -NoProfile -File $GuardCodeQualityScript -WorkspaceRoot $TestRoot -Files @($cleanFile) 2>&1 | Out-Null
    Assert-Equal $LASTEXITCODE 0 "Exit code should be 0 when clean"

    # Test 9: Auto-Fix functionality (-Fix switch)
    $fixTargetFile = Join-Path $srcDir "AutoFixTarget.java"
    @'
package com.example;

import static com.example.model.Player.MAX_HP;

public class AutoFixTarget {
    public int getHp() {
        return 100;
    }
}
'@ | Set-Content -LiteralPath $fixTargetFile -Encoding utf8

    $resFixBefore = Invoke-QualityGuard -Files @($fixTargetFile)
    Assert-True (-not $resFixBefore.IsValid) "Before fix, file should have Rule 101 violation"

    $resFixAfter = Invoke-QualityGuard -Files @($fixTargetFile) -Fix
    Assert-True ($resFixAfter.IsValid) "After -Fix, static import should be fixed and valid"
    Assert-Equal $resFixAfter.FixedFilesCount 1 "FixedFilesCount should be 1"

    Write-Host "All Code Quality Guard Tests Passed Successfully! (9 scenarios verified)" -ForegroundColor Green
} finally {
    Remove-Item -Recurse -Force -LiteralPath $TestRoot -ErrorAction SilentlyContinue
}
