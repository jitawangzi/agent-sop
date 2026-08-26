# 项目 Agent 指令（公共真源）

> 各 AI 工具（Claude Code / GitHub Copilot / Antigravity / Cursor / Pi）统一加载本文件作为项目指令。工具专属差异见各自的根 md（如 CLAUDE.md）。本文件是单一真源，勿在其它文件重复维护。

> **能力分流提示**：若当前工具能力准入为 BLOCKED（见末节“能力准入”），只跑 T2——你无需读 T3/brainstorming/design-reviewer/subagent 等节，直接看“执行强度分层（T 档）”的 T2 + 末节能力准入即可。STRICT 工具（Claude Code / Antigravity / Cursor / Copilot）可跑 T3 完整流程。

## 工作流归属

**Superpowers 是本项目的唯一顶层开发调度器（T3）；T2/T1/快通道用本文件 + 专家 Skills，不调用 Superpowers。**

完整开发任务从 Superpowers `brainstorming` 开始，按 `.ai-sop/workflows/superpowers-adapter.md` 执行。Superpowers 技能必须显式调用，禁止跳过或自行判断"改动太小不需要"：

| 顺序 | 必须调用的 Skill | 说明 |
|:---:|---|---|
| 1 | `superpowers:brainstorming` | 新功能/新设计/行为变更：探索上下文 → 逐一提问 → 方案对比 → 逐节呈现 → 写 spec → 自审 → 用户审阅。设计产出后由 `design-reviewer` 机器审查（闭环自审自修），再交人工确认 |
| 2 | `superpowers:writing-plans` | spec 确认后：拆分为 2-5 分钟可完成的小任务，含精确路径、完整代码、验证命令。**严禁 TBD/TODO 占位符** |
| 3 | `superpowers:subagent-driven-development` | 读计划全文 → 建 Todo → 对每个 Task：派实现者（`implementation-engine`）→ 内审（`implementation-auditor`/`logic-auditor`）→ 修复 → 标记完成。**每个 Task 必须过双重审查** |
| 4 | `superpowers:requesting-code-review` | 全部 Task 完成后**必须显式调用**，派最终 code reviewer 审查整体实现。禁止用普通 Agent 替代 |
| 5 | `superpowers:verification-before-completion` | 声称完成前必须编译/测试验证，禁止"应该可以了"就标记完成 |

**design-reviewer 审查硬证据约束**：设计产出 `06_design_contract.md` 后、进入 `writing-plans` 前，**必须**先经 `design-reviewer` 机器审查并附审查报告。报告须含审查状态（PASS/NEEDS_FIX/PASS_WITH_WARNINGS）、发现分级（BLOCKER/MAJOR/MINOR/INFO）、专项检查覆盖说明、循环轮次。`PASS_WITH_WARNINGS`（仅剩 MINOR/INFO 豁免）是合法通过状态，不等同篡改。**无审查报告不得进入 writing-plans**——靠"设计已自审"或"方案没问题"等无证据说法跳过审查不成立。快通道（纯配置/纯文档）可跳过本约束。

**design-reviewer 闭环熔断（防 Token 风暴）**：机器闭环**最多 2 轮**（审查→修正→重审）。第 2 轮后：若仅剩 `MINOR`/`INFO` 未决问题，自动豁免通过（状态 `PASS_WITH_WARNINGS`，记入报告）；若仍存在 `BLOCKER`/`MAJOR`，强制退出机器循环，呈递人工在批准阶段裁决。**阻断级（`BLOCKER`/`MAJOR`）可判 `NEEDS_FIX`**，触发闭环修复，计入 2 轮熔断；**建议级（`MINOR`/`INFO`）不得判 `NEEDS_FIX`**，记为 `PASS_WITH_WARNINGS` 不阻断，避免挑刺震荡。详见 `superpowers-adapter.md`。

**需求与设计确认为两道独立门禁（默认禁止合并）**：默认两道门禁独立确认（先人工确认 01 调 `workflow-state.ps1 -Operation Approve -Gate requirement`，再确认 06 调 `Approve -Gate design`）。仅当满足【T3 小改动合并呈递豁免】条件（用户显式要求且 DC≤3 且无存储迁移）时，允许在一次响应中同时呈递 01 与 06，用户单次确认后后台分别调用两次 Approve 写入门禁。除该豁免外，不得随意合并呈递。

**人工确认必须写入门禁状态**：每次人工确认（需求/设计）后，**必须**调用 `workflow-state.ps1 -Operation Approve -Gate <requirement|design>` 写入 `APPROVED` 状态与 SHA-256。口头确认不等于门禁通过——后续 `ValidateTestCoverage` 会校验 APPROVED 状态，未写入会阻塞或被绕过。

**已批准文档修改必须 ResetApproval + 重新确认（硬约束）**：`01` / `06` 经人工确认后，任何**改变业务逻辑/契约语义**的修改（包括 design-reviewer 闭环修正、字段取值规则调整、实现期可测性回写、补 DC/DR/TW 条款等）都**必须先 `workflow-state.ps1 -Operation ResetApproval -Gate <requirement|design>` 作废当前批准**，修改后重新走确认 + Approve。`ResetApproval -Gate requirement` 同时重置 design 门禁（需求变了设计也得重审）。

**纯文本润色豁免（UpdateHash，不作废批准）**：仅修改错别字、标点、格式、措辞等**不改变业务逻辑/契约语义**的内容时，用 `workflow-state.ps1 -Operation UpdateHash -Gate <requirement|design>` 只更新哈希值而不作废 APPROVED 状态，避免一个小错别字雪崩回需求评审。UpdateHash 须在 commit message 注明“纯文本润色，不改语义”。AI 判断不准是否纯润色时，**保守用 ResetApproval** 走重新确认——宁可重审，不可滥用 UpdateHash 绕过门禁。

**按需调用**：
- `superpowers:systematic-debugging` — bug 与异常行为，**不要自己猜根因**。**排查前先复现 bug**：优先路径 A（JUnit/JVM 内）快速复现；若必须走路径 B（JSP 业务验证）则接受其成本。**确认问题真实存在后再排查根因**。判责走 `implementation-engine` 的 TRIAGE Judge，须判到 4 类之一：`[IMPL_FAILURE]` 实现缺陷→修代码；`[DESIGN_FLAW]` 设计缺陷→改需求/设计不修代码；`[TEST_ERROR]`/`[INVALID]` 测试错/误报→不改服务端只输出证据；`[CLIENT_ISSUE]` 客户端问题→不改服务端。**判责结论必须附复现证据（硬约束）**：下结论前先跑复现测试，结论附测试输出。修复 3 次仍未通过复现，**停止改代码**——回头重新复现、重新判责、查是否 `[DESIGN_FLAW]`，不堆砌投机修复掩盖症状。
- `superpowers:receiving-code-review` — 接收审查结果

**不适用本项目**（黑名单，禁用原因见注释）：
- `superpowers:dispatching-parallel-agents` — 并行开发走 `.ai-workspace/workflows/parallel-development.md` + `feature-runtime.ps1`
- `superpowers:using-git-worktrees` — 代码隔离用 **SVN 分支**（不是 Git worktree）。运行时隔离用 `feature-runtime.ps1`。**本项目要求在带 `.svn` 的 SVN 工作副本里开发并 `svn commit` 交付**——`svn add`/`svn delete`/`svn commit`/`svn merge` 都依赖 `.svn` 元数据，Git worktree 里没有 `.svn`，这些命令跑不通。**Copilot App 若默认在 worktree 里跑**，要么：① 把该 worktree 做成 SVN 工作副本（`svn checkout` 到该目录）；② 或只在 SVN 工作副本目录开会话。禁止用文件复制覆盖回主目录（会静默回退他人代码）。Owner 校验绑工作区物理路径——Claim 时以实际开发的目录为工作区。
- `superpowers:executing-plans` — 触发 `using-git-worktrees`（冲突）；有 subagent 时统一用 `subagent-driven-development`
- `superpowers:finishing-a-development-branch` — 本项目交付走 SVN，不用 git merge/PR 收尾

**Skill 分级见下文三列表**（T3 必调 / T3 按需 / 全档禁用）。上表仅 T3 编排顺序。

**关于 Superpowers**：Superpowers 是一个流程技能包，提供 brainstorming/writing-plans/subagent-driven-development 等流程技能。**T2/快通道/T1 完全不依赖 Superpowers**——这些档位直接用原生提示词 + 本项目专家 Skills 或单轮上下文推进，严禁报错停机。只有 T3 完整流程才需要 Superpowers。若 T3 所需的 Superpowers 技能不可用，**停止并明确告知用户**：“T3 完整流程需要 Superpowers 技能包。请按 `.ai-sop/SUPERPOWERS_VERIFICATION.md` 安装/激活，或降级为 T2 快速修改。”——不要静默切换、不要假装在跑。

## 执行强度分层（T 档）

**实际执行档位**由单条规则唯一确定：
`实际执行档位 = MIN(用户显式指定 || 变更类默认, 当前工具最高支持档位)`

| 变更类 | 默认档位 |
|---|---|
| 行为/契约/协议/存储结构变更、新玩法、命中高危语义触发器 | T3 |
| 已有行为的缺陷修复、单点非高危逻辑调整 | T2（用户可显式升 T3） |
| 纯配置数值 / 纯文档措辞 | 快通道 |

- **T3**：完整 Superpowers 流程（brainstorming → 需求确认 → design-reviewer → 设计确认 → writing-plans → subagent-driven-development + TDD → 审计 → requesting-code-review → verification-before-completion）。覆盖：**新功能、行为/契约/协议/存储变更**、需求补充以及**命中高危语义触发器的增量扩展**。

  **语义风险分档原则（小 diff ≠ 小风险，强制升 T3 规则）**：
  即使修改代码量极少（如仅 5~10 行），只要命中以下 **【五大高危语义触发器】** 之一，**严禁按 T2 快速修改跳过设计与审计**，必须强制走 T3（或执行完整的 `Mode D: Behavior Impact Audit` 行为影响审计与双重审查）：
  1. **类型/策略扩展**：新增业务类型（`type`）、枚举（`Enum`）、配置表新增类型行、新增策略类或子处理器；
  2. **公共分发修改**：修改了公共路由、分发器、消息映射表（`switch-case` / `Map<Integer, Handler>` / `Interceptor`）；
  3. **状态与存储**：涉及 `Player` 内存变异、Redis/Mongo 读写、跨天/周期重置、资源增减或奖励发放；
  4. **兼容与并发**：涉及新老数据反序列化兼容、多版本滚更混跑、分布式锁或异步任务；
  5. **多分支入口**：在已有 Action/Help 的主干入口中插入了新的条件分支。

  Bug 修复不固定为 T3——看变更触及什么（如修一个 -1 语义的数值边界 = T2；修协议字段解析逻辑或状态变异 = T3）。
- **T2（用户显式"快速修改"）**：跳过 brainstorming/需求确认/design-reviewer/设计确认/writing-plans；保留归属 Claim、编译、验证、回归、文档待更新提醒。仅限**未命中上述高危触发器**的已有行为纯局部单点修复。

  **T2 执行路径（豁免 + 单命令直达）**：T2 跳过 writing-plans，故不调用 `subagent-driven-development`。T2 下**单命令直达**：用户下达 T2 指令后，AI 在单次响应内自动串联【Claim 归属 → 代码修改 → 编译 → 相关测试 → 交付完成】。**编译/测试可能超单轮超时**，允许一次进度回复（“编译中，下一轮继续”），不要求全部单 turn 完成；硬节点保留。最终 `requesting-code-review` 降为 AI 自审 + 附编译/验证证据。T2 保留归属 Claim、编译、验证、回归四个硬节点。
- **T1（用户显式"急速修改"，极少用）**：仅限极端场景。跳过全部流程节点，仅保留编译通过 + guard 逃生口。AI 须先提醒 T1 风险，用户确认后执行。
- **快通道（AI 自动识别）**：纯配置数值变更（`CONFIG_VALUE_CHANGE`）或纯文档变更（`DOC_ONLY`）自动走**快通道**（跳门禁，完成条件 2 项：编译通过 + 纯数值/文档检查；**非 T2**，T2 是 5 项）。其余按上方实际执行档位公式确定。

**快通道边界（硬约束）**：快通道**仅限 `config/**` 等目录下的纯数据文件**（CSV/配置表数值）。**涉及生产代码（如 `src/**`、`pkg/**`、`internal/**`、`app/**` 等）任何修改**（哪怕 1 行）不得走快通道，至少 T2（认领归属+编译+测试）。改关键枚举值/协议字段名/存储结构不是纯配置，须走 T3。

**T 档触发词（中英文）**：T2 = "快速修改"/"简单需求直接实现"/"simple fix"/"quick change"/"just implement"；T1 = "急速修改"/"直接改"/"rush"/"ASAP"；快通道 = AI 自动识别纯配置/纯文档。快通道边界：只改配置文件/CSV 数值（不改业务语义/协议/存储结构）= 纯配置；只改 .md 文档（不改业务规则/技术契约）= 纯文档。改枚举值/协议字段名/存储结构 **不是** 纯配置，须走 T3。

**T 档升降规则**：开始为 T2 发现需要设计评审的，可向用户建议升 T3（"这个改动比预期复杂，建议走完整 T3 流程"），用户同意后升档。开始为 T3 发现可简化的，不可自行降档，须用户显式同意。

**快通道判定树（二元分类，消除矛盾）**：
- **A 类（真静默快通道）**：仅限既有配置项的**纯数值修改**或 `.md` **错别字/措辞润色**（不改业务规则/技术契约/结构）。AI 单轮静默直达，免确认，最终回复附标 `[FastTrack] 仅纯配置/文档变更，已自动应用快通道`。
- **B 类（需确认快通道）**：涉及配置表**新增行/列/枚举**或可能影响加载逻辑的变更。AI 必须暂停并提示：“检测到配置结构变动，是否确认按快通道处理？”用户同意后继续；不同意则默认降为 T2（认领归属+编译+加载验证），仅当修改涉及协议结构或数据存储时才升为 T3。
- 涉及生产代码任何修改**不是**快通道，至少 T2。
- 快通道是独立档位（完成条件 2 项），**不是 T2**（T2 是 5 项）。

AI 单方判断不构成跳门禁的充分理由（B 类必须问用户）。

**BLOCKED 工具的 T2 降级处理（STRICT 工具如 Claude Code / Antigravity / Cursor / Copilot 原生支持 T3，直接跑完整 Superpowers 流程，严禁弹出 T2 拦截）**：
- **STRICT 工具（Claude Code / Antigravity / Cursor / Copilot）**：按变更类默认档位执行（新功能、行为/契约/协议/存储变更走 T3），直接执行 Superpowers 流程，严禁自称仅支持 T2 或拦截！
- **BLOCKED 工具（如 Pi，最高支持 T2）**：实际执行档位 = MIN(用户指定档位, T2)。在 BLOCKED 工具下：若用户未表达流程意图且为已有行为缺陷修复，静默以 T2 执行；若用户消息含“需求/草案/设计/评审/T3”任一词，或变更是新功能/新协议/新存储/用户点名需求，必须提示：“`[SOP 拦截] 工具 <工具名> 因无 subagent（能力准入 BLOCKED），无法执行 T3 独立审查。建议：切换到 STRICT 工具（Claude Code / Antigravity / Cursor / Copilot），或回复‘仍按 T2 实现’。`”
- 已有行为的单点逻辑修复保持静默 T2，不拦截。

## 人工 review 阶段

需求与设计是人工把关阶段，而非单条消息的批准。需求可多轮问题/备选/分段 review，产出 `01_server_rules.md`，等明确批准；设计可多轮架构/兼容/协议/持久化/可测性 review，产出 `06_design_contract.md`，等明确批准。批准后自动连续完成计划/实现/review/测试/修复/回归。除非需求/设计变模糊或环境阻塞，否则**不要增设实现计划、代码 review 或测试结果的批准检查点**。

**T3 小改动合并呈递豁免（一口令两道 SHA）**：当同时满足以下条件时：
① 用户显式要求“合并确认/一次确认”；
② 变更范围小（新增/调整设计契约 ≤ 3 条 DC 且无存储迁移）；
AI 可在一次响应内同时呈递 `01_server_rules.md` 与 `06_design_contract.md`。用户回复单次“确认”后，AI **分别调用两次 Approve**（写入 requirement 与 design 的独立 SHA 门禁记录）。保持“两道门禁状态不漏”，消除“两次等待交互”。

**技术契约调整单门禁模式（`gateMode: "DESIGN_ONLY"`）**：需求方向已定、仅调整协议/存储/技术契约的中型任务（即 `SUPERPOWERS_MANUAL.md` 模板 5），可在 `00_workflow_state.json` 中声明 `gateMode: "DESIGN_ONLY"`（或调 `InitApproval -GateMode DESIGN_ONLY`）。该模式下仅需通过 06 设计门禁（`Approve -Gate design`），01 需求门禁自动豁免放行，不走双门禁也不降级 T2。

**人机交互提问节奏（统一口径）**：brainstorming/澄清阶段，AI **每轮最多问 3 个聚焦问题**，每个问题聚焦单一决策点，允许用户一句话给齐；对有意义的备选给出 2-4 选项并推荐其一（做选择题而非填空题）。本口径为本文件定义，adapter/VERIFICATION 等文档统一引用。

**人工确认自然语言容差**：用户回复“确认/批准/同意/LGTM/Proceed/通过/没问题/可以/按这个搞/OK 写吧/没意见/冲”且**不带修改建议**→触发 Approve 写入门禁。用户回复含“但是/修改/调整/不对/改下”等转向词→**不写 Approve**，先修正文档再次呈递，严禁提前写入。模糊回复（“行”“先这样吧”）→ AI 须追问“这是否为最终确认？有无修改建议？”确认后再写。

**澄清不是批准**：brainstorming 的逐一提问是**澄清，不是批准**。每轮问题下标注：“这是澄清，不是批准。批准词：确认/LGTM。”只有 `01`/`06` 正式呈递时才用固定块：`【待批准：requirement|design】回复“确认”写入门禁。`

**Brainstorm 草稿（跨工具热切换）**：brainstorming 阶段，AI 每轮将阶段性技术选型共识摘要追加至 `.ai-workspace/specs/features/<Feature>/00_brainstorm_scratchpad.md`。新工具切入时优先加载该草稿，实现“零认知损失”热切换——新工具知道前一会话排除了哪些方案，无需重新讨论。

## 全功能审计（手动，人工把关）

主流程审查分两层（职责不重叠）：单任务内审（subagent 内 `implementation-auditor`/`logic-auditor`）、整体收尾（`requesting-code-review`）。复杂大功能交付后可**手动触发全功能审计**查跨任务契约一致性与整体游戏状态正确性。`workflow-orchestrator` 是 Superpowers 主流程之外的人工手动片段编排器（`audit_fix_policy` 取 `REPORT_ONLY` 或 `AUTO_REPAIR`），不进主流程必经链。详见 `.ai-sop/SUPERPOWERS_MANUAL.md`。

## AUDIT-EXEMPT（审计例外声明）

工程实践存在"规则上不通过但有意允许"的反模式。这类有意例外在 `01`/`06` 条款行标 `[AUDIT-EXEMPT: 原因]`，**必须经人工确认**（随文档进门禁，不允许事后补）。审计见该声明对命中项降为 `INFO` 不阻断。

## 共享项目知识

`.ai-workspace/context/` 是所有 Agent 共享的、流程无关的项目知识。

始终阅读：`project-summary.md`、`coding-style.md`、`business-logic-pattern.md`、`project-tooling.md`。
按需阅读：静态配置 `config-rules.md`、协议 `proto-rules.md`、业务测试/JSP/GM `client-test.md`、活动/任务/事件/条件 `business-patterns/`、高风险游戏状态逻辑 `logic-audit-game-server.md`。

**读取前检测存在性**：上述文件在新项目或 fresh clone 后可能尚未创建。AI 读取前须先检测文件是否存在，不存在则跳过该文件并记一条 INFO（不报错、不中断、不幻觉补内容），继续后续流程。

**Context 版本头**：每个 context 文件首行有 `<!-- context-meta owner:X reviewedAt:YYYY-MM expiresAt:YYYY-MM -->`。`doctor.ps1` 检查过期打 WARN。AI 读过期 context 时应提示用户“context 文件 `<file>` 已过期（<expiresAt>），仍以代码为准，建议更新”。

**知识真源位阶**：当 context 文档与实际代码/配置逻辑发生冲突时，以**实际运行代码与现行配置**为准（代码 > 06 设计契约 > context 知识库）。AI 发现冲突时不得按旧 context “修正”实际正确的生产代码，应向用户提示“context 文档『<文件>』的描述与实际代码不符，可能已漂移，建议更新 context”。

**Context 缺失时的降级与反哺**：当核心 context（如 `coding-style.md`）缺失时，AI 应通过直接读取项目现有核心基类（如 `BaseManager`、`GameParam`、`DateUtil`）推断编码风格，不阻断流程；并在任务完成后主动向用户提示：“检测到缺少 `coding-style.md`，是否需要我根据当前项目代码自动生成一份？”

## 项目强制规则

项目编码/架构强制规则（Java/Spring 分层、MongoDB/Redis、XLSDataManager、DateUtil、GameParam、协议发送、GM fixture 等）统一定义在 `.ai-workspace/context/coding-style.md` 与 `.ai-workspace/context/config-rules.md`，始终阅读并遵守——不在此重复，避免漂移。

## 规范功能产物

使用 `.ai-workspace/specs/features/<FeatureName>/`：`01_server_rules.md`（需求，含 BR/EX/AC）、`05_test_plan.md`（测试用例，含 TC）、`05_test_coverage.json`（机器可读追溯）、`06_design_contract.md`（设计，含 DC/DR/TW）。遵循 `.ai-sop/workflows/shared-artifacts.md`。Superpowers 常规 plan/ledger 文件是执行产物，不得替代规范功能契约。

**05_test_coverage.json 自动生成（SyncCoverage）**：`05_test_plan.md` 的 TC 块用 HTML 注释元数据标记：`<!-- meta: { "id": "TC-XX", "title": "...", "covers": ["BR-XX", "DC-XX"], "priority": "P1" } -->`。运行 `workflow-state.ps1 -Operation SyncCoverage -Path .../05_test_coverage.json` 从 `05_test_plan.md` 自动生成 coverage JSON（占位字段供 AI/用户细化）。**禁止手写 coverage JSON**——用 SyncCoverage 生成。

**原生计划产物双向宽容**：允许 AI 在 IDE 原生 Artifact 区生成计划文件供 UI 交互（如 Antigravity 的 `implementation_plan.md`）；但**持久化阶段**，AI 必须将核心技术契约同步/镜像写入 `.ai-workspace/specs/features/<FeatureName>/06_design_contract.md`。规范路径 `06` 是 `ValidateTestCoverage` 校验的唯一真源；根目录散落的临时计划文件不作为契约，交付前清理。

**产物 ID 缩写含义**（AI 工具必须识别）：

| 缩写 | 含义 | 所在产物 |
|---|---|---|
| BR | Business Requirement（业务需求） | 01 |
| EX | Exception（例外） | 01 |
| AC | Acceptance Criteria（验收标准） | 01 |
| TC | Test Case（测试用例） | 05_test_plan |
| DC | Design Contract（设计契约条款） | 06 |
| DR | Design Rule（设计规则/风险） | 06 |
| TW | Test/Workflow（测试/工作流约定） | 06 |

## 领域专家 Skills（执行单元，强制绑定项目专家）

领域专家 Skill 是 Superpowers 的**执行单元**（subagent 派发）与**咨询/校验组件**，不是流程节点。派发实现者与审查者时，**必须使用本项目专家 Skill，禁止用 general-purpose 或 Superpowers 默认 agent**（缺本项目 GameParam/DateUtil/XLSDataManager 等强制规则与领域缺陷库）：

| 角色 | 必须用的项目专家 Skill |
|---|---|
| 实现者 | `implementation-engine` |
| 每 Task 内审（实现/契约合规） | `implementation-auditor` |
| 每 Task 内审（高风险分支/状态/语义） | `logic-auditor` |
| 设计方案审查（人工确认前，机器闭环） | `design-reviewer` |
| 需求预处理（可选手动前置，复杂 docx） | `requirement-analyst` |
| 架构/契约设计（brainstorming 咨询） | `design-architect` |
| 测试覆盖校验（实现后） | `quality-assurance` / `test-plan-auditor` |

**领域专家 Skills 分级（三列，消除“必须/禁用”矛盾）**：

| 分类 | Skills | 说明 |
|---|---|---|
| **T3 必调** | `brainstorming`、`design-reviewer`、`writing-plans`、`subagent-driven-development`、`requesting-code-review`、`verification-before-completion` | T3 流程核心，不可跳 |
| **T3 按需允许** | `systematic-debugging`、`receiving-code-review`、`requirement-analyst`、`design-architect` | 按场景调 |
| **全档禁用** | `dispatching-parallel-agents`、`using-git-worktrees`、`executing-plans`、`finishing-a-development-branch` | 与 SVN/SOP 冲突 |

**审查必须独立上下文**：审查者（`design-reviewer`/`implementation-auditor`/`logic-auditor`/`requesting-code-review`）必须用独立 subagent 上下文，不能用同一会话自审（共享盲区）。**允许用宿主 subagent 机制加载本项目专家 Skill 提示词**（如 Copilot 的 `Task` 工具加载 `implementation-engine` 提示词）——禁的是“同上下文自审”，不是“用宿主 subagent 载入”。

**审查铁律（仅 T3 严格适用）**：spec 合规审查 → 代码质量审查（顺序不可颠倒）→ 修复 → 重新审查 → 通过才标记完成。同文件修改绝不并行派多个实现者。T3 绝不跳过独立审查（哪怕 1 行）。最终审查 `requesting-code-review` 独立于 subagent 内审，禁止跳过。T2 快速修改降为 AI 自审 + 编译/测试硬验证。

**模型分级调度**：派发 subagent 时按角色复杂度选档（最强/标准/便宜），显式指定 model 不省略。`design-architect`/`design-reviewer`/`requesting-code-review`/`logic-auditor` 用最强档；一般实现/合规/`requirement-analyst` 用标准档；机械转录/单文件小修/配置改动用便宜档。修复循环 R4-5 升一档。详见 `.ai-sop/workflows/superpowers-adapter.md`。

被调用时：使用专家的领域 checklist 与交付格式，把发现返回给 Superpowers controller，**不接管编排、不写 `.ai-sop/runtime/`**。

**原生能力动态继承（Base + Overlay）**：本项目专家 Skill 底层动态继承 Superpowers 本地安装的最新原生模板（`implementer-prompt.md`、`task-reviewer-prompt.md`、`code-reviewer.md`、`test-driven-development`、`systematic-debugging`），自动吸收其升级熔断、零信任自评、RED/GREEN 证据链、Plan-Mandated 缺陷独立定性与 Pristine 零噪声测试等通用工程纪律；当 Superpowers 插件更新时，所有专家 Skill 自动获得最新工程能力，无需修改项目代码。若本地未安装 Superpowers 插件，Skill 自动平滑降级为内联通用心智执行。Controller 派发 subagent 时必须在 prompt 首行显式指定专家 Skill 路径（如 `【角色与规范】你的角色是 implementation-engine，请首先读取并严格遵守 .ai-sop/skills/implementation-engine/SKILL.md`）。

## 功能归属

**AI 自动执行脚本（非打印给用户）**：本文件及手册中所有 `workflow-state.ps1`/`workflow-owner.ps1`/`feature-runtime.ps1`/`run-all-tests.ps1` 等命令，AI 在确认用户意图后应**直接在后台执行**（经终端工具/Bash），读取输出继续流程，而不是把命令打印出来让用户手动复制粘贴。仅当涉及人工决策（如批准需求/设计）时才暂停问用户；脚本执行本身是 AI 的职责。

**Guard 拦截时 AI 自动 Claim**：当用户直接下达修改指令且当前无 Active Owner 时，AI 收到 Guard 拦截后**不得把报错抛给用户**，而应自动在后台生成临时 ownerId 并静默执行 Claim，然后重试编辑。仅在 Claim 失败或归属冲突时才提示用户。

功能开始时自动 Claim 归属，生成不可变 owner ID 持久化到 Superpowers ledger。各 harness 统一 `SUPERPOWERS` 归属（`-Workflow SUPERPOWERS` 是归属身份标识，**不等于依赖 Superpowers 技能包**——T2/快通道不依赖 Superpowers 技能，但仍用此归属身份），`agent` 字段区分实际工具：

**FeatureName 命名规则**：用 PascalCase 英文（`[A-Z][A-Za-z0-9]+`，如 `ShopExchangeBuyLimit`、`DailySignInReward`）。从用户话术提取并回显：“将以 `<FeatureName>` 认领，不对请立刻改名”。目录不存在则建。T2 小改也需 feature 名（热修用 `HotfixShopLimit20260821`，无连字符）。*注意：已有 01/06 规格产物的功能目录，后续修改均按 T3 门禁收尾；若需独立 T2 快速修改请开新 FeatureName。*

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-owner.ps1 -Operation Claim `
  -SpecDirectory ".ai-workspace\specs\features\<FeatureName>" `
  -Feature "<FeatureName>" -Workflow SUPERPOWERS `
  -Agent "<CLAUDE_CODE|COPILOT|ANTIGRAVITY|CURSOR|PI>" `
  -OwnerId "<superpowers-run-id>" `
  -Tier "<T2|T3>"
```
*注：`-Tier` 可选 `T1`/`T2`/`T3`/`FAST_TRACK`（默认 `T2`；新功能/复杂变更走 T3 流程时须显式传 `-Tier T3`）。*

`agent` 值取自实际工具而非底层模型。若另一活动流程或 session 拥有该功能，**停止而不是编辑它**。任何修改规范功能产物或生产代码的操作都需要归属；只读审计豁免。验证与完成用同一 owner ID。恢复前、每个修改批次前用 `Validate`：

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-owner.ps1 -Operation Validate `
  -SpecDirectory ".ai-workspace\specs\features\<FeatureName>" `
  -Feature "<FeatureName>" -Workflow SUPERPOWERS `
  -Agent "<CLAUDE_CODE|COPILOT|ANTIGRAVITY|CURSOR|PI>" `
  -OwnerId "<superpowers-run-id>"
```

成功交付后 `Complete`：

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-owner.ps1 -Operation Complete `
  -SpecDirectory ".ai-workspace\specs\features\<FeatureName>" `
  -Feature "<FeatureName>" -Workflow SUPERPOWERS `
  -Agent "<CLAUDE_CODE|COPILOT|ANTIGRAVITY|CURSOR|PI>" `
  -OwnerId "<superpowers-run-id>"
```

失败/阻塞保留归属以便恢复。

**工具切换与归属接管（Transfer）**：用户中途换工具（如从 Claude Code 切 Cursor）继续同一功能时，新工具发现 owner agent 不同会停止。此时 AI 应从 Guard 拦截报错信息、Superpowers ledger 或功能目录下的 `.workflow-owner.json` 镜像中读取**原 ownerId**（不需问用户要——用户未必知道 ownerId）。有活 session 时用 Transfer：

```powershell
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-owner.ps1 -Operation Transfer `
  -SpecDirectory ".ai-workspace/specs/features/<FeatureName>" -Feature "<FeatureName>" `
  -Workflow SUPERPOWERS -Agent "<新工具>" -OwnerId "<原ownerId>"
```

**凭证丢失路径（ForceRelease）**：若 ledger/session/镜像都拿不到原 ownerId（前工具异常退出未同步、或镜像丢失），不要卡死——询问用户“是否强制接管该功能归属？”用户**显式确认**后执行 `workflow-owner.ps1 -Operation ForceRelease -Feature <Name> -Workflow SUPERPOWERS -Agent <原工具> -OwnerId <任何能拿到的原id或占位>` 将归属释放（状态 RELEASED），之后重新 `Claim`。禁止静默接管。功能已 Complete 则无需 Transfer/ForceRelease，开新功能即可。

## 生产代码编辑 Guard

PreToolUse hook 在每次文件编辑前运行 `guard-production-edit.ps1`（各 harness 共用：hook 命令统一指向 `./.ai-sop/scripts/hook-dispatcher.ps1`；Claude Code 经 `.claude/settings.json`，其它经 `.agents/hooks.json`/`.cursor/hooks.json`/`.github/hooks/ai-sop.json`）。编辑 `src\com\**`、`WebRoot\**`、`config\**` 前，**必须存在 ACTIVE 的 `SUPERPOWERS` owner**，否则被拒绝。`AI_SOP_SKIP_OWNER_GUARD=1`（或旧版 `SERVER_NEW_SKIP_OWNER_GUARD=1`）仅对非功能型一次性小改生效；为绕过归属而设它是流程违规。guard 异常可手动关（`.ai-sop/.guard-disabled`）。**更推荐用一次性令牌**：写 `.ai-sop/.guard-token.json`（`{feature, reason, operator, expiresAt}`），guard 仅当 feature 匹配且未过期时放行，过期自动删除，防 `.guard-disabled` 被遗忘导致后续任务无防护。

**Guard 绕过合规提醒**：若 AI 发现 `AI_SOP_SKIP_OWNER_GUARD=1` 或 `SERVER_NEW_SKIP_OWNER_GUARD=1` 开启但当前任务涉及复杂/多文件代码变更，必须在开始前 Warning 提醒用户：“当前开启了 Guard 绕过，此修改将不记录归属且跳过审查。请确认是否为临时小改；若非小改请关闭该变量并走正常归属流程。”AI 不得在复杂变更时默记配合用户违规而不提醒。

## 跨工具交接状态（feature-state.json）

换工具时不丢进度：每个功能目录下可维护 `feature-state.json`（轻量运行时进度，记录 tier/phase/完成项/下一动作/最近验证，不依赖聊天历史）。新工具接管后先查询：

```powershell
pwsh -NoProfile -File ./.ai-sop/scripts/feature-state.ps1 -Operation Get -Feature <FeatureName> -SpecDirectory ".ai-workspace/specs/features/<FeatureName>"
```

输出当前 phase/完成步骤/下一动作/最近验证结果。AI 每完成一个阶段（Claim/需求确认/设计确认/实现/审计/验证）后用 `-Operation Set` 更新进度，供下次或换工具时恢复。

## 完成验证

交付前运行聚合测试与覆盖校验：

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\run-all-tests.ps1 -IncludeCompile
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-state.ps1 -Operation ValidateTestCoverage `
  -Path ".ai-workspace\specs\features\<FeatureName>\05_test_coverage.json"
```

`run-all-tests.ps1` 默认跑工作流脚本测试；`-IncludeCompile` 额外跑 `gradlew compileJava`。全过 exit 0。最后由 `verification-before-completion` 复查。

**验证须匹配声明（硬约束）**：编译通过 ≠ 功能通过 ≠ 业务链路验证；JUnit 通过 ≠ 正式 Tomcat/JSP 业务验证（路径 A ≠ 路径 B）；"已修复"须附原始 bug 复现修复后 Passed 证据；"功能完成"须附覆盖契约校验通过证据。读 exit code 与实际输出，不假设成功。

## 完成定义

完成条件**按档位分**（`workflow-state.ps1 -Operation Status` 显示当前 tier + 门禁 SHA；`workflow-state.ps1 -Operation CheckCompletion -Path .../00_workflow_state.json` 输出机检 ASCII checklist（门禁 SHA/coverage/编译产物/SVN status）。**机检项 [v]=pass/[X]=fail，人工项 [?]=需 AI 验证**。AI 据下表 + CheckCompletion 结果逐项检查并报告）：

**Complete 前硬门禁（VerifyCompletion 内嵌执行）**：`workflow-owner.ps1 -Operation Complete` 内部已嵌入 `VerifyCompletion` 硬门禁检验。在释放归属锁前，脚本会自动在后台先调用 `VerifyCompletion`：T3 严格校验门禁 APPROVED+SHA / coverage 无占位与 carrier 错误 / feature-state 阶段非初始 / 编译产物；T2 校验编译产物。**若 VerifyCompletion 检验未通过（非 0），Complete 会直接抛出错误并拒绝释放归属锁**。AI 亦可事先调用 `workflow-state.ps1 -Operation VerifyCompletion -Path .../00_workflow_state.json` 提前确认是否达到完成标准。

**T3（6 项全过）**：

| # | 条件 | 验证命令 | 成功输出 | 失败恢复 |
|---|---|---|---|---|
| 1 | 需求与设计已确认 | `workflow-state.ps1 -Operation Status -Path .../00_workflow_state.json` | `gate=requirement status=APPROVED` + `gate=design status=APPROVED` + `hashMatch=MATCH` | `ResetApproval` + 修改 + `Approve` |
| 2 | 测试计划与覆盖矩阵已创建/更新 | `workflow-state.ps1 -Operation ValidateTestCoverage -Path .../05_test_coverage.json` | `VALID` | 补 05_test_plan.md + 05_test_coverage.json |
| 3 | 代码编译通过 | `gradlew compileJava` | `BUILD SUCCESSFUL` exit 0 | 修编译错误 |
| 4 | 必要全局审计与逻辑审计通过 | `implementation-auditor` + `logic-auditor` 报告 PASS | 审查报告 PASS | 修复发现 + 重审 |
| 5 | 目标自动化场景通过 | `run-all-tests.ps1 -IncludeCompile` + 定向 JUnit | exit 0 | 修测试 + 重跑 |
| 6 | 中途失败已修复、复审和回归 | 检查无未解决发现 | 无未解决发现 | 补修复 + 回归 |

**T2（5 项，跳过需求/设计/测试计划门禁）**：

| # | 条件 | 验证命令 | 成功输出 |
|---|---|---|---|
| 1 | 归属 Claim | `workflow-owner.ps1 -Operation Validate` | `VALID` |
| 2 | 代码编译通过 | `gradlew compileJava` | `BUILD SUCCESSFUL` exit 0 |
| 3 | 相关测试通过（路径 A JUnit 或路径 B JSP） | 定向 JUnit | exit 0 |
| 4 | 相关回归（定向 JUnit，或写明无自动化及原因） | 定向 JUnit 或说明 | 有测试或说明 |
| 5 | **文档待更新提醒** | AI 输出提醒 | 提醒已输出 |

**快通道（2 项）**：编译通过 + 纯数值/文档检查。**T1（1 项）**：仅编译通过 + guard 令牌。

最终结论表述为“已覆盖场景通过”，不得宣称绝对无缺陷。

## 版本控制

SVN 是团队源码真源。本项目基于 **SVN 分支**开发（不是 trunk 直接开发），每个功能/版本一个 SVN 分支，SVN 分支本身提供代码隔离与合并（`svn merge` 有冲突检测）。

**本地 Git 的定位（仅 SDD 检查点，不做隔离）**：本地 Git 仅用于 `subagent-driven-development` 的 commit 检查点 / review diff / 回滚——它**不承担代码隔离职责**（隔离交给 SVN 分支）。使用前检测——有则用，无则 `git init`（无 remote）+ `.gitignore` 排除构建产物/SVN 元数据 + baseline commit。绝不把本地 Git commit 当 SVN 交付；不推送项目代码到未批准 remote；保留 SVN properties。

**交付闭环（SVN 分支）**：所有验证通过后准备交付时，**AI 不得用 `git push` 交付，也不做"复制回主目录"操作**。交付走 SVN：
1. 在当前 SVN 分支工作目录执行 `svn status`/`svn diff` 确认改动范围；
2. 对新增文件执行 `svn add`，对删除文件执行 `svn delete`（AI 自动执行，勿漏——未跟踪文件 `?` 不会被 `svn commit` 包含）；
3. 输出建议的 `svn commit -m "<FeatureName>: <message>"` 命令供用户**人工执行**最终提交（`svn commit` 涉及团队真源，由人工确认提交，不由 AI 自动执行）。
4. 如需合并到主干/其他分支，用 `svn merge`（有冲突检测，**禁止用文件复制覆盖**，会静默回退他人代码）。

**VCS 增删即时跟踪（硬约束）**：凡新建、删除或重构源码、测试、配置或脚本文件（.java, .groovy, .kt, .xml, .properties, .proto, .ps1, .csv, .json, .sql, .yml, .yaml 等），AI 必须在创建/删除后**立即在后台执行 `svn add <file>` / `svn delete <file>`（或 `git add`）**，禁止留存未跟踪状态到任务交付尾声。涉及文件重命名或移动时，优先使用 `svn move <old> <new>`（或 `git mv`）保留版本历史；若已在文件系统移动，AI 应配合使用 `svn delete <old>` 与 `svn add <new>`。

本地 Git commit 仅作开发检查点，不是交付。

## 并行开发

并行分两层，不要混淆：

**① 代码编辑隔离（防多功能改同一文件冲突）**：用 **SVN 分支**——每个功能 `svn copy` 开新分支，各分支独立 `svn commit`，合并用 `svn merge`（有冲突检测）。**禁止用"Git worktree 复制回 SVN"**（会静默回退他人代码、漏 `svn add`/`svn delete`）。

**② 运行时隔离（多 Tomcat 同时跑）**：用 `.ai-workspace/scripts/feature-runtime.ps1` 分配独立端口 + 物理 `CATALINA_BASE`。这层**与 SVN 分支无关**——同一分支也能多 Tomcat 并行（只要物理工作目录分开）。

一个功能一个 Agent session。遵循 `.ai-workspace/workflows/parallel-development.md`。

## 能力准入（工具能跑什么）

各工具有能力差异，见 `.ai-sop/scripts/harness-capability.ps1`（STRICT/BLOCKED 判定）：
- **STRICT**（Claude Code、Cursor、Copilot、Antigravity）：有独立 subagent + 审查证据，可跑 T3 完整流程（含独立审查）。
- **BLOCKED**（Pi）：缺关键能力（核心无独立 subagent 审查），只能 T2。BLOCKED 不代表工具差，是该能力暂未确认；真机认证后可升 STRICT。

无 subagent 的工具跑 T3 时独立审查实为自审（共享盲区），失 T3 价值——故能力准入判 BLOCKED 只 T2。详见 `.ai-sop/docs/ARCHITECTURE.md`。

**静态表是声明值，非运行时探测**：`harness-capability.ps1` 的 known-capability 表是"该工具声明应具备"的能力（静态默认）。真实环境可能因内网代理/工具版本/特定 shell 而降级（如某 Copilot 插件无 subagent、某 Cursor build 派发 subagent 失败）。两种应对：
- **本机覆盖**：若本机环境某 STRICT 工具实际不支持 subagent/evidence，写 `.ai-sop/.harness-capability-override.json`（gitignored，不共享）降级该能力。格式 `{"CLAUDE_CODE":{"subagent":false,"_reason":"此 build 的 subagent 失效"}}`。`harness-capability.ps1` 合并覆盖后重判（STRICT→BLOCKED），`doctor.ps1` 提示覆盖存在。覆盖文件是本机降级的诚实记录，不静默。
- **派 subagent 失败时优雅降级**：T3 流程中若派 subagent 遇 `Tool not found`/无响应/超时，**不得重试挂死**——视为该工具本机 subagent 能力失效，输出 `[SOP 降级] 当前环境 subagent 派发失败，T3 独立审查不可用，自动降级为 T2 自审 + 附失败证据，或写 override 后重试`。降级后按 T2 完成（自审 + 编译 + 验证），不阻塞交付。

## AI 回复状态行（必带）

AI 每次回复末尾必带一行：`档位=T2 | 阶段=实现 | 下一步=编译 | owner=<id>`。`ai-sop.ps1 Status -Feature <Name>` 打同一行，让人/AI/工具三端能对上进度。

## SOP 拦截标准输出格式

当操作因工具能力准入（BLOCKED）或 Guard 拦截而中断时，AI **必须**用标准格式输出，让用户一眼看出是 SOP 拦截而非工具故障：

```
[SOP 拦截] 工具 <工具名> 因 <缺失能力/拦截原因>，无法执行 <尝试的动作>。
建议：<恢复建议，如切换 STRICT 工具 / Claim 归属 / 用户确认接管 等>
```

示例：`[SOP 拦截] 工具 Pi 因无 subagent（能力准入 BLOCKED），无法执行 T3 design-reviewer 独立审查。建议：降级 T2 或切换到 Claude Code / Antigravity / Cursor / Copilot 跑 T3。`

不得只报“我无法完成”而不给原因和恢复建议。

**Owner 凭证丢失交互式接管**：当 Guard 检测到 Owner 不匹配时，不要冷拒，应在拦截信息中输出 AI 可识别的接管提示：`提示：当前目录被上一会话锁定，输入“接管任务”或“takeover task”即可由 AI 自动 Transfer/ForceRelease 转移所有权。` 用户输入任一口令后，AI 自动执行 Transfer（有活 session）或 ForceRelease（凭证丢失）流程。

## 门禁状态诊断（Status）

查看当前门禁状态 + SHA 是否匹配（只读，不锁不报错）：

```powershell
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-state.ps1 -Operation Status -Path .ai-workspace/specs/features/<FeatureName>/00_workflow_state.json
```

输出 `gate=<requirement|design> status=<APPROVED|DRAFT> sha256=... artifact=... hashMatch=<MATCH|DRIFT>`。`hashMatch=DRIFT` 表示已批准产物被改过——纯文本润色用 `UpdateHash`，实质改动用 `ResetApproval` + `Approve`。

## 归属超时与强制释放（ForceRelease）

前 session 异常退出（崩溃/被杀）没 `Complete` 时，owner 永远 ACTIVE，新 session 无法 Claim。恢复：

```powershell
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-owner.ps1 -Operation ForceRelease `
  -SpecDirectory ".ai-workspace/specs/features/<FeatureName>" -Feature "<FeatureName>" `
  -Workflow SUPERPOWERS -Agent "<原工具>" -OwnerId "<原ownerId>"
```

`ForceRelease` 把 owner 状态改为 `RELEASED`（不删记录，保留审计轨迹），之后可重新 `Claim`。需准确 `Feature` + `OwnerId`，防偷归属。优先用 `Transfer`（有活 session 时）；`ForceRelease` 仅在原 session 已丢失时用。

**换机交接**：换机器/换人时本机注册表（`%LOCALAPPDATA%`）没有原 owner，但功能目录下的 `.workflow-owner.json` 镜像随仓库走。AI 从镜像读原 `ownerId`/`agent`，执行 `ForceRelease`（本机注册表找不到也无妨——镜像 ownerId 用于校验），之后用新身份重新 `Claim`。不需要问用户 ownerId。

## 概念速查表

| 术语 | 一句话 | 详参 |
|---|---|---|
| Superpowers | 流程技能包（brainstorming/writing-plans/SDD 等），T3 需要，T2 不需要 | 本文件"关于 Superpowers" + `.ai-sop/SUPERPOWERS_VERIFICATION.md` |
| harness | AI 编码工具的统称（Claude Code/Copilot/Antigravity/Cursor/Pi） | `.ai-sop/docs/ARCHITECTURE.md` |
| T 档 | 执行强度档位（T3 完整/T2 快速/T1 急速/快通道） | 本文件"执行强度分层" |
| 能力准入 | 工具能力判定（STRICT 可 T3/BLOCKED 只 T2） | 本文件"能力准入" + `harness-capability.ps1` |
| 归属 Claim | 功能开发权的认领，生成不可变 ownerId | 本文件"功能归属" |
| 门禁 | 需求/设计的人工批准状态（APPROVED + SHA） | 本文件"人工 review 阶段" |
| design-reviewer | 机器设计审查（独立 subagent，T3 必需） | 本文件"工作流归属" |
| AUDIT-EXEMPT | 有意允许的反模式例外声明 | 本文件"AUDIT-EXEMPT" |
| UpdateHash | 纯文本润色后只更哈希不作废批准 | 本文件"纯文本润色豁免" |
| Transfer | 换工具时转交归属 | 本文件"工具切换与归属接管" |
| ForceRelease | 原 session 丢失时强制释放归属 | 本文件"归属超时与强制释放" |
| 快通道 | 纯配置/纯文档自动走快通道（独立档位，完成条件 2 项，非 T2） | 本文件"T 档触发词" |
