# Agent-SOP 架构审查与全方位优化提示词（复制以下全文发送给其他大模型）

---

你是一位世界顶级的 **AI 软件工程架构师（AI SWE Architect）**、**操作系统安全与并发控制专家**，同时兼具**开源软件开发者体验（DX）设计专家**的视角。

请对开源项目 **[Agent-SOP](https://github.com/jitawangzi/agent-sop)** 的架构设计、Hook 拦截、多 Agent 事务锁、证据门禁及工程落地规范进行审查，找出有证据的问题与体验卡点。先确认本次审查的提交、范围及实际读取的文件；只读输出报告，不修改文件或默认运行全量测试。优先提出收益明确、复杂度低的改进，区分真实缺陷、能力边界与可选建议，不为“全方位”扩大任务。

---

## 一、 项目背景与架构全景

### 1. 项目定位
**Agent-SOP** 是一个用于企业级代码库的 **AI 编码智能体治理引擎与运行时操作系统（Governance OS for AI Coding Agents）**。
- **开源地址**：`https://github.com/jitawangzi/agent-sop`
- **核心目标**：用明确的流程、任务归属与可核验的执行证据减少误操作和虚假完成。门禁检查记录与绑定是否满足条件，不证明业务语义正确，也不防御同权限主体直接篡改引擎或记录；能力边界见 `docs/QUALITY_GATES.md`。
- **支持环境**：
  - **跨语言**：Java, Go, C++, Python, Rust, TypeScript/Web 等任意代码库；
  - **跨版本控制**：原生支持企业级 **SVN 工作副本** 与 **Git Monorepo / Git Submodule**；
  - **跨 IDE / Harness**：Claude Code、Antigravity、Cursor、GitHub Copilot、Pi CLI 等。

### 2. 核心架构分工：Superpowers（大脑）+ Agent-SOP（操作系统）
- **顶层认知编排器（Superpowers，仅 T3）**：负责方案探索（`brainstorming`）、任务拆解（`writing-plans`）、子智能体驱动（`subagent-driven-development`）、收尾代码审查（`requesting-code-review`）。T1/T2 直接使用任务入口与按需专家技能，不强制完整编排或独立审计。
- **运行时治理底座（Agent-SOP）**：
  1. **Hook 写入守卫**：对已接入 Harness、已识别工具与命令的受控写入检查路径和归属，拒绝缺少合法 ACTIVE 会话绑定的操作。它不是操作系统沙箱，不保证覆盖任意脚本或外部工具的写入。
  2. **SHA-256 完整性与证据绑定**：T3 核对需求、设计批准与当前内容，检查覆盖定义和本任务必测范围；各档按任务条件检查真实执行记录及输入绑定。覆盖矩阵不能代替测试断言与业务语义审查。
  3. **跨 IDE 两阶段事务文件锁（Schema 1.1）**：按 `Session -> Owner -> Grant` 严格顺序加锁，2PC 崩溃安全日志与 TTL 租约自愈。
  4. **任务强度**：默认 T2（代码、相关规格/用例同步与验证），人工可选择 T1（极速实现与编译）或 T3（完整流程）。新修改走 Task Discover / Start / Resume；不自动按风险改档，不新增配置/文档第四档。历史 FAST_TRACK 只保留兼容读取。
  5. **领域专家 Skill**：`design-reviewer`（设计审查）、`logic-auditor`（高风险语义审查）、`implementation-auditor`、`implementation-engine` 等。它们定义通用方法，项目规则由宿主 context 注入。

---

## 二、 审查维度与重点关注项

请从以下 **6 个关键维度** 进行深度审查，直击痛点：

### 维度 1：操作系统 Hook 与物理防越权安全性（OS Guard & Hook Security）
- **路径绕过与逃逸**：已支持的工具和命令是否存在路径穿越、大小写混淆或符号链接绕过？任意解释器脚本与外部工具的未覆盖范围是否明确披露？区分实现漏洞与已声明的非沙箱边界。
- **授权令牌（CommandGrant）生命周期**：按当前实现核对 TTL、单次使用、会话与工作区绑定，是否存在未授权命令冒用或过期结果复用？
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
- **能力准入矩阵**：依据 `scripts/harness-capability.ps1` 和当前能力报告核对 STRICT/BLOCKED，不按工具名称假定能力或任务档位。
- **能力缺口反馈**：已选 T3 却缺少能力时，是否说明缺口并由用户选择更换工具或改档？不得静默升降档；T1/T2 不因完整流程能力缺失而被强加 T3 步骤。

### 维度 6：PowerShell 7 脚本质量与架构精简（Code Quality & Over-Engineering）
- **过度工程识别**：哪些设计在真实软件工程中过于重型、可以合并或简化？
- **跨平台兼容性**：核心脚本（`workflow-owner.ps1`, `workflow-state.ps1`, `hook-dispatcher.ps1` 等）在 Linux/macOS 的 PowerShell 7 下运行是否存在平台特定 API 依赖？

---

## 三、 核心规范与真源

### 规约 A：宿主任务规则摘要

以 `distribution/templates/root/AGENTS.md`、`workflows/agent-t3.md`、`docs/QUALITY_GATES.md` 的当前版本为准；本仓库根 `AGENTS.md` 是底座维护约定，不是宿主日常任务模板。

```markdown
## 工作流归属与 T 档分级
- 默认 T2，人工指定优先；接管继承原任务档位，独立任务不继承历史 T3。
- T1 完成实现和真实编译/基础检查，实际延期才记 FollowUp；T2 同步受影响规格/用例并运行相关测试，记录 RecordSync。
- T3 由 Superpowers 执行完整批准、独立审查、覆盖与验证；复用仍有效成果，不重复已满足的步骤。
- 不自行升降档，不新增配置/文档快通道；T3 能力不足由用户决定更换工具或改档。
- 修改前 Start/Resume 取得本任务 ACTIVE 会话归属；Run 留真实证据，Complete 按本档条件验收并释放归属。
- 只读审核可报告静态发现和未验证范围，不要求补做 T3 批准，也不将审核报告当作编译、测试或完成门禁通过。
```

### 规约 B：安装与跨平台分发（Git 宿主示例）
```powershell
# 已确认使用 Git submodule 的宿主：
git submodule add https://github.com/jitawangzi/agent-sop.git .ai-sop
pwsh -NoProfile -File ./.ai-sop/distribution/bootstrap/install-ai-sop.ps1 -Mode Auto -Action Install
```

SVN 宿主、升级及投影验证按当前安装文档与 `distribution/` 实现检查，不将上述 Git 示例套用于所有工程。

---

## 四、 期望输出格式

请按以下结构输出有文件位置、触发条件和证据的报告。未复现的推断明确标注；未执行测试不能写成通过。已修复的旧问题注明当前状态，低收益或明显增加维护成本的建议列为暂缓，不要求为了凑数提出新机制。

```markdown
# Agent-SOP 深度架构审查与优化报告

## 1. 审查范围与验证边界
[提交、实际读取范围、已执行检查及未验证项]

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

## 5. 建议处理顺序与暂缓项
[按用户影响、复现证据与修复成本排序；无发现则如实说明]
```
