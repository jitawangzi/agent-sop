# Legacy Gemini 兼容

`GEMINI` 仅作为受支持的遗留 owner 身份保留，以便已有运行可以恢复；新的 Google-agent 任务使用 Antigravity IDE/CLI。任务强度、独立修改和接管规则统一遵循 `AGENTS.md`，不因工具名称增加完整流程。

加载：

- `AGENTS.md`
- `ANTIGRAVITY.md`
- `.ai-workspace/context/README.md`

新任务通过 Task Start / Resume 等公共入口使用 `-Agent ANTIGRAVITY`；旧身份只通过已有的兼容接管流程恢复，不手改 owner 或沿用旧 Claim 创建新修改。
