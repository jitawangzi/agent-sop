# Agent-SOP

<p align="center">
  <b>企业级 AI 编码智能体治理引擎与运行时操作系统</b><br>
  <i>Deterministic OS-Level Guardrails, Cryptographic Gates, and Transactional Multi-Agent OS</i>
</p>

<p align="center">
  <a href="#-核心原理深度剖析"><img src="https://img.shields.io/badge/Architecture-Deterministic%20OS-orange.svg" alt="Architecture"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License"></a>
  <a href="https://github.com/PowerShell/PowerShell"><img src="https://img.shields.io/badge/PowerShell-7.0%2B-blue.svg" alt="PowerShell"></a>
  <a href="#-全量自动化测试矩阵"><img src="https://img.shields.io/badge/Tests-14%2F14%20PASS%20(100%25)-brightgreen.svg" alt="Tests"></a>
  <a href="#-支持的-ide--harness-矩阵"><img src="https://img.shields.io/badge/Harness-Claude%20Code%20|%20Antigravity%20|%20Cursor%20|%20Copilot-green.svg" alt="Harness"></a>
</p>

<p align="center">
  <a href="#-极简使用导航先读这个">极简导航</a> •
  <a href="#-为什么需要-agent-sop">痛点背景</a> •
  <a href="#-3-分钟快速上手">快速上手</a> •
  <a href="#-核心原理深度剖析">底层原理</a> •
  <a href="#-与-superpowers-生态的深度融合与架构分工">Superpowers 融合</a> •
  <a href="#-执行强度-t-档分流">T 档调度</a> •
  <a href="#english-summary">English Summary</a>
</p>

---

## 🧭 极简使用导航（先读这个）

| 身份 / 场景 | 你只需要关注的内容 |
|---|---|
| 👤 **人类开发者（日常开发）** | 只需阅读下方的 [3 分钟快速上手](#-3-分钟快速上手)。日常 Bug 修复直接说 `快速修改：修复 X 的空指针`；新功能直接描述需求。不需要记复杂的命令或工单！ |
| 🔄 **跨 IDE / 工具切换** | 在新 IDE（如从 Cursor 切到 Claude Code）直接说 `接着做 <Feature>` 或 `接管任务`，SOP 会自动完成会话绑定与租约交接。 |
| 🤖 **AI 编码智能体 (Agent)** | 统一加载项目根目录下的 **`AGENTS.md`**（单一真源），严格执行 OS 物理拦截与门禁。 |
| 🛠️ **框架维护与架构师** | 阅读 [底层原理剖析](#-核心原理深度剖析) 与 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。 |

---

## 💡 为什么需要 Agent-SOP？

当前各大 AI 编程助手（Claude Code, Cursor, Antigravity, GitHub Copilot）展现了惊人的代码编写能力。然而，在**企业级大型真实工程**（特别是拥有数十万行代码、复杂状态机、混合 SVN/Git 版本控制的严肃业务系统）中，直接让 AI 裸奔写代码往往会引发灾难：

### 传统 AI 编程 vs Agent-SOP 治理

| 工业界痛点场景 | 裸奔 AI 的表现 (常规 Prompt 方式) | Agent-SOP 物理级治理表现 |
|---|---|---|
| **AI 产生幻觉偷改代码** | AI 随着上下文增长发生疲劳，跳过方案评审直接修改核心生产代码。 | **OS 级 PreToolUse Hook 物理阻断**：未持有合法租约直接拒绝写入磁盘（Exit 2）。 |
| **AI 偷偷放宽测试标准** | 实现遇阻时，AI 经常会偷偷把需求或测试断言删减，伪造“全部通过”假象。 | **密码学 SHA-256 防篡改门禁**：需求与设计一旦锁定，修改 1 个标点立即触发熔断。 |
| **多 Agent / 跨 IDE 并发踩踏** | 多个会话或不同 IDE 同时操作同一文件，导致代码被静默覆盖与回退。 | **两阶段事务锁与 Session 状态机**：物理文件锁排队、租约 TTL 超时自愈、崩溃安全日志。 |
| **改动 1 行代码耗费重型流程** | 修一个错别字也要走完 30 分钟的全套大模型拆解，极其浪费 Token 和时间。 | **T1 / T2 / T3 / 快通道动态分流**：纯配置纯文档秒级直达，核心玩法严密闭环。 |
| **无法融入企业私有工程** | 强依赖理想化的独立 Git 分支，无法适配企业现有的 SVN 工作副本或多端口沙盒。 | **原生混合 VCS 支持**：无侵入嵌入 SVN / Git Monorepo，动态分配端口与运行时隔离。 |

> **核心哲学**：大模型的输出是**概率性（Probabilistic）**的，但软件工程的交付必须是**100% 确定性（Deterministic）**的。Agent-SOP 的使命就是**把不可控的 AI，关进确定性的物理工程笼子里**。

---

## 🔬 核心原理深度剖析

Agent-SOP 不是一组简单的 Markdown 提示词，而是一套**深度介入操作系统进程与文件系统的运行时治理底座**。

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        Agent-SOP 物理治理全景                          │
│                                                                        │
│  [ Claude Code ]    [ Antigravity ]    [ Cursor ]    [ Copilot ]       │
│        │                  │                 │             │            │
│        └──────────────────┼─────────────────┴─────────────┘            │
│                           ▼                                            │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ 1. OS 级 PreToolUse Hook 物理拦截层 (hook-dispatcher.ps1)        │  │
│  │  - 语法树 AST 解析，防止相对路径遍历与参数注入 bypass            │  │
│  │  - 校验 ACTIVE 归属锁状态与短期 CommandGrant 租约 (TTL 机制)      │  │
│  │  - 未经授权直接 Exit 2 物理阻断，生产文件 0 污染                  │  │
│  └─────────────────────────────────┬────────────────────────────────┘  │
│                                    ▼                                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ 2. 密码学防篡改门禁系统 (workflow-state.ps1)                     │  │
│  │  - 01_server_rules.md (需求 BR/EX/AC) -> SHA-256 密码学签名      │  │
│  │  - 06_design_contract.md (设计 DC/DR) -> design-reviewer 机器闭环│  │
│  │  - 05_test_coverage.json -> 机器机检可追溯矩阵 (P0/P1 硬阻断)    │  │
│  └─────────────────────────────────┬────────────────────────────────┘  │
│                                    ▼                                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ 3. 跨 IDE 两阶段事务锁与 Session 状态机 (Schema 1.1)            │  │
│  │  - 顺序加锁: Session -> Owner -> CommandGrant                    │  │
│  │  - Two-Phase Commit (2PC) 事务日志，支持断电/强杀崩溃自愈恢复     │  │
│  └─────────────────────────────────┬────────────────────────────────┘  │
│                                    ▼                                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ 4. 业务工作区 (SVN 工作副本 / Git Monorepo / 多端口沙盒环境)     │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

---

### 原理 1：OS 级 PreToolUse Hook 物理拦截（真正的硬约束）

市面上几乎所有 Agent 框架都试图通过 Prompt 告诉模型：“请在获得批准前不要修改生产文件”。但实验表明，长对话下 Prompt 遵循率会随 Token 衰减而跌破 80%。

Agent-SOP 在操作系统与 IDE 工具层之间插入了 **`hook-dispatcher.ps1` 物理防火墙**：
1. **抽象语法树（AST）静态解析**：拦截所有 `write_to_file`、`replace_file_content`、`Bash`（sed, patch, echo >）等写入意图，进行绝对路径规范化，彻底杜绝 `../` 路径穿越或大小写混淆绕过。
2. **生产目录白名单扫描**：一旦命中生产代码目录（如 `src/**`、`config/**`、`WebRoot/**`），立即触发归属判定。
3. **物理驳回（Exit Code 2）**：若当前会话未持有合法的 `ACTIVE` 租约，Hook 在操作系统层面**直接阻断工具执行**，大模型的写入调用根本无法触碰硬盘物理文件，并强制回显错误信息要求 AI 走正规认领流程。

---

### 原理 2：密码学 SHA-256 防篡改门禁（锁死需求与契约）

在复杂的开发任务中，大模型常常因无法解决某个边界 Bug，而“自作聪明”地修改原始需求或删除测试用例，谎称交付成功。

Agent-SOP 引入了**不可变密码学门禁机制**：
- **两道独立人工门禁**：
  1. `01_server_rules.md`（业务需求）：人工确认后，计算 SHA-256 哈希写入 `00_workflow_state.json` 锁定。
  2. `06_design_contract.md`（设计契约）：必须先经过 `design-reviewer` 机器审查闭环（最多 2 轮熔断），再由人工确认并写入 SHA-256。
- **动态防篡改比对**：在后续的 TDD 编码、内审和交付阶段，验证器会反复比对物理文件的实时哈希值。任何对需求条款或契约的私自修改，都会直接导致 `ValidateTestCoverage` 报 FAIL 熔断，强制开发者介入。

---

### 原理 3：跨 IDE 两阶段事务锁与 Session 状态机（Schema 1.1）

企业开发往往允许多个开发者、或同一个开发者使用多种工具（例如主界面用 Cursor，排查 Bug 用 Claude Code CLI，后台跑 Antigravity）协同工作。

Agent-SOP 实现了一套**无中心依赖的文件级两阶段事务（2PC）协调器**：
- **有序层级锁（Ordered Locking）**：统一按照 `Session -> Owner -> Grant` 严格顺序获取文件锁，彻底消除多进程死锁可能。
- **崩溃自愈与超时清理**：每次加锁操作均记录带有时间戳与状态（`PREPARED` / `COMMITTED`）的事务日志。若进程异常退出或断电，下次启动时自动执行 Crash Recovery 回滚或续期。
- **短期租约令牌（CommandGrant TTL）**：对单次命令执行颁发具有毫秒级 TTL 的一次性凭证，防止授权泄漏。

---

### 原理 4：机器机检测试追溯矩阵（拒绝人工盲目 Review）

- 传统的测试计划往往是一堆形式主义的自然语言。
- Agent-SOP 规定测试用例必须以结构化元数据标注：
  ```markdown
  <!-- meta: { "id": "TC-01", "title": "...", "covers": ["BR-01", "DC-02"], "priority": "P1" } -->
  ```
- 通过 `workflow-state.ps1 -Operation SyncCoverage` 自动生成机器可读的 `05_test_coverage.json` 覆盖矩阵。
- 在交付前，机检引擎会逐条扫描 P0/P1 用例的 `setup`、`trigger`、`assertions` 映射。**只要有任何一条核心业务需求未被自动化测试断言覆盖，交付命令直接报 FAIL 阻断**。

---

## 🤝 与 Superpowers 生态的深度融合与架构分工

在完整的 T3 研发流程中，**Agent-SOP 与业界知名的 [Superpowers](https://github.com/obra/superpowers) 形成了完美的“大脑与身体”互补关系**：

```text
┌────────────────────────────────────────────────────────────────────────┐
│ 顶层认知编排器 (Cognitive Workflow Orchestrator): Superpowers          │
│                                                                        │
│  - superpowers:brainstorming           (多轮方案发散与反直觉探索)      │
│  - superpowers:writing-plans           (可执行敏捷任务分解)            │
│  - superpowers:subagent-driven-development (子智能体分发与自驱迭代)     │
│  - superpowers:requesting-code-review  (最终收尾审查)                  │
│  - superpowers:verification-before-completion (完工事实校验)           │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ 调度与驱动
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 运行时治理操作系统 (Runtime Governance & OS Layer): Agent-SOP          │
│                                                                        │
│  🛡️ OS 级 PreToolUse Hook 物理阻断 (未获锁严禁写盘)                     │
│  🔐 需求与设计 SHA-256 密码学不可变门禁 (防 AI 偷改断言)                │
│  👥 领域专家智能体 (design-reviewer / logic-auditor / 实现引擎)        │
│  🔒 跨 IDE 两阶段事务文件锁与崩溃自愈 (Schema 1.1)                     │
│  🚦 T1 / T2 / T3 / FastTrack 动态成本调度 (避免 Token 浪费)            │
└────────────────────────────────────────────────────────────────────────┘
```

### 两者的角色与边界定义：
1. **Superpowers 是“顶层大脑”**：负责任务的思考流与认知编排。它指导 AI 如何有条理地与人类沟通、如何分解 Plan、如何调度子 Agent。
2. **Agent-SOP 是“骨骼与操作系统”**：负责底层的物理防护网与确定性基础设施。它将 Superpowers 的“纯提示词软约束”升级为“操作系统级硬门禁”，并为每个执行步骤提供本项目专属的领域专家（替换掉了通用的 code-reviewer）。
3. **分层解耦与独立性**：
   - **T3 重型功能**：深度结合 Superpowers 的思考编排能力 + Agent-SOP 的物理治理底座。
   - **T2 快速修改 / 快通道**：轻量级修改**完全不依赖 Superpowers**，由 Agent-SOP 原生单命令秒级直达。

---

## 🚦 执行强度 T 档分流

为了避免“杀鸡用牛刀”，Agent-SOP 提供了基于变更类型的精准成本控制：

| 档位 | 适用场景 | 必经阶段 | 人机交互开销 |
|:---:|---|---|:---:|
| **T3 (完整架构档)** | 新玩法、新协议、核心存储结构变更、跨模块重构。 | `Brainstorming` $\rightarrow$ `01 需求门禁` $\rightarrow$ `design-reviewer 机器审查` $\rightarrow$ `06 设计门禁` $\rightarrow$ `Writing-Plans` $\rightarrow$ `TDD Subagents` $\rightarrow$ `双专家审计` $\rightarrow$ `最终 Code Review` $\rightarrow$ `全量回归验证` | 2 次独立人工批准 |
| **T2 (单点修复档)** | 缺陷修复（Bugfix）、已有逻辑边界调整、单点参数校验。 | **单命令直达**：自动认领 Claim $\rightarrow$ 代码修改 $\rightarrow$ 编译 $\rightarrow$ 目标测试 $\rightarrow$ 交付（AI 自审）。 | 0 阻断 (单轮直达) |
| **T1 (应急抢修档)** | 极端紧急线上修复（极少使用）。 | 仅保留编译检查与底层 Guard 逃生，需人工确认开启风险。 | 1 次风险确认 |
| **快通道 (FastTrack)** | 纯配置数值变更（CSV/静态表）、纯文档错别字润色。 | 自动识别，仅需编译通过 + 格式检查，秒级完成。 | 0 阻断 (完全静默) |

---

## 👥 专家 Skill 矩阵

Agent-SOP 预置了高度分工的领域专家智能体（Subagents），在不同阶段各司其职：

| 角色 | 专家 Skill 名称 | 核心职责 | 调度机制 |
|---|---|---|---|
| 📐 **架构设计专家** | `design-architect` | 负责无损扩展、模块拆分与契约设计，产出 06 设计契约。 | Brainstorming 阶段按需咨询 |
| 🛡️ **设计方案审查官** | `design-reviewer` | 宏观规范守门与完整性自检，闭环自审自修，不浪费人工时间。 | 06 提交人工前的机器门禁 |
| 🔨 **高级开发工程师** | `implementation-engine` | 遵循 TDD 模式编写生产代码与测试代码，回填测试矩阵。 | Subagent 主实现者 |
| 🔍 **契约合规审计官** | `implementation-auditor` | 逐行比对代码与设计契约，检查编码规范与异常处理。 | Task 内审守门员 |
| 🧠 **高风险逻辑审计官** | `logic-auditor` | 专门审查能编译运行但语义错误的方法级、分支级隐蔽逻辑漏洞。 | 高风险逻辑专项内审 |
| 🧪 **资深测试开发 (SDET)**| `quality-assurance` | 自动化测试用例设计、断言有效性与全量回归保障。 | TDD 阶段与交付前校验 |
| 📋 **需求预处理专家** | `requirement-analyst` | 将策划 Docx/需求草案提炼为结构化 BR/EX/AC 规范条款。 | 可选前置工具 |

---

## 🚀 3 分钟快速上手

### 1. 引入任何现有项目

Agent-SOP 对宿主工程是**零破坏、无侵入**的，直接支持 Java, Go, C++, Python, Rust, Web 前端等任意工程：

#### 选项 A：Git 仓库引入（推荐）
```bash
# 在你的项目根目录下：
git submodule add https://github.com/jitawangzi/agent-sop.git .ai-sop
pwsh -NoProfile -File ./.ai-sop/distribution/bootstrap/install-ai-sop.ps1 -Mode Auto -Action Install
```

#### 选项 B：SVN 或非 Git 仓库引入
```powershell
# 在你的项目根目录下：
git clone https://github.com/jitawangzi/agent-sop.git .ai-sop
pwsh -NoProfile -File ./.ai-sop/distribution/bootstrap/install-ai-sop.ps1 -Mode Auto -Action Install
```

> **自动生成**：安装器会在项目根目录自动生成统一入口脚本 `ai-sop.ps1`、IDE 挂载配置（`.agents/`、`.claude/`、`.cursor/`、`.github/`）以及版本锁定文件 `tools/ai-sop/ai-sop.lock.json`。

### 2. 环境一键自检（Doctor）

```powershell
pwsh -NoProfile -File ./ai-sop.ps1 Doctor
```

```text
✔ PowerShell 7+          7.6.5
✔ Git CLI                git version 2.54.0
✔ Hook injected          .agents/hooks.json or .claude/settings.json
✔ Lock file              tools/ai-sop/ai-sop.lock.json
✔ Context dir            .ai-workspace/context
-----------------------------------------------
11/11 checks passed (All systems ready!)
```

### 3. 开始与 AI 结对编程

#### 路径 1：日常快速修改（T2 模式，单命令直达，推荐首次上手 ⚡）

直接在任何 AI 工具（Claude Code / Antigravity / Cursor / Copilot）中输入：

```text
快速修改：修复 ShopManager 中的空指针异常
```

> **执行效果**：AI 会在单次响应内自动串联 **【Claim 认领归属 → 修改代码 → 项目编译 → 定向测试验证 → 交付】**，无需人工进行繁琐的方案确认，3 分钟丝滑搞定！

#### 路径 2：完整新功能开发（T3 模式，双门禁严密闭环 🛡️）

当你需要开发新玩法、新协议或复杂模块时输入：

```text
实现新玩法活动：增加每日签到功能 DailySignIn
```

> **执行效果**：Agent-SOP 将自动接管整个研发流程，展开需求头脑风暴（产出 `01_server_rules.md` 待你确认）→ 架构设计并经 `design-reviewer` 机器审查（产出 `06_design_contract.md` 待你确认）→ 拆分任务并派发子智能体进行 TDD 编码与双重内审 → 全自动交付！

---

## 🧪 全量自动化测试矩阵

Agent-SOP 自身拥有极其严苛的自动化测试套件，全面覆盖状态机、AST 解析、并发锁竞争、崩溃自愈与两阶段事务：

```powershell
pwsh -NoProfile -File ./scripts/run-all-tests.ps1
```

```text
Running 14 test suite(s) from ./scripts/tests (serial)
ai-sop-installer.tests                     PASS
doc-script-contract.tests                  PASS
e2e-t2-smoke.tests                         PASS
guard-production-edit.tests                PASS
harness-capability.tests                   PASS
hook-dedup.tests                           PASS
hook-dispatcher.tests                      PASS
hook-event-normalizer.tests                PASS
run-all-tests.tests                        PASS
workflow-command-grant.tests               PASS
workflow-owner.tests                       PASS
workflow-session.tests                     PASS
workflow-state.tests                       PASS
workflow-transaction.tests                 PASS
-----------------------------------------------
14/14 test suites passed (100% GREEN)
```

---

## 🛠️ 支持的 IDE / Harness 矩阵

| Harness / 工具 | 准入支持等级 | 推荐使用流程 | 拦截机制 |
|---|:---:|:---:|---|
| **Claude Code** | `STRICT` (全功能) | 完整 T3 流程 | 深度挂载 `PreToolUse` Hook |
| **Antigravity** | `STRICT` (全功能) | 完整 T3 流程 | 跨 Subagent 治理与锁协同 |
| **Cursor** | `STRICT` (全功能) | 完整 T3 流程 | Rules & Hooks 自动投影 |
| **GitHub Copilot** | `STRICT` (全功能) | 完整 T3 流程 | Task/Subagent 桥接与门禁 |
| **Pi / 极简终端** | `BLOCKED` (轻量) | 自动降级为 T2 单点修复 | 静态规则与编译保护 |

---

## 🌐 English Summary

**Agent-SOP** is an open-source, industrial-grade governance engine and runtime operating system for AI coding agents.

### Why Agent-SOP?
- **Deterministic Guardrails**: Uses OS-level `PreToolUse` hook scripts to physically intercept unauthorized file modifications, eliminating reliance on probabilistic prompt instructions.
- **Cryptographic Gates**: Locks requirements (`01`) and design contracts (`06`) with SHA-256 signatures, preventing agents from secretly modifying acceptance criteria.
- **Transactional Multi-Agent Locks**: Implements 2-Phase Commit (2PC) crash-safe journals and ordered file locks across multiple IDE sessions (Claude Code, Cursor, Antigravity, Copilot).
- **T-Tier Cost Optimization**: Dynamically routes tasks into T3 (Full Architecture), T2 (Single-command fast patch), T1 (Rush), and FastTrack (Config/Doc zero-gate), avoiding token waste.
- **Hybrid VCS & Runtime Isolation**: First-class support for both enterprise SVN working copies and Git monorepos with isolated port/directory sandboxes.

---

## 📄 开源协议 (License)

本项目采用 [MIT License](LICENSE) 开源协议。无论是个人开发者、独立工作室还是商业企业，均可免费引入、修改和商用。
