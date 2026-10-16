# 项目 Agent 指令（公共真源）

> 各 AI 工具（Claude Code / GitHub Copilot / Antigravity / Cursor / Codex / Pi）统一加载本文件作为项目指令。工具专属差异见各自的根 md（如 CLAUDE.md）。本文件是单一真源，勿在其它文件重复维护。

> **能力分流提示**：若当前工具能力准入为 BLOCKED（见末节“能力准入”），支持 T1/T2——你无需读 T3/brainstorming/design-reviewer/subagent 等节，直接看“执行强度分层（T 档）”的 T2 + 末节能力准入即可。STRICT 工具（Claude Code / Antigravity / Cursor / Copilot / Codex）可跑 T3 完整流程。

## 修改任务入口（优先于下文旧功能级命令）

每次代码修改先运行 `pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Discover`，区分独立修改、继续原任务和补收尾。仅讨论不认领；有多个候选才询问一次。用户不需要说固定接管口令。

- 新修改：`ai-sop.ps1 Task -Operation Start -Feature <功能> -TaskId <唯一任务名> -Tier <T1|T2|T3> -Objective "本次目标" -Agent <工具>`。
- 续做：`ai-sop.ps1 Task -Operation Resume -Feature <功能> -TaskId <原任务> -Agent <工具>`。旧 ACTIVE owner 尚无任务记录时省略 TaskId，显式 Resume 收编，保留原 ownerId 和批准；若历史档位不明确，先确认，禁止凭空按 T2 收编。
- 每阶段用 `Checkpoint -NextAction ... -Notes ...` 写下一步；失败/环境阻塞用 `Suspend`，不假装 DONE；独立后续任务可 Start。暂停前应说明未提交修改和依赖。
- 编译/测试通过 `Run -Kind compile|test -Batch <批次> -Executable <程序> -Arguments <参数数组>` 采集真实结果；T3 测试带 `-CaseIds` 映射本次运行覆盖的用例。运行命令必须是实际构建/测试，不能用空命令或固定 exit 0 伪造成功。
- 收尾调用 `Verify` 一次列齐缺项，再 `Complete`；T3 继续执行需求设计、审查、覆盖定义等完整步骤。需要 04 时，先核查其语义覆盖当前改动，再 `ReviewImpact` 记录分析哈希与输入指纹。
- `TaskId` 是一次独立修改，SDD 计划中的 Task/Step 是该修改内部的执行单元。T1/T2 不额外写整套计划文档。

**执行强度属于本次任务。** 用户明确指定 T1/T2 时保留该档位，不因功能有旧 01/06/04 或旧失败记录自动升 T3。风险扫描提供具体建议；发现范围超出原任务时及时说明，不能到收尾才强加完整流程。未指定强度一律默认 T2；T1/T3 由用户选择。Agent 判断影响范围并提出具体建议，不自行升降档，也不因协议、存储或风险关键词要求重复确认。旧功能级校验只供兼容恢复，新修改必须使用 Task 入口。

**状态与异常恢复**：`ai-sop.ps1 Status -Feature <功能>` 与 Task Status 使用同一任务状态，Discover 用于快速发现。缺本地归属或异常中断时先检查 Status，再 Recover → Resume；原会话仍活跃时先确认旧 Agent 已停止，再使用 ForceRecovery 并记录 Notes。检测到本机验证进程仍运行时不可接管。旧 ForceRelease 也同步暂停任务，不代表验收通过。

**验证命令配置**：常用编译/测试命令可配置在 `.ai-workspace/context/verification-commands.json`，使用 `Run -Profile <名称>`；配置属于宿主上下文，不写入核心引擎。Run 会先记 RUNNING，再持续输出日志；超时/失败/中断不能复用更早成功结果。Status 的执行证据结果和已记录批准不替代完整 T3 Verify。

**任务诊断与证据同步**：Start 只创建新 TaskId，已有任务用 Resume，独立新目标不要复用旧身份。Status/Discover 默认简明文本与未完成/有待同步项任务；`-IncludeHistory` 查看历史，自动化使用 `-Json` 的版本化 tasks/warnings 数组；兼容旧逐行输出用 `-OutputFormat JsonLines`。可在 `.ai-workspace/context/verification-inputs.json` 补充真实输入或带理由排除生成目录，不得随意排除共享源码来消除过期证据。新输入清单在 `.ai-workspace/specs/.artifacts/inputs/` 去重保存，必须随规格 Git 同步；本地 `.ai-workspace/.runtime/verification/` 日志无需同步。出现清单缺失/损坏先补同步或重跑，禁止改写成功摘要。投影/引擎部署版本提醒用安装器和 Doctor 处理，不自动升级任务档位。

**可选只读排查**：`ai-sop.ps1 Inputs -InputPath <宿主相对路径>` 解释真实输入规则与扫描开销；`-CandidatePolicy <候选JSON相对路径>` 预览范围差异，不覆盖正式配置。`ai-sop.ps1 Preflight -Feature <Feature> -TaskId <taskId>` 检查交接记录、引用清单和本机执行状态，`-TargetEnginePath <候选引擎目录>` 比较升级兼容性；二者支持 `-Json`。Preflight 按嵌套 Git 实际归属提示同步，不运行源码扫描、事务恢复或归属写入。缺目标声明只报告 UNKNOWN；输出不是完成证据或发布认证。只在排查、交接或升级时按需使用，不增加 T1/T2 必经步骤。命令与边界见操作手册。

**任务完成条件**：T1 真实编译/基础检查成功，报告未测试范围；T2 编译与相关测试成功，并用 RecordSync 记录受影响需求、设计与测试的同步结果；T3 完整规格和审查门禁加当前任务证据。T1/T2 无独立代码审核环节。测试环境失败可以暂停交接，不能写成通过。本次任务 DONE 不代表旧 T3 或整个功能已全面验收。

**启动起点**：先 Start 再修改。startInputs 与任务创建事务一起记录，Resume/Run 不重新采集。T1/T2 默认尝试 500ms/8MiB 预算的内容采集，超限/失败记 UNAVAILABLE，不阻塞普通编译/相关测试；预期申请“不适用”或之后升 T3 时，可在修改前 Start -CaptureBaseline 完整采集，档位不变。起点和引用清单随规格同步。不要用修改后的快照补造起点。

Start 会直接反馈 TASK_START_INPUTS 状态与不可用原因，不用再跑 Status 才知起点结果。Status/Discover 对 DONE/CANCELLED 默认显示 HISTORICAL_NOT_RECHECKED，终态和待同步项独立保留，不因后续改动要求旧任务重跑；显式 Status -RecheckHistory 才检查所选历史任务的证据是否适用于当前输入，检查不重开任务。

**T3 任务范围**：Start 固定修改前内容基线，功能长期批准基线独立保留。用 `Task Changes` 读取本次新增/修改/删除范围；需要 04 时，taskId、baseline、baselineInputDigest、changedFiles、changeSetDigest 必须匹配该范围，ReviewImpact 保存的 `.ai-workspace/specs/.artifacts/changes/` 清单随 specs 同步。用 `SetCaseScope -CaseIds ... -Reason ...` 登记本次必测用例，包含 04 的 requiredRegressionCases；规格变化后重新核对。其他未开发用例不强制本次执行，整体规格覆盖定义仍检查。ChangeTier/SetBaseline 只接受本任务 Start 已记录的起点；缺起点拒绝升级并保留原档位，不能用后续 Run 清单或理由替代。旧 T3 source=START 基线兼容，旧手工 ADOPTED 无起点证明则诊断；历史 DONE 不迁移。T1/T2 不新增上述范围登记。可选 JUnitReports + CaseMap 从本次 JUnit XML 映射结果，不能用旧/跳过/失败报告充当通过。

**损坏结果恢复**：InspectRecovery 只读定位 task/owner/session/待入账结果问题。待入账结果损坏且原执行已停止时，可显式 Recover -QuarantineInvalidEvidence -Reason，先保存原字节再以事务记中断，Resume 后重跑；本地备份在 `.ai-workspace/.runtime/quarantine/`。损坏权限记录不能删除后猜测重建，须可信备份或事务恢复。

**并行边界**：不同功能使用独立工作区和测试数据；同功能多独立主会话并行暂不支持，可由一个主 Agent 协调辅助工作。无跨机器分布式锁，不保证发现未同步的远端会话。Session/Grant/本地 owner 不随 Git 变成新工作区权限。跨工作区先 Suspend、保存规格/任务及相同代码，再在新工作区 Resume；合并结果重新验证。

完整命令及边界见 `.ai-sop/workflows/shared-artifacts.md` 和 `.ai-sop/docs/QUALITY_GATES.md`。以下 `workflow-owner.ps1 -Operation Claim/Complete` 等为旧兼容入口，新修改优先使用 Task，避免重用功能级执行状态。

## 工作流归属

**Superpowers 是本项目的唯一顶层开发调度器（T3）；T2/T1用本文件 + 专家 Skills，不调用 Superpowers。**

完整开发任务从 Superpowers `brainstorming` 开始，按 `.ai-sop/workflows/superpowers-adapter.md` 执行。Superpowers 技能必须显式调用，禁止跳过或自行判断"改动太小不需要"：

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

**已批准文档的版本边界**：T1 延期同步时记录具体待办；T2 修改已批准语义时先 ResetApproval，使旧批准不再代表新文档，随后记录本次用户需求依据并完成同步，不要求补完整 T3 批准。下次相关 T3 验收再确认当前版本。纯文字润色沿用下条规则。**T3 的重新确认要求**：`01` / `06` 经人工确认后，任何**改变业务逻辑/契约语义**的修改（包括 design-reviewer 闭环修正、字段取值规则调整、实现期可测性回写、补 DC/DR/TW 条款等）都**必须先 `workflow-state.ps1 -Operation ResetApproval -Gate <requirement|design>` 作废当前批准**，修改后重新走确认 + Approve。`ResetApproval -Gate requirement` 同时重置 design 门禁（需求变了设计也得重审）。

**纯文本润色豁免（UpdateHash，不作废批准）**：仅修改错别字、标点、格式、措辞等**不改变业务逻辑/契约语义**的内容时，用 `workflow-state.ps1 -Operation UpdateHash -Gate <requirement|design>` 只更新哈希值而不作废 APPROVED 状态，避免一个小错别字雪崩回需求评审。UpdateHash 须在 commit message 注明“纯文本润色，不改语义”。AI 判断不准是否纯润色时使用 ResetApproval；T2 记录变化依据，T3 重新确认，不滥用 UpdateHash。

**T3 按需调用（下列复现和审查流程不强加给 T1/T2）**：
- `superpowers:systematic-debugging` — bug 与异常行为，**不要自己猜根因**。**排查前先复现 bug**：优先路径 A（JUnit/JVM 内）快速复现；若必须走路径 B（JSP 业务验证）则接受其成本。**确认问题真实存在后再排查根因**。判责走 `implementation-engine` 的 TRIAGE Judge，须判到 4 类之一：`[IMPL_FAILURE]` 实现缺陷→修代码；`[DESIGN_FLAW]` 设计缺陷→改需求/设计不修代码；`[TEST_ERROR]`/`[INVALID]` 测试错/误报→不改服务端只输出证据；`[CLIENT_ISSUE]` 客户端问题→不改服务端。**判责结论必须附复现证据（硬约束）**：下结论前先跑复现测试，结论附测试输出。修复 3 次仍未通过复现，**停止改代码**——回头重新复现、重新判责、查是否 `[DESIGN_FLAW]`，不堆砌投机修复掩盖症状。
- `superpowers:receiving-code-review` — 接收审查结果

**不适用本项目**（黑名单，禁用原因见注释）：
- `superpowers:dispatching-parallel-agents` — 并行开发走 `.ai-workspace/workflows/parallel-development.md` + `feature-runtime.ps1`
- `superpowers:using-git-worktrees` — 代码隔离用 **SVN 分支**（不是 Git worktree）。运行时隔离用 `feature-runtime.ps1`。**本项目要求在带 `.svn` 的 SVN 工作副本里开发并 `svn commit` 交付**——`svn add`/`svn delete`/`svn commit`/`svn merge` 都依赖 `.svn` 元数据，Git worktree 里没有 `.svn`，这些命令跑不通。**Copilot App 若默认在 worktree 里跑**，要么：① 把该 worktree 做成 SVN 工作副本（`svn checkout` 到该目录）；② 或只在 SVN 工作副本目录开会话。禁止用文件复制覆盖回主目录（会静默回退他人代码）。Owner 校验绑工作区物理路径——Claim 时以实际开发的目录为工作区。
- `superpowers:executing-plans` — 触发 `using-git-worktrees`（冲突）；有 subagent 时统一用 `subagent-driven-development`
- `superpowers:finishing-a-development-branch` — 本项目交付走 SVN，不用 git merge/PR 收尾

**Skill 分级见下文三列表**（T3 必调 / T3 按需 / 全档禁用）。上表仅 T3 编排顺序。

**关于 Superpowers**：Superpowers 是一个流程技能包，提供 brainstorming/writing-plans/subagent-driven-development 等流程技能。**T2/T1 完全不依赖 Superpowers**——这些档位直接用原生提示词 + 本项目专家 Skills 或单轮上下文推进，严禁报错停机。只有 T3 完整流程才需要 Superpowers。若 T3 所需的 Superpowers 技能不可用，**停止并明确告知用户**：“T3 完整流程需要 Superpowers 技能包。请按 `.ai-sop/SUPERPOWERS_VERIFICATION.md` 安装/激活，或降级为 T2 快速修改。”——不要静默切换、不要假装在跑。

## 执行强度分层（T 档）

**档位表示本次任务的交付流程强度，风险分析不决定档位。** 默认 T2，人工显式选择优先；接管继承原档位，独立新任务重新使用默认值或用户选择。

**执行与交接完整性**：Run 同批次保持命令、Profile 和 CaseIds 范围；确需替换时写 Reason，不能用无关成功命令覆盖失败。Run 自动续期原会话，保存失败留下 `<runId>.pending.json`，用 RetryEvidence 重试入账；会话结束后待进程停止再 Recover/Resume，不盲目重跑或修改旧成功哈希。跨仍标记 ACTIVE/IDLE 的会话接管需 ConfirmTakeover；用户已明确要求切换且旧 Agent 已停止时直接使用，不重复请求确认。Task 可从唯一的原生会话环境推断 Agent，否则显式传 Agent；通用 CLI 以稳定 AI_SESSION_ID 标识同一次会话，禁止借用 owner 的会话身份。

| 档位 | 必做工作 | 可省略的流程 |
|---|---|---|
| T1 极速 | 明确修改目标，完成实现，真实编译通过；确有延期事项才记录 FollowUp | 需求设计同步、补充测试、头脑风暴、正式计划、独立审核 |
| T2 快速（默认） | 明确需求和验收点，完成实现，同步受影响的需求/设计/用例，编译与相关测试通过 | 头脑风暴、重复需求设计批准、正式计划、独立审核 |
| T3 完整 | 完整 Superpowers 需求、设计、计划、实现、审核与验证流程 | 可复用仍适用于当前版本和范围的已有成果，不重复执行已满足的步骤 |

**T1 的实现边界**：协议源文件、生成代码和使程序生效所必需的配置都属于实现，不能按“文档后补”延期。修复使代码恢复到既有约定时无需修改正确的设计；注释修正也不自动欠设计或测试。真实延期的字段说明、行为规则、用例或验证，分别用 AddFollowUp 记录，禁止仅留在聊天里。

**T2 的轻量闭环**：用户已给出的明确需求可直接作为依据，只澄清关键歧义。按实际影响更新相关条款、设计段落和测试，不强制新增整套 01/06/05 或重复写计划。已有文档仍正确、已有用例覆盖充分时记录 UNCHANGED 及依据。完成前 RecordSync（Documentation=UPDATED/UNCHANGED；Tests=UPDATED/UNCHANGED/NOT_APPLICABLE；Summary=具体同步范围和依据）。机器只校验记录完整，内容正确性由 Agent 核实。相关单元/模拟测试为常规选择，不默认启动完整业务环境；集成验证缺口须如实说明并按任务目标安排。

**人工改档**：任务开始后只能用 ChangeTier，带目标 Tier、Reason 和 UserRequest（人工原话或准确摘录）。用户已经选择 T1/T2 时不再次确认风险。Agent 可以建议额外验证或 T3，但不以建议阻止已明确的任务；实际语义不明或范围超出授权时询问具体问题。ChangeTier 保留全部历史验证、批准与待办，不把失败改成通过；Resume 不接受顺便改档。

**待同步提醒（非门禁）**：AddFollowUp 在来源任务中记录 documentation / test-cases / verification，含稳定 ID、具体 Summary 和 Scope。没有实际延期就不创建。Start/Resume 自动检查：同功能列详细事项，其他功能仅显示当前工作区待办数量；提醒后继续，不要求确认、不自动扩展范围、不因待办升档或阻止完成。每次启动/接管提示一次，执行中不重复催办。用户暂不处理时保留 PENDING；实际完成用 CloseFollowUp 记 RESOLVED、具体 Resolution 和处理任务；人工明确无需处理时记 NOT_NEEDED、原因和 UserRequest。旧任务 DONE 不会隐藏待办，新 T2 完成也不会自动清除旧待办。只在当前工作区可见，跨工作区须同步规格仓库。

**适用性**：只保留三个新任务档位。纯文档等任务仍用 T1/T2；SetApplicability 的 NOT_APPLICABLE 绑定本任务 startInputsRef 和当前输入，并在声明/Verify 时核对所有输入增删改仅限项目在 Start 前声明的 nonExecutable 路径，策略未变。该声明是 verification-inputs.json 的可选路径/理由列表，文件仍进入指纹；不能为跳过检查将源码或构建输入伪装成非执行输入。起点未知或旧豁免未绑定时改回 REQUIRED 并正常验证，不因此升档。RecordSync 的 Tests=NOT_APPLICABLE 仅说明用例同步，不自动豁免测试执行。源码注释修改仍默认编译；配置修改需判断真实影响。环境故障、缺少测试或测试失败不能冒充“不适用”，不能用空命令伪造 PASS。T3 不使用轻量豁免。FAST_TRACK 只读兼容历史任务，不创建第四档新任务。

**工具能力**：T1/T2 不依赖 Superpowers 或独立 subagent。用户选 T3 但环境缺能力时说明缺口，由用户选择更换工具或改档，不自动降档、不因“协议/设计”等词拦截默认 T2。

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

游戏服务端（以及任何有状态线上系统）的 T3 不要平均加力。按工作种类把力气放在不同阶段：

| 工作种类 | 典型 | AI 目前稳定性 | 隐蔽 bug 主要从哪漏 | **加力点（顺序）** |
|---|---|---|---|---|
| **GREENFIELD 全新功能** | 新玩法、新协议、新存储 | 设计和实现通常够用 | 需求没说清、状态机自相矛盾 | 需求/设计人工确认；实现按契约做 |
| **LEGACY_EXTENSION 旧系统扩展** | 旧功能加新类型、加分支、改公共分发 | 新路径往往是对的 | **没被改到的旧切面**（重置、限购、补偿、不先查询直接写） | **1. 设计考古 2. 旧行为表征测试（实现前就能跑）3. 按协议走查 4. 人工按协议脚本验收** |

**不要把旧系统扩展的主防线放在「人工总体功能审核」。** 人和 AI 在收尾阶段都会盯 diff / 新代码；旧限购击穿、懒重置不在 diff 里。加时长只会更仔细地看错对象。收尾审核要改的是**审查对象**：按 `04.entryPoints` × **抽到的代表旧 typeKey** 走已有协议，而不是把整个功能再读一遍。

**「列出全部」指 04 声明表，不是每个旧类型一条测试。** `behaviorVariants` 把兄弟键标成 `IDENTICAL_TO_LEGACY` / `INTENTIONAL_DIFF` / `N_A`（或 `excludedWithReason`）是 grep 出来的 JSON 表，几分钟能填。测试与人工协议脚本只抽 **1–2 个共享同一分发的代表旧键**；新类型（`INTENTIONAL_DIFF`）必须有自己的 FUNCTIONAL Case。有独立配置或独立分支的旧键，只对那一子集再各抽 1 个，不要把 20 个同质 enum 常量复制成 20 条 Case。

**「协议脚本」不是新写协议。** 不要为此验收去加客户端包。脚本 = 按固定顺序调用 `04.entryPoints` 里**已经存在**的正式入口（QUERY/INFO、MUTATE/买、RESET 触发）。GM 只许 Arrange/Observe（造满额、拨时间、查库），不许当买入 Act。完整步骤见 `SUPERPOWERS_MANUAL.md` 模板 11b。

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

**技术契约调整单门禁模式（`gateMode: "DESIGN_ONLY"`）**：需求方向已定、仅调整协议/存储/技术契约的中型任务（即 `SUPERPOWERS_MANUAL.md` 模板 5），可在 `00_workflow_state.json` 中声明 `gateMode: "DESIGN_ONLY"`（或调 `InitApproval -GateMode DESIGN_ONLY`）。该模式下仅需通过 06 设计门禁（`Approve -Gate design`），01 需求门禁自动豁免放行，不走双门禁也不降级 T2。

**人机交互提问节奏（统一口径）**：brainstorming/澄清阶段，AI **每轮最多问 3 个聚焦问题**，每个问题聚焦单一决策点，允许用户一句话给齐；对有意义的备选给出 2-4 选项并推荐其一（做选择题而非填空题）。本口径为本文件定义，adapter/VERIFICATION 等文档统一引用。

**人工确认自然语言容差**：用户回复“确认/批准/同意/LGTM/Proceed/通过/没问题/可以/按这个搞/OK 写吧/没意见/冲”且**不带修改建议**→触发 Approve 写入门禁。用户回复含“但是/修改/调整/不对/改下”等转向词→**不写 Approve**，先修正文档再次呈递，严禁提前写入。模糊回复（“行”“先这样吧”）→ AI 须追问“这是否为最终确认？有无修改建议？”确认后再写。

**澄清不是批准**：brainstorming 的逐一提问是**澄清，不是批准**。每轮问题下标注：“这是澄清，不是批准。批准词：确认/LGTM。”只有 `01`/`06` 正式呈递时才用固定块：`【待批准：requirement|design】回复“确认”写入门禁。`

**Brainstorm 草稿（跨工具热切换）**：brainstorming 阶段，AI 每轮将阶段性技术选型共识摘要追加至 `.ai-workspace/specs/features/<Feature>/00_brainstorm_scratchpad.md`。新工具切入时优先加载该草稿，实现“零认知损失”热切换——新工具知道前一会话排除了哪些方案，无需重新讨论。

## 全功能审计（手动，人工把关）

主流程审查分两层（职责不重叠）：单任务内审（subagent 内 `implementation-auditor`/`logic-auditor`）、整体收尾（`requesting-code-review`）。复杂大功能交付后可**手动触发全功能审计**。

**旧系统扩展的全功能审计 / 人工总体审核不得按类或按版本 diff 起审。** 必须按协议：读取 `04.entryPoints` 与 `behaviorVariants`，对每个 `IDENTICAL_TO_LEGACY` 的 `typeKey` 走 QUERY/MUTATE（含不先查询直接写）、RESET、COMPENSATE。这是人工总体审核的正确形态——力度来自脚本穷尽，不是来自多花时间看新代码。`workflow-orchestrator` 在存在 `04_change_impact.json` 且含类型/策略扩展时，默认派 **Protocol Trace / Mode E**，禁止只带 `focus_methods` 或 revision diff。详见 `.ai-sop/SUPERPOWERS_MANUAL.md`。

## AUDIT-EXEMPT（审计例外声明）

工程实践存在"规则上不通过但有意允许"的反模式。这类有意例外在 `01`/`06` 条款行标 `[AUDIT-EXEMPT: 原因]`，**必须经人工确认**（随文档进门禁，不允许事后补）。审计见该声明对命中项降为 `INFO` 不阻断。

## 共享项目知识

`.ai-workspace/context/` 是所有 Agent 共享的、流程无关的项目知识。

始终阅读：`project-summary.md`、`coding-style.md`、`business-logic-pattern.md`、`project-tooling.md`。
按需阅读：静态配置 `config-rules.md`、协议 `proto-rules.md`、业务测试/JSP/GM `client-test.md`、活动/任务/事件/条件 `business-patterns/`、高风险游戏状态逻辑 `logic-audit-game-server.md`。

**读取前检测存在性**：上述文件在新项目或 fresh clone 后可能尚未创建。AI 读取前须先检测文件是否存在，不存在则跳过该文件并记一条 INFO（不报错、不中断、不幻觉补内容），继续后续流程。

**Context 版本头**：每个 context 文件首行有 `<!-- context-meta owner:X reviewedAt:YYYY-MM expiresAt:YYYY-MM -->`。`doctor.ps1` 检查过期打 WARN。AI 读过期 context 时应提示用户“context 文件 `<file>` 已过期（<expiresAt>），仍以代码为准，建议更新”。

**知识真源位阶**（两套冲突，不要混成「06 总是大于 context」）：
1. **代码 vs 过期 context**：context 与实际运行代码/现行配置冲突时，以代码为准，提示 context 可能漂移。不得按旧 context 去改已经正确的生产代码。
2. **强制规范 vs 本功能 06**：`.ai-workspace/context/coding-style.md`（协议相关再加 `proto-rules.md`）是项目**默认工程规范**。`06` 只约束本功能方案，**不得违反**其中硬规则。冲突时以强制规范为准，记设计缺陷，`ResetApproval -Gate design`；禁止以「已批契约 / 与 06 一致」结案。经人工确认的 `[AUDIT-EXEMPT]` 除外。

**默认工程规范（设计 / 实现 / 审计）**：`design-architect`、`design-reviewer`、`implementation-engine`、`implementation-auditor`、`logic-auditor` 在开始工作前必须用 Read **打开** `.ai-workspace/context/coding-style.md`（文件存在时），不得只凭 Skill 或 06 的摘要代替原文。无该文件则 INFO 降级，不阻断。Controller 派发这些角色时必须在 prompt 里写上同一句【默认工程规范】（见 adapter）。

**Context 缺失时的降级与反哺**：当核心 context（如 `coding-style.md`）缺失时，AI 应通过直接读取项目现有核心基类（如 `BaseManager`、`GameParam`、`DateUtil`）推断编码风格，不阻断流程；并在任务完成后主动向用户提示：“检测到缺少 `coding-style.md`，是否需要我根据当前项目代码自动生成一份？”

## 项目强制规则

项目编码/架构强制规则统一定义在 `.ai-workspace/context/coding-style.md` 与 `.ai-workspace/context/config-rules.md`，不在本文件重复。上述设计/实现/审计角色以 `coding-style.md` 为默认规范；`06` 不得违反。新增 Redis/Mongo 对象字段的存储键按该文件简写，协议键走 `proto-rules.md`。

## 规范功能产物

使用 `.ai-workspace/specs/features/<FeatureName>/`：`01_server_rules.md`（需求，含 BR/EX/AC）、`04_change_impact.json`（行为影响；类型/策略扩展时含 8 切面完成度）、`05_test_plan.md`（测试用例，含 TC）、`05_test_coverage.json`（机器可读追溯）、`06_design_contract.md`（设计，含 DC/DR/TW）、`07_design_review.md`（design-reviewer 结论，T3 Complete 必读，须含与当前 06 一致的 `审查对象 sha256`）、`compile-evidence.json`（最近一次编译 exitCode=0 且 `workingTreeDigest` 匹配当前工作区）、T2 可选 `test-evidence.json`。遵循 `.ai-sop/workflows/shared-artifacts.md`。Superpowers 常规 plan/ledger 文件是执行产物，不得替代规范功能契约。

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

**审查铁律（仅 T3 严格适用）**：每个 Task **先编译通过再内审**。顺序：`implementation-engine` 交【编译证据】（`command` + `exitCode=0` + 成功摘录）→ 才派 `implementation-auditor` / `logic-auditor` → spec 合规审查 → 代码质量审查（顺序不可颠倒）→ 修复回派实现者并再编译 → 重新审查 → 通过才标记该 Task 完成。engine 未返回或无编译证据时**禁止**派审计官，禁止与实现者并行派审，禁止一条 prompt 打包多个 Task 后立刻审。controller / 编排会话**不得自己改生产代码或测试源**（编译失败或审计要修一律回派 `implementation-engine` `REPAIR`）。生产代码再改后，先前内审 PASS 作废，必须再编译再审。同文件修改绝不并行派多个实现者。T3 绝不跳过独立审查（哪怕 1 行）。最终审查 `requesting-code-review` 独立于 subagent 内审，禁止跳过，也**不能**替代被作废的任务内审。T2 完成相关规格/用例同步与编译/测试，不要求独立审核节点。

**子代理进度可见（覆盖 Superpowers SDD）**：原生 SDD「不要向人汇报进度」**对本项目不生效**。每个独立 subagent 返回后、下一串工具或下一个 subagent 之前，controller 必须先向用户输出 1–3 行可见进度（谁完成、结论、下一步）。长编译/测试开始前同样先报。禁止子代理已结束后静默连跑，导致主窗口像卡死。状态行不能替代本条。详见 `superpowers-adapter.md`「人机交互」。

**模型分级调度**：派发 subagent 时按角色复杂度选档（最强/标准/便宜），显式指定 model 不省略。`design-architect`/`design-reviewer`/`requesting-code-review`/`logic-auditor` 用最强档；一般实现/合规/`requirement-analyst` 用标准档；机械转录/单文件小修/配置改动用便宜档。修复循环 R4-5 升一档。详见 `.ai-sop/workflows/superpowers-adapter.md`。

被调用时：使用专家的领域 checklist 与交付格式，把发现返回给 Superpowers controller，**不接管编排、不写 `.ai-sop/runtime/`**。

**专家 Skill 自包含**：实现者/审查员只遵守 `.ai-sop/skills/<role>/SKILL.md`。**不要**去读 Superpowers 插件里的 `implementer-prompt.md`、`task-reviewer-prompt.md`、`code-reviewer.md` 等（那是流程编排/派发模板，与专家 overlay 冲突）。T3 由 controller 用 Skill 工具显式调用 Superpowers 流程 skill。Controller 派发 subagent 时必须在 prompt 首行指定专家 Skill 路径，并附【默认工程规范】（见 `.ai-sop/workflows/superpowers-adapter.md` 派发契约）。

## 功能归属

**AI 自动执行脚本（非打印给用户）**：本文件及手册中所有 `workflow-state.ps1`/`workflow-owner.ps1`/`feature-runtime.ps1`/`run-all-tests.ps1` 等命令，AI 在确认用户意图后应**直接在后台执行**（经终端工具/Bash），读取输出继续流程，而不是把命令打印出来让用户手动复制粘贴。仅当涉及人工决策（如批准需求/设计）时才暂停问用户；脚本执行本身是 AI 的职责。

**Guard 拦截后的任务识别**：先 `ai-sop.ps1 Task -Operation Discover` 识别功能和任务。独立修改用 Start，继续原任务用 Resume；异常中断先 Status / InspectRecovery，再 Recover → Resume。不要生成临时 ownerId 直接 Claim 来绕过任务入口。已获授权且任务明确时自动继续；存在归属冲突则说明原因，确认旧 Agent 停止后才进行强制恢复，不要求固定接管口令。

新任务由 Task Start 管理归属、基线与 taskId，Task Verify 通过后 Task Complete；中断用 Checkpoint / Suspend。已有功能继续使用原 FeatureName，独立修改创建新 taskId。同功能不并行运行多个主任务。

**旧功能级命令兼容**：下方 Claim / Validate / Complete / Transfer 示例仅用于尚未迁移、没有 taskId 的存量归属；有 taskId 时使用任务入口，不混用完成语义。各 harness 统一 `SUPERPOWERS` 归属（它是身份标识，不代表 T1/T2 依赖完整 Superpowers 流程），`agent` 字段区分实际工具。

**FeatureName 命名规则**：用 PascalCase 英文（`[A-Z][A-Za-z0-9]+`，如 `ShopExchangeBuyLimit`、`DailySignInReward`）。从用户话术提取并回显：“将以 `<FeatureName>` 认领，不对请立刻改名”。目录不存在则建。T2 小改也需 feature 名（热修用 `HotfixShopLimit20260821`，无连字符）。已有功能继续使用原 FeatureName，新建独立 taskId；历史 01/06 不改变任务档位。

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-owner.ps1 -Operation Claim `
  -SpecDirectory ".ai-workspace\specs\features\<FeatureName>" `
  -Feature "<FeatureName>" -Workflow SUPERPOWERS `
  -Agent "<CLAUDE_CODE|COPILOT|ANTIGRAVITY|CURSOR|CODEX|PI>" `
  -OwnerId "<superpowers-run-id>" `
  -Tier "<T2|T3>"
```
*注：旧接口保留 `FAST_TRACK` 兼容值；新任务只选 T1/T2/T3，默认 T2，T1/T3 由人工指定。功能规模和历史档位不改变新任务默认值。*

`agent` 值取自实际工具而非底层模型。若另一活动流程或 session 拥有该功能，**停止而不是编辑它**。任何修改规范功能产物或生产代码的操作都需要归属；只读审计豁免。验证与完成用同一 owner ID。恢复前、每个修改批次前用 `Validate`：

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-owner.ps1 -Operation Validate `
  -SpecDirectory ".ai-workspace\specs\features\<FeatureName>" `
  -Feature "<FeatureName>" -Workflow SUPERPOWERS `
  -Agent "<CLAUDE_CODE|COPILOT|ANTIGRAVITY|CURSOR|CODEX|PI>" `
  -OwnerId "<superpowers-run-id>"
```
*注：已 Claim 的功能执行 Validate / Check 时，仅传 `-Feature "<FeatureName>"` 即可，脚本会自动从工作区解析规格目录并补全活动归属。*

成功交付后 `Complete`：

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-owner.ps1 -Operation Complete `
  -SpecDirectory ".ai-workspace\specs\features\<FeatureName>" `
  -Feature "<FeatureName>" -Workflow SUPERPOWERS `
  -Agent "<CLAUDE_CODE|COPILOT|ANTIGRAVITY|CURSOR|CODEX|PI>" `
  -OwnerId "<superpowers-run-id>"
```

旧流程失败时不得 Complete。任务模式遇到中断或环境阻塞应 Checkpoint / Suspend，保留进度并释放执行占用。

**旧归属的工具切换（Transfer）**：没有 taskId 的历史归属可从 ledger 或 `.workflow-owner.json` 获取原 ownerId，核对本地 Status 与会话状态。确认原 Agent 已停止且此次确为继续同一工作后，才用 Transfer；有 taskId 时使用 Resume / Recover，不把镜像视为本机执行权限。

```powershell
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-owner.ps1 -Operation Transfer `
  -SpecDirectory ".ai-workspace/specs/features/<FeatureName>" -Feature "<FeatureName>" `
  -Workflow SUPERPOWERS -Agent "<新工具>" -OwnerId "<原ownerId>" -ConfirmTakeover
```

**旧归属凭证丢失**：先用 Status / Preflight 检查可恢复的身份和本地状态；无法核实 ownerId 时报告缺口，不用占位值强制释放。已完成工作下的新修改沿用功能目录、创建独立 taskId，不为规避旧状态另开功能。

## 生产代码编辑 Guard

PreToolUse hook 在每次文件编辑前运行 `guard-production-edit.ps1`（各 harness 共用：hook 命令统一指向 `./.ai-sop/scripts/hook-dispatcher.ps1`；Claude Code 经 `.claude/settings.json`，其它经 `.agents/hooks.json`/`.cursor/hooks.json`/`.github/hooks/ai-sop.json`）。编辑默认生产路径（`src/`、`pkg/`、`cmd/`、`internal/`、`app/`、`lib/`、`WebRoot/`、`config/`、`include/`；宿主可用 `.ai-sop/config/project-policy.json` 的 `productionPatterns` 覆盖）前，**必须存在 ACTIVE 的 `SUPERPOWERS` owner**，否则被拒绝。`AI_SOP_SKIP_OWNER_GUARD=1`（或旧版 `SERVER_NEW_SKIP_OWNER_GUARD=1`）仅对非功能型一次性小改生效；为绕过归属而设它是流程违规。guard 异常可手动关（`.ai-sop/.guard-disabled`）。**更推荐用一次性令牌**：写 `.ai-sop/.guard-token.json`（`{feature, reason, operator, expiresAt}`），guard 仅当 feature 匹配且未过期时放行，过期自动删除，防 `.guard-disabled` 被遗忘导致后续任务无防护。

**Guard 绕过合规提醒**：若 AI 发现 `AI_SOP_SKIP_OWNER_GUARD=1` 或 `SERVER_NEW_SKIP_OWNER_GUARD=1` 开启但当前任务涉及复杂/多文件代码变更，必须在开始前 Warning 提醒用户：“当前开启了 Guard 绕过，此修改将不记录归属且跳过审查。请确认是否为临时小改；若非小改请关闭该变量并走正常归属流程。”AI 不得在复杂变更时默记配合用户违规而不提醒。

## 跨工具交接状态（feature-state.json）

任务模式的进度以 `tasks/<taskId>/task.json` 为准，使用 Task Status / Checkpoint。下面的 `feature-state.json` 仅供旧流程恢复参考，不作为新任务身份或完成状态：

```powershell
pwsh -NoProfile -File ./.ai-sop/scripts/feature-state.ps1 -Operation Get -Feature <FeatureName> -SpecDirectory ".ai-workspace/specs/features/<FeatureName>"
```

输出当前 phase/完成步骤/下一动作/最近验证结果。AI 每完成一个阶段（Claim/需求确认/设计确认/实现/审计/验证）后用 `-Operation Set` 更新进度，供下次或换工具时恢复。

## 完成验证

新任务按下节档位要求使用 Task Run / Verify / Complete。以下覆盖校验示例用于 T3 或旧流程诊断（任务模式调用 ValidateTestCoverage 时加 `-TaskId`）；修改 SOP 脚本本身时另须运行聚合测试。普通宿主 T1/T2 不默认执行 SOP 全量套件或完整覆盖检查：

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\run-all-tests.ps1 -IncludeCompile
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-state.ps1 -Operation ValidateTestCoverage `
  -Path ".ai-workspace\specs\features\<FeatureName>\05_test_coverage.json"
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-state.ps1 -Operation LintSpecs `
  -Path ".ai-workspace\specs\features\<FeatureName>" -Phase PLAN
```

`run-all-tests.ps1` 默认跑工作流脚本测试；`-IncludeCompile` 额外跑 `gradlew compileJava`。全过 exit 0。最后由 `verification-before-completion` 复查。

**验证须匹配声明（硬约束）**：编译通过不代表行为回归通过，单元测试也不代表完整业务链路验证。T1 可报告“代码修复并编译通过，行为回归待执行”，不因延期回归阻止按 T1 完成；T2 报告相关测试和同步结果；T3 附适用覆盖契约证据。任何档位都读取真实退出码与输出，不扩大验证结论。

## 完成定义

质量保证分层（机器硬门禁 vs AI 自报、证据绑定、明确不做）见 `.ai-sop/docs/QUALITY_GATES.md`。下表是操作清单。

完成条件**按档位分**（`workflow-state.ps1 -Operation Status` 显示当前 tier + 门禁 SHA；`workflow-state.ps1 -Operation CheckCompletion -Path .../00_workflow_state.json` 输出机检 ASCII checklist（门禁 SHA/coverage/`07`/`compile-evidence.json`/SVN status）。**机检项 [v]=pass/[X]=fail，人工项 [?]=需 AI 验证**。`CheckCompletion` 是诊断（exit 0）；硬失败只在 `VerifyCompletion` / `Complete`。AI 据下表 + CheckCompletion 结果逐项检查并报告）：

**Complete 前硬门禁**：新任务由 Task Complete 调用 VerifyCompletion -TaskId。T1 检查真实编译；T2 检查真实编译、相关测试及 RecordSync；T3 另外检查批准与当前规格哈希、设计审核、覆盖映射及适用的影响分析。T1/T2 的明确适用性说明按上文处理。失败不释放为已完成，可 Suspend 保留问题并释放执行占用。机器不以 FollowUp 标记阻断任何档位；T3 仍需解决实际相关规格和验证缺口。旧 compile-evidence.json/test-evidence.json 仅用于未迁移的功能级兼容路径，新任务不手写这些执行记录。

**T3 完成清单（机检项 1–3 由 `VerifyCompletion` 强制；第 4–6 项为 AI 自报，机器不读 08/09）**：

| # | 条件 | 验证命令 | 成功输出 | 失败恢复 |
|---|---|---|---|---|
| 1 | 需求与设计已确认 | `workflow-state.ps1 -Operation Status -Path .../00_workflow_state.json` | `gate=requirement status=APPROVED` + `gate=design status=APPROVED` + `hashMatch=MATCH` | `ResetApproval` + 修改 + `Approve` |
| 2 | 测试计划与覆盖矩阵已创建/更新 | `workflow-state.ps1 -Operation ValidateTestCoverage -Path .../05_test_coverage.json` | `VALID` | 补 05_test_plan.md + 05_test_coverage.json |
| 3 | 代码编译通过 | Task Run -Kind compile | 当前输入下真实成功 | 修复后重新执行编译 |
| 4 | 必要全局审计与逻辑审计通过 | `implementation-auditor` + `logic-auditor` 报告 PASS | **AI 据独立 subagent 报告自报**（`VerifyCompletion` 不读 08/09） | 修复发现 + 重审 |
| 5 | 目标自动化场景通过 | `run-all-tests.ps1 -IncludeCompile` + 定向 JUnit | exit 0 | 修测试 + 重跑 |
| 6 | 中途失败已修复、复审和回归 | 检查无未解决发现 | 无未解决发现 | 补修复 + 回归 |

**T2 完成清单（新任务使用 Task 验证）**：

| # | 条件 | 验证命令 | 成功输出 |
|---|---|---|---|
| 1 | 当前任务归属 | Task Start / Resume | 当前任务 ACTIVE |
| 2 | 代码编译通过 | Task Run -Kind compile | exit 0，输入有效 |
| 3 | 相关测试通过 | Task Run 的真实测试结果 | exit 0，输入有效 |
| 4 | 受影响需求、设计与测试同步 | Task RecordSync | 已更新，或说明无需更新的依据 |
| 5 | 如实报告范围与缺口 | 区分未覆盖、环境阻塞和不适用 | 不把未执行写成通过 |

**T1**：本任务真实编译/基础检查通过，报告未验证范围；确有延期才创建非阻断待同步项。纯文档适用性按上文三档规则处理。

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
- **STRICT**（Claude Code、Cursor、Copilot、Antigravity、Codex）：有独立 subagent + 审查证据，可跑 T3 完整流程（含独立审查）。
- **BLOCKED**（Pi）：缺关键能力（核心无独立 subagent 审查），支持 T1/T2。BLOCKED 不代表工具差，是该能力暂未确认；真机认证后可升 STRICT。

无 subagent 的工具跑 T3 时独立审查实为自审（共享盲区），失 T3 价值——故能力准入判 BLOCKED 支持 T1/T2。详见 `.ai-sop/docs/ARCHITECTURE.md`。

**静态表是声明值，非运行时探测**：`harness-capability.ps1` 的 known-capability 表是"该工具声明应具备"的能力（静态默认）。真实环境可能因内网代理/工具版本/特定 shell 而降级（如某 Copilot 插件无 subagent、某 Cursor build 派发 subagent 失败）。两种应对：
- **本机覆盖**：若本机环境某 STRICT 工具实际不支持 subagent/evidence，写 `.ai-sop/.harness-capability-override.json`（gitignored，不共享）降级该能力。格式 `{"CLAUDE_CODE":{"subagent":false,"_reason":"此 build 的 subagent 失效"}}`。`harness-capability.ps1` 合并覆盖后重判（STRICT→BLOCKED），`doctor.ps1` 提示覆盖存在。覆盖文件是本机降级的诚实记录，不静默。
- **T3 子代理不可用**：保留当前任务进度并说明缺失能力，提出切换工具或人工改档的选项；不能静默按 T2 完成。已经选择 T1/T2 的任务不依赖独立子代理，不因此拦截。

## AI 回复状态行（必带）

AI 每次回复末尾必带一行：`档位=T2 | 阶段=实现 | 下一步=编译 | owner=<id>`。`ai-sop.ps1 Status -Feature <Name>` 打同一行，让人/AI/工具三端能对上进度。

## SOP 拦截标准输出格式

当操作因工具能力准入（BLOCKED）或 Guard 拦截而中断时，AI **必须**用标准格式输出，让用户一眼看出是 SOP 拦截而非工具故障：

```
[SOP 拦截] 工具 <工具名> 因 <缺失能力/拦截原因>，无法执行 <尝试的动作>。
建议：<恢复建议，如切换具备所需能力的工具 / Task Discover / 检查原任务状态 等>
```

示例：`[SOP 拦截] 工具 Pi 因无 subagent（能力准入 BLOCKED），无法执行 T3 design-reviewer 独立审查。建议：切换到具备独立审查能力的工具继续 T3；只有用户主动选择 T2 时才改档。`

不得只报“我无法完成”而不给原因和恢复建议。

**接管提示**：说明哪个功能/任务持有归属、下一步检查什么。普通继续工作使用 Resume；异常中断用 InspectRecovery → Recover → Resume。用户表达接管意图后仍须核对任务身份、旧 Agent 与验证进程状态，不能把一句口令当成无条件抢占授权。

**事务不确定状态**：遇到 `WORKFLOW_TRANSACTION_INDETERMINATE` 保留 journal 与目标文件，运行 `ai-sop.ps1 Preflight` 做只读诊断。它不会修复事务；无法确定目标状态时停止修改并报告诊断，不删除日志、不用 ForceRelease 绕过。恢复边界见 `.ai-sop/SUPERPOWERS_MANUAL.md`。

## 门禁状态诊断（Status）

查看当前门禁状态 + SHA 是否匹配（只读，不锁不报错）：

```powershell
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-state.ps1 -Operation Status -Path .ai-workspace/specs/features/<FeatureName>/00_workflow_state.json
```

输出 `gate=<requirement|design> status=<APPROVED|DRAFT> sha256=... artifact=... hashMatch=<MATCH|DRIFT>`。`hashMatch=DRIFT` 表示已批准产物被改过——纯文本润色用 `UpdateHash`，实质改动用 `ResetApproval` + `Approve`。

## 旧归属的强制释放（ForceRelease，仅兼容）

有 taskId 的异常退出使用 InspectRecovery / Recover / Resume。下面仅用于没有 taskId 的旧归属：核实真实 Feature、ownerId 和原 Agent，确认原会话停止，且已获强制释放授权后执行；缺失身份不可填占位值。

```powershell
pwsh -NoProfile -File ./.ai-sop/scripts/workflow-owner.ps1 -Operation ForceRelease `
  -SpecDirectory ".ai-workspace/specs/features/<FeatureName>" -Feature "<FeatureName>" `
  -Workflow SUPERPOWERS -Agent "<原工具>" -OwnerId "<原ownerId>"
```

`ForceRelease` 保留审计记录；若关联任务，会同步暂停任务，不代表验收通过。本机验证进程仍运行时不能接管。旧归属能够正常 Transfer 时无需强制释放；不得用它绕过未决事务。

**换机交接**：镜像只提供历史身份参考，不复制本机注册表、事务日志或 `.runtime` 权限。先 Preflight / Status；带 taskId 的任务按 Recover → Resume 获取本机归属，旧任务先按任务入口的显式采纳规则迁移。来源或身份不清时报告缺口，不自动 ForceRelease。

## 概念速查表

| 术语 | 一句话 | 详参 |
|---|---|---|
| Superpowers | 流程技能包（brainstorming/writing-plans/SDD 等），T3 需要，T2 不需要 | 本文件"关于 Superpowers" + `.ai-sop/SUPERPOWERS_VERIFICATION.md` |
| harness | AI 编码工具的统称（Claude Code/Copilot/Antigravity/Cursor/Codex/Pi） | `.ai-sop/docs/ARCHITECTURE.md` |
| T 档 | 执行强度档位（T3 完整/T2 快速/T1 极速） | 本文件"执行强度分层" |
| 能力准入 | 工具能力判定（STRICT 可 T3/BLOCKED 支持 T1/T2） | 本文件"能力准入" + `harness-capability.ps1` |
| 归属 Claim | 功能开发权的认领，生成不可变 ownerId | 本文件"功能归属" |
| 门禁 | 需求/设计的人工批准状态（APPROVED + SHA） | 本文件"人工 review 阶段" |
| design-reviewer | 机器设计审查（独立 subagent，T3 必需） | 本文件"工作流归属" |
| AUDIT-EXEMPT | 有意允许的反模式例外声明 | 本文件"AUDIT-EXEMPT" |
| UpdateHash | 纯文本润色后只更哈希不作废批准 | 本文件"纯文本润色豁免" |
| Transfer | 换工具时转交归属 | 本文件"工具切换与归属接管" |
| ForceRelease | 原 session 丢失时强制释放归属 | 本文件"归属超时与强制释放" |
| FAST_TRACK | 旧档位兼容标记；新任务用 T1/T2 适用性说明 | 本文件“执行强度分层” |
