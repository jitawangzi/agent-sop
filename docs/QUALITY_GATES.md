# 质量保证设计（Quality Gates）

## 任务模式：按本次修改验证

输入范围可由项目的 `.ai-workspace/context/verification-inputs.json` 配置：默认保守扫描不变，include 补入真实输入，exclude 用明确路径和理由排除输出。更具体路径优先，父目录 include 不解除子目录输出/日志排除；显式 include 可覆盖同路径默认排除，同路径 include/exclude 冲突则拒绝配置。配置摘要参与 inputs-v4，旧 v3 清单可读取但证据过期；无配置保持 inputs-v2，Git/SVN ignore 不是输入真源。活动 T3 的基线口径不可变，应在原引擎完成后升级输入规则，不能用升级理由重写起点。配置的语义正确性仍依赖项目维护者，不允许通过随意排除源码消除失败。新 Run 的完整输入清单按哈希保存于 `.ai-workspace/specs/.artifacts/inputs/`，task.json 引用 inputsRef；验证检查清单存在、内容哈希和输入摘要，缺失/损坏必须补同步或重跑。旧内嵌清单兼容，历史 DONE 不迁移。本地日志不参与完成判定。

一次 Status/Verify 使用同一调用内的内容快照；后续调用及 Run 的前后快照重新读取。Status 是诊断视图，`-Json` 提供固定结构；部署投影漂移只提醒，损坏规格 JSON 则在实际依赖它的 T3 校验中明确失败。Start 不得复用旧 TaskId 恢复暂停任务，Resume 不得静默丢弃新传入的不同目标。

当前默认入口是 `ai-sop.ps1 Task`（底层 `workflow-task.ps1`）。功能保存长期规格，每次独立修改有固定 taskId 和独立 T1/T2/T3（默认 T2，人工指定优先）；接管只更换执行会话，不改变任务身份或档位。本节描述任务模式；后续旧矩阵中的功能级证据要求仅用于未提供 taskId 的兼容路径。

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

`VerifyCompletion -TaskId` 一次输出缺失命令记录、失败批次、输入变更文件和 T3 规格问题；`CheckCompletion -TaskId` 使用同一检查但仅作诊断。原有 `testCount >= cases.Count` 数量代理已经移除，旧记录仍必须真实成功且数量自洽。

验证输入使用内容指纹 `inputs-v2`，覆盖工作区中的保守输入集合（包括公共源码、测试、构建及依赖声明），不受暂存或提交状态影响。常规 build/target/bin/obj/out/classes 仅在工作区根或可识别的 Maven/Gradle 模块根排除，不按任意层级的源码包名过滤；有 web.xml 的 WEB-INF/classes 为标准 Java Web 编译输出，排除 classes 而保留 web.xml。另排除治理目录、worktree 的 .git 文件、根 .ai-sop-staging、依赖缓存、滚动日志与临时文件。依赖锁文件仍属于输入。算法版本参与摘要，旧 v1 证据需重新运行验证，历史 DONE 不迁移。未排除的符号链接会明确失败，不静默漏掉链接输入。该快照不等于密封构建：外部服务、未声明环境和工具链变化仍需控制器判断并重跑；不同工作区及合并后的代码不能仅凭各自历史 PASS 宣称集成通过。

`Run` 在执行前后采集输入，输入变化则保留失败诊断、禁止完成。不能给旧成功结果换一个新哈希。不同测试批次可在相同输入下累计；失败批次必须以同批次的真实成功复跑解决。新记录不因单纯经过 7/30 天而失败，旧格式保留原校验以免静默改变证据含义。

T3 Start 固定任务的修改前内容清单，长期功能批准基线独立保留。所有新任务的 startInputs 与任务创建事务绑定，T1/T2 默认尝试 500ms/8MiB 预算采集，超限或失败记 UNAVAILABLE，部分清单不保存；Start -CaptureBaseline 可显式完整采集而不改变档位。预算不保证底层 IO 或整个 Start 的硬耗时。普通 T1/T2 编译/相关测试不要求起点可用。`Changes` 返回相对任务基线的内容差异；`ReviewImpact` 将 04 的 taskId、baseline、baselineInputDigest、changedFiles、changeSetDigest 与实际差异核对，并保存可交接的 `.ai-workspace/specs/.artifacts/changes/` 清单。Verify 同时检查 04、完整输入和差异清单，不能仅通过重填 inputDigest 复用旧分析。这是显式确认分析的动作，不是自动修复分析。更改已批准需求设计语义应 ResetApproval，T3 重新批准；T2 记录变更依据并同步，不要求当次补完整批准。

T3 用 `SetCaseScope` 显式登记本任务 requiredCaseIds 和理由，包含影响分析声明的回归用例；规格变更后重新核对。必测用例的载体、断言和本任务执行证据必须有效，不强制执行整个功能的其他用例；整体规格批准及覆盖定义仍检查。独立新任务另取基线与范围；ChangeTier/SetBaseline 只复用当前任务 Start 已登记的引用，Run 清单或口述理由不能证明修改前来源。缺起点时拒绝升级并保留原档位。旧 T3 source=START 保持兼容，旧 ADOPTED 无来源证明则明确诊断，不能判为无差异；历史 DONE 不迁移。任务必须先 Start 再改动；该机制不防御同权限主体直接篡改引擎或任务记录。

可选 JUnit XML 映射核对本次报告的 classname/name、成功状态及文件更新，CaseIds 从报告派生；缺失、陈旧、跳过或失败的映射不能通过。它不替代测试语义审查，也不对同权限恶意进程提供防伪保证。T1/T2 不新增此项必做流程。

T1/T2 的执行入口不计算规格摘要，轻量 Verify 的风险扫描失败仅提示，不让历史规格损坏间接升级成完成门禁。T3 测试仍读取并绑定需求、设计和测试定义。

验证命令在启动前写入 RUNNING，避免进程突然退出后更早的成功记录成为“最新结果”。终态记录同批次替换该次尝试，超时/中断均不能满足必需验证。Task Status 和根 Status 采用相同摘要，但执行证据有效不等于完整 T3 验收。Recover/ForceRelease 同步恢复任务、归属和会话，未结束的本机验证进程不能绕过。

新记录使用执行协议 2：Checkpoint 只接受任务目录内的 runId 待保存文件，新尝试必须为 RUNNING，终态必须匹配既有尝试的任务、会话 epoch、命令、输入、用例范围和运行器身份。改变同一批次的验证定义需提供 Reason，保留替换关系。运行期间 Checkpoint 仅续期原绑定会话；终态结果先原子落盘，事务失败保留，RetryEvidence 可幂等重试，Recover 可接收已停止本地运行的匹配终态结果。路径、进程和摘要校验用于正常接口的完整性检查；拥有引擎与注册表写权限的同一主体仍可修改文件，不宣称实现了对恶意本地写入的防伪。

运行中的会话读取/续期锁超时仅在最后确认的租约有效期内退避重试，连续失败最多 30 秒，每次重试的锁与事务阶段共享最多 3 秒预算，且受原租约/重试截止时间约束。会话结束、归属或 epoch 改变不重试；租约到期或耗尽重试窗口停止子进程并记录 INTERRUPTED/RUN_CONTROL_INTERRUPTED，与真实子进程非零退出的 FAILED 区分。最终保存失败仍保留原始结果，不通过延长重试窗口复活旧会话。

损坏待入账结果默认阻断恢复；InspectRecovery 只读诊断。原进程停止后可显式 QuarantineInvalidEvidence，先保存原字节和哈希再以两阶段事务记为中断，必须重跑；损坏 task/owner/session 不自动猜测修复。日志路径先准备再登记 RUNNING，避免尚未启动就留下虚假运行状态。

暂停释放的是执行占用，不是验收义务；本次 T2 DONE 不能替原 T3 宣告功能整体完成。独立后续任务不继承旧测试欠账，实际依赖与代码重叠仍需先辨明。

ChangeTier 是人工调整交付要求的显式操作，需要原话和原因；不清除失败证据，不重置任务身份。Status 始终显示最新失败批次，包括 T1 不强制要求的测试，避免把“按 T1 完成”写成“全部测试通过”。

T2 必须有 RecordSync；机器验证记录结构，不声称能够证明设计和代码语义一致。FollowUp 的判定、范围和关闭依据同样由 Agent 核实，标记本身永远不作为完成门禁。Start/Resume 每次只提醒一次，不自动加入后续任务。更新走现有 Owner Checkpoint 事务和锁，不引入第二套状态写入机制。

T1/T2 的 NOT_APPLICABLE 必须提供具体理由，同时绑定 startInputsRef 和当前输入。声明及 Verify 都检查起点到当前的全部输入增删改仅落在项目预先配置的 nonExecutable 字面路径中，并检查输入策略未变；未配置路径按可能执行输入处理。这些文件仍被哈希，不能用事后改配置或重声明消除源码变化。起点未知、旧豁免无起点绑定时改回 REQUIRED 并正常验证，不自动升级档位。不能豁免尚未解决的失败或环境故障；T3 不接受此轻量豁免。nonExecutable 的语义正确性仍由项目维护者/Agent 负责，不以扩展名猜测语义。旧任务仍能读取，正常 T1/T2 验证不要求补起点，不强制迁移历史 DONE。

> 面向：维护 SOP 的人，以及需要分清「机器查什么 / AI 自报什么」的人。  
> 操作清单（命令、完成表）仍以宿主投影 `AGENTS.md`「完成定义」为准。  
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

第三类要 JUnit XML / subagent transcript 才接近防伪，成本高一个数量级。当前刻意不做到那一层。任务级「先编译再审」靠 controller 纪律 + auditor 拒 PASS，不加第四类机器门禁。

---

## 2. 分层（从外到内）

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

## 3. 机器硬门禁 vs AI 自报

`VerifyCompletion`（`Complete` 内嵌）只认磁盘上的契约与证据。下表是单一真源。

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

## 4. 证据怎么绑（防过期）

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

## 7. 明确不做（现在）

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

---

## 8. 下一刀（收益序）

1. **流程，不是引擎**：用新 FeatureName 走完一次 T3 到 Complete（忽略已交付旧目录）。看 AI 会不会忘写 07 / compile-evidence、LintSpecs 卡在哪，用卡点反哺。
2. **若 07 在真 T3 上稳定且内审常被跳过**：再给 implementation-auditor / logic-auditor 加与 07 同构的报告 + SHA 绑定。
3. **若真撞到**：规格只写包名导致 `FEATURE_SCOPE_UNRESOLVED` 误要 04 → 再加宽定位。
4. **不优先**：Hook AST 扩面、JUnit XML、transaction flake、真机认证。

---

## 9. 命令

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
