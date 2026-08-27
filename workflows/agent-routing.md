# 基于 Agent 的工作流路由

五个 harness 统一使用 Superpowers 作为顶层调度器；无需 workflow-mode 提示。

| Agent | 顶层调度器 | Workflow owner 值 | agent 值 |
|---|---|---|---|
| Claude Code | Superpowers | `SUPERPOWERS` | `CLAUDE_CODE` |
| GitHub Copilot | Superpowers | `SUPERPOWERS` | `COPILOT` |
| Antigravity IDE/CLI | Superpowers | `SUPERPOWERS` | `ANTIGRAVITY` |
| Cursor | Superpowers | `SUPERPOWERS` | `CURSOR` |
| Pi | Superpowers（能力准入 BLOCKED，只 T2） | `SUPERPOWERS` | `PI` |

`CUSTOM_SKILLS` 与 `GEMINI` 作为兼容身份保留（供历史运行恢复等场景）；新流程统一使用 `SUPERPOWERS`，新的 Google-agent 任务使用 `ANTIGRAVITY`，与 Antigravity 选用的模型无关。

## 规则

1. 一个功能有且仅有一个活动的顶层调度器（Superpowers）。
2. 选定的 Agent 为每次功能运行生成一个不可变 `ownerId`，并从需求到交付始终持有归属。
3. 领域 Context 与规范功能产物是共享的。
4. 领域专家 Skill 被 Superpowers 强制绑定调用（实现/审计等），不接管编排。
5. 当 Superpowers 不可用时，**停止并报告必须安装它**；不要静默切换到其他调度方式。
6. 工作流切换是异常情况，必须在稳定产物边界、经用户明确指示后进行。
7. 任何修改规范功能产物、生产代码或业务测试入口的阶段都需要归属。只读审计例外。
8. 并行功能使用独立的 Agent session 和隔离工作目录。一个 Agent session 与工作目录只承载一个活动功能运行时。

归属通过 `.ai-sop/scripts/workflow-owner.ps1` 管理的机器级注册表协调；worktree 中的 `.workflow-owner.json` 只是可读镜像。
功能名必须与规范的 `.ai-workspace/specs/features/<FeatureName>` 目录一致。注册表 key 大小写归一化，因此别名与大小写变化无法制造并行 Claim。

修改型独立阶段在执行前生成并持久化 owner ID。独立阶段成功完成时立即调用 `workflow-owner.ps1 -Operation Complete`；失败或未解决阻塞时保留活动归属以便显式恢复。
长时运行或恢复的工作在每个修改批次前校验活动身份。生产代码编辑由 PreToolUse guard 在所有 harness 强制（见 `.ai-workspace/workflows/parallel-development.md`）。

运行时与 Tomcat 隔离定义于 `.ai-workspace/workflows/parallel-development.md`。

## 并行功能执行

并行功能执行与 Tomcat 隔离定义于 `.ai-workspace/workflows/parallel-development.md`。

## 双 Agent 协同审查路由 (Dual-Agent Review Routing)

当采用异构双 Agent（如 Antigravity 主开发 + Copilot 主审查，或 Claude Code + Cursor）交替迭代时：
- **Dev Agent** 持有活动的 Workflow Owner 归属，主导业务代码修改与测试执行；
- **Reviewer Agent** 作为独立只读审计角色，通过 `scripts/review-mailbox.ps1` 与规格产物 `review-mailbox.json` 进行结构化交互（详见 `workflows/dual-agent-review.md`）；
- 审查者无需 Claim 写归属，通过标准信箱契约输出 `APPROVED` / `REJECTED` 判定，驱动主开发 Agent 进行闭环修复。

