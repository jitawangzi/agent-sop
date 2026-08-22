# Agent-SOP 架构审查与全方位优化提示词（复制以下全文发送给其他大模型）

---

你是一位世界顶级的 **AI 软件工程架构师（AI SWE Architect）**、**操作系统安全与并发控制专家**，同时兼具**开源软件开发者体验（DX）设计专家**的视角。

请对开源项目 **[Agent-SOP](https://github.com/jitawangzi/agent-sop)** 的全套架构设计、物理拦截安全机制、多 Agent 事务锁、密码学门禁以及工程落地规范进行**极其严苛、深度、批判性的全方位审查**，找出潜在的漏洞、设计死锁、过度工程、跨平台隐患与体验卡点，并给出具体的代码/规范优化方案。

---

## 一、 项目背景与架构全景

### 1. 项目定位
**Agent-SOP** 是一个用于企业级代码库的 **AI 编码智能体治理引擎与运行时操作系统（Governance OS for AI Coding Agents）**。
- **开源地址**：`https://github.com/jitawangzi/agent-sop`
- **核心哲学**：大模型的输出是**概率性（Probabilistic）**的，但软件工程的交付必须是**100% 确定性（Deterministic）**的。Agent-SOP 的使命就是**把不可控的 AI，关进 100% 确定性的物理工程笼子里**。
- **支持环境**：
  - **跨语言**：Java, Go, C++, Python, Rust, TypeScript/Web 等任意代码库；
  - **跨版本控制**：原生支持企业级 **SVN 工作副本** 与 **Git Monorepo / Git Submodule**；
  - **跨 IDE / Harness**：Claude Code、Antigravity、Cursor、GitHub Copilot、Pi CLI 等。

### 2. 核心架构分工：Superpowers（大脑）+ Agent-SOP（操作系统）
- **顶层认知编排器（Superpowers）**：负责方案探索（`brainstorming`）、任务拆解（`writing-plans`）、子智能体驱动（`subagent-driven-development`）、收尾代码审查（`requesting-code-review`）。
- **运行时治理底座（Agent-SOP）**：
  1. **OS 级 PreToolUse Hook 物理阻断**：拦截所有 `write_to_file`、`replace_file_content`、`Bash`（sed/patch）等写入意图，AST 解析规范化路径，未持合法 ACTIVE 租约直接 Exit 2 物理阻断。
  2. **密码学 SHA-256 防篡改门禁**：`01_server_rules.md`（需求）与 `06_design_contract.md`（设计）经人工批准后锁定 SHA-256，`05_test_coverage.json` 机器可读矩阵硬阻断未覆盖交付。
  3. **跨 IDE 两阶段事务文件锁（Schema 1.1）**：按 `Session -> Owner -> Grant` 严格顺序加锁，2PC 崩溃安全日志与 TTL 租约自愈。
  4. **T 档成本分流**：T3（完整架构 6 步）、T2（缺陷修复单命令直达）、T1（急速抢修）、FastTrack（纯配置/文档秒级完成）。
  5. **10 个领域专家 Skill 矩阵**：`design-reviewer`（机器自审闭环）、`logic-auditor`（高风险语义漏洞审查）、`implementation-auditor`、`implementation-engine`（TDD 实现）等。

---

## 二、 审查维度与重点关注项

请从以下 **6 个关键维度** 进行深度审查，直击痛点：

### 维度 1：操作系统 Hook 与物理防越权安全性（OS Guard & Hook Security）
- **路径绕过与逃逸**：AST 静态解析是否能 100% 阻断 `../` 路径穿越、Windows 盘符大小写混淆、符号链接（Symlink）穿透、或复杂 Shell 命令（`python -c "open('file','w').write(...)"`）？
- **授权令牌（CommandGrant）生命周期**：短期 TTL（毫秒级）与自愈补发机制是否存在未授权命令冒用的安全窗口？
- **逃生通道风险**：`AI_SOP_SKIP_OWNER_GUARD=1` 与 `.guard-disabled` 开关的合规约束是否足够严密？

### 维度 2：并发事务锁与死锁/崩溃自愈（Concurrency, 2PC & Crash Recovery）
- **死锁可能性**：多 Agent 并发竞争或多 IDE 会话并发操作时，`Session -> Owner -> Grant` 的有序锁机制在极限场景（如垃圾收集卡顿、文件系统高延迟）下是否存在死锁风险？
- **2PC 崩溃恢复**：若进程在 `PREPARED` 与 `COMMITTED` 之间被 `kill -9` 强杀或断电，强杀恢复算法是否存在数据撕裂（Torn Write）？

### 维度 3：密码学门禁与防大模型作弊机制（Cryptographic Gates & Anti-Tampering）
- **SHA-256 规范化**：跨平台换行符（CRLF vs LF）与 UTF-8 BOM 在 Windows/Linux/macOS 间传递时，门禁哈希是否会发生误判漂移？
- **测试覆盖矩阵（05_test_coverage.json）**：基于 HTML 注释提取元数据并自动同步的设计，是否可能被大模型通过虚假占位符（如空的 assertion）蒙混过关？

### 维度 4：开源开发者上手体验与心智（Developer Experience & Onboarding）
- **从 0 到 1 的摩擦力**：一个从未听说过本项目的外部工程师，在阅读 `README.md` 和安装文档后，将其接入自己的 Go / Python / Java 项目时，会在哪里感到困惑或遇到卡点？
- **概念认知负担**：T 档分流、两阶段事务、Superpowers 适配、专家 Skill 等概念是否过于密集？如何让普通用户“零配置也能秒用，进阶用户能深度定制”？

### 维度 5：跨 IDE / Harness 兼容性与降级韧性（Portability & Graceful Degradation）
- **能力准入矩阵**：STRICT 工具（Claude Code / Antigravity / Cursor / Copilot）与 BLOCKED 工具（Pi / 极简终端）的判定机制是否准确？
- **降级平滑度**：当在弱能力环境（BLOCKED）下运行时，系统静默降级为 T2 单点修复是否足够鲁棒？

### 维度 6：PowerShell 7 脚本质量与架构精简（Code Quality & Over-Engineering）
- **过度工程识别**：哪些设计在真实软件工程中过于重型、可以合并或简化？
- **跨平台兼容性**：核心脚本（`workflow-owner.ps1`, `workflow-state.ps1`, `hook-dispatcher.ps1` 等）在 Linux/macOS 的 PowerShell 7 下运行是否存在平台特定 API 依赖？

---

## 三、 核心规范节选（供审查的代码与规约）

### 规约 A：AGENTS.md 根指令（节选）
```markdown
## 工作流归属与 T 档分级
- T3 由 Superpowers 编排；T2/T1/快通道用原生单命令直达，不调用 Superpowers。
- 实际执行档位：MIN(用户显式指定 || 变更类默认, 工具最高支持档位)。
- T3 必调：brainstorming -> 01需求人工批准 -> design-reviewer(机器自审闭环<=2轮) -> 06设计人工批准 -> writing-plans -> SDD(TDD) -> logic-auditor/implementation-auditor -> requesting-code-review -> verification-before-completion。
- 快通道：仅限纯配置数值或纯文档，跳过门禁，2项完成条件（编译+格式检查）。
- 物理拦截：编辑生产代码前必须持有 ACTIVE 且 session-bound 的 Owner 锁，否则 OS Hook 强制退出 Exit 2。
```

### 规约 B：安装与跨平台分发（install-ai-sop.ps1 节选）
```powershell
# 任何新工程引入只需 2 行：
git submodule add https://github.com/jitawangzi/agent-sop.git .ai-sop
pwsh -NoProfile -File ./.ai-sop/distribution/bootstrap/install-ai-sop.ps1 -Mode Auto -Action Install
# 自动生成：ai-sop.ps1、tools/ai-sop/ai-sop.lock.json、.agents/hooks.json、.claude/settings.json
```

---

## 四、 期望输出格式

请不要给出泛泛而谈的客套话，请按照以下结构输出**高密度、尖锐、且附带具体改进代码/文本**的审查报告：

```markdown
# Agent-SOP 深度架构审查与优化报告

## 1. 总体评价与架构成熟度评分（1-10分）
[客观评价该架构在当前 AI 软件工程领域的创新性、前沿度与工程实用价值]

## 2. 🔴 阻断级缺陷与安全漏洞 (Blockers / High Risk)
> 编号：B-01 — 简述问题
> 涉及模块/文件：...
> 漏洞原理与复现场景：...
> 具体修复建议与代码补丁：...

## 3. 🟡 架构优化与死锁/体验改进 (Major / Architectural Improvements)
> 编号：M-01 — 简述问题
> 涉及机制：...
> 为什么当前设计存在痛点：...
> 优化方案与对比：...

## 4. 🟢 锦上添花与开发者体验优化 (Minor / DX Polish)
> 编号：P-01 — 简述优化点
> 建议改法：...

## 5. 针对开源全球推广的 3 个关键战略建议
1. ...
2. ...
3. ...
```
