# 单个实现子会话委派

适用于同一物理工作区、同一任务、同一客户端类型的父子会话。父会话保留 owner/sessionBinding；一个任务最多有一个执行子会话。它不改变 T1/T2/T3，不允许同工作区同功能多任务并行。普通单会话任务和只读审查不增加步骤。

## 正常执行

1. 父会话按原流程 Start/Resume，完成当前档位所需的前置工作。首次派发实现子会话时，传入 Feature、taskId、档位、实现范围，要求先登记身份并返回，暂不修改。
2. 子会话用 **自己的** Hook 注入参数执行 Join。此操作只登记会话，不转移任务、不授予写权限。返回真实 nativeSessionId 给父会话。
3. 父会话按收到的 ID 执行 Delegate；成功后继续派发/恢复同一子会话。不能把 Task 工具的 resume ID 当成 nativeSessionId，也不能根据名称或提示词推断父子关系。
4. 子会话修改代码及相关测试，按原档位用 Task Run 编译/测试。编译、测试证据绑定真实子会话、委派 ID 和父会话 epoch。同步结论交回父会话。子会话不 Start/Resume/Recover/ConfirmTakeover，不改档、不批准、不完成任务、不继续派发其他执行者。
5. 子会话结束且验证全部停止后，父会话 RevokeDelegation，恢复自己的执行权限，再 RecordSync、ReviewImpact、记录批准/门禁或 Complete。只读审查可在期间读取并返回报告。

以下命令从宿主根目录执行；示例 ID 必须换成各自 Hook 注入及子会话返回的真实值：

```powershell
# 子会话：登记并回报身份，不认领父任务。
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Join -Feature Example -TaskId fix-1 -Agent CURSOR -NativeSessionId child-session
# 父会话：显式授权同一个子会话，默认有效期 120 分钟，可设 1–480 分钟。
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation Delegate -Feature Example -TaskId fix-1 -Agent CURSOR -NativeSessionId parent-session -ChildNativeSessionId child-session -Reason "实现已批准范围并执行相关验证"
# 子会话完成后，由父会话收回执行权。
pwsh -NoProfile -File ./ai-sop.ps1 Task -Operation RevokeDelegation -Feature Example -TaskId fix-1 -Agent CURSOR -NativeSessionId parent-session -Reason "实现及验证结束，进入审查和收尾"
```

父会话在委派期间可读取、派发和操作明确的任务控制入口；源码编辑、任意 Shell 和新验证被拒绝，避免父子同时写入。子会话的 Join 不代表授权成功。Task Status / InspectRecovery 中的 executionDelegation 显示本地授权，不把同步来的 specs 任务记录当成授权。

## 退出、超时与恢复

- 委派到期后不会自动把写权限交回父会话。父会话确认子会话停止后显式撤销，再续做或重新授权；不能直接覆盖原委派。已发出的任意编辑/Shell 无法靠事后撤销撤回，撤销前仍要等客户端执行结束。
- 有 RUNNING 验证时禁止撤销、换人、暂停或接管；同一任务第二个验证也会被拒绝。先等待，异常时查看日志和 InspectRecovery，确认进程已停止后按既有 Recover 流程恢复。不要手改状态解除占用。
- Suspend、Cancel、真正 Transfer/Rebind、Recover 会使旧委派失效。Resume 不会自动恢复旧子会话授权。父会话结束或 epoch 变化、子会话结束/到期，均不能继续沿用旧授权。
- 父会话等待期间普通空闲租约到期，不单独终止仍在有效期内的显式委派；该委派受自己的期限控制，父会话结束或 epoch 变化仍立即失效。父会话返回后若需要 Resume/Rebind，先确认子会话停止；不得为派发新任务抢占仍运行的验证。
- Task Run 每次续期检查委派和父会话；只续期尚有效的父子会话，不延长委派期限、不复活已结束会话。失败时保留 pending 证据。授权尚有效可由原子会话 RetryEvidence；授权失效后，待进程停止由父会话 InspectRecovery → Recover 保存原结果，不重写为父会话执行。
- 同步或升级仅更新 SOP 文件，不自动为当前任务建立委派，也不修改历史 task、owner 或规格。旧任务没有委派字段时继续按原规则工作。

自动回归覆盖真实 Hook wrapper 进程及后台验证进程；它证明引擎协议行为，不等同于每个客户端版本的 UI 现场认证。

## 客户端握手差异

- Codex 的原生子线程事件也可能携带父 `session_id`；适配器优先使用原生 `agent_id` 作为执行线程身份，不能在协议翻译时丢弃。子线程使用 Hook 回显的自身 ID；带 `collaboration` 前缀的已知派发/恢复工具同样受归属和唯一执行者检查，未知名称仍拒绝。

- Claude Code 的子 Agent 与父会话可能共用原生 `session_id`。SOP 根据原生 `session_id` 和 `agent_id` 生成稳定的 `claude-child:…` 执行身份，并在子会话只读工具/拒绝消息中回显。Join 和父会话 Delegate 必须完整使用该回显值，不能使用父 ID，也不能截短哈希。恢复子 Agent 的工具 ID 则继续使用客户端返回值；新版本可用父会话的 `SendMessage` 继续同一个子 Agent。
- Antigravity 子会话回报后会进入 `IDLE`。未过期、生命周期已确认且未绑定任务的空闲子会话可以接受显式 Delegate，恢复调用时仍需经过原生 PreInvocation 激活。已结束/已过期记录不能通过 Delegate 复活。
- Pi 必须实际装有子 Agent 扩展并提供独立会话身份及恢复能力。仅安装 SOP 的 Pi 扩展不会增加子 Agent 工具；没有这些能力时由父会话直接实现，不伪造身份，不循环 Join/Resume。
- 命令失败先核对完整 ID 和 reasonCode。时间戳为 UTC 时应按时区比较，不按日期字符串判断是否过期；不要为解决输入错误扫描全部工作区注册表或手工改状态。
