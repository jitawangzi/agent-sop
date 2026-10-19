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

先 Start/Resume，成功后回显实际档位与执行要求，再修改。未指定默认 T2；新 T1/T3 仍须 UserRequest。讨论与原生只读工具不需要任务。Shell 仍按已有保守策略处理，不能因为名字叫“测试”或“读取”便自动放行任意命令。无法识别的工具拒绝并保留诊断，不猜测它是只读。

## 验证

自动化覆盖五端事件载荷和真实任务状态变迁：无任务拒绝源码/文档编辑，Start 后允许，Suspend 后拒绝，Resume 后允许，Cancel 后拒绝；另测 Pi 扩展进程错误、坏 JSON 和超时。隔离探测命令：

```powershell
pwsh -NoProfile -File .ai-sop/scripts/verify-guard-live.ps1 -Agent CODEX
```

Agent 可换为 ANTIGRAVITY、CURSOR、PI、CLAUDE_CODE。此命令不改业务目录，输出明确标记 `clientHookCertified=false`。

实际客户端验收需在临时测试工程中检查：Hook 日志确实出现、无任务的写入被客户端阻止、登记任务后写入成功、暂停后再次阻止。记录客户端版本和载荷；不能以 in-process 探测代替此项，也不要在业务任务中故意制造非法写入。

真实进程回归由 `scripts/tests/hook-process.test.mjs` 覆盖：经项目 wrapper 启动 PowerShell，在本地代码页环境下发送 UTF-8/BOM 与中文路径，严格解码返回字节，检查原生拒绝协议及任务生命周期。Cursor 真实载荷允许相同的 conversation_id/session_id、缺省或空 cwd，以及 Windows `/D:/...` 工作区表示；身份不一致和越界路径仍拒绝。Cursor 自动导入 Claude Hook 时，两份有效载荷识别为同一个 Cursor 会话，由已有去重逻辑处理，不停用用户的其他 Hook。自动化通过仍不代表客户端现场认证通过。

## 协议依据

- [Codex Hooks](https://learn.chatgpt.com/docs/hooks)：原生 PreToolUse、工具覆盖和信任要求。
- [Antigravity Hooks](https://antigravity.google/docs/hooks)：项目配置与原生事件。
- [Cursor Hooks](https://cursor.com/docs/hooks)：preToolUse 与 failClosed。
- [Claude Code Hooks](https://code.claude.com/docs/en/hooks)：PreToolUse、原生返回值和 onFailure。
- [Pi 扩展](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)：tool_call 与会话生命周期。桥接代码不依赖包名，兼容新旧 Pi 包的相同扩展 API。

这些入口是工作流防误操作机制，不是针对同权限恶意代码的安全沙箱，也不覆盖客户端明确不触发 Hook 的特殊工具路径。
