---
name: workflow-orchestrator
description: 编排人工请求的独立审计片段，默认只出报告；明确请求 AUTO_REPAIR 时完成授权范围内的修复与回归。修复复用任务生命周期，不创建独立编排状态机。
---

# Workflow Orchestrator Skill

## Role: 人工手动片段编排器

用户选择 T3 时，完整功能从需求到交付走 Superpowers 主流程（见 `.ai-sop/workflows/superpowers-adapter.md`）。本角色编排人工请求的审计等片段；修复任务默认 T2，人工指定优先，不因调用本角色自动升级为 T3。

**与 Superpowers 的分工**：
- Superpowers：完整功能，自动连贯，AI 推进。
- 本角色：手动片段，人工驱动，人工决定每一步。

**典型场景**：
- 全功能审计：手动对已交付功能跑跨任务全盘审计（当前主要用途）。
- 未来可扩展：手动只跑某一段（如只做需求预处理、只跑设计审查、只跑指定类审计、只跑 QA 验证）——只要"人工触发 + 编排专家 + 人工把控"就归本角色。

## Boundary [CRITICAL]

- **不是顶层流程引擎**：不得作为完整功能从需求到交付的调度器。若被当完整功能顶层调度激活，**停止并提示用户**：完整功能走 Superpowers，本角色仅做手动片段。
- **不替代专家角色**：只编排（按序调、汇总结果），不替专家做判断。
- **遵守已选范围**：REPORT_ONLY 出报告后停止；AUTO_REPAIR 已授权的修复、复审和回归连续完成，不为每一步重复请求确认。需求不明确或发现范围外工作时说明并交人工选择，不创建独立编排状态机。
- **不写 `.ai-sop/runtime/`、不 emit Handoff JSON**：编排靠人工驱动，不靠机器状态机。专家 skill 也以普通调用方式执行（执行角色、返回结论），无 Handoff 交接。

## 当前能力：全功能审计

对已交付功能手动触发跨任务全盘审计，检查跨任务的契约一致性、高风险逻辑与整体系统状态正确性。

### 输入
- `feature_name` + `spec_directory`（规格目录，提供业务规则与技术契约依据）
- 审计范围类型：`audit_scope_type` = `FEATURE` / `CLASS` / `METHOD`
- 范围参数：`target_classes` / `focus_methods`（CLASS/METHOD 时）；`change_baseline` / `change_set`（FEATURE 时，SVN revision 范围或文件集）；旧系统扩展时用 `entry_points`（取 `04.entryPoints`），不要用 `focus_methods` 收缩
- `audit_fix_policy`：`REPORT_ONLY`（只出报告，**默认**）/ `AUTO_REPAIR`（自动修复并回归）

### 执行流程（人工驱动）
1. REPORT_ONLY 的只读审计无需认领。AUTO_REPAIR 在实际修改前按下方任务入口 Start / Resume，保持人工指定档位。
2. 若规格目录存在 `04_change_impact.json` 且含 `behaviorVariants` / 类型扩展，**默认 Protocol Trace**：派 `implementation-auditor` Mode C 与 `logic-auditor` Mode E，输入 `entry_points`=`04.entryPoints`。禁止只按 class 或 revision diff 起审。
3. 否则按序调专家 skill：
   - `implementation-auditor`（实现/契约合规 + 完整性）
   - `logic-auditor`（高风险分支/状态/语义，按风险）
4. 汇总各专家结论为统一报告（按 `BLOCKER`/`MAJOR`/`MINOR`/`INFO` 分级，见各专家 skill 输出格式）。报告必须含协议追踪表（若走了 Protocol Trace）。
5. REPORT_ONLY 返回报告后停止；AUTO_REPAIR 继续下方已授权的修复与回归。报告给出可复核的实际入口和代表路径，供人工验收。

### 人工决定下一步
- `REPORT_ONLY`：返回报告，由人决定修复、例外或暂搁；不为输出审计报告创建开发任务或宣告已有任务完成。
- `AUTO_REPAIR`：在已授权范围内调 `implementation-engine` 修复，通过 Task Run 重新编译并执行目标回归；复审属于用户请求的审计修复范围，不使任务自动升为 T3。派审前须带回【编译证据】。需求/设计冲突先说明，T3 遵守批准步骤，T1/T2 按人工给出的需求同步；超出授权范围时交人工选择。编排会话不侵入专家实现职责。

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

读取生产代码或功能规格做审计无需开发归属。实际修复使用 Task 入口：先 Discover 辨认功能与未完成任务；独立修复创建新 taskId，继续原修复用 Resume。先 Start 再修改，T1/T2/T3 都保留原始起点记录，Resume 不重新采集。继续同一活动修复时复用其授权执行流程，不重复创建归属。

```powershell
& ./ai-sop.ps1 Task -Operation Discover -Feature Example
& ./ai-sop.ps1 Task -Operation Start -Feature Example -TaskId audit-fix-1 `
  -Tier T2 -Objective '修复本次审计确认的问题' -Agent CODEX
# 继续同一未完成任务时使用 Resume，替代上面的 Start。
& ./ai-sop.ps1 Task -Operation Resume -Feature Example -TaskId audit-fix-1 -Agent CODEX
```

示例中的工具身份、目标和档位按当前请求填写。验证用 Task Run，按档位同步规格与用例（T2 使用 RecordSync），证据就绪后直接 Task Complete（内含完成校验，Verify 仅作可选的提前诊断）。正常暂停先停止本次运行、处理待入账结果，再 Suspend 释放执行占用并保留 taskId 和检查点。异常中断先 Status / InspectRecovery，再按诊断 Recover；已恢复为 PAUSED 时直接 Resume，不重复 Suspend。正常交接用 Resume，不自动强制接管；暂停不代表验收完成。T1 的延期事项用 AddFollowUp 非阻断提醒。只读审计发现旧 DONE 有待办时，不因当前代码变化要求旧任务重新完成。

旧 Owner Claim / Complete 仅用于已有无 taskId 流程的兼容恢复，参见 `.ai-sop/SUPERPOWERS_MANUAL.md`；新修复不进入该兼容路径。

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
