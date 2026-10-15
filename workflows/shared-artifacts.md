# 共享功能产物契约

## 修改任务与执行会话（当前入口）

本文宿主路径均相对于 Agent 运行的项目根目录；AI SOP 引擎安装在 `.ai-sop/`。
功能规格保存在 `.ai-workspace/specs/features/<Feature>/`；一次独立修改保存为
`.ai-workspace/specs/features/<Feature>/tasks/<taskId>/task.json`，符合引擎的 `schemas/workflow-task.schema.json`。

`.ai-workspace/` 保存项目级上下文，`.ai-workspace/specs/` 保存业务功能规格；两者可以是各自独立的 Git 仓库。此布局下，前者忽略 `specs/` 是正常的仓库边界：规格及任务记录应在后者提交、同步，不能仅提交前者。验证记录分别保存代码、项目上下文、功能规格实际所属的 Git 根目录及提交号。
这里的修改任务与 SDD 计划里的 Task/Step 不同，T1 可延期同步，T2 按影响同步相关需求、设计与测试；不要求额外创建整套规格或计划。

- 功能长期存在；任务有固定目标、独立 T1/T2/T3（默认 T2）、不可变 ownerId；Agent/session 可以更换。
- 使用 `workflow-task.ps1` 或根入口 `ai-sop.ps1 Task`。先 Discover，确定是 Start、Resume 还是原任务收尾；仅讨论不认领，有歧义只询问候选任务。
- Start 为独立修改创建新记录，不继承历史成功证据，不修改功能级进度和批准。
- Resume 保持 taskId/ownerId/tier。ACTIVE 任务用 Transfer；PAUSED 任务重新 Claim。旧 ACTIVE owner 可显式 Resume 收编为任务，保留批准但重新采集执行证据。
- Checkpoint 记录下一步与说明；Suspend 保存 PAUSED 并释放本地归属；Cancel 保存 CANCELLED；Complete 只有本任务检查通过才保存 DONE。
- 任务、owner、session、grant 在同一两阶段事务中变化；TASK 记录受功能 Owner Lock 保护，锁顺序仍是 Session → Owner → Grant。
- 一个功能在一个工作区只有一个执行 owner。同功能多独立会话并行不支持；不同功能用独立工作区。没有跨机器分布式锁，远端未同步活动不能自动探测。
- `task.json` 和必要规格应纳入宿主选定的持久化策略；日志按需保留。Session/Grant/Owner 权限记录留本机。Discover/Doctor 根据 specs 实际所属仓库检查忽略规则，独立 specs 仓库不受父仓库忽略规则的误报影响，不自动修改宿主忽略规则或提交历史文件。
- 跨工作区迁移：先在原工作区 Suspend，持久保存任务和相同代码，再在新工作区 Resume；新工作区重新取得本地会话，证据必须在当地重新校验。缺本地 owner 的 ACTIVE 记录仅供诊断，禁止静默继承权限。
- 功能整体验收与轻量任务 DONE 不同。T1/T2 不替旧 T3 收尾；共享代码修改和合并后仍需重新验证集成结果。

Recover 是显式恢复动作：任务转为 PAUSED，匹配的本地 owner 释放、session 解绑，通过 RECOVER 两阶段事务一起完成。没有本地 owner 时只恢复任务记录，Resume 再建立本地权限；ACTIVE/IDLE 会话需要确认停止后显式 ForceRecovery，本机仍存活的验证进程不能强制绕过。ForceRelease 使用相同恢复逻辑。任务保存 lastRecovery 审计说明。

验证记录可带 runId 和 outcome：RUNNING 在进程启动前写入，后续检查点更新同一尝试；终态为 PASSED/FAILED/TIMED_OUT/INTERRUPTED，旧无 outcome 记录保持兼容。一次任务只允许运行一个验证命令。PID、启动时间、机器和工作区仅用于诊断进程，不是跨机器权限凭证；RUNNING 不被当成成功，恢复后保留中断结果。日志是逐步写入的辅助材料，任务状态与证据依然通过事务更新。

Status 与 Discover 共用摘要；Status 额外检查执行证据的当前输入，Discover 不做全工作区哈希扫描。历史批准按 recordedApprovals 展示，完整验收仍是 Verify。项目命令配置位于 `.ai-workspace/context/verification-commands.json`，遵守引擎 schemas/verification-commands.schema.json；配置选项包含命令参数数组、批次、超时和 CaseIds。

任务执行记录中的 `inputs-v2` 是源码等验证输入的内容快照，不使用 Git status、暂存状态或基线 diff。配置 `.ai-workspace/context/verification-inputs.json` 后使用绑定配置摘要的 `inputs-v3`；include 补充输入、exclude 带理由排除生成文件/目录，仍覆盖未被排除的公共输入。新记录用 `inputsRef` 引用 `.ai-workspace/specs/.artifacts/inputs/<sha256>.json` 的去重清单，可定位过期文件；清单与任务都须在 specs 仓库持久化及同步，缺失/损坏不降级为通过。旧内嵌 inputs 继续兼容，旧引擎读取新记录前需要升级。算法版本参与摘要，旧 v1 证据不能换哈希继续充当新证据。审查 baseline 仍用于分析修改范围，不与验证输入指纹混用。

新日志使用本地 `.ai-workspace/.runtime/verification/<Feature>/<taskId>/<runId>.log`，目录带本地忽略规则；跨工作区不要求同步日志，旧任务日志仍支持读取。清单是不可变辅助产物，先原子写入再通过两阶段事务保存任务引用，失败可能留下无引用清单，但不出现假的已提交任务状态。暂不自动清理清单，避免删掉其他任务或未同步工作区仍使用的证据。

Status/Discover 默认文本显示未完成任务和有待同步项的历史任务；`-TaskId` 精确查询，`-IncludeHistory` 包含全部历史。机器接口用 `-Json`（schemas/task-status.schema.json，schemaVersion=1.0，tasks/warnings 始终为数组），`-OutputFormat JsonLines` 保留旧逐行接口。单次 Status/Verify 共用输入快照，调用之间以及 Run 前后不缓存。Start 拒绝已存在 TaskId；Resume 不修改旧目标。LEGACY 仅表示旧流程资料，不代表一个已经建立权限的任务。

新执行记录绑定任务、原会话 epoch、命令及用例范围。RUNNING 必须先入账，终态通过同一 runId 更新；同批次更换验证定义需 Reason，保留历史。`<runId>.pending.json` 为原子保存的待入账结果，失败时不得删除；RetryEvidence 只重试同一终态，Recover 在原进程已停止且本机绑定一致时可保存该结果。运行器续期不复活已结束/已转移会话。跨仍活跃会话的 Resume/Transfer 需 ConfirmTakeover；当前调用身份不能从原 owner 推断。

`Run` 执行真实命令并记录退出码、输入前后指纹和批次；失败同样保留。T1 至少成功编译；T2/T3 还需成功测试；T2 还需 RecordSync 说明相关规格/用例已同步或无需更新。T1/T2 对确无适用验证的纯文档任务可用 SetApplicability 记录具体原因，不能用于环境故障、缺少测试或测试失败。不同批次可累计，但每个批次最后一次必须成功且适用于当前输入；T3 用 `CaseIds` 映射覆盖矩阵的用例，不用测试条数替代覆盖。CaseIds 是控制器根据实际输出提供的映射，当前不解析所有测试框架的报告，也不宣称防止伪造测试命令。

T3 的 04 仍须满足 schema、固定 baseline 和语义完整性。人工/Agent 确认分析仍覆盖当前改动后，运行 `ReviewImpact` 将分析文件哈希和当前输入指纹绑定到任务；不能盲目用该命令刷新过期分析。需求/设计批准及 07 哈希检查保持有效。


任务记录可包含 `tierHistory`、`syncReview`、`applicability`、`followUps`，旧格式仍可读取。ChangeTier 记录人工请求和原因，不删除历史验证；Resume 不顺便改档。T2 的 RecordSync 记录 Agent 对受影响文档/测试的核对结论，机器不证明语义一致性，也不新增文档哈希门禁。

FollowUp 存在来源任务内，PENDING 不参与 Verify/Complete。Start/Resume 提示同功能详情和其他功能数量；FollowUps 汇总当前工作区可见事项。CloseFollowUp 由同功能活动任务通过 Checkpoint 两阶段事务更新来源与当前任务，保留来源任务状态和归属身份。关闭需具体依据；NOT_NEEDED 还需人工请求，暂不处理不清除标记。跨仓库先同步规格 Git，不把这些资料当成本地执行权限。操作示例见 `SUPERPOWERS_MANUAL.md`。

下面的功能级执行证据规则保留给未接入 taskId 的旧流程；新任务优先使用上述入口，历史证据文件不参与 T1/T2 的任务完成判断。

各 harness（Claude Code / Copilot / Antigravity / Cursor / Codex / Pi）统一走 Superpowers，共享：

`.ai-workspace/specs/features/<FeatureName>/`

质量保证分层（哪些产物进 `VerifyCompletion`、哪些仍是自报）见 `docs/QUALITY_GATES.md`。

## 规范产物

| 产物 | 契约 |
|---|---|
| `01_server_rules.md` | 业务规则，含稳定的 `BR-*`（Business Requirement）、`EX-*`（Exception）、`AC-*`（Acceptance Criteria）声明 |
| `04_change_impact.json` | 行为影响契约（遵循 `schemas/change-impact.schema.json`）。仅当 AssessRisk 命中类型/策略扩展或公共分发、或风险无法评估时必填；绿场 T3 不强制。命中类型/策略扩展或公共分发时，必须含非空 `behaviorVariants`、`legacyPaths`、`invariants` 以及 8 个生命周期切面；`entryPoints` 须覆盖 QUERY/MUTATE 等全部相关公共入口；切面证据须可定位，变更 enum 的兄弟键须列全 |
| `05_test_plan.md` | 可执行用例，含稳定的 `TC-*`（Test Case）声明 + `<!-- meta: {...} -->` 元数据（供 SyncCoverage 生成 coverage JSON） |
| `05_test_coverage.json` | 需求/设计到用例的追溯。类型/策略扩展时 Case 须机读声明 `CHARACTERIZATION`、`entryPointIds`、`variantKeys`、`facetIds`、`bypassesPriorQuery`；表征载体方法体须含这些字面量与调用，并含 `persistenceColdReload` 与再读存储调用 |
| `06_design_contract.md` | 技术契约，含稳定的 `DC-*`（Design Contract）、`DR-*`（Design Rule/风险）、`TW-*`（Test/Workflow 约定）声明 |
| `07_design_review.md` | design-reviewer 机器审查结论。T3 `VerifyCompletion` 读取 `审查状态：PASS` 或 `PASS_WITH_WARNINGS`，且 `审查对象 sha256` 必须等于当前 `06_design_contract.md`；缺文件、`NEEDS_FIX` 或 SHA 漂移不能 Complete |
| `compile-evidence.json` | 最近一次编译记录（`command` / `exitCode` / `executedAt` / `workingTreeDigest`）。T3 Complete 必填且 digest 须匹配当前工作区；`build/classes` 目录存在不算编译过 |
| `test-evidence.json` | T2 可选测试记录。文件存在则 `VerifyCompletion` 要求 exitCode=0 |
| `.workflow-owner.json` | 机器级活动归属的可读镜像 |

Superpowers 在 `docs/superpowers/` 下的 plan/ledger 是执行记录，不替代规范产物。主流程不使用 `.ai-sop/runtime/`（仅手动全功能审计的 `AUDIT_ONLY` 场景按需使用，不进主流程必经链）。

权威 owner 注册表是机器本地的，所有 worktree 共享。归属身份统一为 `SUPERPOWERS` workflow + Agent 字段（`CLAUDE_CODE`/`COPILOT`/`ANTIGRAVITY`/`CURSOR`/`CODEX`/`PI`）+ 不可变的功能运行 `ownerId`。

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
