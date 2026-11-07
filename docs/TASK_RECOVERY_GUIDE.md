# 任务恢复与协作参考

只在暂停、接管、异常恢复或跨工作区协作时读取。日常入口仍是宿主 AGENTS.md；不改变档位、完成条件或授权。

## 暂停、接管与异常

长任务的重要节点按需 Checkpoint；短 T1/T2 不为每次编辑写检查点。暂停直接 Suspend 并带 NextAction/Notes，保存进度并释放占用；Cancel 表示取消，不表示完成，也不撤销实际代码修改。旧任务暂停后可启动独立小任务，无需先通过旧完成门禁。

**写前检查**：实际接入 Hook 的编辑路径会核对当前活动任务、合法档位及 owner/session 身份；只有旧 owner 没有 taskId 时须 Resume 收编。正常 T1 也必须登记和验证；人工紧急停用 Guard 是独立维护操作，不代表 T1 合规或完成，Agent 不得自行启用。客户端未加载或未信任 Hook、或写入路径不触发 Hook 时，不能承诺机器阻断；开场说明和 Complete 仍须遵守。

**写入 Guard 拦截后的任务识别**：Discover 确认 Feature/taskId；普通续做 Resume，异常中断先 InspectRecovery，按诊断 Recover → Resume。不得直接 Claim、手写权限或启用绕过开关规避任务入口。确认旧 Agent 已停止且验证进程不再运行，才进行强制恢复；已明确授权的接管不重复询问。跨 ACTIVE/IDLE 会话的正常接管按提示使用 ConfirmTakeover。

**损坏与未决状态**：保留原始记录和日志；InspectRecovery 只读定位问题。待入账证据损坏且进程已停止时，显式 Recover -QuarantineInvalidEvidence -Reason 保存原字节并记中断，再恢复执行。权限记录损坏依靠可信备份/事务恢复，不能删除后猜测重建。WORKFLOW_TRANSACTION_INDETERMINATE 先 Preflight；无法确定状态时停止修改并报告，不用 ForceRelease 绕过。

**旧功能级命令兼容**：仅在处理无 taskId 的旧归属、feature-state.json 或旧执行证据时，读取 `.ai-sop/workflows/agent-legacy.md`。旧 ACTIVE owner 的显式 Resume 收编保留原身份与批准；历史档位不明确时先确认，不默认按 T2 收编。缺少原始起点的旧 T3 不能用当前快照伪造恢复。本次任务 DONE 不代表旧 T3 或整个功能已验收。

**并行与同步**：同一工作区同功能仍串行。不同工作区允许同功能 T1/T2 之间、T3 与 T1/T2 并行，各用不同 TaskId、独立代码和规格副本；T3 + T3 暂不支持。不同功能可并行。同步来的外部 ACTIVE 记录不授予本地权限；无跨机器实时锁，未同步冲突无法自动探测。接管同一任务仍先在原处 Suspend，再同步相同代码及规格/任务记录，接收端 Resume。`.ai-workspace` 与 `specs` 按实际 Git 归属分别同步，`.artifacts/` 随 specs 保存；本机 Session/Grant/owner 和 `.runtime/` 不同步为权限。合并结果重新验证，误开 T3 + T3 的保全与恢复见 `.ai-sop/docs/PARALLEL_TASKS.md`。
