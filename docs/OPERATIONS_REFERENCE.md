# 日常任务扩展参考（验证、待办、哈希与诊断）

> 仅在需要执行验证批次续跑、FollowUp/ChangeTier/SetApplicability、修改已批准规格或运行 Inputs/Preflight 诊断时读取。纯问答、解释与只读审查无需读取本文件。

## 验证证据与启动起点

- **验证 Profile 与命令**：Profile 定义在 `.ai-workspace/context/verification-commands.json`；也可通过 `Task -Operation Run` 指定 `-Kind`、`-Batch`、`-Executable`、`-Arguments`。必须是真实构建/测试，不能用空命令或固定 `exit 0` 造成功。
- **批次复用与失败保留**：批次按验证目标命名，RED/GREEN 与修复后复测复用原 `Kind`/`Batch`，`Run` 自动保留尝试历史；同批次更换命令、Profile 或用例范围须写 `-Reason`。失败/超时/中断不能被无关批次或旧成功覆盖。`Run` 保存失败时保留 `pending.json`，按提示 `RetryEvidence`，不盲目重跑或改写证据哈希。
- **范围与参数传递**：T3 的 `SetCaseScope` 不替代 `Run` 的实际 `CaseIds`/`JUnit` 映射。参数数组在 PowerShell 内用 `& ./ai-sop.ps1` 传递，不能把逗号表达式直接传给 `pwsh -File`。多轮失败或过期批次细节见 `.ai-sop/docs/VERIFICATION_CONTINUATION.md`。
- **启动起点（`startInputs`）**：`Start` 自动记录 `startInputs`；T1/T2 轻量采集超限记 `UNAVAILABLE`，不阻塞普通编译/相关测试。预期申请执行豁免或后续升 T3 时，应在修改前运行：
  ```powershell
  pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Start -Feature <Feature> -TaskId <TaskId> -Objective "本次目标" -CaptureBaseline -Agent <工具> -NativeSessionId <会话ID>
  ```
  `Resume`/`Run` 不重拍起点，不能用修改后的快照补造原始基线。`TaskId` 表示一次独立修改，T3 计划中的 `Task`/`Step` 是内部执行单元。
- **进度与历史核对**：日常进度用 `Task -Operation Discover`，可加 `-Feature` 与 `-LogTailLines 20`（不扫描全部验证输入）。仅需核对当前证据时用 `Status`。终态默认 `HISTORICAL_NOT_RECHECKED`，后续改动不要求旧任务重跑；显式 `-RecheckHistory` 只检查所选历史证据，不重开任务。

## 待办、改档与适用性

- **待同步提醒（FollowUp）**：`AddFollowUp` 在来源任务中记录 `documentation` / `test-cases` / `verification`，含具体 `Summary` 和 `Scope`。`Start`/`Resume` 自动提醒一次并继续当前任务；不要求确认、不扩大范围、**不因待办升档或阻止完成**。解决后用 `CloseFollowUp` 记录 `Resolution`；人工明确无需处理才记 `NOT_NEEDED` 与 `-UserRequest`。`DONE` 不隐藏待办，新任务完成也不自动清除旧事项。
- **改档（`ChangeTier`）**：人工改档使用 `Task -Operation ChangeTier`，带 `-Tier`、`-Reason`、`-UserRequest`，保留历史失败与待办。
- **适用性（`SetApplicability`）**：纯文档仍用 T1/T2；执行豁免须通过 `SetApplicability` 校验本任务起点与 `Start` 前声明的 `nonExecutable` 路径，不能把源码/构建输入伪装成非执行输入。起点未知则正常验证；测试失败或环境故障不是“不适用”。`RecordSync` 的 `Tests=NOT_APPLICABLE` 不豁免测试执行。T3 不使用轻量豁免。

## 已批准文档与工程规范同步

- **重置批准 / 更新哈希**：修改已批准需求或设计的语义前，先运行：
  ```powershell
  pwsh -NoProfile -File ./.ai-sop/scripts/workflow-state.ps1 -Operation ResetApproval -Gate <requirement|design>
  ```
  T2 记录本次需求依据并同步受影响文档，不补完整 T3 批准；T3 修改后须重新确认并 `Approve`（重置 `requirement` 会同时重置 `design`）。仅错字、格式等不改语义的润色可用：
  ```powershell
  pwsh -NoProfile -File ./.ai-sop/scripts/workflow-state.ps1 -Operation UpdateHash -Gate <requirement|design>
  ```
  提交说明注明“不改语义”；判断不准时使用 `ResetApproval`。T1 延期同步记录 `FollowUp`。
- **工程规范与 `context/` 核对**：设计、实现、审查角色须读取实际存在的 `coding-style.md` 等默认工程规范，协议修改还须读 `proto-rules.md`；功能 `06` 不得违反强制规范。冲突记为设计缺陷，用 `ResetApproval -Gate design` 作废批准，不能因“与已批 06 一致”放行；人工确认的 `AUDIT-EXEMPT` 例外须有记录。派发专家时附规范路径，不以摘要替代原文。
- **缺失与过期 `context/`**：读取前检查存在性；缺失时简短提示并核对现行代码，不编造上下文、不因缺文件停工。过期 `context` 须提示；与现行代码不符时核实漂移，不按旧 `context` 改动已正确代码，详见 `.ai-sop/SUPERPOWERS_MANUAL.md`「项目上下文与能力诊断」。

## 只读诊断工具（Inputs / Preflight）

- **输入解释**：按需使用 `pwsh -NoProfile -File ./ai-sop.ps1 Inputs -ExplainOnly -InputPath <路径>` 解释输入选择；`-CandidatePolicy` 预览配置。
- **升级/交接预检**：`pwsh -NoProfile -File ./ai-sop.ps1 Preflight` 用于交接或升级只读排查，可用 `-Feature`、`-TaskId` 限定范围，`-TargetEnginePath` 比较版本兼容。
- 二者均不增加日常必经步骤，输出不代表验收通过。输入策略不能为消除过期证据而排除真实源码；修改策略前检查存量任务兼容性。缺失清单先同步或重跑，不改写成功摘要。
