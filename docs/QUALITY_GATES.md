# 质量保证设计（Quality Gates）

## 任务模式：按本次修改验证

输入范围可由项目的 `.ai-workspace/context/verification-inputs.json` 配置：默认保守扫描不变，include 补入真实输入，exclude 用明确路径和理由排除输出。更具体路径优先，父目录 include 不解除子目录输出/日志排除；显式 include 可覆盖同路径默认排除，同路径 include/exclude 冲突则拒绝配置。配置摘要参与 inputs-v4，旧 v3 清单可读取但证据过期；无配置保持 inputs-v2，Git/SVN ignore 不是输入真源。活动 T3 的基线口径不可变，应在原引擎完成后升级输入规则，不能用升级理由重写起点。配置的语义正确性仍依赖项目维护者，不允许通过随意排除源码消除失败。新 Run 的完整输入清单按哈希保存于 `.ai-workspace/specs/.artifacts/inputs/`，task.json 引用 inputsRef；验证检查清单存在、内容哈希和输入摘要，缺失/损坏必须补同步或重跑。旧内嵌清单兼容，历史 DONE 不迁移。本地日志不参与完成判定。

一次 Status/Verify 使用同一调用内的内容快照；后续调用及 Run 的前后快照重新读取。Status 是诊断视图，`-Json` 提供固定结构；部署投影漂移只提醒，损坏规格 JSON 则在实际依赖它的 T3 校验中明确失败。Start 不得复用旧 TaskId 恢复暂停任务，Resume 不得静默丢弃新传入的不同目标。

Status 默认仅对未完成任务检查当前输入；DONE/CANCELLED 即使有待同步项也保留历史状态，标为 HISTORICAL_NOT_RECHECKED。显式 RecheckHistory 才复核所选历史证据，不改变任务终态或创建补跑义务。Start 反馈已登记的起点状态、不可用原因与能力边界，不重新扫描或增加门禁。

当前默认入口是 `ai-sop.ps1 Task`（底层 `workflow-task.ps1`）。功能保存长期规格，每次独立修改有固定 taskId 和独立 T1/T2/T3（默认 T2，人工指定优先）；接管只更换执行会话，不改变任务身份或档位。本节描述任务模式；后续旧矩阵中的功能级证据要求仅用于未提供 taskId 的兼容路径。

**写前与档位边界**：本机制只应用于已安装 SOP 的宿主。讨论、解释、只读审核不需要任务或档位；修改前先确定新任务/续做，Start/Resume 成功并说明实际档位后再写。新任务默认 T2，T1/T3 Start 缺少 UserRequest 则拒绝创建；选择记录随任务事务保存，改档继续使用原有 tierHistory。旧任务续做不追溯补造人工依据，子 Agent 继承 controller 的任务与档位。原话由 Agent 记录，不能据此证明人工身份。

已接入 Hook 的 Guard 对识别出的工作区 FILE_EDIT 核对 ACTIVE task、合法档位、owner/session 绑定和物理工作区身份，不仅检查有无 owner。无 taskId 的历史归属需 Resume 收编；安全读取和专用治理命令保留既有路由。正常 T1 不等于关闭 Guard；人工紧急停用单独显示 GUARD_DISABLED / GUARD_DISABLED_FOR_FEATURE，不构成合规 T1 或完成证据。该保障依赖真实 Hook 接线及调用识别，当前 Codex blockingHook=false，不承诺其写前阻断，也不防御任意 shell 或同权限直接篡改。

Start/Resume/ChangeTier 从登记结果回显档位、来源和义务，Agent 首次修改前转告用户；机器不验证聊天内容是否真实展示。Complete 核对本档交付证据，但不强制拦住结束回复，暂停和未完成报告仍可正常返回。文档同步的语义质量继续由 Agent 核实，不新增人工确认或 T1/T2 审核环节。

| 项目 | T1 任务 | T2 任务 | T3 任务 |
|---|---|---|---|
| 真实编译/基础验证 | 适用时必须成功 | 适用时必须成功 | 必须成功 |
| 相关测试 | 默认不要求，报告未验证范围 | 适用时必须成功 | 必须成功并映射要求的 CaseIds |
| 历史功能规格是否强制升档 | 否 | 否 | 按本次 T3 检查 |
| 风险扫描 | 提醒，不静默升档 | 提醒，不静默升档 | 完整风险与影响分析 |
| 需求设计/07/覆盖定义 | 可延期同步；实际欠项才记 FollowUp | 按影响同步相关规格/用例，RecordSync 记录；无需完整批准或独立审核 | 沿用适用的批准，仍检查当前哈希与内容 |
| 旧功能或全局 evidence 文件 | 不读取 | 不读取 | 执行证据用本任务记录 |
| 必需验证失败或环境阻塞 | Suspend/交接，不能冒充通过 | 同左 | 同左 |
| 历史待同步项 | 提醒，不阻塞 | 提醒，不继承为本次义务 | 提醒；实际相关缺口按 T3 验收 |

正常收尾直接 Task Complete，在提交 DONE/释放归属前执行 `VerifyCompletion -TaskId`；不需要先单独 Task Verify。移除重复调用不缓存或跳过最终校验，证据缺失/失败/过期仍拒绝完成。Verify 保留为可选的提前诊断，Discover 用于不扫描全部输入的进度查询。

`VerifyCompletion -TaskId` 一次输出缺失命令记录、失败批次、输入变更文件和 T3 规格问题；`CheckCompletion -TaskId` 使用同一检查但仅作诊断。原有 `testCount >= cases.Count` 数量代理已经移除，旧记录仍必须真实成功且数量自洽。

验证输入使用内容指纹 `inputs-v2`，覆盖工作区中的保守输入集合（包括公共源码、测试、构建及依赖声明），不受暂存或提交状态影响。常规 build/target/bin/obj/out/classes 仅在工作区根或可识别的 Maven/Gradle 模块根排除，不按任意层级的源码包名过滤；有 web.xml 的 WEB-INF/classes 为标准 Java Web 编译输出，排除 classes 而保留 web.xml。另排除治理目录、worktree 的 .git 文件、根 .ai-sop-staging、依赖缓存、滚动日志与临时文件。依赖锁文件仍属于输入。算法版本参与摘要，旧 v1 证据需重新运行验证，历史 DONE 不迁移。未排除的符号链接会明确失败，不静默漏掉链接输入。该快照不等于密封构建：外部服务、未声明环境和工具链变化仍需控制器判断并重跑；不同工作区及合并后的代码不能仅凭各自历史 PASS 宣称集成通过。

`Run` 在执行前后采集输入，输入变化则保留失败诊断、禁止完成。不能给旧成功结果换一个新哈希。不同测试批次可在相同输入下累计；失败批次必须以同批次的真实成功复跑解决。新记录不因单纯经过 7/30 天而失败，旧格式保留原校验以免静默改变证据含义。

T3 Start 固定任务的修改前内容清单，长期功能批准基线独立保留。所有新任务的 startInputs 与任务创建事务绑定，T1/T2 默认尝试 500ms/8MiB 预算采集，超限或失败记 UNAVAILABLE，部分清单不保存；Start -CaptureBaseline 可显式完整采集而不改变档位。预算不保证底层 IO 或整个 Start 的硬耗时。普通 T1/T2 编译/相关测试不要求起点可用。`Changes` 返回相对任务基线的内容差异；`ReviewImpact` 将 04 的 taskId、baseline、baselineInputDigest、changedFiles、changeSetDigest 与实际差异核对，并保存可交接的 `.ai-workspace/specs/.artifacts/changes/` 清单。Verify 同时检查 04、完整输入和差异清单，不能仅通过重填 inputDigest 复用旧分析。这是显式确认分析的动作，不是自动修复分析。更改已批准需求设计语义应 ResetApproval，T3 重新批准；T2 记录变更依据并同步，不要求当次补完整批准。

新任务在创建事务中另存 startImpact，用于区分未修改的历史 04 与本任务修改的 04；它独立于源码采集预算，不改变 T1/T2 的完成要求。T3 不允许本任务新增/修改的 04 因缺少或保留旧 taskId 被跳过，已有审核绑定也不能靠删除文件或改归属消除。旧任务缺字段时明确报告来源未知，保持历史兼容，不在接管时补造起点。

T3 用 `SetCaseScope` 显式登记本任务 requiredCaseIds 和理由，包含影响分析声明的回归用例；规格变更后重新核对。必测用例的载体、断言和本任务执行证据必须有效，不强制执行整个功能的其他用例；整体规格批准及覆盖定义仍检查。覆盖辅助函数显式接收 TaskId，输出实际检查范围；T1/T2 空范围不能声称用例已检查，T3 空范围继续报 TASK_CASE_SCOPE_REQUIRED。独立新任务另取基线与范围；ChangeTier/SetBaseline 只复用当前任务 Start 已登记的引用，Run 清单或口述理由不能证明修改前来源。缺起点时拒绝升级并保留原档位。旧 T3 source=START 保持兼容，旧 ADOPTED 无来源证明则明确诊断，不能判为无差异；历史 DONE 不迁移。任务必须先 Start 再改动；该机制不防御同权限主体直接篡改引擎或任务记录。

可选 JUnit XML 映射核对本次报告的 classname/name、成功状态及文件更新，CaseIds 从报告派生；缺失、陈旧、跳过或失败的映射不能通过。提供的 tests/failures/errors/skipped 汇总须为非负整数，成功证据的汇总须与 testcase 明细一致；嵌套 suite 按后代明细核对，报告计数不重复累加父子汇总。映射外的跳过用例不阻止已映射用例通过。它不替代测试语义审查，也不对同权限恶意进程提供防伪保证。T1/T2 不新增此项必做流程。

T1/T2 的执行入口不计算规格摘要，轻量 Verify 的风险扫描失败仅提示，不让历史规格损坏间接升级成完成门禁。T3 测试仍读取并绑定需求、设计和测试定义。

可选验证定义使用独立绑定：新 Profile 摘要 `profile-command-v2` 只覆盖所选命令的规范化字段，并对 `caseMap`、`junitReports` 做工作区物理路径规范化（Windows 不区分大小写）；JUnit 配置 `junit-map-v1` 记录规范化映射与来源路径。运行结束及当前任务验收均重新读取定义，不因 context 目录未进入业务输入指纹而漏掉变更。对象键序、排版与映射项排列不改变新摘要，命令参数顺序、参数中的换行及 executable 原文仍有意义；其他 Profile 的有效改动不影响本批次。已有 `profile-command-v1` 仍核对原命令字段摘要，无版本 Profile 仍核对原整文件摘要，不重解释旧证据。旧映射无来源路径则诊断未绑定、要求相关批次重跑；历史终态默认不重验、不迁移。缺失或非法配置报告具体 kind/batch。定义与命令改变仍通过 Reason 留痕，不能刷新旧 PASS 的绑定。这只检查定义完整性，不证明命令和测试本身足够有效。

`AssessRisk -TaskId` 对 T1/T2/T3 均只返回任务诊断，不写入功能批准、风险状态或任务归属。T1/T2 使用 Start 时已记录的有限输入快照筛选本次变化；快照缺失或无法读取时返回 `scopeStatus=UNAVAILABLE`、空摘要及未知风险，不借用功能差异、不自动升级。T3 缺少基线仍保留其原有保守诊断。`recommendationOnly=true` 表示风险建议不会替代人工指定的强度。

批准状态读取统一优先选择 `00_workflow_state.json`，缺失时兼容 `workflow-state.json`，覆盖校验和基线完整性检查遵循同一规则。新版文件存在但损坏时必须报错，不能回退旧批准；新建状态继续使用规范文件名。

事务恢复在取得 Session → Owner → Grant 锁后重新读取日志。正常提交已删除日志时跳过，不计为一次恢复；日志身份、目标或锁范围变化时拒绝重放。提交证明遇到同一日志在检查后被删除，会继续核对持久化注册表；其他 IO 错误保持失败或未知，不能据此确认提交成功。

Preflight 的旧功能盘点会列出无 taskId 功能的根目录规格、批准记录展示、嵌套仓库与同步状态，并标为 LEGACY_UNVERIFIED；不自动创建任务、不验证其完成门禁。显式 TaskId 不存在仍报选择为空。活动任务预检会展示所用验证定义的漂移及文件归属；目标引擎兼容声明缺少所需定义绑定能力时明确提示，不能把可读取 JSON 当成支持这些检查。

验证命令在启动前写入 RUNNING，避免进程突然退出后更早的成功记录成为“最新结果”。终态记录同批次替换该次尝试，超时/中断均不能满足必需验证。Task Status 和根 Status 采用相同摘要，但执行证据有效不等于完整 T3 验收。Recover/ForceRelease 同步恢复任务、归属和会话，未结束的本机验证进程不能绕过。

子进程超时后的清理也有独立预算：终止、取消读取与 Dispose 在后台执行，主流程最多等待 5 秒。失败记录在清理前落盘；清理未确认会追加诊断，不能被记作成功。Start 基线和 Preflight 的 Git/SVN 元信息查询采用有限等待：无法确认基线时拒绝认领，预检查询失败时显示 UNKNOWN，不推断为无仓库、未跟踪或干净。超时保护不证明底层 Git/操作系统阻塞已消除，也不保证无法追溯的后台进程已退出。

`workflow-state.ps1` 的风险分析、差异摘要、覆盖和完成检查也使用有界 Git/SVN 查询：本地身份查询最多 10 秒，diff/status 等扫描最多 60 秒；一次调用累计 VCS 等待预算 180 秒，另计有界清理时间。某个工具超时或无法启动后，本次操作不再重复等待该工具，下一次操作可以重新探测。失败的 stdout/stderr 不会被当作有效差异，硬门禁不能以“没有查到文件”放行。T1/T2 任务的风险范围缺失或扫描失败会输出 `RISK_ADVISORY: scope UNKNOWN`，属于非阻塞提醒，不自动升级强度；原有编译、测试和同步要求仍然有效。

新记录使用执行协议 2：Checkpoint 只接受任务目录内的 runId 待保存文件，新尝试必须为 RUNNING，终态必须匹配既有尝试的任务、会话 epoch、命令、输入、用例范围和运行器身份。改变同一批次的验证定义需提供 Reason，保留替换关系。运行期间 Checkpoint 仅续期原绑定会话；终态结果先原子落盘，事务失败保留，RetryEvidence 可幂等重试，Recover 可接收已停止本地运行的匹配终态结果。路径、进程和摘要校验用于正常接口的完整性检查；拥有引擎与注册表写权限的同一主体仍可修改文件，不宣称实现了对恶意本地写入的防伪。

运行中的会话读取/续期锁超时仅在最后确认的租约有效期内退避重试，连续失败最多 30 秒，每次重试的锁与事务阶段共享最多 3 秒预算，且受原租约/重试截止时间约束。会话结束、归属或 epoch 改变不重试；租约到期或耗尽重试窗口停止子进程并记录 INTERRUPTED/RUN_CONTROL_INTERRUPTED，与真实子进程非零退出的 FAILED 区分。最终保存失败仍保留原始结果，不通过延长重试窗口复活旧会话。

损坏待入账结果默认阻断恢复；InspectRecovery 只读诊断。原进程停止后可显式 QuarantineInvalidEvidence，先保存原字节和哈希再以两阶段事务记为中断，必须重跑；损坏 task/owner/session 不自动猜测修复。日志路径先准备再登记 RUNNING，避免尚未启动就留下虚假运行状态。

Status/Discover、InspectRecovery、Preflight 共用只读恢复建议：校验 pending 的身份与结果后才提示 RetryEvidence，RUNNING/远端未知/损坏记录分别提示等待、确认停止或诊断恢复。另一任务的 ACTIVE 归属提示冲突；同一物理工作区、规格目录与功能下的 COMPLETE/RELEASED 归属标为 HISTORICAL_OTHER_TASK，不要求先释放历史占用，也不借用它的会话。身份不匹配仍须诊断。未完成 T3 的原始基线缺失/策略不兼容与会话失效分别呈现，Resume 不修复基线。运行时长、超时配置、日志更新时间和可选日志尾部仅为即时观察；尾部限 200 行、32 KiB，不改变任务/会话，不以日志静默判定进程死亡。旧记录没有超时字段时保持未知。

暂停释放的是执行占用，不是验收义务；本次 T2 DONE 不能替原 T3 宣告功能整体完成。独立后续任务不继承旧测试欠账，实际依赖与代码重叠仍需先辨明。

Claim（包括 Start 和 PAUSED Resume）、BindSession、RebindSession、Transfer（包括旧 owner 收编）以及 Schema 1.1 Validate 在 Session → Owner → Grant 锁内检查同功能其他 ACTIVE task.json，随后以原两阶段事务提交，避免本地注册表丢失或旧 owner 收编时误建第二个活动任务。同会话 Resume 的 Validate 使用锁内读取的 owner.taskId 排除自身。PAUSED、DONE、CANCELLED 不挡新任务；Suspend、Cancel、Recover 不增加此项前置检查，恢复旧任务无需补完旧完成门禁。检查只针对本地已同步状态，不保证其他机器未同步的并行写入安全。

ChangeTier 是人工调整交付要求的显式操作，需要原话和原因；不清除失败证据，不重置任务身份。Status 始终显示最新失败批次，包括 T1 不强制要求的测试，避免把“按 T1 完成”写成“全部测试通过”。

T2 必须有 RecordSync；机器验证记录结构，不声称能够证明设计和代码语义一致。FollowUp 的判定、范围和关闭依据同样由 Agent 核实，标记本身永远不作为完成门禁。Start/Resume 每次只提醒一次，不自动加入后续任务。更新走现有 Owner Checkpoint 事务和锁，不引入第二套状态写入机制。

Cancel 提交成功后，非阻塞提示该任务已关闭的 FollowUp；取消任务不等于撤销真实修改，因此不自动重新打开。ReopenFollowUp 显式记录原因，保留关闭历史，并以同一 Checkpoint 事务更新来源任务与当前任务，来源任务无需重新验收。

04 的新 startImpact/impactReview 显式记录 `sha256-text-lf-v1`，只消除文本 CRLF/LF 差异。旧无标记记录仍用原字节摘要，不重新解释旧证据；业务输入原始字节哈希保持不变。机器生成的 inputs/changes 清单使用无格式化换行的规范 JSON，不需要为此迁移内容地址。

T1/T2 的 NOT_APPLICABLE 必须提供具体理由，同时绑定 startInputsRef 和当前输入。声明及 Verify 都检查起点到当前的全部输入增删改仅落在项目预先配置的 nonExecutable 字面路径中，并检查输入策略未变；未配置路径按可能执行输入处理。这些文件仍被哈希，不能用事后改配置或重声明消除源码变化。起点未知、旧豁免无起点绑定时改回 REQUIRED 并正常验证，不自动升级档位。不能豁免尚未解决的失败或环境故障；T3 不接受此轻量豁免。nonExecutable 的语义正确性仍由项目维护者/Agent 负责，不以扩展名猜测语义。旧任务仍能读取，正常 T1/T2 验证不要求补起点，不强制迁移历史 DONE。

> 面向：维护 SOP 的人，以及需要分清「机器查什么 / AI 自报什么」的人。  
> 各档完成条件见宿主投影 `AGENTS.md`「执行强度：默认 T2，人工显式选择优先」与「开始、执行、完成」（[源模板](../distribution/templates/root/AGENTS.md)）；T3 详细清单见 [T3 执行参考「完成验收」](../workflows/agent-t3.md#完成验收)。
> 本文件回答：**为什么这样分层、假绿收到哪一层、机器上限在哪、下一步不加什么。**

相关：`docs/ARCHITECTURE.md`（决策 11/12）、`workflows/shared-artifacts.md`（产物契约）、`SUPERPOWERS_MANUAL.md`（人工操作）、`skills/quality-assurance/SKILL.md`（测试方法论）。

---

## 1. 要挡住的三类假绿

| 假绿形态 | 例子 | 机器对策 |
|---|---|---|
| **没做却声称做过** | 没独立审查、没编译、覆盖矩阵是 `__TODO__` | 功能目录要有可读文件；`LintSpecs` 中途就能报缺 |
| **做过但已过期** | 编过一次后改了六天代码；06 作废再批仍拿旧 PASS 报告 | 证据绑 `workingTreeDigest` / 产物 SHA |
| **当场伪造** | 手写 `exitCode=0`、空 `@Test`、只断言回包 | 部分可挡（表征方法体、冷重载调用）；**挡不住**同一次会话编一份假 JSON |
| **未编译就审 PASS** | engine 还在跑 / 缺 import 时 auditor 已 PASS；controller 自己补编译 | **流程约束**（adapter：无【编译证据】不派审；auditor 缺证据只能 `INDETERMINATE`）。兼容模式 Complete 查功能目录 `compile-evidence.json`；任务模式读取本任务 Run 记录，仍不证明独立审查实际发生 |

任务模式已支持可选 JUnit XML 映射与运行器结果绑定，但不能防御同权限本地写入。T3 的「先编译再审」仍依赖 controller 与 auditor 的职责约束；T1/T2 不因这些审查说明增加独立审核。

---

## 2. 旧功能级兼容：分层（从外到内）

质量保证不是单道 Complete 检查，而是几层职责不重叠的笼子。外层挡「不该写」，内层挡「写了但没证明」。

```text
1. 物理拦截     Hook + Owner 锁          未认领不能改生产目录
2. 档位分流     T1 / T2 / T3              默认 T2，人工指定；风险仅建议
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

## 3. 旧功能级兼容：机器硬门禁 vs AI 自报

下表仅说明未传 TaskId 的存量 VerifyCompletion / Complete。新任务按本文开头的任务模式矩阵执行，不能把下表用于 T1/T2 升档或要求新任务补旧证据。

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
| 受影响规格/用例同步 | 完整规格门禁 | RecordSync 结构机检，语义由 Agent 核实 | AI |
| `build/`、`classes/`、`target/` 目录存在 | **不算**编译过 | **不算** | 已否决 |

`CheckCompletion` 是诊断清单（exit 0），应与上表同一套信号，不得把构建目录打成 `[v]`。硬失败只发生在 `VerifyCompletion` / `Complete`。

中途早失败：`LintSpecs -Phase PLAN`（`doctor.ps1 -Feature` 也会调）扫当前功能目录：缺 00、未覆盖条款、PLAN 占位、MISSING 载体、缺 07 / 编译证据。实现中途修，不要拖到 Complete。

---

## 4. 旧功能级兼容：证据怎么绑（防过期）

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

## 7. 旧版设计取舍（历史记录）

本表记录旧功能级流程的取舍；任务模式的运行器证据和可选 JUnit 支持以开头说明为准，不将这里的旧 Task 用法当作当前 taskId 契约。

| 不做 | 原因 |
|---|---|
| 存量已交付功能倒算失败 / 一律豁免开关 | 掩盖规格债，或误伤旧目录 |
| 全 T3 强制 04 | 绿场造假材料 |
| 用 `build/classes` 当编译证明 | 过期产物假绿 |
| 强制 08/09 实现审计文件（在真 T3 稳定前） | 叠摩擦，07 模式尚未在真功能上验证 |
| 不为每个 Task 写 `compile-evidence.json` | 摩擦大；Task 交接用实现者【编译证据】粘贴进内审 prompt。Complete 仍只认功能目录那一份 |
| 按 Task 个数设机器上限 / 强制拆或强制合 | 切分是 writing-plans 判断；机检个数只会逼出假拆或假合 |
| 绑定 JUnit XML / 编译器 transcript | 防当场伪造；成本高一个数量级 |
| Hook 扩到 `python -c` / `tee` 写文件 | 覆盖成本高、易误拦 |
| 先验加宽规格定位（只写包名就当定位到） | 等真撞到 `FEATURE_SCOPE_UNRESOLVED` 再加 |

改 SOP 核心脚本后，本地硬门禁是 `pwsh -NoProfile -File ./scripts/run-all-tests.ps1` 全绿，不是 GitHub CI。

聚合运行器为每套测试设置独立时限（默认 900 秒，可显式延长），超时以失败收尾并保留 stdout、stderr 与结果摘要；不通过重试或忽略失败冒充全绿。可选 Git/SVN 版本注记探测超时只产生“元信息不可用”诊断，编译、测试、输入绑定等原有通过条件不变。具体参数、日志和清理边界见 [操作手册「完成验证」](../SUPERPOWERS_MANUAL.md#完成验证)。

---

## 8. 后续验证方向

已有可选 `Inputs` 输入解释和 `Preflight` 交接/升级预检：前者复用扫描规则，后者校验任务引用、识别嵌套 Git 和兼容性声明，均不写入任务权威状态。Preflight 不调用带事务恢复的会话查询、不运行候选引擎，避免只读检查改变现场。报告具有即时观察的限制，不证明远端同步或业务语义正确，UNKNOWN 不作为兼容通过。继续用实际项目布局验证独立任务、跨 Agent 接管与不同功能工作区的完整流程；T1/T2 保持轻量，是否增加新的审查门禁需有实际问题依据。

`Inputs -ExplainOnly -InputPath ...` 使用同一遍历规则但只读取指定路径及祖先的元数据，返回 RULES_ONLY、无输入指纹，不可代替真实验证扫描。候选配置在扫描前校验；默认 FULL 保留完整清单/内容哈希及候选增删对比。两种模式均为按需诊断，不加入 Start 或完成门禁。

---

## 9. 旧功能级兼容命令

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
