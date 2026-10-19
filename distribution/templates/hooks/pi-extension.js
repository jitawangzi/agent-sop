import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// 仅桥接原生事件；所有授权仍由 PowerShell dispatcher 和任务状态机决定。
export function runGuard(wrapper, event, payload, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const child = spawn('pwsh', ['-NoProfile', '-File', wrapper, '-AgentHint', 'PI', '-EventHint', event],
      { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) { child.kill(); reject(error); } else resolve(result);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish(new Error('AI_SOP_HOOK_TIMEOUT: 防护超时，已拒绝本次工具调用。'));
    }, timeoutMs);
    child.on('error', error => finish(error));
    child.stdin.on('error', error => finish(error));
    child.stdout.on('data', chunk => {
      stdout += chunk;
      if (stdout.length > 1024 * 1024) { child.kill(); finish(new Error('AI_SOP_HOOK_OUTPUT_LIMIT')); }
    });
    child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-8192); });
    child.on('close', code => {
      if (stderr.trim()) console.error(`[AI SOP] ${stderr.trim()}`);
      if (code !== 0) return finish(new Error(`AI_SOP_HOOK_FAILED: exit=${code}; ${stderr}`));
      try {
        const result = JSON.parse(stdout);
        if (!result || typeof result !== 'object' || (event === 'PRE_TOOL_USE' && typeof result.block !== 'boolean')) {
          throw new Error('AI_SOP_HOOK_RESPONSE_INVALID');
        }
        finish(null, result);
      } catch (error) { finish(error); }
    });
    child.stdin.end(JSON.stringify(payload));
  });
}

export default function (pi) {
  const wrapper = fileURLToPath(new URL('../hook-wrapper.ps1', import.meta.url));
  const previousSession = process.env.AI_SESSION_ID;
  let currentSession;
  const payload = (ctx, eventName) => {
    currentSession = ctx.sessionManager.getSessionId();
    process.env.AI_SESSION_ID = currentSession;
    return { session_id: currentSession, cwd: ctx.cwd, hook_event_name: eventName };
  };
  pi.on('session_start', async (_event, ctx) => {
    try { await runGuard(wrapper, 'SESSION_START', { ...payload(ctx, 'SessionStart'), source: 'startup' }); }
    catch (error) { console.error(`[AI SOP] 会话初始化失败，写入仍须通过防护：${error.message}`); }
  });
  pi.on('tool_call', async (event, ctx) => {
    try {
      return await runGuard(wrapper, 'PRE_TOOL_USE', { ...payload(ctx, 'PreToolUse'),
        tool_name: event.toolName, tool_input: event.input, tool_use_id: event.toolCallId });
    } catch (error) {
      console.error(`[AI SOP] ${error.message}`);
      return { block: true, reason: error.message };
    }
  });
  pi.on('session_shutdown', async (_event, ctx) => {
    try { await runGuard(wrapper, 'SESSION_END', payload(ctx, 'SessionEnd')); }
    catch (error) { console.error(`[AI SOP] 会话结束记录失败：${error.message}`); }
    finally {
      if (process.env.AI_SESSION_ID === currentSession) {
        if (previousSession === undefined) delete process.env.AI_SESSION_ID;
        else process.env.AI_SESSION_ID = previousSession;
      }
    }
  });
}
