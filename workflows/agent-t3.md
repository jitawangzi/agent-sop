# T3 执行参考

> 仅在用户选择 T3，或接管既有 T3 任务时读取。公共任务入口与 T1/T2 规则以项目根 AGENTS.md 为准。本文件保存详细编排要求，流程顺序见 superpowers-adapter.md。

新建 T3 任务必须在 Start 带 UserRequest 保存人工选择完整流程的原话；接管原 T3 用 Resume 继承，不补造选择依据。操作成功后、首次修改前，向用户说明本次按 T3（人工指定或沿用原任务）执行完整流程；子 Agent 继承 controller 的任务与档位。只读讨论不因阅读本文件就变成 T3 修改任务。

接管或继续已有 T3 时，先核对已有产物、批准、审查与证据是否仍适用于当前版本和任务范围；符合条件的成果可复用，不从头重复已满足的步骤。发生变化时按对应失效规则补做，不能把旧成功当作当前结果。

## 当前任务范围

**T3 任务范围**：Start 固定修改前内容基线，功能长期批准基线独立保留。用 `Task Changes` 读取本次新增/修改/删除范围；需要 04 时，taskId、baseline、baselineInputDigest、changedFiles、changeSetDigest 必须匹配该范围，ReviewImpact 保存的 `.ai-workspace/specs/.artifacts/changes/` 清单随 specs 同步。用 `SetCaseScope -CaseIds ... -Reason ...` 登记本次必测用例，包含 04 的 requiredRegressionCases；规格变化后重新核对。其他未开发用例不强制本次执行，整体规格覆盖定义仍检查。ChangeTier/SetBaseline 只接受本任务 Start 已记录的起点；缺起点拒绝升级并保留原档位，不能用后续 Run 清单或理由替代。旧 T3 source=START 基线兼容，旧手工 ADOPTED 无起点证明则诊断；历史 DONE 不迁移。T1/T2 不新增上述范围登记。可选 JUnitReports + CaseMap 从本次 JUnit XML 映射结果，不能用旧/跳过/失败报告充当通过。

## 工作流归属

**Superpowers 是本项目的唯一顶层开发调度器（T3）；T2/T1用项目根 AGENTS.md + 按需专家 Skills，不调用 Superpowers。**

T3 完整开发任务从 Superpowers `brainstorming` 开始，按 `.ai-sop/workflows/superpowers-adapter.md` 执行。Superpowers 技能必须显式调用，禁止跳过或自行判断"改动太小不需要"：

| 顺序 | 必须调用的 Skill | 说明 |
|:---:|---|---|
| 1 | `superpowers:brainstorming` | 新功能/新设计/行为变更：探索上下文 → 逐一提问 → 方案对比 → 逐节呈现 → 写 spec → 自审 → 用户审阅。设计产出后由 `design-reviewer` 机器审查（闭环自审自修），再交人工确认 |
| 2 | `superpowers:writing-plans` | spec 确认后写实现计划。**Task** = 一次实现+编译+内审的审查单位（紧耦合小改动默认 1 个 Task）；**Step** 才是 2–5 分钟动作。计划须含精确路径、完整代码、验证命令。**严禁 TBD/TODO 占位符**。粒度见 adapter「writing-plans Task 粒度」 |
| 3 | `superpowers:subagent-driven-development` | 读计划全文 → 建 Todo → 对每个 Task：派实现者（`implementation-engine`）→ 内审（`implementation-auditor`/`logic-auditor`）→ 修复 → 标记完成。**每个 Task 必须过双重审查** |
| 4 | `superpowers:requesting-code-review` | 全部 Task 完成后**必须显式调用**，派最终 code reviewer 审查整体实现。禁止用普通 Agent 替代 |
| 5 | `superpowers:verification-before-completion` | 声称完成前必须编译/测试验证，禁止"应该可以了"就标记完成 |

**design-reviewer 审查硬证据约束**：设计产出 `06_design_contract.md` 后、进入 `writing-plans` 前，**必须**先经 `design-reviewer` 机器审查并附审查报告。报告须含审查状态（PASS/NEEDS_FIX/PASS_WITH_WARNINGS）、发现分级（BLOCKER/MAJOR/MINOR/INFO）、专项检查覆盖说明、循环轮次。`PASS_WITH_WARNINGS`（仅剩 MINOR/INFO 豁免）是合法通过状态，不等同篡改。**无审查报告不得进入 writing-plans**——靠"设计已自审"或"方案没问题"等无证据说法跳过审查不成立。T1/T2 不受本 T3 约束。

**design-reviewer 闭环熔断（防 Token 风暴）**：机器闭环**最多 2 轮**（审查→修正→重审）。第 2 轮后：若仅剩 `MINOR`/`INFO` 未决问题，自动豁免通过（状态 `PASS_WITH_WARNINGS`，记入报告）；若仍存在 `BLOCKER`/`MAJOR`，强制退出机器循环，呈递人工在批准阶段裁决。**阻断级（`BLOCKER`/`MAJOR`）可判 `NEEDS_FIX`**，触发闭环修复，计入 2 轮熔断；**建议级（`MINOR`/`INFO`）不得判 `NEEDS_FIX`**，记为 `PASS_WITH_WARNINGS` 不阻断，避免挑刺震荡。详见 `superpowers-adapter.md`。

**需求与设计确认为两道独立门禁（默认禁止合并）**：默认两道门禁独立确认（仅 T3：先人工确认 01 调 `workflow-state.ps1 -Operation Approve -Gate requirement`，再确认 06 调 `Approve -Gate design`）。仅当满足【T3 小改动合并呈递豁免】条件（用户显式要求且 DC≤3 且无存储迁移）时，允许在一次响应中同时呈递 01 与 06，用户单次确认后后台分别调用两次 Approve 写入门禁。除该豁免外，不得随意合并呈递。

**人工确认必须写入门禁状态**：每次人工确认（需求/设计）后，**必须**调用 `workflow-state.ps1 -Operation Approve -Gate <requirement|design>` 写入 `APPROVED` 状态与 SHA-256。口头确认不等于门禁通过——后续 `ValidateTestCoverage` 会校验 APPROVED 状态，未写入会阻塞或被绕过。

**T3 按需调用（下列复现和审查流程不强加给 T1/T2）**：
- `superpowers:systematic-debugging` — bug 与异常行为，**不要自己猜根因**。**排查前先复现 bug**：优先路径 A（JUnit/JVM 内）快速复现；若必须走路径 B（JSP 业务验证）则接受其成本。**确认问题真实存在后再排查根因**。判责走 `implementation-engine` 的 TRIAGE Judge，须判到 4 类之一：`[IMPL_FAILURE]` 实现缺陷→修代码；`[DESIGN_FLAW]` 设计缺陷→改需求/设计不修代码；`[TEST_ERROR]`/`[INVALID]` 测试错/误报→不改服务端只输出证据；`[CLIENT_ISSUE]` 客户端问题→不改服务端。**判责结论必须附复现证据（硬约束）**：下结论前先跑复现测试，结论附测试输出。修复 3 次仍未通过复现，**停止改代码**——回头重新复现、重新判责、查是否 `[DESIGN_FLAW]`，不堆砌投机修复掩盖症状。
- `superpowers:receiving-code-review` — 接收审查结果

**不适用本项目**（黑名单，禁用原因见注释）：
- `superpowers:dispatching-parallel-agents` — 隔离与并行遵循宿主 context 和 SOP 任务规则，不另起并行编排。同功能 T3 可以与其他工作区的 T1/T2 并行，同工作区同功能仍串行，T3 + T3 暂不支持；详见 [有限并行](../docs/PARALLEL_TASKS.md)。
- `superpowers:using-git-worktrees` — 工作区隔离与版本控制遵循宿主 context 和用户约定；不自动创建 worktree，不用文件复制覆盖代替合并。Owner 绑定实际开发目录的物理路径。
- `superpowers:executing-plans` — 触发 `using-git-worktrees`（冲突）；有 subagent 时统一用 `subagent-driven-development`
- `superpowers:finishing-a-development-branch` — 收尾与提交遵循宿主版本控制约定和 Task Complete，不额外引入另一套分支交付流程。

**Skill 分级见下文三列表**（T3 必调 / T3 按需 / 全档禁用）。上表仅 T3 编排顺序。

**关于 Superpowers**：Superpowers 是一个流程技能包，提供 brainstorming/writing-plans/subagent-driven-development 等流程技能。**T2/T1 完全不依赖 Superpowers**——这些档位直接用原生提示词 + 本项目专家 Skills 或单轮上下文推进，严禁报错停机。只有 T3 完整流程才需要 Superpowers。若 T3 所需的 Superpowers 技能不可用，**停止并明确告知用户**：“T3 完整流程需要 Superpowers 技能包。请按 `.ai-sop/SUPERPOWERS_VERIFICATION.md` 安装/激活，或降级为 T2 快速修改。”——不要静默切换、不要假装在跑。

## 影响分析与覆盖

以下影响、覆盖与独立审查要求仅在 **T3** 下执行；T1/T2 可引用分析建议，但不因此新增完整流程门禁。

  **04 强制范围**：`04_change_impact.json` 不是所有 T3 的必交件。仅当 `AssessRisk` 命中 `TYPE_EXTENSION` 或 `PUBLIC_ROUTING`（旧系统扩展），或风险无法评估（`WORKSPACE_UNRESOLVED` / `VCS_ERROR` / `VCS_UNAVAILABLE` / overlay git+SVN 但生产 SVN 扫不到 / 规格无法定位生产文件）时，`VerifyCompletion` 才强制 04。绿场 T3 有 01/06 + 覆盖矩阵即可 Complete；缺 04 不失败。若 04 已存在，仍会校验有效且未过期。混合仓里过期的 overlay git SHA（或功能目录缺 baseline）在 SVN 工作副本可用时按 SVN 评估，不因 `INVALID_BASELINE` 中断。`AssessRisk` 只扫本功能规格能定位到的生产文件，不把整棵脏工作副本算进本功能。

  **类型/策略扩展完成度（机器硬门禁，不只靠审查清单）**：命中触发器 1 或 2 时，`04_change_impact.json` 存在仍不够。`ValidateChangeImpact` / `VerifyCompletion` 会要求：
  - 非空 `behaviorVariants`（每个新旧类型/策略键标明 `IDENTICAL_TO_LEGACY` / `INTENTIONAL_DIFF` / `N_A`）
  - 非空 `legacyPaths`（旧分发/入口的受保护行为；`IDENTICAL_TO_LEGACY` 必须带 `regressionCaseId`）
  - 非空 `invariants`（`INV-*` 必须被 `05_test_coverage.json` 的 `invariantIds` 覆盖）
  - `lifecycleFacets` 必须对 `INIT`/`QUERY`/`VALIDATE`/`MUTATE`/`PERSIST`/`RESET`/`SERIALIZE`/`COMPENSATE` 逐条给出 `TOUCHED`/`INHERITED`/`N_A`（缺切面不得省略，只能显式 N_A + 证据）
  这防止“只改了新类型主路径、漏掉旧流程切面”的小 diff 高风险缺陷。实现者必须 grep 兄弟类型标识符列出全部分发位点，不得用 `focus_methods` 把审计缩到新改的几行。

  **按协议审查 + 表征覆盖（机器硬门禁）**：class / 版本 diff 审查看不到未改动的旧切面。类型/策略扩展时，审计应从 `04.entryPoints` 的公共入口 + `typeKey` 样例输入往下模拟完整执行（logic-auditor Mode E / implementation-auditor Protocol Trace），而不是从 Helper 类或 `focus_methods` 起审。`VerifyCompletion` 额外要求 `05_test_coverage.json`：
  - 每个 `04.entryPoints` 出现在某条 Case 的 `entryPointIds`
  - 每个 `INTENTIONAL_DIFF` 的 `typeKey` 出现在某条 Case 的 `variantKeys`（新类型自己的 FUNCTIONAL/CHARACTERIZATION Case，抽样本不适用于新键）
  - 若存在 `IDENTICAL_TO_LEGACY`，**至少抽 1 个**共享同一分发的代表旧键，出现在某条 `testTypes` 含 `CHARACTERIZATION` 的 Case。同质兄弟不必每个都有 Case；有独立配置/独立分支的旧键仍须单独抽样（见 `04.legacyPaths`）
  - 每个 `TOUCHED`/`INHERITED` 切面出现在某条 Case 的 `facetIds`
  - QUERY 切面仍生效时，至少一条 Case `bypassesPriorQuery=true`（不先查询、直接发写入入口）
  - 每条 `CHARACTERIZATION` Case 必须有非 `N_A` 的 `assertions.persistenceColdReload`（含 `coldReloadEntity`），且载体方法体再读存储
  缺任一项报 `TYPE_EXTENSION_COVERAGE_INCOMPLETE`。`04.behaviorVariants` 仍须登记兄弟键（或 `excludedWithReason`）——那是声明表，不是“每个旧类型一条测试”。设计阶段就必须把 **已有** QUERY/MUTATE/RESET/COMPENSATE/观测入口写进 `04.entryPoints`，而不是只列主写入协议，也不是为此新写一套协议。

  **证据门禁（防 N_A 填空、防空表征 Case）**：`ValidateChangeImpact` 还会拒绝：
  - `lifecycleFacets` / `N_A` 变体的证据是套话（`n/a`、`不适用`、`main path covers`）或短于 24 字、没有 `Class#method` / 源文件 / `typeKey`
  - 变更文件里的 enum / `TYPE_*` 兄弟常量未全部写入 `behaviorVariants` 或 `excludedWithReason`（只登记新键、漏旧键）。这是 04 声明表，机器在单文件 ≤32 个候选键时检查；不等于要求每个旧键都有测试或人工点一遍。
  - 8 个必填切面里超过 4 个 `N_A`
  `VerifyCompletion` 还会读 `CHARACTERIZATION` Case 的 `automationCarrier#method` 方法体：空 `@Test`、没有调用、或方法里不出现 `variantKeys`/`entryPointIds` 字面量，一律 `TYPE_EXTENSION_COVERAGE_INCOMPLETE`。同一条表征 Case 还必须有非 `N_A` 的 `assertions.persistenceColdReload`（含 `coldReloadEntity`），且方法体出现 `selectById` / `getById` / `findById` / `reloadFresh` 一类再读存储的调用——只断言协议回包算假绿。这仍不能证明运行时打到了旧分发，但能挡住“JSON 填了、测试是空方法”和“测了入口、没冷读库”的假覆盖。


## 两类工作：全新功能 vs 旧系统扩展（隐蔽缺陷投入点）

有状态线上系统的 T3 不要平均加力。按工作种类把力气放在不同阶段：

| 工作种类 | 典型 | AI 目前稳定性 | 隐蔽 bug 主要从哪漏 | **加力点（顺序）** |
|---|---|---|---|---|
| **GREENFIELD 全新功能** | 新模块、新接口、新存储 | 设计和实现通常够用 | 需求没说清、状态机自相矛盾 | 需求/设计人工确认；实现按契约做 |
| **LEGACY_EXTENSION 旧系统扩展** | 旧功能加新类型、加分支、改公共分发 | 新路径往往是对的 | **没被改到的旧切面**（重置、限购、补偿、不先查询直接写） | **1. 设计考古 2. 旧行为表征测试（实现前就能跑）3. 按协议走查 4. 人工按协议脚本验收** |

**不要把旧系统扩展的主防线放在「人工总体功能审核」。** 人和 AI 在收尾阶段都会盯 diff / 新代码；旧限购击穿、懒重置不在 diff 里。加时长只会更仔细地看错对象。收尾审核要改的是**审查对象**：按 `04.entryPoints` × **抽到的代表旧 typeKey** 走已有协议，而不是把整个功能再读一遍。

**「列出全部」指 04 声明表，不是每个旧类型一条测试。** `behaviorVariants` 把兄弟键标成 `IDENTICAL_TO_LEGACY` / `INTENTIONAL_DIFF` / `N_A`（或 `excludedWithReason`）是 grep 出来的 JSON 表，几分钟能填。测试与人工协议脚本只抽 **1–2 个共享同一分发的代表旧键**；新类型（`INTENTIONAL_DIFF`）必须有自己的 FUNCTIONAL Case。有独立配置或独立分支的旧键，只对那一子集再各抽 1 个，不要把 20 个同质 enum 常量复制成 20 条 Case。

**「协议脚本」不是新写协议。** 不要为此验收去加客户端包。脚本 = 按固定顺序调用 `04.entryPoints` 里**已经存在**的正式入口（QUERY/INFO、MUTATE/买、RESET 触发）。项目提供的辅助工具只用于 Arrange/Observe（准备数据、调整时间、观察存储），Act 使用正式业务入口。完整步骤见 `SUPERPOWERS_MANUAL.md` 模板 11b。

**「先锁旧限购/重置，再提交新类型代码」锁的是共享分发，不是旧功能清单。** 新类型自己的缺陷用 FUNCTIONAL（可 TDD、可先红后绿）抓。旧类型表征 Case 是共享 dispatcher / 重置 / 限购 /「不先查直接写」上的金丝雀：不改旧 Case 正文，只换/绑一个已有 `typeKey`。线上事故往往是「以为加键不影响旧类型」，表征测的就是这个假设。顺序：先在**当前基线**跑绿（锁的是已有行为），再提交新类型代码，改完还得绿。这不是否认新类型也会写错。

**LEGACY_EXTENSION 的强制顺序（与 GREENFIELD 不同）**：

1. **头脑风暴先考古，再谈新方案。** 前三问必须是：相关**已有**公共入口有哪些（QUERY/MUTATE/RESET/COMPENSATE）？已有哪些类型/策略键、哪些必须 `IDENTICAL_TO_LEGACY`？限购/计数/跨天是否会在「不先查询、直接写」时自愈？不要先讨论新类型怎么做酷。
2. **设计阶段产出 `04_change_impact.json`（8 切面 + 已有全入口 + 兄弟键声明表），与 `06` 一起进人工确认。** 旧切面没列进 04，后面的实现、测试、审查都不会去打。这是旧系统扩展**唯一最值钱的人工确认**（比收尾看代码更值钱）。没有这张表，不准开始画新类型主路径。
3. **表征测试锁旧行为，且必须在改生产代码之前就能在当前基线上跑绿。** 这是对「不前置完整测试计划」的**唯一例外**：抽 1–2 个 `IDENTICAL_TO_LEGACY` 代表（正式协议 Act、冷重载、含 bypass QUERY）。描述的是**现在已有**的行为，不依赖尚未实现的新类型。先红后绿是针对新类型；旧限购/重置是金样，先绿再改，改完还得绿。复杂联调环境的噪音会掩盖限购击穿；隔离的表征 Case 不会。
4. **实现与内审按协议走（Mode E），禁止只审新改的几行。** 走查绑代表旧键 + 全部新键，不必对每个同质旧键各走一遍。
5. **人工总体功能审核 = 执行协议脚本，不是加一轮代码阅读。** 对人：用模板 11b，对抽到的代表旧类型走「满额 → 跨周期 → 不先查直接写 → 冷重载看次数」。对 AI 收尾：`requesting-code-review` / 全功能审计必须带协议追踪表；禁止只交 class/diff 报告。

GREENFIELD 仍保持：设计确认后测试计划不构成第三门禁，具体新功能 TC 可在 TDD 中产出。

**人工时间怎么花（旧系统扩展）**：设计确认 `04` 已有协议清单、8 切表、兄弟键声明 > 看表征 Case 是否打到代表旧类型 > 按脚本点协议。不要把同等时间花在读 Helper 新分支、为每个同质旧类型复制 Case，或「整体再审一遍」。

## 人工 review 阶段

需求与设计是人工把关阶段，而非单条消息的批准。需求可多轮问题/备选/分段 review，产出 `01_server_rules.md`，等明确批准；设计可多轮架构/兼容/协议/持久化/可测性 review，产出 `06_design_contract.md`，等明确批准。批准后自动连续完成计划/实现/review/测试/修复/回归。除非需求/设计变模糊或环境阻塞，否则**不要增设实现计划、代码 review 或测试结果的批准检查点**。

**T3 小改动合并呈递豁免（一口令两道 SHA）**：当同时满足以下条件时：
① 用户显式要求“合并确认/一次确认”；
② 变更范围小（新增/调整设计契约 ≤ 3 条 DC 且无存储迁移）；
AI 可在一次响应内同时呈递 `01_server_rules.md` 与 `06_design_contract.md`。用户回复单次“确认”后，AI **分别调用两次 Approve**（写入 requirement 与 design 的独立 SHA 门禁记录）。保持“两道门禁状态不漏”，消除“两次等待交互”。

**技术契约调整单门禁模式（`gateMode: "DESIGN_ONLY"`）**：人工选择 T3、需求方向已定且仅调整协议/存储/技术契约时（如 `SUPERPOWERS_MANUAL.md` 模板 5 显式选择 T3），可在 `00_workflow_state.json` 中声明 `gateMode: "DESIGN_ONLY"`（或调 `InitApproval -GateMode DESIGN_ONLY`）。该模式下仅需通过 06 设计门禁（`Approve -Gate design`），01 需求门禁自动豁免放行；模板 5 默认 T2 时不适用本模式，不因技术契约调整自动升级。

**人机交互提问节奏（统一口径）**：brainstorming/澄清阶段，AI **每轮最多问 3 个聚焦问题**，每个问题聚焦单一决策点，允许用户一句话给齐；对有意义的备选给出 2-4 选项并推荐其一（做选择题而非填空题）。本口径为本文件定义，adapter/VERIFICATION 等文档统一引用。

**人工确认自然语言容差**：用户回复“确认/批准/同意/LGTM/Proceed/通过/没问题/可以/按这个搞/OK 写吧/没意见/冲”且**不带修改建议**→触发 Approve 写入门禁。用户回复含“但是/修改/调整/不对/改下”等转向词→**不写 Approve**，先修正文档再次呈递，严禁提前写入。模糊回复（“行”“先这样吧”）→ AI 须追问“这是否为最终确认？有无修改建议？”确认后再写。

**澄清不是批准**：brainstorming 的逐一提问是**澄清，不是批准**。每轮问题下标注：“这是澄清，不是批准。批准词：确认/LGTM。”只有 `01`/`06` 正式呈递时才用固定块：`【待批准：requirement|design】回复“确认”写入门禁。`

**Brainstorm 草稿（跨工具热切换）**：brainstorming 阶段，AI 每轮将阶段性技术选型共识摘要追加至 `.ai-workspace/specs/features/<Feature>/00_brainstorm_scratchpad.md`。新工具切入时优先加载该草稿，实现“零认知损失”热切换——新工具知道前一会话排除了哪些方案，无需重新讨论。

## 全功能审计（手动，人工把关）

主流程审查分两层（职责不重叠）：单任务内审（subagent 内 `implementation-auditor`/`logic-auditor`）、整体收尾（`requesting-code-review`）。复杂大功能交付后可**手动触发全功能审计**。

**旧系统扩展的全功能审计 / 人工总体审核不得按类或按版本 diff 起审。** 必须按协议：读取 `04.entryPoints` 与 `behaviorVariants`，对每个 `IDENTICAL_TO_LEGACY` 的 `typeKey` 走 QUERY/MUTATE（含不先查询直接写）、RESET、COMPENSATE。这是人工总体审核的正确形态——力度来自脚本穷尽，不是来自多花时间看新代码。`workflow-orchestrator` 在存在 `04_change_impact.json` 且含类型/策略扩展时，默认派 **Protocol Trace / Mode E**，禁止只带 `focus_methods` 或 revision diff。详见 `.ai-sop/SUPERPOWERS_MANUAL.md`。

## AUDIT-EXEMPT（审计例外声明）

工程实践存在"规则上不通过但有意允许"的反模式。这类有意例外在 `01`/`06` 条款行标 `[AUDIT-EXEMPT: 原因]`，**必须经人工确认**（随文档进门禁，不允许事后补）。审计见该声明对命中项降为 `INFO` 不阻断。

## 规范功能产物

使用 `.ai-workspace/specs/features/<FeatureName>/`：`01_server_rules.md`（需求，含 BR/EX/AC）、`04_change_impact.json`（行为影响；类型/策略扩展时含 8 切面完成度）、`05_test_plan.md`（测试用例，含 TC）、`05_test_coverage.json`（机器可读追溯）、`06_design_contract.md`（设计，含 DC/DR/TW）、`07_design_review.md`（design-reviewer 结论，T3 Complete 必读，须含与当前 06 一致的 `审查对象 sha256`）、任务验证记录（由 Task Run 自动生成；功能级 compile-evidence.json/test-evidence.json 仅用于旧流程兼容）。遵循 `.ai-sop/workflows/shared-artifacts.md`。Superpowers 常规 plan/ledger 文件是执行产物，不得替代规范功能契约。

**05_test_coverage.json 自动生成（SyncCoverage）**：`05_test_plan.md` 的 TC 块用 HTML 注释元数据标记：`<!-- meta: { "id": "TC-XX", "title": "...", "covers": ["BR-XX", "DC-XX"], "priority": "P1", "carrier": "test/Foo.java#testBar" } -->`。也可在 meta 后写 Given/When/Then（或前置/触发/断言）列表与 `载体:` 行，`SyncCoverage` 会填进 setup/trigger/assertions/automationCarrier。运行 `workflow-state.ps1 -Operation SyncCoverage -Path .../05_test_coverage.json` 后看 `INFERRED:` / `MISSING:` 清单；禁止把 `__TODO__` 骨架留到 VERIFY。**禁止手写 coverage JSON**——用 SyncCoverage 生成后再细化。

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
| INV | Invariant（行为不变量，类型扩展必填） | 04_change_impact + 05_test_coverage |

## 领域专家 Skills（执行单元，强制绑定项目专家）

领域专家 Skill 是 Superpowers 的**执行单元**（subagent 派发）与**咨询/校验组件**，不是流程节点。派发实现者与审查者时，**必须使用本项目专家 Skill，禁止用 general-purpose 或 Superpowers 默认 agent**（缺少宿主 context 注入的强制规则与领域缺陷库）：

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
| **全档禁用** | `dispatching-parallel-agents`、`using-git-worktrees`、`executing-plans`、`finishing-a-development-branch` | 由宿主版本控制约定与 SOP 编排统一管理 |

**审查必须独立上下文**：审查者（`design-reviewer`/`implementation-auditor`/`logic-auditor`/`requesting-code-review`）必须用独立 subagent 上下文，不能用同一会话自审（共享盲区）。**允许用宿主 subagent 机制加载本项目专家 Skill 提示词**（如 Copilot 的 `Task` 工具加载 `implementation-engine` 提示词）——禁的是“同上下文自审”，不是“用宿主 subagent 载入”。

**审查铁律（仅 T3 严格适用）**：每个 Task **先编译通过再内审**。顺序：`implementation-engine` 交【编译证据】（`command` + `exitCode=0` + 成功摘录）→ 才派 `implementation-auditor` / `logic-auditor` → spec 合规审查 → 代码质量审查（顺序不可颠倒）→ 修复回派实现者并再编译 → 重新审查 → 通过才标记该 Task 完成。engine 未返回或无编译证据时**禁止**派审计官，禁止与实现者并行派审，禁止一条 prompt 打包多个 Task 后立刻审。controller / 编排会话**不得自己改生产代码或测试源**（编译失败或审计要修一律回派 `implementation-engine` `REPAIR`）。生产代码再改后，先前内审 PASS 作废，必须再编译再审。同文件修改绝不并行派多个实现者。T3 绝不跳过独立审查（哪怕 1 行）。最终审查 `requesting-code-review` 独立于 subagent 内审，禁止跳过，也**不能**替代被作废的任务内审。T2 完成相关规格/用例同步与编译/测试，不要求独立审核节点。

**子代理进度可见（覆盖 Superpowers SDD）**：原生 SDD「不要向人汇报进度」**对本项目不生效**。每个独立 subagent 返回后、下一串工具或下一个 subagent 之前，controller 必须先向用户输出 1–3 行可见进度（谁完成、结论、下一步）。长编译/测试开始前同样先报。禁止子代理已结束后静默连跑，导致主窗口像卡死。状态行不能替代本条。详见 `superpowers-adapter.md`「人机交互」。

**模型分级调度**：派发 subagent 时按角色复杂度选档（最强/标准/便宜），显式指定 model 不省略。`design-architect`/`design-reviewer`/`requesting-code-review`/`logic-auditor` 用最强档；一般实现/合规/`requirement-analyst` 用标准档；机械转录/单文件小修/配置改动用便宜档。修复循环 R4-5 升一档。详见 `.ai-sop/workflows/superpowers-adapter.md`。

被调用时：使用专家的领域 checklist 与交付格式，把发现返回给 Superpowers controller，**不接管编排、不写 `.ai-sop/runtime/`**。

**专家 Skill 自包含**：实现者/审查员只遵守 `.ai-sop/skills/<role>/SKILL.md`。**不要**去读 Superpowers 插件里的 `implementer-prompt.md`、`task-reviewer-prompt.md`、`code-reviewer.md` 等（那是流程编排/派发模板，与专家 overlay 冲突）。T3 由 controller 用 Skill 工具显式调用 Superpowers 流程 skill。Controller 派发 subagent 时必须在 prompt 首行指定专家 Skill 路径，并附【默认工程规范】（见 `.ai-sop/workflows/superpowers-adapter.md` 派发契约）。

## 完成验收

新任务通过 Task Run 采集真实编译/测试结果，T3 测试批次带实际覆盖的 CaseIds（或使用本次 JUnitReports + CaseMap 映射），不能用文字摘录或旧功能级证据替代。Task Complete 内含 VerifyCompletion -TaskId；它核对当前批准与规格哈希、07 设计审查、覆盖定义、本次必测用例、适用的 04 绑定及执行证据。下面是核对清单，不要求把所有诊断命令再串行执行一遍。

**T3 完成清单（机器检查批准、设计审查、覆盖/影响绑定和执行记录；独立内审结论及验证范围仍需如实自报，机器不读 08/09）**：

| # | 条件 | 验证命令 | 成功输出 | 失败恢复 |
|---|---|---|---|---|
| 1 | 需求与设计已确认 | `workflow-state.ps1 -Operation Status -Path .../00_workflow_state.json` | `gate=requirement status=APPROVED` + `gate=design status=APPROVED` + `hashMatch=MATCH` | `ResetApproval` + 修改 + `Approve` |
| 2 | 测试计划与覆盖矩阵已创建/更新 | `workflow-state.ps1 -Operation ValidateTestCoverage -Path .../05_test_coverage.json` | `VALID` | 补 05_test_plan.md + 05_test_coverage.json |
| 3 | 代码编译通过 | Task Run -Kind compile | 当前输入下真实成功 | 修复后重新执行编译 |
| 4 | 必要全局审计与逻辑审计通过 | `implementation-auditor` + `logic-auditor` 报告 PASS | **AI 据独立 subagent 报告自报**（`VerifyCompletion` 不读 08/09） | 修复发现 + 重审 |
| 5 | 目标自动化场景通过 | Task Run 执行相关项目测试，绑定本次必测 CaseIds | 当前输入下成功且用例范围满足要求；不夸大覆盖 | 修测试 + 重跑 |
| 6 | 中途失败已修复、复审和回归 | 检查无未解决发现 | 无未解决发现 | 补修复 + 回归 |

修改 SOP 脚本本身仍须执行仓库要求的全量套件；普通宿主功能按本次目标运行相关项目测试，不将引擎自身的回归套件当成业务验收。
