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

- **合格标准**：必须达到 **100% PASS**（所有测试套件全部绿灯）。
- **单模块调试**：
  - 门禁状态机：`pwsh -NoProfile -File ./scripts/tests/workflow-state.tests.ps1`
  - 归属与锁：`pwsh -NoProfile -File ./scripts/tests/workflow-owner.tests.ps1`
  - 会话管理：`pwsh -NoProfile -File ./scripts/tests/workflow-session.tests.ps1`
  - 事务与锁：`pwsh -NoProfile -File ./scripts/tests/workflow-transaction.tests.ps1`
  - 授权令牌：`pwsh -NoProfile -File ./scripts/tests/workflow-command-grant.tests.ps1`
  - 安装与投影：`pwsh -NoProfile -File ./scripts/tests/ai-sop-installer.tests.ps1`

---

## 三、核心架构铁律（Invariants）

1. **100% 领域中立（Domain-Agnostic）**：
   - 核心脚本（`scripts/`）、Schema 定义（`schemas/`）与通用技能（`skills/`）只定义通用的软件工程方法论、治理流程与审计规则；具体的业务框架、数据结构与编码风格由接入项目的 `context/` 注入。
2. **AST 语法树与路径规范化**：
   - 所有命令解析（如 `ConvertFrom-AiSopOwnerCommandIntent`）必须使用 PowerShell 原生 AST 语法树解析，禁止使用粗暴正则匹配。
   - 所有工作区路径必须经过 `Resolve-PhysicalPathIdentity` 规范化，杜绝路径穿越与大小写/符号链接逃逸。
3. **两阶段事务与有序文件锁（Schema 1.1）**：
   - 状态写入必须通过 `Invoke-AiSopWorkflowTransaction` 实现两阶段提交，支持 crash 自动回滚与未决重放。
   - 并发锁必须严格遵循锁定顺序：`Session Lock -> Owner Lock -> Grant Lock`，防止死锁。
4. **智能自愈与零摩擦通行**：
   - 在非 Hook 环境直接调用命令时，通过 `Get-ExactGrant` 自动校验参数合法性并补签即时 Grant，保证在任何终端都能直接运行，同时保留完整的审计追踪日志。
5. **分发投影完整性（Distribution）**：
   - 涉及安装器或投影文件改动时，确保 `distribution/` 中的 manifest 与核心安装脚本同步更新。

---

## 四、文档与技能规范

- **手册单一真源**：SOP 用户操作指南为 `SUPERPOWERS_MANUAL.md`，工作流适配器为 `workflows/superpowers-adapter.md`。
- **专家 Skill**：`skills/` 下的专家 Skill（`implementation-engine`, `logic-auditor`, `design-reviewer` 等）仅定义角色职责与检查清单，不硬编码具体业务专有名词。
