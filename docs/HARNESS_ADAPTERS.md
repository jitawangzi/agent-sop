# 客户端写前检查接入

仅安装 AI SOP 的宿主使用这些入口。普通项目不安装全局 Hook，不自动引入档位。适配复用同一任务、档位、归属和会话检查，不增加 T1/T2 的审批或独立审核步骤。

| 客户端 | 项目入口 | 启用与限制 |
|---|---|---|
| Antigravity App / IDE / CLI | `.agents/hooks.json` → wrapper | 在 Hooks 面板或 `/hooks` 检查 ai-sop 已启用；继续使用原生 PreInvocation / PreToolUse / Stop。 |
| Cursor | `.cursor/hooks.json` → wrapper | preToolUse 使用 failClosed，错误与超时拒绝调用；生命周期仍不阻止会话启动。 |
| Claude Code | `.claude/settings.json` → wrapper | 使用 SessionStart / PreToolUse / SessionEnd；支持 onFailure 的版本将写前 Hook 异常也视为阻断。安装保留其他自定义 hooks。 |
| Codex 本地 CLI / App | `.codex/hooks.json` → wrapper，固定 `-AgentHint CODEX` | 客户端必须支持原生 PreToolUse，项目层必须受信任，并在客户端审核信任当前 Hook。CLI 可用 `/hooks` 检查；配置变化可能再次要求审核。安装器不代替用户信任，也不写入绕过信任的选项。 |
| Pi | `.pi/extensions/ai-sop.js` → `.pi/hook-wrapper.ps1` | 项目扩展自动发现；重启或 `/reload`。tool_call 读取 dispatcher 原生 block 结果，进程错误、坏 JSON、超时都拒绝；扩展加载不代表 T3 独立审核能力已经具备。 |

各客户端从宿主根目录启动。Hook 未加载、旧客户端不支持事件、客户端忽略结果，都不能称为已防护。先完成下面的实际验证，再将该客户端列为已认证。配置中的 blockingHook 表示已实现且文档支持的接入能力，不是现场认证；`harness-certification.json` 不因此自动写 PASS。

## 会话与档位

Hook 注入当前会话说明。Agent 在 Task 命令中携带说明中的 `-Agent` 和 `-NativeSessionId`，避免 CLI 子进程被识别为新会话。该参数仅在当前命令及其子进程生效，结束后恢复；引导检查拒绝与原生 Hook 会话不一致的参数。Pi 同时把原生 session id 传入子进程环境。

Cursor 的拒绝结果在 user_message 和 agent_message 两个通道同时提供原因及当前会话参数；即使客户端未展示 SessionStart 上下文，也可按拒绝说明正常 Start/Resume，无需停用防护或猜测会话 ID。原生 Grep 的 file_path 映射为统一搜索路径，继续执行工作区路径检查；同时传入 path 和 file_path 时拒绝。空正则是合法的只读搜索，不因此要求启动任务。

Pi 的 edit 同时兼容旧版 `path/oldText/newText` 和新版 `path/edits[]`。编辑数组保留原顺序，只允许修改顶层 path 指定的文件；空数组、混用两种格式或在数组项中指定另一个路径均拒绝。

先 Start/Resume，成功后回显实际档位与执行要求，再修改。未指定默认 T2；新 T1/T3 仍须 UserRequest。讨论与原生只读工具不需要任务。Shell 仍按已有保守策略处理，不能因为名字叫“测试”或“读取”便自动放行任意命令。无法识别的工具拒绝并保留诊断，不猜测它是只读。

实现子会话不走 Resume 接管。使用自己的会话参数 Join 回报身份，父会话 Delegate 后再恢复同一子会话，执行及撤销步骤见 [执行委派](EXECUTION_DELEGATION.md)。只读子会话仍不 Join，不改变权限。

## 验证

自动化覆盖五端事件载荷和真实任务状态变迁：无任务拒绝源码/文档编辑，Start 后允许，Suspend 后拒绝，Resume 后允许，Cancel 后拒绝；另测 Pi 扩展进程错误、坏 JSON 和超时。隔离探测命令：

```powershell
pwsh -NoProfile -File .ai-sop/scripts/verify-guard-live.ps1 -Agent CODEX
```

Agent 可换为 ANTIGRAVITY、CURSOR、PI、CLAUDE_CODE。此命令不改业务目录，输出明确标记 `clientHookCertified=false`。

实际客户端验收需在临时测试工程中检查：Hook 日志确实出现、无任务的写入被客户端阻止、登记任务后写入成功、暂停后再次阻止。记录客户端版本和载荷；不能以 in-process 探测代替此项，也不要在业务任务中故意制造非法写入。

Codex 的“项目受信任”和“Hook 已信任”是两项独立状态。验收前通过原生 `/hooks` 审核本工程的三个 SOP 事件，确认 Active，而非只看到 Installed；新目录需要单独检查。未信任的 Hook 会被客户端跳过，不能将此时的写入成功误诊为 dispatcher 放行。自动验收也应先完成正常信任，不用绕过 Hook 信任的开关代替。

Codex 的常用 Shell 只读命令无需活动任务，暂停或取消任务后也可继续讨论、查看代码：例如 `Get-Content -LiteralPath 'src/example.txt'`、`Get-ChildItem src -File`、`rg -n pattern src`、`git status --short`、`git diff`、`git log --oneline -n 5`。支持固定只读管道（例如 `Get-Content ... | Select-Object -First 20`）及多个已识别的读取语句；POSIX Shell 支持字面路径的 cat/head/tail 和 sed 行范围读取。路径须在工作区内，未知参数、变量、脚本块、重定向以及混合写入不会获此豁免；遇到复杂只读表达式被拒，可拆成简单读取命令，无需为讨论创建任务。

放行时通过 Codex 原生 `updatedInput.command` 返回重新构造的命令：Git 禁用 pager、可选锁、fsmonitor、签名校验及外部 diff/textconv，rg 禁用配置文件，PowerShell 使用模块限定的只读 cmdlet。去重重放仍重验路径并返回安全化命令。任意 Shell、脚本执行和文件写入继续执行任务防护。

Antigravity `run_command` 同样支持这些免任务的字面只读命令，包括 `Get-ChildItem`、`rg`、`git status/log/diff`，以及只读取本地配置的 `git remote -v`、`git remote get-url origin`、`git branch --show-current`。使用原生 `CommandLine`、可选 `Cwd`、非负整数 `WaitMsBeforeAsync` 和字符串 `toolSummary/toolAction`；`IsDaemon/RunPersistent` 仅接受省略或 false，已有终端、未知参数和命令混写不获只读豁免。Hook 通过原生 `overwrite.CommandLine` 返回安全化命令，并将 `overwrite.Cwd` 固定为已检查的目录；不设置 `permissionOverrides`，不使用 `auto_approve`，仍由客户端执行自身权限规则。无任务时不能修改 remote、创建/删除分支或运行任意脚本。

真实进程回归由 `scripts/tests/hook-process.test.mjs` 覆盖：经项目 wrapper 启动 PowerShell，在本地代码页环境下发送 UTF-8/BOM 与中文路径，严格解码返回字节，检查原生拒绝协议及任务生命周期。Cursor 真实载荷允许相同的 conversation_id/session_id、缺省或空 cwd，以及 Windows `/D:/...` 工作区表示；身份不一致和越界路径仍拒绝。Cursor 自动导入 Claude Hook 时，两份有效载荷识别为同一个 Cursor 会话，由已有去重逻辑处理，不停用用户的其他 Hook。自动化通过仍不代表客户端现场认证通过。

Antigravity `read_file` 接受新版 `Path`、`StartLine`、`EndLine`、`ByteOffset`，并兼容旧版 `path`、`line_start`、`line_end`、`offset`。原生参数先映射到严格 READ 校验；未知字段、非整数范围和重复别名仍拒绝。合法读取无需 Start/Resume，未登记或 INACTIVE 会话也可读取，且不会登记、续租、恢复或接管任务。此适配不把宽泛 ANY_OBJECT 工具或任意 Shell 命令当作只读。

Antigravity `read_file` 除当前工作区外，还可读取本机用户目录下 `.gemini/{antigravity,antigravity-cli,antigravity-ide}/builtin/skills/`，以及对应 `brain/<当前 conversationId>/` 的上传文件和 Artifacts。范围按本机用户配置目录及当前会话标识推导，不信任载荷提供的任意 `appDataDir/artifactDirectoryPath`；其他会话、配置凭据、目录穿越与链接逃逸仍拒绝。该例外只适用于已严格校验的 `read_file`，不授权写入，也不扩大 Shell 的目录范围。

无任务的 Shell 读取仍限定于当前工作区；跨项目审核应在对应项目工作区读取。已有 ACTIVE 任务下的任意 Shell 沿用归属/命令授权策略，并非逐路径安全沙箱；不能以临时 Resume 审核任务来规避只读通道的范围限制。

## 协议依据

- [Codex Hooks](https://learn.chatgpt.com/docs/hooks)：原生 PreToolUse、工具覆盖和信任要求。
- [Antigravity Hooks](https://antigravity.google/docs/hooks)：项目配置与原生事件。
- [Cursor Hooks](https://cursor.com/docs/hooks)：preToolUse 与 failClosed。
- [Claude Code Hooks](https://code.claude.com/docs/en/hooks)：PreToolUse、原生返回值和 onFailure。
- [Pi 扩展](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)：tool_call 与会话生命周期。桥接代码不依赖包名，兼容新旧 Pi 包的相同扩展 API。

这些入口是工作流防误操作机制，不是针对同权限恶意代码的安全沙箱，也不覆盖客户端明确不触发 Hook 的特殊工具路径。
