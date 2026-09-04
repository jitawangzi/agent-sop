# AI SOP 核心底座开发指令（Meta-Governance Framework）

> 本仓库是 **通用 AI Agent 研发治理平台与运行时操作系统（AI SOP Engine）** 的独立开发工作区。
> 本工程专注于流程编排、门禁治理、会话锁、事务协调器、跨 Agent 协议与自动化测试。**禁止引入任何特定业务领域（如具体游戏业务代码、特定数据库表或业务错误码）的硬编码。**

---

## 一、工程定位与核心职责

- **语言与技术栈**：PowerShell 7 (`pwsh`), JSON Schema (Draft 2020-12 / Draft 7), Markdown 规范体系。
- **治理目标**：为 Claude Code、Antigravity、Cursor、GitHub Copilot、Pi 等各类 AI 编程助手提供统一的生命周期锁、物理防越权 Hook、SHA-256 防篡改门禁与标准化交付闭环。

---

## 二、测试与验证单一真源（Hard Requirement）

任何脚本修改、Schema 调整或规范更新，在声称完成或提交前，**必须执行全量自动化测试套件**：

```powershell
pwsh -NoProfile -File ./scripts/run-all-tests.ps1
```

- **合格标准**：必须达到 **100% PASS**（所有 14 套测试全部绿灯）。
- **单模块调试**：
  - 门禁状态机：`pwsh -NoProfile -File ./scripts/tests/workflow-state.tests.ps1`
  - 归属与锁：`pwsh -NoProfile -File ./scripts/tests/workflow-owner.tests.ps1`
  - 会话管理：`pwsh -NoProfile -File ./scripts/tests/workflow-session.tests.ps1`
  - 事务与锁：`pwsh -NoProfile -File ./scripts/tests/workflow-transaction.tests.ps1`
  - 授权令牌：`pwsh -NoProfile -File ./scripts/tests/workflow-command-grant.tests.ps1`
  - 安装与投影：`pwsh -NoProfile -File ./scripts/tests/ai-sop-installer.tests.ps1`
  - 端到端烟测：`pwsh -NoProfile -File ./scripts/tests/e2e-t2-smoke.tests.ps1`

---

## 三、核心架构铁律（Invariants）

1. **100% 领域中立（Domain-Agnostic）**：
   - 核心脚本（`scripts/`）、Schema 定义（`schemas/`）与通用技能（`skills/`）只定义通用的软件工程方法论、治理流程与审计规则；具体的业务框架、数据结构与编码风格由接入项目的 `context/` 注入。
2. **跨平台兼容与路径规范化**：
   - 必须兼容 Windows、Linux 与 macOS。在 POSIX 环境下使用原生 `.NET` 托管 API 解析，在 Windows 下使用 Win32 句柄解析。
   - 所有工作区路径必须经过 `Resolve-PhysicalPathIdentity` 规范化，杜绝路径穿越与大小写/符号链接逃逸。
3. **两阶段事务与有序文件锁（Schema 1.1）**：
   - 状态写入必须通过 `Invoke-AiSopWorkflowTransaction` 实现两阶段提交，支持 crash 自动回滚与未决重放。
   - 并发锁必须严格遵循锁定顺序：`Session Lock -> Owner Lock -> Grant Lock`，防止死锁。
4. **多租户工作区隔离**：
   - 全局注册表默认使用基于物理工作区路径的 SHA-256 Scope 隔离，防止单机多工程并发互相踩踏。
5. **分发投影完整性（Distribution）**：
   - 涉及安装器或模板文件改动时（如 `distribution/templates/root/AGENTS.md`），确保 `distribution/project-manifest.json` 中的组件与哈希值同步更新。

---

## 四、文档与技能规范

- **用户操作手册**：SOP 操作指南为 `SUPERPOWERS_MANUAL.md`，工作流适配器为 `workflows/superpowers-adapter.md`。
- **质量保证设计**：机器门禁 vs 自报、证据绑定、明确不做见 `docs/QUALITY_GATES.md`。
- **模板单一真源**：下游宿主工程所使用的 Agent 指令模板维护在 `distribution/templates/root/AGENTS.md`。
- **专家 Skill**：`skills/` 下的专家 Skill（`implementation-engine`, `logic-auditor`, `design-reviewer` 等）仅定义角色职责与通用检查清单，不硬编码具体业务专有名词。

---

## 五、提交与推送约定

- **本仓库（agent-sop）**：改动完成后默认 `git commit` 并 `git push` 到 `origin`。
- **宿主 SVN**：生产代码 / `WebRoot` / `src` **不要** `svn commit`（仍由人工提交团队真源）。
- **宿主 `.ai-workspace/`**：该目录是独立 git（`ai-workspace.git`）。其中的修改默认在该嵌套仓库里 `git commit` 并 `git push`。不要把宿主根目录 git 里的 `.ai-sop`、生产文件或未相关 context 一并提交。
