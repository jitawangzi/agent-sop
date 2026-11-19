# 项目 Agent 指令（公共入口）

各工具统一遵循本文件；工具调用差异见各自根指令文件，项目知识按 `.ai-workspace/context/README.md` 按需加载。引擎在 `.ai-sop/`，规格与任务在 `.ai-workspace/specs/features/<FeatureName>/`。

## 首屏路由与红线

- **纯问答 / 解释 / 只读审查**：直接回答并按需读取工作区代码或 `.ai-workspace/context/README.md`；**不读 `.ai-sop/` 下的流程/参考文档，不跑 `Task Discover` / `Start` / `Resume`**。
- **独立 Bug 排查 / 疑似误报核查**：先按 `.ai-sop/skills/bug-debugger/SKILL.md` 做只读分诊与根因溯源（存在 `.ai-workspace/context/debugging-playbook.md` 时优先加载），**不提前 `Task Start`**；确认为需改代码/埋点后再进入下方修改入口。
- **转为修改源码、测试、配置或文档前**：先确定任务与档位；**主会话**必须 `Task Start` 或 `Resume` 成功后才写入，所有 `Task` 命令携带 Hook 注入的 `-Agent` 与 `-NativeSessionId`（通用 CLI 用稳定 `AI_SESSION_ID`，不借用旧 owner 身份）。
- **子会话边界**：**只读子 Agent** 只读取并返回报告，不调用 Start/Resume/Recover/ConfirmTakeover；读取失败报告具体路径或载荷错误。**实现子会话**先用自身会话参数 `Task Join` 回报 `nativeSessionId`，由父会话 `Task Delegate` 后执行，禁止 `Resume`/`ConfirmTakeover` 抢占父任务（详见 `.ai-sop/docs/EXECUTION_DELEGATION.md`）。

## 执行强度：默认 T2，人工显式选择优先

仅适用于已安装本 SOP 的宿主项目。接管继承原档位；新任务人工指定优先，未指定直接采用 **T2**，“简单改一下”“尽快处理”不等于 T1。Agent 可建议范围，**不自行升降档**，不因历史 T3 规格或工具能力强加完整流程。

| 档位 | 完成要求 | 流程 |
|---|---|---|
| T1 极速 | 完成实现，真实编译/基础检查通过，说明未验证范围；确有延期才记 `AddFollowUp` | 无独立审查；可延期文档与测试同步 |
| T2 快速（默认） | 明确验收点，完成实现，同步受影响需求/设计/用例，编译与相关测试通过，完成前 `RecordSync` | 不重复批准，不强制计划或独立审查 |
| T3 完整 | 当前范围的完整规格、批准、**先编译通过再内审**、独立审查、覆盖与验证；复用仍有效成果 | 执行前**必须先读** `.ai-sop/workflows/agent-t3.md` 和 `.ai-sop/workflows/superpowers-adapter.md` |

- **T1/T2 无独立代码审核环节**，不依赖 Superpowers 或独立 subagent；禁止在未明确升级时用 `dispatching-parallel-agents`、`using-git-worktrees`、`executing-plans`、`finishing-a-development-branch` 替代 SOP 编排。
- 有真实延期才用 `AddFollowUp`（解决后 `CloseFollowUp`），**不因待办升档或阻止完成**。

## 开始、执行、完成

1. 准备执行修改时，新任务、切换工作区或跨 Agent 接管先运行 `Task -Operation Discover`；同会话任务已明确时沿用 `taskId`。
2. 独立修改用 `Start`（T1/T3 须带 `-UserRequest` 原话；新功能名用 PascalCase），继续原修改用 `Resume`；**成功后才能写入**。首次修改前向用户简短说明实际档位与流程，同一任务不重复播报。
3. 编译/测试用 `Task Run` 留证；满足本档条件后直接 `Task Complete`（内含完成校验，不固定串行 Verify → Status → Complete）。

```powershell
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Start -Feature <Feature> -TaskId <TaskId> -Objective "本次目标" -Agent <工具>
# 默认 T2；人工选择 T1/T3 时加 -Tier T1 或 -Tier T3，以及 -UserRequest "实际选择原话"。
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Resume -Feature <Feature> -TaskId <TaskId> -Agent <工具>
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Run -Feature <Feature> -TaskId <TaskId> -Agent <工具> -Profile <名称>
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Complete -Feature <Feature> -TaskId <TaskId> -Agent <工具>
```

## 按需加载参考

- **Guard 拦截后的任务识别**：先 `Discover`，普通续做 `Resume`，异常中断先 `InspectRecovery` 再 `Recover → Resume`；恢复与并行细节按需读 `.ai-sop/docs/TASK_RECOVERY_GUIDE.md`、`.ai-sop/docs/EXECUTION_DELEGATION.md`。
- **验证证据、FollowUp、改档、哈希与诊断**：批次命名/`RetryEvidence`、`startInputs`、`AddFollowUp`/`CloseFollowUp`、`ChangeTier`/`SetApplicability`、`ResetApproval`/`UpdateHash`、`Inputs`/`Preflight`、工程规范与 `context/` 核对，按需读 `.ai-sop/docs/OPERATIONS_REFERENCE.md`、`.ai-sop/docs/VERIFICATION_CONTINUATION.md`。
- **旧功能级命令兼容**（无 taskId 旧归属/旧证据）：`.ai-sop/workflows/agent-legacy.md`。
- **其他按需参考**：审查材料与 `findings/` 读 `.ai-sop/docs/REVIEW_AND_FINDINGS.md`；门禁设计读 `.ai-sop/docs/QUALITY_GATES.md`；客户端 Hook 接入读 `.ai-sop/docs/HARNESS_ADAPTERS.md`；全功能审计（仅手动）读 `.ai-sop/skills/workflow-orchestrator/SKILL.md`；完整字段手册见 `.ai-sop/SUPERPOWERS_MANUAL.md`。

## 汇报与版本控制

- 版本控制遵循宿主约定；确认文件所属仓库，SVN 宿主不执行最终 `svn commit`。
- 收尾说明实际档位、改动、文档/用例同步依据、验证范围与 `Complete` 结果；拦截格式：`[SOP 拦截] <工具/任务> 因 <具体原因> 无法执行 <动作>；下一步：<具体恢复建议>`。
