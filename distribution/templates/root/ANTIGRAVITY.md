# Antigravity 项目指令

@AGENTS.md

## Antigravity 专属差异

公共部分（Superpowers 流程、guard、归属、并行、能力准入）由上方 `@AGENTS.md` 导入。以下为 Antigravity 特有：

- 功能归属 Claim 使用 `Workflow=SUPERPOWERS`、`Agent=ANTIGRAVITY`。
- Antigravity 能力准入判定为 STRICT，原生具备 invoke_subagent 与独立审查证据链，按变更类默认执行 Superpowers 流程（新功能/新协议/新存储走 T3）。
- 一个功能从开始到交付固定使用一个 Antigravity task/session 和一个隔离工作目录。
- 并行开发时使用独立的 Antigravity task/project 或 CLI session，扎根于独立 SVN working copy（代码隔离用 SVN 分支），遵循 `.ai-workspace/workflows/parallel-development.md`。
- 生产代码编辑由 `.agents/hooks.json` 的 PreToolUse guard 强制（hook 命令指向 `./.ai-sop/scripts/hook-dispatcher.ps1`，编辑前必须 ACTIVE SUPERPOWERS owner）。
- **SDD 编译准入（Antigravity 易踩）**：`invoke_subagent` / 自定义 Agent 不得与 `implementation-engine` 并行派 `implementation-auditor` / `logic-auditor`。必须等实现者返回【编译证据】（`exitCode=0`）再派审。一次只派一个 Task；禁止把 Task 1–N 打进同一实现者 prompt 后立刻审。编排会话不得 `Edit` 生产代码或测试源来「补编译错误」——回派实现者 `REPAIR`。详见 `AGENTS.md` 审查铁律与 `workflows/superpowers-adapter.md`「编译准入再审查」。

Antigravity 指令文件的自动发现能力因客户端版本而异。当 `AGENTS.md` / `ANTIGRAVITY.md` 未被自动加载时，请在 Antigravity Project/CLI context 中显式配置包含它们。
