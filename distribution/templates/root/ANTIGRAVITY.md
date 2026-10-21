# Antigravity 项目指令

@AGENTS.md

## Antigravity 专属差异

任务强度、任务身份、接管、并行与完成条件统一遵循上方 `@AGENTS.md`；项目知识从 `.ai-workspace/context/README.md` 按需加载。以下仅说明 Antigravity 调用差异：

- Task Start / Resume 等写操作使用 `-Agent ANTIGRAVITY`；不以直接 Claim 替代公共任务入口。
- 能力准入以引擎配置及本机可用能力为准；STRICT 只表示可执行相应流程，不决定任务强度。T1/T2 不因使用 Antigravity 而增加 Superpowers 或独立审查步骤。
- Antigravity task/session 是工具会话，SOP taskId 标识一次独立修改；二者不要混用。继续原修改或切换 Agent 时通过公共任务入口接管，不要求整个功能固定在同一工具会话。
- 不同功能的并行会话使用独立 task/project 或 CLI session；工作区及测试数据隔离方式遵循公共指令与宿主上下文。
- `.agents/hooks.json` 从其所在目录运行 `hook-wrapper.ps1`，即项目的 `.agents/hook-wrapper.ps1`，再转发到 `.ai-sop/scripts/hook-dispatcher.ps1`。PreToolUse guard 对识别出的工作区写入检查当前会话的 ACTIVE task、合法档位及 owner 绑定；仅有旧 owner 时先 Resume 收编。配置存在不代表客户端已执行 Hook，不能承诺未接入或未识别路径的写前阻断。
- **SDD 编译准入（仅已选择的 T3 SDD 流程）**：使用 `invoke_subagent` / 自定义 Agent 派发专家时，必须等 `implementation-engine` 返回【编译证据】（`exitCode=0`）再派 `implementation-auditor` / `logic-auditor`，不得与实现者并行派审。一次只派一个计划 Task；禁止把 Task 1–N 打进同一实现者 prompt 后立刻审。编排会话的修复回派实现者 `REPAIR`，详见 `.ai-sop/workflows/agent-t3.md` 与 `.ai-sop/workflows/superpowers-adapter.md`「编译准入再审查」。

Antigravity 指令文件的自动发现能力因客户端版本而异。当 `AGENTS.md` / `ANTIGRAVITY.md` 未被自动加载时，请在 Antigravity Project/CLI context 中显式配置包含它们。
