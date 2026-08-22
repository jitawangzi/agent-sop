# Superpowers 流程实战验证清单

多个 harness（Claude Code / GitHub Copilot / Antigravity / Cursor / Pi）统一使用 Superpowers 作为唯一过程引擎。本文档是一份**实战验证清单**：用一个真实小功能走一遍完整流程，逐项确认流程落地正确。各工具能力差异见 `.ai-sop/scripts/harness-capability.ps1`（STRICT 可跑 T3，BLOCKED 只 T2）。

## 前置准备

1. 确认 Superpowers 插件已安装（Claude Code 会话启动时应自动激活；若 Copilot/Antigravity 未激活，按其文档安装/启用）。
2. 选一个**真实但小**的功能（建议一个纯新增的小玩法或一个明确的业务规则调整），准备其规格目录：
   ```text
   .ai-workspace/specs/features/<FeatureName>/
   ```
3. 准备一个独立工作目录（独立 SVN 工作副本或独立 Git 工作区），遵循 `.ai-workspace/workflows/parallel-development.md`。

## 验证项

### A. 流程入口与自动 Skill 选择

- [ ] **A1**：描述任务后，AI 自动进入 `superpowers:brainstorming`，而非手动激活 `workflow-orchestrator`。
- [ ] **A2**：AI **没有**调用 `workflow-orchestrator` 作为顶层调度器（它是手动片段编排器，仅全功能审计等手动场景用，不调度完整功能）。

### B. 快通道前置判断（brainstorming 前）

- [ ] **B1**：若本次是**纯配置数值变更**（只改配置/CSV 数值、业务语义不变），AI 在 brainstorming 前识别为快通道，**跳过需求与设计门禁**，直接进实现 + 配置检查 + 受影响场景回归。
- [ ] **B2**：若本次是**纯文档变更**（不改业务规则/技术契约），AI 跳过门禁，完成文档检查后停止。
- [ ] **B3**：若本次是新功能/业务规则变更，AI **走完整 Superpowers 流程**，未借快通道绕过门禁。

### C. 人机交互与人工门禁

- [ ] **C1**：brainstorming 时 AI **每轮最多问 3 个聚焦问题**（每个聚焦单一决策点，允许用户一句话给齐；统一口径见 AGENTS.md「人工 review 阶段」），对有意义的备选给出 2-4 选项并推荐其一（做选择题而非填空题）。
- [ ] **C2**：需求阶段产出 `01_server_rules.md`（含 `BR-*`/`EX-*`/`AC-*`），AI 自审后**等待你的最终确认**才继续。
- [ ] **C3**：设计阶段产出 `06_design_contract.md`（含 `DC-*`/`DR-*`/`TW-*`），等待你的最终确认。需求与设计在**同一轮 `brainstorming` skill 调用中连续产出，但分两次独立呈递人工确认**（先确认 01 需求再确认 06 设计，不可合并确认）。
- [ ] **C3a**：设计产出后、人工确认前，AI 调用 `design-reviewer` 做**机器审查**（宏观规范守门 + 设计完整性自检 + 已知缺陷模式对照），且是**闭环自审自修**——有 BLOCKER/MAJOR/MINOR 自动回 design-architect 修后重审，**不占你时间**；你只看到"已通过机器审查的方案"。若 AI 把未过审的方案直接交你确认，视为不合规。严重度术语统一为 BLOCKER/MAJOR/MINOR/INFO（与 AGENTS.md/adapter 一致，非 CRITICAL/HIGH/MEDIUM）。
- [ ] **C4**：设计确认后，AI **自动连续**进入 writing-plans → subagent-driven-development + TDD → 覆盖校验 → 收尾审查 → 验证，**不**在中间增设批准检查点。**不**前置 QA 测试计划（TC 在 TDD 中产出）。

### D. 领域专家 Skill 强制绑定（关键）

- [ ] **D1**：`subagent-driven-development` 派发**实现者**时，AI 使用 `implementation-engine`（项目 Skill），**未**用 general-purpose 或 Superpowers 默认 agent。
- [ ] **D2**：每 Task 内审使用 `implementation-auditor`（实现/契约合规）与 `logic-auditor`（高风险分支/状态/语义）作**执行单元**，**未**用 Superpowers 默认 code-reviewer。
- [ ] **D3**：`implementation-auditor`/`logic-auditor` 是 subagent **内审执行单元**，而**非**实现后独立流程节点（主流程中无"实现后单独跑全局审计"必经步骤）。
- [ ] **D4**：brainstorming 按需咨询 `requirement-analyst`/`design-architect`；测试覆盖校验用 `quality-assurance`/`test-plan-auditor`（咨询/校验，非流程节点）。
- [ ] **D5**：专家被调用时**未**写 `.ai-sop/runtime/`、**未** emit 自定义 Handoff JSON（把发现返回给 Superpowers controller）。

### E. 三层审查分层（职责不重叠）

- [ ] **E1**（单任务内审）：每个 Task 在 subagent 内过内审：spec 合规 → 代码质量（顺序不可颠倒）。
- [ ] **E2**：内审发现问题 → 修复 → 重新审查 → 通过才标记完成（闭环）。
- [ ] **E3**（整体收尾）：全部 Task 完成后，AI **通过 Skill 显式调用** `superpowers:requesting-code-review` 做整体收尾审查，**未**跳过（哪怕改动很小）。
- [ ] **E4**（全功能审计·可选）：复杂大功能交付后，可**手动**触发 `workflow-orchestrator` AUDIT_ONLY 全盘审计（`REPORT_ONLY`/`AUTO_REPAIR`）查跨任务契约一致性——它是可选手动收尾，**不**在主流程必经链。

### F. 生产代码编辑 Guard（归属强制）

- [ ] **F1**：未 Claim 归属前，编辑 `src\com\**`/`WebRoot\**`/`config\**` 被 guard 拒绝，stderr 提示"requires ACTIVE feature owner"。
- [ ] **F2**：Claim 归属后（`SUPERPOWERS`），编辑生产代码被放行。
- [ ] **F3**：归属用 `SUPERPOWERS`（不再是 `CUSTOM_SKILLS`），`agent` 字段反映实际工具：
  ```powershell
  pwsh -NoProfile -File .\.ai-sop\scripts\workflow-owner.ps1 -Operation Claim `
    -SpecDirectory ".ai-workspace\specs\features/<FeatureName>" `
    -Feature "<FeatureName>" -Workflow SUPERPOWERS `
    -Agent "<CLAUDE_CODE|COPILOT|ANTIGRAVITY|CURSOR|PI>" -OwnerId "<run-id>"
  ```

### G. 完成验证

- [ ] **G1**：交付前 AI 运行聚合测试：
  ```powershell
  pwsh -NoProfile -File .\.ai-sop\scripts\run-all-tests.ps1 -IncludeCompile
  ```
- [ ] **G2**：AI 运行覆盖校验：
  ```powershell
  pwsh -NoProfile -File .\.ai-sop\scripts\workflow-state.ps1 -Operation ValidateTestCoverage `
    -Path ".ai-workspace\specs\features/<FeatureName>/05_test_coverage.json"
  ```
- [ ] **G3**：AI 调用 `superpowers:verification-before-completion`，禁止"应该可以了"就标记完成。
- [ ] **G4**：最终结论表述为"已覆盖场景通过"，**未**宣称"功能无缺陷"。

### H. 并行与不适用 Skill

- [ ] **H1**：AI **未**使用 `superpowers:dispatching-parallel-agents`（已声明不适用）；并行开发走 `feature-runtime.ps1`：
  ```powershell
  pwsh -NoProfile -File .\.ai-workspace\scripts\feature-runtime.ps1 -Operation Allocate `
    -Feature "<FeatureName>" -WorkspacePath $PWD
  ```
- [ ] **H2**：AI **未**使用 `superpowers:using-git-worktrees`（代码隔离用独立 SVN 工作副本或 Git 分支，运行时隔离由 `feature-runtime.ps1` 管理）。

### I. 跨 harness 一致性（若用 Copilot/Antigravity 验证）

- [ ] **I1**：在 Copilot/Antigravity 里走同一流程，行为与 Claude Code 一致（统一 Superpowers 引擎）。
- [ ] **I2**：Antigravity 的 `.agents/hooks.json` 真的在编辑生产代码时触发 guard（B4 真机验证）。若编辑直接成功无反馈，hook 未生效，检查 `.agents/hooks.json` schema/工具名。
- [ ] **I3**：各 harness 的 hook 配置（`.claude/settings.json` / `.agents/hooks.json` / `.cursor/hooks.json` / `.github/hooks/ai-sop.json`）真在编辑生产代码时触发 guard，hook 命令均指向 `./.ai-sop/scripts/hook-dispatcher.ps1`。

## 结果判定

- **全部通过**：流程落地正确，可正式以 Superpowers 为唯一流程。
- **个别不符**：记下项号与现象，反馈调整文档/约束。
- **多处不符且影响流程正确性**：记下现象集中反馈，逐项修正。
