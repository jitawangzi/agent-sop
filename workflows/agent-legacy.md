# 旧流程兼容与诊断参考

> 仅在处理无 taskId 的存量归属、feature-state.json 或旧功能级证据时读取。新修改与已有 taskId 的接管遵循项目根 AGENTS.md 的 Task 入口；不从本文件创建新的功能级流程。

## 旧功能级命令兼容

**旧功能级命令兼容**：下方 Claim / Validate / Complete / Transfer 示例仅用于尚未迁移、没有 taskId 的存量归属；有 taskId 时使用任务入口，不混用完成语义。各 harness 统一 `SUPERPOWERS` 归属（它是身份标识，不代表 T1/T2 依赖完整 Superpowers 流程），`agent` 字段区分实际工具。

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

## 任务写前 Guard

新版 Guard 对实际接入 Hook 且识别出的工作区 FILE_EDIT 检查当前会话关联的 ACTIVE task、合法档位及 owner 身份。历史 ACTIVE owner 没有 taskId 时不能直接编辑；先 Discover 辨明原任务，再显式 Resume 收编并保留原档位、批准与身份。直接 Claim / Transfer 只用于兼容诊断和恢复，不代替写前任务入口；无可信起点的旧 T3 仍遵守原引擎收尾限制。

正常 T1 也需要任务、编译/基础验证及 Complete。`AI_SOP_SKIP_OWNER_GUARD`（兼容 `SERVER_NEW_SKIP_OWNER_GUARD`）、`.ai-sop/.guard-disabled` 和一次性 `.guard-token.json` 保留为人工明确要求的紧急维护入口，输出 GUARD_DISABLED / GUARD_DISABLED_FOR_FEATURE，不能称作 T1 或小改快通道。Agent 不得自行启用；发现已停用时明确提醒其当前不提供写前防护，维护结束后恢复。设置这些开关本身不构成任务完成或自动豁免审查。

只读讨论无需任务；Hook 未接入或未识别的调用不承诺写前阻断，Codex 原生 Hook 需客户端审核信任，Pi 扩展需实际加载。边界与操作细节见 `.ai-sop/SUPERPOWERS_MANUAL.md`「任务写前 Guard」。

## 跨工具交接状态（feature-state.json）

任务模式的进度以 `tasks/<taskId>/task.json` 为准，使用 Task Status / Checkpoint。下面的 `feature-state.json` 仅供旧流程恢复参考，不作为新任务身份或完成状态：

```powershell
pwsh -NoProfile -File ./.ai-sop/scripts/feature-state.ps1 -Operation Get -Feature <FeatureName> -SpecDirectory ".ai-workspace/specs/features/<FeatureName>"
```

输出当前 phase/完成步骤/下一动作/最近验证结果。AI 每完成一个阶段（Claim/需求确认/设计确认/实现/审计/验证）后用 `-Operation Set` 更新进度，供下次或换工具时恢复。

## 完成验证

新任务按宿主根 `AGENTS.md` 的档位要求使用 Task Run 留证，再 Task Complete；Verify 仅作可选的提前诊断。以下覆盖校验示例用于 T3 或旧流程诊断（任务模式调用 ValidateTestCoverage 时加 `-TaskId`）；修改 SOP 脚本本身时另须运行聚合测试。普通宿主 T1/T2 不默认执行 SOP 全量套件或完整覆盖检查：

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\run-all-tests.ps1 -IncludeCompile
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-state.ps1 -Operation ValidateTestCoverage `
  -Path ".ai-workspace\specs\features\<FeatureName>\05_test_coverage.json"
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-state.ps1 -Operation LintSpecs `
  -Path ".ai-workspace\specs\features\<FeatureName>" -Phase PLAN
```

`run-all-tests.ps1` 默认跑工作流脚本测试；`-IncludeCompile` 额外跑 `gradlew compileJava`。全过 exit 0。最后由 `verification-before-completion` 复查。

## 门禁状态诊断（Status）

旧 `CheckCompletion` 的 exit 0 不等于完成门禁通过，必须读取返回的诊断；新任务只以 Task Complete 成功作为完成并释放归属的依据。FAST_TRACK 仅用于读取历史任务，不创建第四档新任务。

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
