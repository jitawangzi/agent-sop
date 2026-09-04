# 质量保证设计（Quality Gates）

> 面向：维护 SOP 的人，以及需要分清「机器查什么 / AI 自报什么」的人。  
> 操作清单（命令、完成表）仍以宿主投影 `AGENTS.md`「完成定义」为准。  
> 本文件回答：**为什么这样分层、假绿收到哪一层、机器上限在哪、下一步不加什么。**

相关：`docs/ARCHITECTURE.md`（决策 11/12）、`workflows/shared-artifacts.md`（产物契约）、`SUPERPOWERS_MANUAL.md`（人工操作）、`skills/quality-assurance/SKILL.md`（测试方法论）。

---

## 1. 要挡住的三类假绿

| 假绿形态 | 例子 | 机器对策 |
|---|---|---|
| **没做却声称做过** | 没独立审查、没编译、覆盖矩阵是 `__TODO__` | 功能目录要有可读文件；`LintSpecs` 中途就能报缺 |
| **做过但已过期** | 编过一次后改了六天代码；06 作废再批仍拿旧 PASS 报告 | 证据绑 `workingTreeDigest` / 产物 SHA |
| **当场伪造** | 手写 `exitCode=0`、空 `@Test`、只断言回包 | 部分可挡（表征方法体、冷重载调用）；**挡不住**同一次会话编一份假 JSON |
| **未编译就审 PASS** | engine 还在跑 / 缺 import 时 auditor 已 PASS；controller 自己补编译 | **流程约束**（adapter：无【编译证据】不派审；auditor 缺证据只能 `INDETERMINATE`）。Complete 仍只查功能目录 `compile-evidence.json`，不给每个 Task 再造一份机器文件 |

第三类要 JUnit XML / subagent transcript 才接近防伪，成本高一个数量级。当前刻意不做到那一层。任务级「先编译再审」靠 controller 纪律 + auditor 拒 PASS，不加第四类机器门禁。

---

## 2. 分层（从外到内）

质量保证不是单道 Complete 检查，而是几层职责不重叠的笼子。外层挡「不该写」，内层挡「写了但没证明」。

```text
1. 物理拦截     Hook + Owner 锁          未认领不能改生产目录
2. 档位分流     T3 / T2 / T1 / 快通道     高危语义禁止降档
3. 人工门禁     01 / 06 + SHA-256         需求与设计锁定
4. 设计审查     07_design_review.md       独立 subagent；绑 06 SHA
5. 规格与覆盖   05 + SyncCoverage         条款→Case 机读追溯
6. 旧系统扩展   04 + 表征 + 冷重载         只在类型/公共分发时强制
7. 编译证据     compile-evidence.json     绑当前工作区 digest
8. 测试证据     05.executionEvidence      T3 覆盖矩阵；T2 可选 test-evidence
9. 代码审查     implementation-auditor    Complete 仍自报（见 §5）
                logic-auditor
                requesting-code-review
10. SOP 自身    run-all-tests.ps1         改 scripts/ 必须 100% PASS
```

`quality-assurance` / `test-plan-auditor` 负责测试方法论、覆盖矩阵与路径选择（路径 A JUnit ≠ 路径 B 业务验证）。它们**不替代**第 5–8 层机检。

---

## 3. 机器硬门禁 vs AI 自报

`VerifyCompletion`（`Complete` 内嵌）只认磁盘上的契约与证据。下表是单一真源。

| 项 | T3 | T2 | 谁执行 |
|---|---|---|---|
| Owner Claim / Validate | 要 | 要 | `workflow-owner.ps1` |
| 01/06 APPROVED + SHA 匹配 | 要（`DESIGN_ONLY` 豁免 01） | 不要求 | `workflow-state.ps1` |
| `05_test_coverage.json` 无占位、载体可解析 | 要 | 不要求 | ValidateTestCoverage / LintSpecs |
| `07_design_review.md` PASS 或 PASS_WITH_WARNINGS，且 `审查对象 sha256` = 当前 06 | 要（有 06 时） | 不要求 | Test-DesignReviewGate |
| `compile-evidence.json` exitCode=0 + `workingTreeDigest` 匹配 | 要 | 文件存在才校验 | Get-CommandEvidenceProblem |
| `04_change_impact.json` 完整完成度 | 仅 TYPE_EXTENSION / PUBLIC_ROUTING，或风险无法评估 | 高危触发则禁止停在 T2 | AssessRisk + ValidateChangeImpact |
| 表征 Case 方法体含 typeKey/入口、冷重载再读存储 | 同上（旧系统扩展） | — | Assert-ExtensionCoverageCompleteness |
| `test-evidence.json` | 不强制（测在 05.executionEvidence） | 可选；有则须 exitCode=0 | Get-CommandEvidenceProblem |
| `implementation-auditor` / `logic-auditor` 报告 | **自报** | 自报 | subagent 回 controller；Complete **不读** 08/09 |
| 文档待更新 / 快通道纯数值检查 | — | 自报 | AI |
| `build/`、`classes/`、`target/` 目录存在 | **不算**编译过 | **不算** | 已否决 |

`CheckCompletion` 是诊断清单（exit 0），应与上表同一套信号，不得把构建目录打成 `[v]`。硬失败只发生在 `VerifyCompletion` / `Complete`。

中途早失败：`LintSpecs -Phase PLAN`（`doctor.ps1 -Feature` 也会调）扫当前功能目录：缺 00、未覆盖条款、PLAN 占位、MISSING 载体、缺 07 / 编译证据。实现中途修，不要拖到 Complete。

---

## 4. 证据怎么绑（防过期）

| 证据 | 绑定 | 何时失效 |
|---|---|---|
| 01 / 06 | 规范化 SHA-256 写入 `00_workflow_state.json` | 改条款语义 → ResetApproval；纯润色 → UpdateHash |
| `07_design_review.md` | `审查对象 sha256` = 当前 06 的同一套规范化哈希 | 06 再批或改契约后旧 PASS 失败 |
| `compile-evidence.json` | `workingTreeDigest` = 当前工作区 changeSetDigest | 改生产代码后须重编译并重写证据 |
| `05_test_coverage.json` 的 `executionEvidence` | 同样的 `workingTreeDigest` | 改代码后须重跑测试 |

digest 计算会忽略功能目录里的审查/证据元数据（`07_design_review.md`、`compile-evidence.json`、`05_test_coverage.json`、`00_workflow_state.json` 等），避免「写完证据文件 digest 立刻过期」。

`workingTreeDigest` 来自 `AssessRisk` 返回的 `changeSetDigest`。证据 7 天内、`executedAt` 必须是可解析时间戳。

---

## 5. 代码审查为什么还不进 Complete

T3 完成表第 4 项（`implementation-auditor` / `logic-auditor` PASS）是 **subagent 回传 + AI 据报告自报**。`VerifyCompletion` 不读 08/09 文件。

这是有意的，不是漏做：

- 07 刚变成「文件 + 06 SHA」。先让真实 T3 跑稳，再抄同一模式加实现审计产物。
- 现在加 08/09 会叠一套「没写报告就不能 Complete」，摩擦大，且同样挡不住当场编 PASS。
- 审查隔离仍靠流程：审查者必须独立 subagent，禁止同上下文自审。机器能查的是 07 这份设计审查文件，还不是实现审计文件。

等有一个新 FeatureName 走完 T3 到 Complete 之后，若 AI 经常跳过内审，再为 `implementation-auditor` / `logic-auditor` 加与 07 同构的报告门禁。

---

## 6. 旧系统扩展 vs 绿场

完整 04（8 切面、兄弟键、表征 Case、冷重载）是为「在已有分发上加类型 / 改公共路由」准备的。绿场新功能没有可填的旧切面，逼交 04 只会得到 `N_A` 套话。

机器规则：

1. AssessRisk 命中 `TYPE_EXTENSION` 或 `PUBLIC_ROUTING` → 必须有 04，且走完成度 + 表征覆盖。
2. 没命中 → T3 可以没有 04；01/06 + 覆盖矩阵照旧。
3. 风险看不清（工作区解析失败、VCS 不可用、混合仓扫不到生产副本）→ 宁可要 04。

混合仓（根上 overlay git 管 SOP、SVN 管生产源码）：语义触发扫 SVN；过期 overlay git SHA 在 SVN 可用时 fail-soft，不因 `INVALID_BASELINE` 卡死。AssessRisk 只交本功能规格能定位到的生产文件。

**机器上限**：表征 Case 能要求方法体出现 `typeKey` / 入口字面量、以及再读存储调用。它**不能证明**运行时打到了旧分发。再加一层 JSON 检查收益很低。

详见 `ARCHITECTURE.md` 决策 11。

---

## 7. 明确不做（现在）

| 不做 | 原因 |
|---|---|
| 存量已交付功能倒算失败 / 一律豁免开关 | 掩盖规格债，或误伤旧目录 |
| 全 T3 强制 04 | 绿场造假材料 |
| 用 `build/classes` 当编译证明 | 过期产物假绿 |
| 强制 08/09 实现审计文件（在真 T3 稳定前） | 叠摩擦，07 模式尚未在真功能上验证 |
| 不为每个 Task 写 `compile-evidence.json` | 摩擦大；Task 交接用实现者【编译证据】粘贴进内审 prompt。Complete 仍只认功能目录那一份 |
| 绑定 JUnit XML / 编译器 transcript | 防当场伪造；成本高一个数量级 |
| Hook 扩到 `python -c` / `tee` 写文件 | 覆盖成本高、易误拦 |
| 先验加宽规格定位（只写包名就当定位到） | 等真撞到 `FEATURE_SCOPE_UNRESOLVED` 再加 |

改 SOP 核心脚本后，本地硬门禁是 `pwsh -NoProfile -File ./scripts/run-all-tests.ps1` 全绿，不是 GitHub CI。

---

## 8. 下一刀（收益序）

1. **流程，不是引擎**：用新 FeatureName 走完一次 T3 到 Complete（忽略已交付旧目录）。看 AI 会不会忘写 07 / compile-evidence、LintSpecs 卡在哪，用卡点反哺。
2. **若 07 在真 T3 上稳定且内审常被跳过**：再给 implementation-auditor / logic-auditor 加与 07 同构的报告 + SHA 绑定。
3. **若真撞到**：规格只写包名导致 `FEATURE_SCOPE_UNRESOLVED` 误要 04 → 再加宽定位。
4. **不优先**：Hook AST 扩面、JUnit XML、transaction flake、真机认证。

---

## 9. 命令

```powershell
# 中途：当前功能缺 00 / 条款 / 载体 / 07 / 编译证据
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-state.ps1 -Operation LintSpecs `
  -Path ".ai-workspace/specs/features/<Feature>" -Phase PLAN

pwsh -NoProfile -File ./.ai-sop/scripts/doctor.ps1 -Feature <Feature>

# 覆盖矩阵（禁止手写 JSON；用 SyncCoverage）
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-state.ps1 -Operation SyncCoverage `
  -Path ".ai-workspace/specs/features/<Feature>/05_test_coverage.json"

# 诊断清单（exit 0；[v]/[X]/[?]）
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-state.ps1 -Operation CheckCompletion `
  -Path ".ai-workspace/specs/features/<Feature>/00_workflow_state.json"

# 硬门禁（Complete 内嵌；失败不释放锁）
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-state.ps1 -Operation VerifyCompletion `
  -Path ".ai-workspace/specs/features/<Feature>/00_workflow_state.json"

# 当前工作区 digest（写入 compile-evidence.workingTreeDigest）
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-state.ps1 -Operation AssessRisk `
  -Path ".ai-workspace/specs/features/<Feature>"
```

`compile-evidence.json` 最小字段：`command`、`exitCode`（须 0）、`executedAt`、`workingTreeDigest`（64 位 hex，等于 AssessRisk 的 `changeSetDigest`）。

`07_design_review.md` 必须含：

```text
审查对象 sha256：<与 Approve -Gate design / Status 相同的 06 SHA>
审查状态：PASS | PASS_WITH_WARNINGS | NEEDS_FIX
```
