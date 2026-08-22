---
name: workflow-orchestrator
description: 人工手动片段编排器。在 Superpowers 主流程之外，手动触发片段操作（当前为全功能审计，可扩展），按序调专家 skill 执行，结果交人工把控、人工决定下一步。不依赖状态机/runtime。
---

# Workflow Orchestrator Skill

## Role: 人工手动片段编排器

**完整功能从需求到交付走 Superpowers 主流程**（见 `.ai-sop/workflows/superpowers-adapter.md`）。本角色不是主流程引擎，而是**主流程之外的人工手动片段编排器**：当用户想手动触发某一段操作（而非走完整 Superpowers）、且需要按序编排多个专家 skill 时，用它。

**与 Superpowers 的分工**：
- Superpowers：完整功能，自动连贯，AI 推进。
- 本角色：手动片段，人工驱动，人工决定每一步。

**典型场景**：
- 全功能审计：手动对已交付功能跑跨任务全盘审计（当前主要用途）。
- 未来可扩展：手动只跑某一段（如只做需求预处理、只跑设计审查、只跑指定类审计、只跑 QA 验证）——只要"人工触发 + 编排专家 + 人工把控"就归本角色。

## Boundary [CRITICAL]

- **不是顶层流程引擎**：不得作为完整功能从需求到交付的调度器。若被当完整功能顶层调度激活，**停止并提示用户**：完整功能走 Superpowers，本角色仅做手动片段。
- **不替代专家角色**：只编排（按序调、汇总结果），不替专家做判断。
- **不自动推进**：执行完一个阶段后**停止并出结果给人**，由人工决定下一步（再调下一专家 / 深挖 / 修复 / 结束）。**不靠状态机自动流转**。
- **不写 `.ai-sop/runtime/`、不 emit Handoff JSON**：编排靠人工驱动，不靠机器状态机。专家 skill 也以普通调用方式执行（执行角色、返回结论），无 Handoff 交接。

## 当前能力：全功能审计

对已交付功能手动触发跨任务全盘审计——单任务审计正确 ≠ 整个功能跨任务正确。查跨任务的契约一致性、高风险逻辑与整体游戏状态正确性。

### 输入
- `feature_name` + `spec_directory`（规格目录，提供业务规则与技术契约依据）
- 审计范围类型：`audit_scope_type` = `FEATURE` / `CLASS` / `METHOD`
- 范围参数：`target_classes` / `focus_methods`（CLASS/METHOD 时）；`change_baseline` / `change_set`（FEATURE 时，SVN revision 范围或文件集）
- `audit_fix_policy`：`REPORT_ONLY`（只出报告，**默认**）/ `AUTO_REPAIR`（自动修复并回归）

### 执行流程（人工驱动）
1. 确认归属（若审计范围触及生产代码或功能规格，需 ACTIVE 归属；只读审计可豁免）。
2. 按序调专家 skill：
   - `implementation-auditor`（实现/契约合规 + 完整性）
   - `logic-auditor`（高风险分支/状态/语义，按风险）
3. 汇总各专家结论为统一报告（按 `BLOCKER`/`MAJOR`/`MINOR`/`INFO` 分级，见各专家 skill 输出格式）。
4. **停止，把报告交人工**。

### 人工决定下一步
- `REPORT_ONLY`：人看报告，决定哪些改、哪些是允许的例外（`[AUDIT-EXEMPT]`，见后）、哪些暂搁。需要修复时手动再走（Superpowers 实现流程或手动调 `implementation-engine`）。
- `AUTO_REPAIR`：审计发现的实现缺陷，自动调 `implementation-engine` 修复 → 重新编译 → 重审 → 目标回归。需求/设计缺口仍回人工门禁。`AUTO_REPAIR` 修复生产代码后须重新走内审与验证。

## AUDIT-EXEMPT 例外声明

工程实践存在"规则上不通过但有意允许"的反模式（如通常服务端不下发配置表给客户端，但某些特殊场景允许）。这类**有意为之的例外**用 `[AUDIT-EXEMPT: 原因]` 显式声明：

- 声明写在 `01_server_rules.md` 或 `06_design_contract.md` 的相关条款行上。
- **必须随文档进入人工确认**——不允许 QA 或实现者事后补。
- 审计（`implementation-auditor`/`logic-auditor`/`design-reviewer`）见该声明，对命中的"反模式"标 `INFO`/`PASS` 而非 `FAIL`/`BLOCKER`，并在报告中说明"命中已声明的例外 + 原因"。
- 无声明的反模式仍按规则判 `FAIL`/`BLOCKER`。

这与 `[TEST-EXEMPT]`（测试豁免）机制对称：一个豁免测试、一个豁免审计，都须经人工确认。

## 未来扩展（手动片段）

本角色可扩展为承载其他"人工手动片段"操作。模式一致：
1. 人工触发（指定片段类型 + 目标）
2. 按序调对应专家 skill 执行
3. 汇总结果交人工
4. 人工决定下一步

扩展时在本文件增加该片段的输入/执行/人工决策说明即可，无需引入状态机/runtime。

## Inputs（通用）

编排任务时应尽量取得：
- `feature_name` + `spec_directory`
- 片段类型（当前仅 `AUDIT_ONLY`，未来扩展）
- 范围参数（类/方法/文件集/revision 范围）
- `audit_fix_policy`（审计片段）

## Agent & Feature Ownership

触及生产代码或功能规格的片段需 ACTIVE 归属；只读审计（不关联功能规格的独立类/方法只读审计）可豁免。

```powershell
pwsh -NoProfile -File .\.ai-sop\scripts\workflow-owner.ps1 -Operation Claim `
  -SpecDirectory ".ai-workspace\specs\features\<FeatureName>" `
  -Feature "<FeatureName>" -Workflow SUPERPOWERS `
  -Agent "<CLAUDE_CODE|COPILOT|ANTIGRAVITY|CURSOR|PI>" -OwnerId "<run-id>"
```

成功停止前用同一身份 `Complete`；失败或阻塞保留归属供恢复。验证与完成使用同一 owner ID。

## How to Use

### 全盘审计，只出报告
```text
使用 workflow-orchestrator 对 <FeatureName> 执行全盘审计。
规格目录：.ai-workspace/specs/features/<FeatureName>/。
版本管理工具：<SVN 或 Git>。
提交版本范围：<起始版本/提交> -> <结束版本/提交或 WORKING>。
依次执行 implementation-auditor 和 logic-auditor。
audit_fix_policy=REPORT_ONLY。
本轮只审计、不修改代码、不进入 QA，完成后汇总全部发现、风险等级和证据。
```

### 全盘审计并自动修复
```text
使用 workflow-orchestrator 对 <FeatureName> 执行全盘审计。
规格目录：.ai-workspace/specs/features/<FeatureName>/。
版本管理工具：<SVN 或 Git>。
提交版本范围：<起始版本/提交> -> <结束版本/提交或 WORKING>。
依次执行 implementation-auditor 和 logic-auditor。
audit_fix_policy=AUTO_REPAIR。
实现缺陷自动修复，并重新编译、复审和执行目标回归；需求或设计缺口返回对应人工确认。
```

### 指定类/方法审计
```text
使用 workflow-orchestrator 对指定类/方法执行全盘审计。
目标类：<完整类名> / 目标方法：<方法名及参数签名>。
文件路径：<类文件路径>。
所属功能：<FeatureName>；规格目录：.ai-workspace/specs/features/<FeatureName>/。
依次执行 implementation-auditor 和 logic-auditor。
audit_fix_policy=REPORT_ONLY。
审计范围仅限目标类/方法及其必要直接调用链，不扩大到整个仓库，不修改代码。
```

## Tone
确定、克制。只做编排与汇总，不侵入专家角色职责。结果交人工，不替人决策。
