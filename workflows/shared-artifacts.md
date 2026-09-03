# 共享功能产物契约

各 harness（Claude Code / Copilot / Antigravity / Cursor / Pi）统一走 Superpowers，共享：

`.ai-workspace/specs/features/<FeatureName>/`

## 规范产物

| 产物 | 契约 |
|---|---|
| `01_server_rules.md` | 业务规则，含稳定的 `BR-*`（Business Requirement）、`EX-*`（Exception）、`AC-*`（Acceptance Criteria）声明 |
| `04_change_impact.json` | 行为影响契约（遵循 `schemas/change-impact.schema.json`）。仅当 AssessRisk 命中类型/策略扩展或公共分发、或风险无法评估时必填；绿场 T3 不强制。命中类型/策略扩展或公共分发时，必须含非空 `behaviorVariants`、`legacyPaths`、`invariants` 以及 8 个生命周期切面；`entryPoints` 须覆盖 QUERY/MUTATE 等全部相关公共入口；切面证据须可定位，变更 enum 的兄弟键须列全 |
| `05_test_plan.md` | 可执行用例，含稳定的 `TC-*`（Test Case）声明 + `<!-- meta: {...} -->` 元数据（供 SyncCoverage 生成 coverage JSON） |
| `05_test_coverage.json` | 需求/设计到用例的追溯。类型/策略扩展时 Case 须机读声明 `CHARACTERIZATION`、`entryPointIds`、`variantKeys`、`facetIds`、`bypassesPriorQuery`；表征载体方法体须含这些字面量与调用，并含 `persistenceColdReload` 与再读存储调用 |
| `06_design_contract.md` | 技术契约，含稳定的 `DC-*`（Design Contract）、`DR-*`（Design Rule/风险）、`TW-*`（Test/Workflow 约定）声明 |
| `07_design_review.md` | design-reviewer 机器审查结论。T3 `VerifyCompletion` 读取 `审查状态：PASS` 或 `PASS_WITH_WARNINGS`；缺文件或 `NEEDS_FIX` 不能 Complete |
| `compile-evidence.json` | 最近一次编译记录（`command` / `exitCode` / `executedAt`）。T3 Complete 必填；`build/classes` 目录存在不算编译过 |
| `test-evidence.json` | T2 可选测试记录。文件存在则 `VerifyCompletion` 要求 exitCode=0 |
| `review-mailbox.json` | 跨 Agent 协同审查信箱（遵循 `schemas/review-mailbox.schema.json`） |
| `.workflow-owner.json` | 机器级活动归属的可读镜像 |

Superpowers 在 `docs/superpowers/` 下的 plan/ledger 是执行记录，不替代规范产物。主流程不使用 `.ai-sop/runtime/`（仅手动全功能审计的 `AUDIT_ONLY` 场景按需使用，不进主流程必经链）。

权威 owner 注册表是机器本地的，所有 worktree 共享。归属身份统一为 `SUPERPOWERS` workflow + Agent 字段（`CLAUDE_CODE`/`COPILOT`/`ANTIGRAVITY`/`CURSOR`/`PI`）+ 不可变的功能运行 `ownerId`。

## 人工把关阶段

需求与设计各自都可包含多轮交互评审。

- 中间一致不等于最终确认。
- 最终确认作用于完整的规范产物。
- 编辑已确认产物即作废其此前的确认。

## 完成基线

Superpowers 流程必须建立：

- 已确认的需求与设计
- 完整的测试计划与覆盖映射
- 编译通过
- 实现审计
- 基于风险的逻辑审计
- 选定的自动化验证路径
- 任何生产代码修复后的回归

最终用语应为“已覆盖场景通过”，而非“功能无缺陷”。
