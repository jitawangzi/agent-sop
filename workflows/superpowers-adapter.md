# Superpowers Adapter（唯一过程引擎）

## 归属

**Superpowers 是本项目唯一的过程引擎，五个 harness（Claude Code / GitHub Copilot / Antigravity / Cursor / Pi）统一使用它**（STRICT 工具跑 T3，BLOCKED 工具 Pi 只 T2，见 `harness-capability.ps1`）。`workflow-orchestrator` 不再作为顶层调度器，而是**Superpowers 主流程之外的人工手动片段编排器**（当前=全功能审计，可扩展）；不使用状态机/runtime/Handoff，编排靠人工驱动。

## 流程

主流程骨架为 Superpowers 原生节点；领域专家 Skill 作为**执行单元**（subagent 派发）与**门禁组件**（节点校验）被调用，不作为独立流程节点插入。

```text
claim feature ownership (SUPERPOWERS)
-> [执行强度判断] T3(默认完整流程) / T2(用户指定快速) / T1(用户指定急速) / 自动快通道(纯配置/纯文档)
-> superpowers:brainstorming
     （一轮调用，两次独立呈递：需求探索 -> 人工确认 01_server_rules.md
       -> 续做设计 -> design-architect 产出 06_design_contract.md
       -> design-reviewer 机器审查（闭环自审自修，不进人工门禁）
       -> 人工确认 06_design_contract.md）
-> superpowers:writing-plans
-> quality-assurance(PLAN)（产测试范围/覆盖矩阵/风险清单供 TDD 参考，非完整前置测试计划）
-> superpowers:subagent-driven-development + TDD
     实现者 = implementation-engine（执行单元）
     每 Task 内审 = implementation-auditor / logic-auditor（执行单元，按风险）
-> ValidateTestCoverage（覆盖校验，实现后）
-> superpowers:requesting-code-review（整体收尾审查）
-> superpowers:verification-before-completion
-> complete feature ownership
```

**流程关键点**：
- 需求与设计在同一轮 `brainstorming` skill 调用中连续产出，但分两次独立呈递人工确认（先确认 01 需求再确认 06 设计，不可合并确认）。
- 设计产出后由 `design-reviewer` 做**机器闭环自审自修**（宏观规范守门 + 设计完整性自检 + 已知缺陷模式对照），不进人工门禁、不占人工时间；存在 `BLOCKER`/`MAJOR` 未修复时不交人工确认。机器闭环**最多 2 轮**（审查→修正→重审）；第 2 轮后仅剩 `MINOR`/`INFO` → 自动豁免通过（`PASS_WITH_WARNINGS`）；仍有 `BLOCKER`/`MAJOR` → 交人工确认。`design-reviewer` 阻断级（`BLOCKER`/`MAJOR`）可判 `NEEDS_FIX`，建议级（`MINOR`/`INFO`）不得判 `NEEDS_FIX`（防挑刺震荡）。**硬证据约束**：进入 `writing-plans` 前必须附 `design-reviewer` 审查报告（含 PASS/NEEDS_FIX/PASS_WITH_WARNINGS、发现分级、专项覆盖、循环轮次）；无报告不得进 writing-plans，快通道除外。**独立派发约束**：`design-reviewer` 必须用 Agent 工具作为独立 subagent 派发（`subagent_type=design-reviewer`），禁止用 `Skill()` 内联自审；NEEDS_FIX 时由 controller 回派独立的 `design-architect`（Agent 派发）修正，禁止 design-reviewer 自改方案。
- **不前置** QA 测试计划：具体 TC 在 TDD 中产出；`ValidateTestCoverage` 在实现后做覆盖完整性校验。
- `implementation-auditor`/`logic-auditor` 是 subagent **内审执行单元**，不作实现后的独立流程节点（其全盘视角由可选的全功能审计覆盖，见下）。

## 人机交互

- 每轮最多 3 个聚焦问题，每个聚焦单一决策点，允许用户一句话给齐（统一口径见 AGENTS.md「人工 review 阶段」）。
- 对有意义的备选方案进行比较并推荐其一。
- 需求与设计可在同一 brainstorming 内多轮澄清与分段确认。
- 只有完整的 `01_server_rules.md` 与 `06_design_contract.md` 需要最终确认。
- 设计最终确认后自动继续，除非需求/设计变得模糊或环境被阻塞。
- 不要让用户选择执行策略；当任务可独立 review 时默认采用 `subagent-driven-development`。

## 领域专家（执行单元，非流程节点）

Superpowers 不懂游戏服务端领域。它的 `subagent-driven-development` 派发实现者与审查者时，**必须使用本项目的领域专家 Skill，禁止用 general-purpose 或 Superpowers 默认 agent**：

| 角色（执行单元） | 必须用的专家 Skill |
|---|---|
| 实现者 | `implementation-engine` |
| 每 Task 内审（实现/契约合规） | `implementation-auditor` |
| 每 Task 内审（高风险分支/状态/语义） | `logic-auditor` |
| 设计方案审查（人工确认前，机器闭环） | `design-reviewer` |

brainstorming 节点按需咨询 `design-architect`；设计产出后由 `design-reviewer` 机器审查；测试覆盖校验用 `quality-assurance`/`test-plan-auditor`。这些是**咨询/校验/审查**，不是流程节点。

**需求预处理（可选前置，手动）**：复杂 docx 资料可手动先调 `requirement-analyst` 产 `00_server_rules_draft.md` 草案，brainstorming 基于草案定稿 `01_server_rules.md`。简单需求跳过。不进主流程必经链。

被 Superpowers 调用时：
- 使用专家的领域 checklist 与交付格式
- **不 emit/apply 自定义流程的 Handoff JSON**
- **不创建或修改 `.ai-sop/runtime/`**
- 把发现返回给 Superpowers controller

任何编辑规范产物的专家调用都属于修改型工作，需要活动的 Superpowers owner ID；只读的咨询性 review 不需要。

## 三层审查定位（职责不重叠）

| 层 | 何时 | 视角 | 执行 |
|---|---|---|---|
| 单任务内审 | 每个 Task（subagent 内） | spec 合规 + 代码质量 + 高风险逻辑 | `implementation-auditor`/`logic-auditor` 作执行单元 |
| 整体收尾 | 全部 Task 后 | 流程合规 + 整体一致性 | Superpowers `requesting-code-review` |
| 全功能审计（可选手动） | 交付后按需 | 跨任务契约一致 + 整体游戏状态正确性 | `workflow-orchestrator` AUDIT_ONLY 全盘（见下） |

**审查铁律**：spec 合规审查 → 代码质量审查（顺序不可颠倒）→ 发现问题修复 → 重新审查 → 通过才标记完成。整体收尾 `requesting-code-review` 独立于 subagent 内审，禁止跳过（哪怕 1 行改动）。

## 模型分级调度

Superpowers 控制器派发 subagent 时，应按角色复杂度选档，平衡成本与质量。**轮次比 token 单价更费钱**——便宜模型在多步任务上多轮反而更贵；但纯转录/机械任务用便宜模型省。各 harness 都支持按 subagent 指定模型（Claude Code 与 Copilot 用 frontmatter `model` / per-invocation `model` 参数；Antigravity 用 agent 定义 `model` 字段）。注意 PI 核心无 subagent（能力准入 BLOCKED，只 T2），Cursor/Copilot/Antigravity 的 subagent 能力见 `harness-capability.ps1`。

用 **harness 无关的档位概念**，不写死模型名（各 harness 的可用模型不同，按其实际可选映射）：

| 档位 | 适用角色 | 理由 |
|---|---|---|
| **最强可用** | `design-architect`（架构设计）、`design-reviewer`（设计审查）、`requesting-code-review`（整体收尾）、`logic-auditor`（高风险逻辑） | 需判断力/全局观/跨任务推理，错判代价高 |
| **标准** | `implementation-engine`（一般实现）、`implementation-auditor`（实现合规）、`quality-assurance`、`requirement-analyst` | 多文件协调与规范判断，需要稳定性 |
| **便宜** | `implementation-engine`（机械任务：纯转录、单文件小修、配置值改动）、`test-plan-auditor`、`feature-maintainer`（分类） | 规则明确、判断少，cheap 档足够 |

**派发铁律**：
- 派发时**显式指定 model**，不要省略（省略会继承会话默认模型，往往是最强最贵档，悄悄抵消分级收益）。
- **修复循环升档**：subagent-driven-development 的修复循环 R1-3 续派原模型；R4-5 换比卡住档位**高一档**的模型（卡住通常是实现者看不到自己的问题，需更强推理）。
- **任务复杂度信号**（实现任务）：1-2 文件 + 完整 spec → 便宜档；多文件 + 集成 → 标准档；需设计判断/广域理解 → 最强档。
- 当 plan 文本已含**完整待写代码**时，实现是"转录 + 测试"，用最便宜档。
- 单文件机械修复用最便宜档；subagent 内审按上表角色档位，不随实现任务降档。

**harness 限制**：若某 harness 不支持 per-agent model（或如 Copilot 部分版本 dispatch 路径不生效），则该 harness 全程用会话默认模型，文档指导作为"理想配置"记录，不阻塞流程。

## 全功能审计（手动，人工把关，不进主流程必经链）

单任务审计正确 ≠ 整个功能跨任务正确。对于复杂大功能，交付后可**手动触发**全盘审计，查跨任务的契约一致性、高风险逻辑与整体游戏状态正确性——这是通用 `requesting-code-review` 覆盖不全的领域深度视角。

由 `workflow-orchestrator` 承载（它是 Superpowers 主流程之外的**人工手动片段编排器**）：手动触发 → 按序调 `implementation-auditor`+`logic-auditor` → 汇总报告交人工 → 人工决定下一步（不自动推进，不靠状态机）。`audit_fix_policy` 取 `REPORT_ONLY`（只出报告，默认，人工判断哪些改/哪些是允许的例外）或 `AUTO_REPAIR`（自动修复并回归）。

触发方式与模板见 `.ai-sop/SUPERPOWERS_MANUAL.md`。`AUTO_REPAIR` 修复生产代码后须重新走内审与验证。

## AUDIT-EXEMPT（审计例外声明）

工程实践存在"规则上不通过但有意允许"的反模式（如通常服务端不下发配置表给客户端，某些特殊场景允许）。这类有意例外在 `01_server_rules.md`/`06_design_contract.md` 条款行标 `[AUDIT-EXEMPT: 原因]`，**必须经人工确认**（随文档进门禁，不允许事后补）。`implementation-auditor`/`logic-auditor`/`design-reviewer` 见该声明对命中项降为 `INFO` 不阻断；理由须充分、范围须明确，否则仍要求补全。与 `[TEST-EXEMPT]` 对称。

## 不适用本项目

- `superpowers:dispatching-parallel-agents` — 与本项目的并行运行时冲突；并行开发走 `.ai-workspace/workflows/parallel-development.md` + `feature-runtime.ps1`。
- `superpowers:using-git-worktrees` — 代码隔离用 **SVN 分支**（不是 Git worktree）；运行时隔离（多 Tomcat）由 `feature-runtime.ps1` 分配独立端口/`CATALINA_BASE`，与 SVN 分支无关。
- `superpowers:executing-plans` — 触发 `using-git-worktrees`（与 `feature-runtime.ps1` 冲突）；有 subagent 时统一用 `subagent-driven-development`。
- `superpowers:finishing-a-development-branch` — 基于 git merge/PR 收尾，本项目交付走 SVN；subagent 末尾的 finishing 由 `verification-before-completion` + 人工 SVN 提交替代。git 仅作开发隔离/检查点，非交付目标。

## 执行强度分层

**实际执行档位**由单条规则唯一确定：
`实际执行档位 = MIN(用户显式指定 || 变更类默认, 当前工具最高支持档位)`

变更类默认：行为/契约/协议/存储结构变更、新玩法 = T3；已有行为的缺陷修复、单点逻辑调整 = T2；纯配置数值/纯文档 = 快通道。BLOCKED 工具（最高 T2）在用户未表达流程意图时静默降为 T2，用户表达 T3 流程意图时触发 `[SOP 拦截]`。

- **T3**（默认覆盖新功能/协议/存储/行为变更）：完整 Superpowers 流程（brainstorming → 需求确认 → design-reviewer → 设计确认 → writing-plans → subagent-driven-development + TDD → 审计 → requesting-code-review → verification-before-completion）。**只有 T3 需要 Superpowers 技能包**；T2/快通道/T1 不依赖。
- **T2 快速**（用户显式"快速修改"/"简单需求直接实现"，或变更类默认=缺陷/单点时）：跳 brainstorming/需求设计门禁/design-reviewer/writing-plans，保留 Claim + 编译 + 验证 + 回归 + 文档待更新提醒（5 项）。
- **T1 急速**（"急速修改"/"直接改"，极少用）：跳全部流程，仅保留编译 + guard 逃生口。AI 须先提醒 T1 风险，用户确认后执行。

**快通道**（AI 自动识别，无需用户指定；**独立档位，非 T2**，完成条件 2 项：编译通过 + 纯数值/文档检查）：纯配置数值变更（`CONFIG_VALUE_CHANGE`）→ 直接实现 + 配置检查 + 受影响场景回归；纯文档变更（`DOC_ONLY`）→ 文档检查后停止。

详见 AGENTS.md「执行强度分层」档位表与快通道判定树。

## 领域门禁组件（节点级，非流程引擎）

以下脚本作为 Superpowers 关键节点的**校验组件**被调用，不作为流程引擎：

- 需求/设计确认：`workflow-state.ps1 -Operation Approve`（写入 SHA-256 与确认状态）。
- 覆盖完整性校验（实现后）：`workflow-state.ps1 -Operation ValidateTestCoverage`。
- 人工确认后继续：`workflow-state.ps1 -Operation ValidateApproval`。

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-state.ps1 -Operation ValidateTestCoverage `
  -Path ".ai-workspace\specs\features\<FeatureName>\05_test_coverage.json"
```

覆盖校验在**实现后**进行：TDD 产出 TC 后，校验需求/设计到用例的追溯是否完整。校验发现都自动修复。需求/设计缺口返回对应的人工确认阶段。

## review 与验证

- 单任务内审（subagent 内）覆盖该 Task 的 spec 合规、代码质量与高风险逻辑，由 `implementation-auditor`/`logic-auditor` 作执行单元完成。
- 整体收尾由 Superpowers `requesting-code-review` 完成，覆盖流程合规与整体一致性。
- 跨任务全盘审计为可选的手动全功能审计（见上），按需触发。
- QA 遵循 `client-test.md`。
- 完成校验会复查测试覆盖与所需的项目测试。

## SVN + 本地 Git

SVN 是团队源码真源与代码隔离手段（每功能一 SVN 分支，合并用 `svn merge` 有冲突检测）。本地 Git **仅作 SDD 的 commit 检查点 / review diff / 回滚，不做代码隔离**（隔离交给 SVN 分支）。运行时隔离（多 Tomcat）由 `feature-runtime.ps1` 分配独立端口 + 物理 `CATALINA_BASE`，与 SVN 分支无关。

推荐：

1. 在带 `.svn` 的 SVN 工作副本里开发（每功能一 SVN 分支）。
2. 维护不含未批准 remote 的本地 Git baseline，仅用于 SDD 检查点（commit/diff/回滚），不承担隔离。
3. 开发、测试与 review 都在该 SVN 工作副本中进行。
4. 交付前：`svn status` / `svn diff` 确认改动范围，对新增文件 `svn add`、删除文件 `svn delete`（未跟踪文件 `?` 不会被 `svn commit` 包含）。
5. 通过 SVN 提交（`svn commit` 涉及团队真源，由人工确认提交，不由 AI 自动执行）。
6. 如需合并到主干/其他分支，用 `svn merge`（有冲突检测，**禁止用文件复制覆盖**，会静默回退他人代码）。

**禁止"Git worktree 开发→复制回 SVN 工作副本"**：Git worktree 没有 `.svn` 元数据，`svn add`/`svn delete`/`svn commit`/`svn merge` 跑不通；文件复制覆盖会静默回退他人代码。详见 `AGENTS.md`「版本控制」「并行开发」与 `.ai-workspace/workflows/parallel-development.md`。

## 归属强制

PreToolUse hook 在每次文件编辑前运行 `guard-production-edit.ps1`（各 harness 共用：hook 命令统一指向 `./.ai-sop/scripts/hook-dispatcher.ps1`；Claude Code 经 `.claude/settings.json`，其它经 `.agents/hooks.json`/`.cursor/hooks.json`/`.github/hooks/ai-sop.json`）。除非机器级注册表中存在 ACTIVE 的 `SUPERPOWERS` owner，否则拒绝编辑生产路径（`src\com\**`、`WebRoot\**`、`config\**`）。guard 异常时可手动关（`.ai-sop/.guard-disabled`）。

`AI_SOP_SKIP_OWNER_GUARD=1`（或旧版 `SERVER_NEW_SKIP_OWNER_GUARD=1`）仅作为非功能型一次性小改（临时 hot-fix、探索性 probe）的逃生口。为绕过某次功能运行的归属而设置它是流程违规。

## 归属完成

Superpowers ledger 存储生成的功能 owner ID。成功交付或成功的修改型独立工作以同一身份调用 `workflow-owner.ps1 -Operation Complete`。失败或阻塞的运行保留活动归属以便恢复。
在恢复运行或任何修改规范产物/生产代码的批次前，以同一身份调用 `workflow-owner.ps1 -Operation Validate`。只读审计不 Claim 归属。

各 harness 统一 `SUPERPOWERS` 归属，`agent` 字段区分实际工具（CLAUDE_CODE/COPILOT/ANTIGRAVITY/CURSOR/PI）。`CUSTOM_SKILLS`/`GEMINI` 作为兼容身份保留（供历史运行恢复等场景）。PI 的 Claim 经 `pi-adapter/bootstrap-pi-session.ps1` 注册 session。
