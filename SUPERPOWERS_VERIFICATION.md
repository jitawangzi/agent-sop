# Superpowers 流程实战验证清单

多个 harness（Claude Code / GitHub Copilot / Antigravity / Cursor / Codex / Pi）统一使用 Superpowers 作为唯一过程引擎。本文档针对人工选择的 **T3**，是一份**实战验证清单**：用一个真实小功能走一遍完整流程，逐项确认流程落地正确。各工具能力差异见 `.ai-sop/scripts/harness-capability.ps1`（STRICT 可跑 T3，BLOCKED 支持 T1/T2）。

## 前置准备

1. 确认 Superpowers 插件已安装（Claude Code 会话启动时应自动激活；若 Copilot/Antigravity 未激活，按其文档安装/启用）。
2. 选一个**真实但小**的功能（建议一个纯新增的小玩法或一个明确的业务规则调整），准备其规格目录：
   ```text
   .ai-workspace/specs/features/<FeatureName>/
   ```
3. 准备一个独立工作目录（独立 SVN 工作副本或独立 Git 工作区），遵循 `.ai-workspace/workflows/parallel-development.md`。

## 验证项

### A. 流程入口与自动 Skill 选择

- [ ] **A1**：明确选择 T3 后，AI 进入 `superpowers:brainstorming`，而非手动激活 `workflow-orchestrator`。
- [ ] **A2**：AI **没有**调用 `workflow-orchestrator` 作为顶层调度器（它是手动片段编排器，仅全功能审计等手动场景用，不调度完整功能）。

### B. 任务档位与轻量流程

- [ ] **B1**：未指定档位时默认 T2，受影响规格/用例同步、编译和相关测试；不进入完整 brainstorming，不因协议或存储关键词升档。
- [ ] **B2**：人工指定 T1 时不重复确认；真实延期才 AddFollowUp，下一任务启动提醒但不阻塞、不自动补历史工作。
- [ ] **B3**：人工选择 T3 时执行完整流程；缺能力时说明，不自动降级。
- [ ] **B4**：纯文档任务按适用性记录理由，不使用空命令制造通过。失败/环境故障不得写成不适用。
- [ ] **B5**：跨 Agent Resume 保留档位及待办；人工改档保留历史结果，T2 完成不清除旧待办。

### C. 人机交互与人工门禁

- [ ] **C1**：brainstorming 时 AI **每轮最多问 3 个聚焦问题**（每个聚焦单一决策点，允许用户一句话给齐；统一口径见 AGENTS.md「汇报」与 `.ai-sop/workflows/agent-t3.md`「人工 review 阶段」），对有意义的备选给出 2-4 选项并推荐其一（做选择题而非填空题）。
- [ ] **C2**：需求阶段产出 `01_server_rules.md`（含 `BR-*`/`EX-*`/`AC-*`），AI 自审后**等待你的最终确认**才继续。
- [ ] **C3**：设计阶段产出 `06_design_contract.md`（含 `DC-*`/`DR-*`/`TW-*`），等待最终确认。需求与设计默认分两次独立呈递；合并呈递须满足 [T3 执行参考「人工 review 阶段」](workflows/agent-t3.md#人工-review-阶段) 的条件，单次确认仍分别写入两道 Approve；DESIGN_ONLY 按同节规则处理。
- [ ] **C3a**：设计产出后由独立 `design-reviewer` 审查，报告包含状态、发现分级、专项覆盖和轮次。BLOCKER/MAJOR 可触发修正与重审，**最多 2 轮**；MINOR/INFO 不触发 NEEDS_FIX，可记 PASS_WITH_WARNINGS。达到上限仍有阻断项时，保留 NEEDS_FIX 和报告交人工裁决，不冒充通过，也不继续无限返修。规则见 [T3 执行参考「工作流归属」](workflows/agent-t3.md#工作流归属)。
- [ ] **C4**：设计确认后，AI **自动连续**进入 writing-plans → subagent-driven-development + TDD → 覆盖校验 → 收尾审查 → 验证，不在中间增设批准检查点。GREENFIELD 的新 TC 在 TDD 中产出，不前置完整测试计划；LEGACY_EXTENSION 按 T3 规则在改生产代码前先建立并跑绿代表旧行为的表征 Case。

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

### F. 任务写前 Guard（实际 Hook 接入路径）

- [ ] **F1**：未建立任务时，识别出的源码、测试、配置及项目文档编辑被拒绝；安全读取仍可执行。仅有旧 ACTIVE owner 而无 taskId 时提示 TASK_REQUIRED，按 Discover / Resume 收编。
- [ ] **F2**：Start / Resume 成功后，当前会话关联的 ACTIVE task、合法档位和 owner 身份一致时，编辑可放行；任务暂停或身份不匹配时拒绝。
- [ ] **F3**：修改前输出实际登记档位、来源及本档义务；本清单验证人工选择的 T3，启动示例必须替换真实请求：
  ```powershell
  pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Start `
    -Feature "<FeatureName>" -TaskId "<TaskId>" -Tier T3 `
    -Objective "<本次目标>" -UserRequest "<人工选择 T3 的原话>" `
    -Agent "<CLAUDE_CODE|COPILOT|ANTIGRAVITY|CURSOR|CODEX|PI>"
  ```
- [ ] **F4**：正常 T1 使用任务入口，不停用 Guard；人工紧急停用明确显示 GUARD_DISABLED / GUARD_DISABLED_FOR_FEATURE，不被当作合规 T1。

必须记录所测工具是否真实调用 Hook，不能凭配置存在判为通过。五端均有适配入口，但客户端尚未实测的项目必须标为待验证；不要关闭防护来完成此清单。

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
