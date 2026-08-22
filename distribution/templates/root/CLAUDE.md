# Claude Code 项目指令

@AGENTS.md

## Claude Code 专属差异

以下为 Claude Code 特有语法/约束，公共部分（Superpowers 流程、T 档、guard、归属、产物、并行、能力准入）由上方 `@AGENTS.md` 导入。

### Skill 工具显式调用

Claude Code 用 **Skill 工具**显式调用 Superpowers 技能（`superpowers:brainstorming` 等，见 AGENTS.md 工作流归属表）。**仅 T3 调用 Superpowers**；T2/T1/快通道不调用，直接用 AGENTS.md + 专家 Skills 推进。

### subagent_type 派发语法

Claude Code 用 **Agent 工具**作为独立 subagent 派发领域专家：

- `design-reviewer` 必须用 Agent 工具作为独立 subagent 派发（`subagent_type=design-reviewer`），**禁止用 `Skill()` 加载到当前上下文自审**（审查与设计同上下文共享盲区）。
- `design-architect` 修正也用 Agent 派发（`subagent_type=design-architect`）。
- 实现者/内审（`implementation-engine`/`implementation-auditor`/`logic-auditor`）在 `subagent-driven-development` 内由 subagent 派发。

其余公共约束（审查铁律、模型分级调度、不接管编排、不写 `.ai-sop/runtime/`）见 AGENTS.md「领域专家 Skills」。
