# 项目 Agent 指令（公共入口）

各工具统一遵循本文件；工具调用差异见各自根指令文件，项目知识见 `.ai-workspace/context/README.md`。路径均相对 Agent 启动的项目根：引擎在 `.ai-sop/`，项目上下文在 `.ai-workspace/context/`，功能规格与任务在 `.ai-workspace/specs/features/<FeatureName>/`。

## 执行强度：默认 T2，人工显式选择优先

本规则仅适用于已安装本 SOP 的宿主项目，不向普通未安装项目或引擎开发仓库传播。讨论、解释和只读审核无需选择档位、Discover 或认领；转为修改源码、测试、配置或项目文档前，必须先确定本次任务与档位。

档位属于本次任务。接管继承原档位；独立新任务人工指定优先，未指定直接采用 T2，无需确认。“简单改一下”“尽快处理”不等于选择 T1。Agent 判断影响范围并提出建议，**不自行升降档**，不因历史 T3 规格、协议/存储关键词或工具名称强加完整流程。

| 档位 | 完成要求 | 流程 |
|---|---|---|
| T1 极速 | 完成实现，真实编译/基础检查通过，说明未验证范围；确有延期才记 FollowUp | 无需头脑风暴、正式计划、独立审核；可延期文档与测试同步 |
| T2 快速（默认） | 明确验收点，完成实现，同步受影响需求/设计/用例，编译与相关测试通过，记录 RecordSync | 不重复批准需求设计，不强制计划或独立审核 |
| T3 完整 | 当前范围的完整规格、批准、独立审查、覆盖与验证；复用仍有效的成果，不重复已满足步骤 | 执行前必须读取 `.ai-sop/workflows/agent-t3.md` 和 `.ai-sop/workflows/superpowers-adapter.md` |

**T1/T2 无独立代码审核环节**，不依赖 Superpowers 或独立 subagent。已选 T3 却缺少能力时说明缺口，由用户决定切换工具或改档；STRICT 表示具备 T3 能力，不替用户选择档位。

**T1**：协议源文件、生成代码及生效所必需的配置属于实现，不能按“文档后补”延期。恢复既有约定、修改注释等，不自动产生补文档/测试任务。有真实延期才用 AddFollowUp 留下具体范围，不能只写在聊天里。

**T2**：用户已给出的明确需求直接作为依据，只澄清关键歧义。按实际影响修改现有条款、设计段落与测试，不强制新建整套 01/06/05。完成前 `RecordSync`：Documentation=UPDATED/UNCHANGED；Tests=UPDATED/UNCHANGED/NOT_APPLICABLE；Summary 写清同步范围及无需更新的依据。机器检查记录完整性，Agent 核实内容。常规使用相关单元/模拟测试，不默认启动完整业务环境；集成验证缺口如实说明并按任务目标安排。

**改档与适用性**：人工改档使用 ChangeTier，带 Tier、Reason、UserRequest，保留历史失败与待办。纯文档仍用 T1/T2；执行豁免须通过 SetApplicability 校验本任务起点与 Start 前声明的 nonExecutable 路径，不能把源码/构建输入伪装成非执行输入。起点未知则正常验证；测试失败、环境故障不是“不适用”。RecordSync 的 Tests=NOT_APPLICABLE 不豁免测试执行。T3 不使用轻量豁免。

## 开始、执行、完成

**只读子 Agent**：审查只读取工作区文件并返回报告，由 controller 保持任务归属和记录门禁。子会话不调用 Start、Resume、Recover 或 ConfirmTakeover，不修改规格、代码及权限记录。读取失败时报告具体路径/载荷错误，不以接管父任务绕过；子会话 ID 不等于写入授权。需要修改时由 controller 执行，或使用已验证的显式委派/串行交接机制，不假定子 Agent 自动继承权限。

1. 准备执行修改时，新任务、切换功能/工作区或跨 Agent 接管先 `pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Discover`，区分独立修改、原任务续做、补收尾。多个候选才询问一次，无需固定接管口令。同会话任务已明确时沿用 taskId，不按文件或回复重复 Discover/Resume。
2. 独立修改用 Start，继续原修改用 Resume；**操作成功后才能写入**。新 Start 未指定档位为 T2；选择 T1/T3 必须带 `-UserRequest` 保存已有人工原话，不编造或为已明确选择重复确认。沿用现有 FeatureName，独立小任务使用新的 taskId；新功能名使用 PascalCase（`[A-Z][A-Za-z0-9]+`，无连字符）并向用户回显，不为躲避旧任务状态改功能名。
   首次修改前，依据登记结果向用户简短说明“本次按 **T2（默认）** 执行：修改实现、同步受影响文档和用例，完成编译及相关测试”；人工选择或续做则注明来源及实际档位义务。同一任务不重复播报；接管、新任务或改档时再说明。子 Agent 沿用 controller 的 taskId、档位与工作范围，不自行默认成 T2 或另建任务；这些上下文不自动授予子会话写权限。
3. 编译/测试用 Task Run 记录真实执行。满足本档条件后直接 Complete；它内含完成校验，成功才标记 DONE 并释放归属。Verify 仅用于提前诊断，不固定串行 Verify → Status → Complete；失败后修复具体缺项，条件未变不反复重试。

```powershell
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Start -Feature <Feature> -TaskId <TaskId> -Objective "本次目标" -Agent <工具>
# 上例默认 T2；人工选择 T1/T3 时加 -Tier T1 或 -Tier T3，以及 -UserRequest "实际选择原话"。
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Resume -Feature <Feature> -TaskId <TaskId> -Agent <工具>
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Run -Feature <Feature> -TaskId <TaskId> -Agent <工具> -Profile <名称>
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Complete -Feature <Feature> -TaskId <TaskId> -Agent <工具>
```

上述命令由 Agent 根据已明确的任务直接执行并读取结果。`-Agent` 使用实际工具身份；通用 CLI 用稳定的 AI_SESSION_ID 标识同一会话，不借用旧 owner 的会话身份。

**验证证据**：Profile 定义在 `.ai-workspace/context/verification-commands.json`；也可 Run 指定 Kind、Batch、Executable、Arguments。必须是真实构建/测试，不能用空命令或固定 exit 0 造成功。同批次更换命令、Profile 或用例范围须写 Reason；失败/超时/中断不能被无关批次或旧成功覆盖。Run 保存失败时保留 pending.json，按提示 RetryEvidence，不盲目重跑或改写证据哈希。

**启动起点**：Start 自动记录 startInputs；T1/T2 的轻量采集超限记 UNAVAILABLE，不阻塞普通编译/相关测试。预期申请执行豁免或后续升 T3 时，可在修改前 Start -CaptureBaseline。Resume/Run 不重拍起点；不能用修改后的快照补造原始基线。TaskId 表示一次独立修改，T3 计划中的 Task/Step 是内部执行单元。

**待同步提醒**：AddFollowUp 在来源任务中记录 documentation / test-cases / verification，含具体 Summary 和 Scope。Start/Resume 自动提醒一次，继续当前任务；不要求确认、不扩大范围、**不因待办升档或阻止完成**。解决后 CloseFollowUp 记录 Resolution；人工明确无需处理才记 NOT_NEEDED 与 UserRequest。DONE 不隐藏待办，新任务完成也不自动清除旧事项。

## 暂停、接管与异常

长任务的重要节点按需 Checkpoint；短 T1/T2 不为每次编辑写检查点。暂停直接 Suspend 并带 NextAction/Notes，保存进度并释放占用；Cancel 表示取消，不表示完成，也不撤销实际代码修改。旧任务暂停后可启动独立小任务，无需先通过旧完成门禁。

**写前检查**：实际接入 Hook 的编辑路径会核对当前活动任务、合法档位及 owner/session 身份；只有旧 owner 没有 taskId 时须 Resume 收编。正常 T1 也必须登记和验证；人工紧急停用 Guard 是独立维护操作，不代表 T1 合规或完成，Agent 不得自行启用。客户端未加载或未信任 Hook、或写入路径不触发 Hook 时，不能承诺机器阻断；开场说明和 Complete 仍须遵守。

**写入 Guard 拦截后的任务识别**：Discover 确认 Feature/taskId；普通续做 Resume，异常中断先 InspectRecovery，按诊断 Recover → Resume。不得直接 Claim、手写权限或启用绕过开关规避任务入口。确认旧 Agent 已停止且验证进程不再运行，才进行强制恢复；已明确授权的接管不重复询问。跨 ACTIVE/IDLE 会话的正常接管按提示使用 ConfirmTakeover。

**损坏与未决状态**：保留原始记录和日志；InspectRecovery 只读定位问题。待入账证据损坏且进程已停止时，显式 Recover -QuarantineInvalidEvidence -Reason 保存原字节并记中断，再恢复执行。权限记录损坏依靠可信备份/事务恢复，不能删除后猜测重建。WORKFLOW_TRANSACTION_INDETERMINATE 先 Preflight；无法确定状态时停止修改并报告，不用 ForceRelease 绕过。

**旧功能级命令兼容**：仅在处理无 taskId 的旧归属、feature-state.json 或旧执行证据时，读取 `.ai-sop/workflows/agent-legacy.md`。旧 ACTIVE owner 的显式 Resume 收编保留原身份与批准；历史档位不明确时先确认，不默认按 T2 收编。缺少原始起点的旧 T3 不能用当前快照伪造恢复。本次任务 DONE 不代表旧 T3 或整个功能已验收。

**并行与同步**：同一工作区同功能仍串行。不同工作区允许同功能 T1/T2 之间、T3 与 T1/T2 并行，各用不同 TaskId、独立代码和规格副本；T3 + T3 暂不支持。不同功能可并行。同步来的外部 ACTIVE 记录不授予本地权限；无跨机器实时锁，未同步冲突无法自动探测。接管同一任务仍先在原处 Suspend，再同步相同代码及规格/任务记录，接收端 Resume。`.ai-workspace` 与 `specs` 按实际 Git 归属分别同步，`.artifacts/` 随 specs 保存；本机 Session/Grant/owner 和 `.runtime/` 不同步为权限。合并结果重新验证，误开 T3 + T3 的保全与恢复见 `.ai-sop/docs/PARALLEL_TASKS.md`。

## 项目知识与文档一致性

按 `.ai-workspace/context/README.md` 加载项目知识；`project-summary.md`、`coding-style.md`、`business-logic-pattern.md`、`project-tooling.md` 存在时须阅读，领域规则按需加载。读取前检查存在性；缺失时简短提示并检查现有代码，不编造上下文、不因缺文件停工。过期 context 须提示；与现行代码不符时核实漂移，不按旧 context 改动已正确的代码。详细降级与更新规则见操作手册「项目上下文与能力诊断」。

设计、实现、审查角色须读取实际存在的 coding-style.md 等默认工程规范，协议修改还须读 proto-rules.md；功能 06 不得违反强制规范。冲突记为设计缺陷，用 `ResetApproval -Gate design` 作废批准，不能因“与已批 06 一致”放行；人工确认的 AUDIT-EXEMPT 例外须有记录。派发专家时附规范路径，不能以摘要替代原文。领域规则由宿主 context 注入。

**已批准文档**：修改语义前用 `workflow-state.ps1 -Operation ResetApproval -Gate <requirement|design>`；T2 记录本次需求依据并同步，不补完整 T3 批准。T3 修改后须重新确认 + Approve；requirement 重置会同时重置 design。仅错字、格式等不改语义的润色可用 `workflow-state.ps1 -Operation UpdateHash -Gate <requirement|design>`，提交说明注明“不改语义”；判断不准时 ResetApproval。T1 延期同步记录 FollowUp。

版本控制遵循宿主 context 和用户约定；先确认每个文件实际所属仓库，提交只含本任务相关改动。新增/删除后立即用相应 VCS 登记，不拖到交付；重命名/移动优先用 VCS move 保留历史。SVN 宿主的最终 svn commit 由人工执行，本地 Git 检查点不代表 SVN 交付；不推送到未批准的 remote，不用文件覆盖代替合并。

## 按需加载与诊断

| 触发场景 | 读取/执行 |
|---|---|
| 已选 T3 或续做 T3 | **必须先读** `.ai-sop/workflows/agent-t3.md`、`.ai-sop/workflows/superpowers-adapter.md`；保持先编译通过再内审，独立审查与批准门禁 |
| 旧归属、旧证据恢复 | `.ai-sop/workflows/agent-legacy.md` |
| 专家实现/审查已被任务要求 | `.ai-sop/skills/<role>/SKILL.md`；T1/T2 不因工具能力自动增加独立审查 |
| 字段、命令或恢复细节 | `.ai-sop/SUPERPOWERS_MANUAL.md`、`.ai-sop/workflows/shared-artifacts.md` |
| 门禁设计与自报边界 | `.ai-sop/docs/QUALITY_GATES.md` |
| 手动全功能审计 | `.ai-sop/skills/workflow-orchestrator/SKILL.md`；不作为日常 T1/T2 步骤 |

日常进度用 Task Discover，可加 -Feature 与 -LogTailLines 20；它不扫描全部验证输入。需要核对当前证据才用 Status。终态默认 HISTORICAL_NOT_RECHECKED，后续改动不要求旧任务重跑；显式 -RecheckHistory 只检查所选历史证据，不重开任务。

按需使用 Inputs -ExplainOnly -InputPath 解释输入选择；-CandidatePolicy 预览配置。Preflight 用于交接/升级只读排查，-Feature/-TaskId 限定范围，-TargetEnginePath 比较版本兼容。二者不增加日常必经步骤，输出不代表验收通过。输入策略不能为消除过期证据而排除真实源码；修改策略前检查存量任务兼容性。缺失清单先同步或重跑，不改写成功摘要。

全档不得用 dispatching-parallel-agents、using-git-worktrees、executing-plans、finishing-a-development-branch 替代本 SOP 编排；具体工作区隔离遵循宿主约定。T3 Superpowers 缺失时按 `.ai-sop/SUPERPOWERS_VERIFICATION.md` 处理，由人工决定更换工具或改档。

## 汇报

开始、长耗时操作、重要结论、阻塞和交接时简短说明进展。收尾报告实际档位、改动、文档/用例同步或无需更新的依据、验证范围，以及 Complete 是否成功；不能只改代码就宣称 T2 完成。编译通过不等于行为测试通过，单元测试不等于完整业务验证。允许暂停或报告未完成，不以阻止结束回复代替完成检查。除首次修改前的档位说明外，无需固定状态行，也不为汇报专门重复 Status。澄清每轮最多 3 个聚焦问题；需求明确且已授权时连续执行。

遇到拦截明确说明：`[SOP 拦截] <工具/任务> 因 <具体原因> 无法执行 <动作>；下一步：<具体恢复建议>`。交接写清 Feature、taskId、档位、已完成与未解决项。报告已覆盖场景的结果，不宣称绝对无缺陷。

客户端 Hook 注入了当前会话标识时，所有 Task 命令携带其指定的 -Agent 与 -NativeSessionId；不要把子进程 PID 当作新会话。各客户端启用、信任与验证见 .ai-sop/docs/HARNESS_ADAPTERS.md。
