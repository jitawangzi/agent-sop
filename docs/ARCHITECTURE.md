# AI SOP 架构与维护指南（开发者文档）

> 面向：维护这套 AI SOP 的人（架构演进、工具适配、问题排查）
> 不面向：日常用 SOP 干活的开发者——见《AI SOP 使用指南》
> 真源位置：`.ai-sop/`（Git submodule，远程 agent-sop）

---

# 第一部分：设计层面（为什么这么设计）

## 一、要解决的核心问题

### 问题背景
AI 编码工具百花齐放（Claude Code、Copilot、Cursor、Antigravity、Pi、Codex…），但带来三个痛点：

1. **工具绑定陷阱**：流程知识写死在某个工具的约定里（如 Claude Code 的 `.claude/`），换工具时积累的工作流清零，要重学重配。
2. **质量不可控**：AI 直接改生产代码无门禁，易引入回归；AI 自己审自己有盲区。
3. **跨项目/跨人不可复现**：换机器、换人、换项目时 SOP 无法可靠复现，靠人记忆和手工搬运。

### 本 SOP 的设计目标
- **工具无关**：标准流程不绑死任何工具名，换工具只换薄适配层，流程资产不变。
- **可复现**：fresh clone + 一条命令，全套 SOP 就位，跨机/跨人一致。
- **质量门禁**：生产编辑有归属拦截、独立审查、双人工批准、篡改检测。
- **分层演进**：标准流程作为核心资产持续演进（git 历史干净），项目领域知识随项目漂移互不污染。

每个子系统都对应这些目标的一部分，下面逐个讲"为什么需要它、解决什么问题、为什么这么设计"。

---

## 二、核心设计决策与原因

### 决策1：标准流程与项目领域分层（为什么分两层）

**问题**：早期所有 SOP 内容混在 `.claude/`——skills（标准流程）和 context（项目业务知识）、specs（需求文档）混在一个 git 历史。导致：
- 改 skills（值得长期演进）和改 context（随项目失效）混在一起，git 历史不清晰
- 换项目时，标准流程被项目领域知识"污染"，难以干净复用
- 想沉淀的核心资产和一次性项目内容没界限

**为什么这么设计**：按"是否值得跨项目长期演进"分层：
- **标准流程层**（`.ai-sop` 子模块）：skills/agents/schemas/scripts 门禁/distribution——跨项目共享、git 历史要干净、持续演进。
- **项目领域层**（`.ai-workspace` 根 Git）：context/specs/项目部署脚本——随项目更换失效、本地漂移。

**考虑过的替代**：
- 不分层（全混一个仓）：git 历史脏，核心资产被项目噪音淹没——否决。
- 全进根 Git 不用子模块：标准流程无法跨项目共享真源——否决。
- 两者都做子模块：项目领域知识没必要跨项目共享，徒增复杂——否决。

**价值**：标准流程 git log 只含流程演进，不含"这个游戏的某功能需求"噪音；核心资产可干净复用。

### 决策2：单一真源 + 投影（为什么不复制多份）

**问题**：各工具的 skills 发现路径不同（Claude Code 认 `.claude/skills`、Pi/Codex 认 `.agents/skills`、Cursor 认 `.cursor/skills`）。若每工具各维护一份 skills 内容，会漂移——改了一处忘同步另一处，行为不一致。

**为什么这么设计**：单一真源（`.ai-sop/skills`）+ installer 生成投影（`.claude/skills`、`.agents/skills`）。投影是生成的、gitignored、有 hash 校验——手工改投影会被 verify 拒绝。

**考虑过的替代**：
- 每工具一份独立维护：漂移、维护成本高——否决。
- 软链代替复制投影：Windows 软链需管理员权限、跨平台不稳——否决（用复制 + hash 校验）。
- 不投影，各工具配 path 指向 `.ai-sop/skills`：部分工具不支持自定义 skill 路径（Claude Code 固定认 `.claude/skills`）——需投影兜底。

**价值**：改一处真源，installer 重新生成所有投影，全工具行为一致；fresh clone 后一条命令复现。

### 决策3：`.ai-sop` 中立名 + `.claude` 退化为适配壳（为什么不叫 .claude）

**问题**：原标准流程真源叫 `.claude/`（Claude Code 工具名），名字偏袒 Claude。虽然其它工具通过 `.agents/skills` 不碰 `.claude`，但"真源目录名是某工具名"本身是耦合信号，且语义混乱（`.claude` 既指"标准流程"又指"Claude Code 专属"）。

**为什么这么设计**：真源改名 `.ai-sop`（中立），`.claude` 退化为 **Claude Code 专属适配壳**（和 `.agents`/`.cursor`/`.github` 同级的投影层，只含 settings + skills 投影，不含 scripts 真源）。

**考虑过的替代**：
- 直接改名不留 `.claude`：Claude Code 硬依赖 `.claude/settings.json` + `.claude/skills/`，改名会破坏它的发现机制——必须保留 `.claude` 作壳。
- `.claude` 当真源、`.ai-sop` 不存在：名字偏 Claude，不中立——否决。
- 合并 `.agents` 和 `.ai-sop`：破坏 Agent Skills 规范（`.agents/skills` 是规范定义的发现点，不该塞 scripts/schemas）——否决。

**约束/代价**：Claude Code 仍硬依赖 `.claude/` 这个名（settings/skills 必须在那），这是工具约束改不掉；但 `.claude` 内容退化为纯适配壳，不再是真源。hooks 命令指向 `./.ai-sop/scripts/`，绕过 `.claude` 当执行路径。

### 决策4：Owner/Session 双绑定（为什么功能开发要 Claim 归属）

**问题**：多 AI 工具/多 session 并行开发时，谁在改什么、是否授权、是否冲突——无归属则混乱。且生产代码编辑若无归属，任何 session 都能改，无质量边界。

**为什么这么设计**：
- **Owner 1.1**：功能开发先 Claim 归属（`SUPERPOWERS/工具/ownerId`），绑定一个 session。Validate/Complete 消耗 AST 校验的 command grant（one-use）。
- **生产编辑 guard**：编辑 `src/com|WebRoot|config` 要求 session-bound owner；非生产路径放行。
- **双人工批准**：需求(01)+设计(06)必须人工确认 + SHA 锁定，篡改检测。

**为什么用 grant 而非简单 owner 字段**：grant 绑定 AST 校验的 canonical 命令文本（不含变量/管道/重定向），one-use，10 秒过期——防止伪造归属、重放、命令注入。比"owner 字段存在就放行"安全得多。

**考虑过的替代**：
- 无归属，靠人自觉：并行时混乱、生产无边界——否决。
- 简单 owner 标记（存 ACTIVE 即放行）：无法证明当前 session 绑定、易被任意 ACTIVE owner 放行——不安全，否决。
- 全局单 owner：不支持多功能并行——否决。

**价值**：并行开发有归属边界，生产编辑可追溯，审查隔离可证明（设计者与审查者不同 session）。

### 决策5：Guard 手动开关（为什么允许绕过门禁）

**问题**：guard 在某些情况（session 注册链断、迁移期、确认安全的批量编辑）会误拦，导致 AI 工具完全无法干活——门禁变成阻塞而非保护。但全局硬编码绕过又不安全。

**为什么这么设计**：手动开关文件 `.ai-sop/.guard-disabled`（创建=关、删除=恢复）。env 优先（显式设非1 不逃逸），未设才看开关文件。开关文件 gitignored（本机运行时开关）。

**为什么不用纯 env**：Claude Code 的 hook 是子进程，env 继承不可靠（用户级 env 要重启才生效）。开关文件是文件系统，每个 hook 子进程都能可靠读。

**价值**：门禁异常时可快速恢复工作（手动关），但不留永久后门（gitignored、要手动恢复）；env 路径仍保留给 CI/自动化。

### 决策6：能力准入 STRICT/BLOCKED（为什么不让所有工具都跑 T3）

**问题**：不同 AI 工具能力差异大（有无 subagent、会话恢复、独立审查证据）。若都允许跑 T3 自动流程，弱能力工具跑出来的"独立审查"实为自审，T3 的质量保证失效——但工具不会自己声明能力不足。

**为什么这么设计**：`harness-capability.ps1` 探测每工具的能力并区分关键与辅助：**关键能力** = {subagent, evidence}（全满足→STRICT，任一缺失→BLOCKED）；**辅助能力** = {skillDiscovery, blockingHook, workspace, pauseResume}（记录但不 gating）。未知默认 BLOCKED（不静默降级）。T3 核心是独立审查，需要 subagent 派发独立上下文的审查者且能产出 evidence；pauseResume/blockingHook/skillDiscovery 影响体验与可用性，但不决定能否做独立审查。

**为什么 evidence 是关键能力**：T3 核心是独立审查（design-reviewer 必须独立 subagent 派发，禁止内联自审）。无 subagent 的工具无法独立派发，evidence=false→BLOCKED，只能 T2。

**考虑过的替代**：
- 都允许 T3，靠人自觉选工具：人会忘/图省事，T3 审查失效——否决。
- 静默降级（弱工具自动跑 T2）：无提醒，质量隐性下降——否决（要明确输出缺口）。
- 全局禁用某工具：太死板，工具升级后不能自动升档——否决。

**价值**："Pi 只 T2"从文档约束变可查询判定；未知工具默认 BLOCKED 防止静默降级；工具能力升级后校准表即可升 STRICT。

### 决策7：Installer + Lock + Manifest（为什么需要版本锁和投影校验）

**问题**：fresh clone 后，`.ai-sop` 子模块可能 checkout 到任意 commit，投影可能漂移，无法保证"SOP 是预期版本且各工具投影一致"。靠人手动同步不可靠。

**为什么这么设计**：
- **Lock**（`tools/ai-sop/ai-sop.lock.json`）：pin `.ai-sop` 到哪个 commit + manifest/core/bootstrap/certification 的 blob hash。commit 必须是已发布 40 位 SHA（禁 branch/tag/latest）。
- **Manifest**：声明 7 个单文件投影的 source/target/hash（targetSha256 = 渲染后 LF hash）。
- **Verify**（只读）：校验 HEAD==lock.commit、manifest blob==lock 声明、各投影 target hash==manifest 声明。报告 PROJECTION_DRIFT 等。
- **Install**：checkout lock commit + 生成投影 + hash 校验。

**为什么 hash 用 git blob bytes 而非工作树文本**：工作树文本受 `core.autocrlf` 影响换行，hash 不稳；git blob bytes 是规范化的，跨机一致（DC-004）。`.gitattributes` 强制 LF 保证渲染目标 hash 可复现。

**考虑过的替代**：
- 无 lock，submodule 跟随分支：版本不可控，可能拉到未发布/不稳定 commit——否决。
- 只 lock commit 不校验投影 hash：投影可能漂移，各工具行为不一致——不够，加 manifest hash。
- 手动同步投影：易忘、易错——自动化。

**价值**：fresh clone + Install = 确定版本 + 一致投影，跨机跨人可复现；Verify 主动报告漂移。

### 决策8：Git submodule + SVN 共存（为什么不用单一 VCS）

**问题**：游戏代码是 SVN 团队共享正式版本控制；SOP 是个人持续优化的核心资产，要 Git 跟踪 + push 到私有远程。两者不能合并（SVN 是团队正式、Git 是个人资产），且 SOP 不能进 SVN（每人 SOP 不同，会污染团队仓库）。

**为什么这么设计**：
- 根目录：SVN 工作副本（业务代码）+ 根 Git（跟踪 SOP 相关 + `.ai-workspace` + gitlink + lock）。
- `.ai-sop`：Git submodule（远程 agent-sop）。
- 根 `.gitignore`：ignore 全部业务代码，根 Git 只管 SOP。
- installer Git 模式用 submodule update，SVN 模式用独立 clone+rename（不创建 svn:externals，不 vendor 完整 SOP）。

**为什么 SOP 不进 SVN**：每人 SOP 演进不同，进 SVN 会污染团队仓库；SVN 只版本化 lock + bootstrap（DC-012），安装出的 `.ai-sop` 是 detached 到 lock commit 的独立 Git checkout。

**考虑过的替代**：
- 全迁 SVN：SOP 是个人 Git 资产，迁 SVN 失去 Git 演进能力——否决。
- 全迁 Git（游戏代码也 Git）：游戏代码是团队 SVN 正式版本控制，不能擅改——否决。
- SOP vendor 进 SVN：每人不同，污染团队——否决。

**价值**：游戏代码（SVN 团队）和 SOP（Git 个人资产）各自用合适 VCS，互不污染；根 Git 只管 SOP，ignore 游戏；fresh clone 可复现。

### 决策9：测试串行默认 + 弹窗抑制（为什么不一味追求并行快）

**问题**：测试套件含时序敏感的 strong-kill 恢复测试（750ms deadline + 文件锁），并行跑时 CPU 争抢导致 deadline 超时、锁竞争 REGISTRY_LOCK_TIMEOUT——flaky 失败，不是真缺陷。且 hook 子进程弹窗影响开发体验。

**为什么这么设计**：
- `run-all-tests.ps1` 默认串行（时序测试安全），`-Parallel` 可选（快但可能 flake）。
- 所有 `Start-Process` 加 `-WindowStyle Hidden`（不弹窗）。
- deadline 用 env 可覆盖（`SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS`、`SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS`），strong-kill 子进程设宽值。

**考虑过的替代**：
- 全并行：flaky 严重，CI 不可靠——否决。
- 全串行无并行选项：太慢，开发体验差——保留 `-Parallel`。
- 放宽所有 deadline：生产语义变松，掩盖真卡死——只对测试子进程放宽。

**价值**：CI 稳定绿（串行），想快可并行（接受 flake）；开发时不被弹窗打扰。

---

## 三、关键不变量（设计契约的核心约束）

这些是整个架构必须始终成立的约束，违反就是缺陷：

1. **单一真源**：`.ai-sop` 是唯一可编辑标准流程；`.claude/skills`、`.agents/skills` 是投影，手工改被 hash 校验拒绝。
2. **生产编辑需归属**：编辑 `src/com|WebRoot|config` 必须有 session-bound owner；无归属则拦截。
3. **独立审查隔离**：design-reviewer 必须独立 subagent 派发（不同 session/run ID），禁止内联自审。
4. **已批准产物不可篡改**：01/06 批准后 SHA 锁定，改动触发 ValidateTestCoverage 拦截。
5. **能力准入不静默降级**：未知能力默认 BLOCKED，明确输出缺口，不偷偷降级跑 T3。
6. **lock 引用已发布 commit**：禁 branch/tag/latest/未发布 SHA，保证可复现。
7. **分发可复现**：fresh clone + Install = lock commit + 一致投影，0 无映射 gitlink。

---

# 第二部分：架构与维护（怎么用/怎么改）

## 一、架构总览

本 SOP 采用**分层 + 单一真源 + 薄适配**架构，核心目标是换 AI 工具时低成本迁移、SOP 不随工具变。

```
项目根 (SVN 工作副本 = 游戏代码正式版本控制)
│
├── .ai-sop/                   【标准流程真源】Git submodule(中立名,持续演进核心资产)
│   ├── skills/ agents/         10 领域角色 + 9 审查角色(真源)
│   ├── scripts/                门禁/流程/capability/pi-adapter(真源)
│   ├── schemas/                流程契约 schema(workflow-*/hook-*/harness-capability)
│   ├── workflows/              标准流程编排
│   ├── distribution/           installer + 投影模板 + capability/certification
│   ├── config/                 流程状态机
│   └── settings.json           标准模板(hooks 指 .ai-sop/scripts)
│
├── .claude/                   【Claude Code 适配壳】根 Git 普通目录(非 submodule)
│   ├── settings.json           适配真源(hooks -> ./.ai-sop/scripts)
│   ├── claude.json commit.cmd Claude Code 专属配置
│   └── skills/ agents/         投影(installer 生成,gitignored)
│
├── .agents/skills/            【跨工具公共投影】pi/Codex/Antigravity 认
├── .cursor/ .github/hooks/    各工具 hooks 投影
├── CLAUDE.md AGENTS.md ...    根 md 投影(installer 生成)
├── .ai-workspace/             【项目领域层】根 Git(本地漂移)
│   ├── context/                项目领域知识
│   ├── specs/features/        所有功能需求/设计
│   ├── scripts/                项目部署(feature-runtime/tomcat-*)
│   └── workflows/ schemas/
├── tools/ai-sop/               installer 根入口 + lock
└── .gitmodules .gitattributes .gitignore
```

## 二、分层判据

| 内容 | 归属 | 判据 |
|---|---|---|
| skills/agents/workflows-标准/schemas/scripts-门禁/distribution/config | `.ai-sop`(标准流程) | 跨项目长期演进、git 历史要干净 |
| context/specs/tomcat 部署/parallel-development/feature-runtime | `.ai-workspace`(项目领域) | 随项目更换失效、本地漂移 |

**核心原则**：`.ai-sop` 是单一可编辑真源；`.claude/skills`、`.agents/skills` 是 installer 生成的投影（gitignored，手工改会被 hash 校验拒绝）。

## 三、换工具的适配方式

新增 AI 工具时，按"薄适配"接入（目标 ≤5 文件、≤1 人日）：

1. **skills 发现**：该工具是否认 `.agents/skills/`（pi/Codex/Antigravity）或自定义路径？若自定义，installer 加一条投影规则。
2. **hooks**：该工具的 hook 配置入口（如 `.cursor/hooks.json`、`.github/hooks/ai-sop.json`），命令统一指向 `./.ai-sop/scripts/hook-dispatcher.ps1`。
3. **能力准入**：在 `harness-capability.ps1` 的 known-capability 表加该工具条目，跑探测判定 STRICT/BLOCKED。
4. **真机认证**（阶段6）：接入真机跑黄金任务，填 `harness-certification.json`。

**不改**：标准流程真源（`.ai-sop`）、门禁逻辑、owner/session 流程。

## 四、能力准入（STRICT/BLOCKED）

`harness-capability.ps1` 对每个工具判定能跑 T3 还是只 T2：
- **关键能力** = {subagent, evidence}（全满足→STRICT，任一缺失→BLOCKED）
- **辅助能力** = {skillDiscovery, blockingHook, workspace, pauseResume}（记录，不 gating）
- 全关键满足 → STRICT（可跑 T3 自动实现+独立审查）
- 任一关键缺失/未知 → BLOCKED（只能 T2，明确输出缺口，不静默降级）

当前判定（`distribution/harness-capability.json`，由 `harness-capability.ps1 -All` 生成的快照；运行时以脚本探测为准）：
- STRICT：Claude Code/CLI、Copilot/CLI、Antigravity/CLI、Cursor/CLI（均有 subagent+evidence；Copilot/Antigravity 的 pauseResume 待 P3 真机确认，但 pauseResume 是辅助能力不影响 STRICT 判定）
- BLOCKED：Pi/CLI（核心无 subagent→无 evidence，只能 T2）

判定命令：`pwsh -NoProfile -File ./.ai-sop/scripts/harness-capability.ps1 -All`

## 五、关键子系统

### Installer（tools/ai-sop/ + .ai-sop/distribution/）
- `Action=Install`：从 lock 指定 commit checkout `.ai-sop`，生成所有投影（根 md + hooks + .claude/skills + .agents/skills），hash 校验。
- `Action=Verify`：只读校验 lock/commit/manifest/projections 一致性（报告 PROJECTION_DRIFT 等）。
- Lock（`tools/ai-sop/ai-sop.lock.json`）：pin 子模块 commit + manifest/core/bootstrap/certification blob hash。
- Manifest（`.ai-sop/distribution/project-manifest.json`）：声明 7 个单文件投影的 source/target/hash。

### Owner/Session（.ai-sop/scripts/workflow-owner.ps1 等）
- 功能归属：Claim/Validate/Complete，SUPERPOWERS + 五端（CLAUDE_CODE/COPILOT/ANTIGRAVITY/CURSOR/PI）。
- Owner 1.1 需 session + AST 校验的 command grant；PI 经 `pi-adapter/bootstrap-pi-session.ps1` 注册。
- 双人工批准（requirement + design）+ SHA 锁定 + 篡改检测。

### Guard（.ai-sop/scripts/guard-production-edit.ps1）
- 生产编辑拦截（src/com|WebRoot|config）需 session-bound owner。
- 手动开关：`.ai-sop/.guard-disabled`（创建=关 guard，删除=恢复）。
- T1 逃逸：env `SERVER_NEW_SKIP_OWNER_GUARD=1` 或开关文件；env 优先（显式非1 不逃逸）。

## 六、日常维护操作

### 改标准流程
- 编辑 `.ai-sop/`（真源），子模块 commit + push。
- 跑 `pwsh -NoProfile -File ./.ai-sop/scripts/run-all-tests.ps1` 确认绿。
- 跑 installer verify 确认投影一致；若改了模板，`Action=Install` 重新生成投影。

### 改项目领域知识
- 编辑 `.ai-workspace/context/`（根 Git），根仓库 commit。

### 加新功能 spec
- `.ai-workspace/specs/features/<Feature>/`（00_workflow_state + 01/06 + 05）。
- 经 owner Claim + 双人工批准。

### 测试
- `run-all-tests.ps1`：默认串行（时序敏感测试安全），`-Parallel` 可并行（快但可能 flake）。
- 单套件：`run-all-tests.ps1 -Suite <name>`。
- feature-runtime 环境敏感（需 clean Tomcat）、workflow-transaction 负载 flaky——单独跑更稳。

## 七、Git/SVN 拓扑

- 根仓库：Git（本地，无 remote）+ SVN 工作副本（业务代码正式版本控制）。
- `.ai-sop`：Git submodule（远程 agent-sop），根 Git 只跟踪 gitlink + lock。
- `.claude`/`.agents`/`.ai-workspace`：根 Git 普通目录。
- `.gitignore`：根 Git 只管 SOP 相关，ignore 全部游戏代码。
- 分发：fresh clone 经 installer `Action=Install` 复现全套 SOP（projection 自动生成）。

## 八、已知项

- feature-runtime 聚合跑环境敏感（Tomcat JSP 500 + 负载），单独跑 PASS——既有特性。
- workflow-transaction 负载下偶发 deadline flaky——既有。
- `.claude` nested checkout（非 absorbed submodule），功能正常，absorbgitdirs 待 worktree 清理后。
- harness-certification.json BLOCKED 占位，待 P3 真机认证。
- lock commit 需在 SOP 改动后重新 finalize（installer finalize 循环）。

## 九、阶段演进记录

| 阶段 | 内容 |
|---|---|
| 1 | 修拓扑（删意外根 Git、submodule、flaky） |
| 2 | P0 收尾（installer/manifest/lock/SVN Install） |
| 3 | AiSopLayering（标准流程 vs 项目领域分层） |
| 4 | AiSopRename（.claude→.ai-sop 改名 + 薄适配 + 投影生成） |
| 5 | P1 能力准入（harness-capability） |
| 6 | P3 真机认证（待真机环境） |
| P4 | 中立核心抽取（不做，数据驱动） |

## 十、相关文档
- 《AI SOP 使用指南》（使用者）
- `.ai-sop/SUPERPOWERS_MANUAL.md`（Superpowers 流程）
- `.ai-workspace/specs/features/AiSopPortabilityP0/06_design_contract.md`（P0 完整契约 DC-001~057）
