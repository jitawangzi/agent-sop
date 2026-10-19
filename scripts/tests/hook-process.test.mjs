import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, cp, copyFile, writeFile, readFile, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('../../', import.meta.url));
const root = await mkdtemp(join(tmpdir(), 'sop-hook-process-'));
const workspace = join(root, '中文 workspace');
const env = { ...process.env };
for (const kind of ['OWNER', 'SESSION', 'COMMAND_GRANT', 'TRANSACTION']) env[`AI_SOP_${kind}_REGISTRY`] = join(root, kind);
env.AI_SOP_SKIP_OWNER_GUARD = '0'; env.SERVER_NEW_SKIP_OWNER_GUARD = '0';
env.SERVER_NEW_HOOK_DEDUP_REGISTRY = join(root, 'dedup');
env.SERVER_NEW_HOOK_CORRELATION_REGISTRY = join(root, 'correlation');
const session = 'real-process-fixture';
const utf8 = new TextDecoder('utf-8', { fatal: true });
function run(args, input = Buffer.alloc(0)) {
  return new Promise((resolve, reject) => {
    const p = spawn('pwsh', args, { cwd: workspace, env, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout = [], stderr = [];
    const timer = setTimeout(() => { p.kill(); reject(new Error('Hook process exceeded 25 seconds')); }, 25000);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.stdin.on('error', e => { clearTimeout(timer); p.kill(); reject(e); });
    p.stdout.on('data', x => stdout.push(x)); p.stderr.on('data', x => stderr.push(x));
    p.on('close', code => {
      clearTimeout(timer);
      try { resolve({ code, stdout: utf8.decode(Buffer.concat(stdout)), stderr: utf8.decode(Buffer.concat(stderr)) }); }
      catch (e) { reject(new Error(args.join(' ') + ': ' + e.message)); }
    });
    p.stdin.end(input);
  });
}
async function hook(adapter, event, payload, bom = false, hint = '') {
  const input = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const bytes = Buffer.from((bom ? '\ufeff' : '') + input, 'utf8');
  // 模拟 Windows 客户端继承本地代码页；wrapper 必须自行恢复协议编码。
  const wrapper = join(workspace, adapter, 'hook-wrapper.ps1').replaceAll("'", "''");
  const command = `[Console]::InputEncoding=[Text.Encoding]::GetEncoding(936); [Console]::OutputEncoding=[Text.Encoding]::GetEncoding(936); & '${wrapper}' -EventHint ${event} ${hint ? '-AgentHint ' + hint : ''}; exit $LASTEXITCODE`;
  const r = await run(['-NoProfile', '-Command', command], bytes);
  const value = JSON.parse(r.stdout);
  assert(!r.stdout.includes('\ufffd'), r.stdout);
  return { ...r, value };
}
const roots = [process.platform === 'win32' ? '/' + workspace.replaceAll('\\', '/') : workspace];
let counter = 0;
const cursor = (name, input, extra = {}) => ({ conversation_id: session, session_id: session,
  generation_id: 'generation-1', tool_use_id: `tool-${++counter}\npart`, hook_event_name: 'preToolUse',
  cursor_version: '3.15.19', workspace_roots: roots, tool_name: name, tool_input: input, ...extra });
async function task(op, agent = 'CURSOR', nativeSession = session) {
  const args = ['-NoProfile', '-File', join(workspace, '.ai-sop/scripts/workflow-task.ps1'), '-Operation', op,
    '-WorkspacePath', workspace, '-Feature', 'Probe', '-TaskId', `${agent.toLowerCase()}-process-test`, '-Agent', agent, '-NativeSessionId', nativeSession];
  if (op === 'Start') args.push('-Objective', '真实进程验收');
  const command = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); & " + args.slice(2).map(x => x.startsWith('-') ? x : "'" + x.replaceAll("'", "''") + "'").join(' ') + '; exit $LASTEXITCODE';
  const r = await run(['-NoProfile', '-Command', command]); assert.equal(r.code, 0, r.stdout + r.stderr);
}
try {
  await mkdir(workspace);
  for (const dir of ['scripts', 'schemas', 'config']) await cp(join(source, dir), join(workspace, '.ai-sop', dir), { recursive: true });
  for (const adapter of ['.cursor', '.agents', '.claude', '.pi', '.codex']) {
    await mkdir(join(workspace, adapter));
    await copyFile(join(source, 'distribution/templates/hooks/hook-wrapper.ps1'), join(workspace, adapter, 'hook-wrapper.ps1'));
  }
  await mkdir(join(workspace, '.ai-workspace/specs/features/Probe'), { recursive: true });
  await mkdir(join(workspace, 'src'));
  const file = join(workspace, 'src/中文.txt'); await writeFile(file, 'BEFORE');
  const start = await hook('.cursor', 'SESSION_START', { session_id: session, conversation_id: session,
    generation_id: 'generation-1', is_background_agent: false, composer_mode: 'agent', hook_event_name: 'sessionStart',
    workspace_roots: roots, cursor_version: '3.15.19', model: 'fixture', model_id: 'fixture', model_params: [] }, true);
  assert.equal(start.code, 0); assert.equal(typeof start.value.additional_context, 'string', JSON.stringify(start)); assert.match(start.value.additional_context, /当前会话/);
  const edit = cursor('Write', { file_path: file, content: '修改内容' });
  const denied = await hook('.cursor', 'PRE_TOOL_USE', edit, true);
  assert.equal(denied.value.permission, 'deny'); assert.match(denied.value.agent_message, /ACTIVE/);
  assert.equal(denied.value.user_message, denied.value.agent_message);
  assert.match(denied.value.user_message, /AI_SOP_GUARD_SESSION_BINDING_INVALID/);
  // 只使用客户端实际展示的通道取回会话，再验证正常启动入口。
  const visibleSession = /-Agent CURSOR -NativeSessionId '([^']+)'/.exec(denied.value.user_message)?.[1];
  assert.equal(visibleSession, session);
  const imported = await hook('.claude', 'PRE_TOOL_USE', edit);
  assert.equal(imported.value.permission, 'deny'); assert.equal(imported.value.agent_message, denied.value.agent_message);
  assert.equal(imported.value.user_message, denied.value.user_message);
  const read = await hook('.cursor', 'PRE_TOOL_USE', cursor('Read', { file_path: file }, { cwd: '' }));
  assert.equal(read.value.permission, 'allow', JSON.stringify(read));
  for (const input of [
    { pattern: '', file_path: workspace, glob: '**/*.txt', output_mode: 'files_with_matches' },
    { pattern: 'BEFORE', file_path: file, output_mode: 'content' },
    { pattern: 'BEFORE', path: file }
  ]) {
    const search = await hook('.cursor', 'PRE_TOOL_USE', cursor('Grep', input));
    assert.equal(search.value.permission, 'allow', JSON.stringify(search));
  }
  for (const input of [
    { pattern: 'BEFORE', file_path: root },
    { pattern: 'BEFORE', file_path: file, path: file },
    { pattern: 'BEFORE', file_path: 42 },
    { pattern: null, file_path: file },
    { pattern: 'BEFORE', file_path: file, command: 'unrecognized' }
  ]) {
    const search = await hook('.cursor', 'PRE_TOOL_USE', cursor('Grep', input));
    assert.equal(search.value.permission, 'deny', JSON.stringify(search));
  }
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', cursor('UnrecognizedSearch', { pattern: '', file_path: file }))).value.permission, 'deny');
  const conflict = await hook('.cursor', 'PRE_TOOL_USE', cursor('Read', { file_path: file }, { session_id: 'foreign-session' }));
  assert.equal(conflict.value.permission, 'deny');
  const outside = await hook('.cursor', 'PRE_TOOL_USE', cursor('Read', { file_path: file }, { workspace_roots: [root] }));
  assert.equal(outside.value.permission, 'deny');
  for (const adapter of ['.cursor', '.claude']) {
    const bad = await hook(adapter, 'PRE_TOOL_USE', '{broken');
    assert(bad.code === 2 || bad.value.permission === 'deny', JSON.stringify(bad));
  }
  const ag = await hook('.agents', 'PRE_TOOL_USE', { conversationId: 'ag-native-fixture', workspacePaths: [workspace],
    stepIdx: 1, toolCall: { name: 'replace_file_content', args: { TargetFile: file, TargetContent: 'BEFORE', ReplacementContent: '修改' } } });
  assert.equal(ag.value.decision, 'deny'); assert.match(ag.value.reason, /写入前/);
  const bootstrapCommand = "pwsh -NoProfile -File './.ai-sop/scripts/workflow-task.ps1' -Operation Start -Feature Probe -TaskId process-test -Agent CURSOR -NativeSessionId '" + visibleSession + "' -Objective '真实进程验收'";
  const bootstrap = await hook('.cursor', 'PRE_TOOL_USE', cursor('Shell', { command: bootstrapCommand, cwd: '', timeout: 30000 }, { cwd: '' }));
  assert.equal(bootstrap.value.permission, 'allow', JSON.stringify(bootstrap));
  await task('Start');
  const active = await hook('.cursor', 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: '修改' }));
  assert.equal(active.value.permission, 'allow', JSON.stringify(active));
  await task('Suspend');
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: '修改' }))).value.permission, 'deny');
  await task('Resume');
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: '修改' }))).value.permission, 'allow');
  await task('Cancel');
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: '修改' }))).value.permission, 'deny');
  const piSession = 'pi-process-fixture';
  await hook('.pi', 'SESSION_START', { session_id: piSession, cwd: workspace, hook_event_name: 'SessionStart', source: 'startup' }, false, 'PI');
  const piEdit = async input => hook('.pi', 'PRE_TOOL_USE', { session_id: piSession, cwd: workspace,
    hook_event_name: 'PreToolUse', tool_name: 'edit', tool_use_id: `pi-${++counter}`, tool_input: input }, false, 'PI');
  const batch = { path: file, edits: [{ oldText: 'BEFORE', newText: '中间' }, { oldText: '中间', newText: 'AFTER' }] };
  const noTask = await piEdit(batch);
  assert.equal(noTask.value.block, true); assert.match(noTask.value.reason, /SESSION_BINDING_INVALID/);
  await task('Start', 'PI', piSession);
  assert.equal((await piEdit(batch)).value.block, false);
  assert.equal((await piEdit({ path: file, oldText: 'BEFORE', newText: 'AFTER' })).value.block, false);
  for (const input of [
    { path: file, edits: [] },
    { path: file, edits: batch.edits, oldText: 'BEFORE', newText: 'AFTER' },
    { path: file, edits: [{ oldText: 'BEFORE', newText: null }] },
    { path: file, edits: [{ path: root, oldText: 'BEFORE', newText: 'AFTER' }] },
    { path: join(root, 'outside.txt'), edits: batch.edits }
  ]) assert.equal((await piEdit(input)).value.block, true);
  await task('Suspend', 'PI', piSession);
  assert.equal((await piEdit(batch)).value.block, true);
  await task('Resume', 'PI', piSession);
  assert.equal((await piEdit(batch)).value.block, false);
  await task('Cancel', 'PI', piSession);
  assert.equal((await piEdit(batch)).value.block, true);
  // Codex 原生协议经真实 wrapper 进程验证，去重重放也必须带安全化命令。
  const codexSession = 'codex-read-process';
  await hook('.codex', 'SESSION_START', { session_id: codexSession, cwd: workspace,
    hook_event_name: 'SessionStart', source: 'startup' }, false, 'CODEX');
  const codexPayload = (name, input) => ({ session_id: codexSession, cwd: workspace,
    hook_event_name: 'PreToolUse', tool_name: name, tool_use_id: `codex-${++counter}`, tool_input: input });
  const codexHook = payload => hook('.codex', 'PRE_TOOL_USE', payload, false, 'CODEX');
  const readPayload = codexPayload('Bash', { command: "Get-Content -LiteralPath 'src/中文.txt'", shell: 'pwsh', timeout_ms: 10000 });
  for (let replay = 0; replay < 2; replay++) {
    const result = await codexHook(readPayload);
    const output = result.value.hookSpecificOutput;
    assert.equal(output.permissionDecision, 'allow', JSON.stringify(result));
    assert.match(output.updatedInput.command, /Microsoft.PowerShell.Management\\Get-Content/);
    const execution = await run(['-NoProfile', '-Command', output.updatedInput.command]);
    assert.equal(execution.code, 0, execution.stderr); assert.match(execution.stdout, /BEFORE/);
  }
  for (const command of ['git status --short', 'git diff', 'rg -n BEFORE src']) {
    const output = (await codexHook(codexPayload('Bash', { command }))).value.hookSpecificOutput;
    assert.equal(output.permissionDecision, 'allow');
    assert.match(output.updatedInput.command, command.startsWith('git') ? /--no-pager --no-optional-locks/ : /--no-config/);
  }
  const writeCommand = "Set-Content -LiteralPath 'src/中文.txt' -Value 'BAD'";
  for (const command of [writeCommand, `Get-Content 'src/中文.txt'; ${writeCommand}`, "Get-Content 'src/中文.txt' > src/out.txt", 'git diff --output=src/out.txt']) {
    assert.equal((await codexHook(codexPayload('Bash', { command }))).value.hookSpecificOutput.permissionDecision, 'deny');
  }
  const patch = () => codexPayload('apply_patch', { command: `*** Begin Patch\n*** Update File: ${file}\n@@\n-BEFORE\n+AFTER\n*** End Patch` });
  assert.equal((await codexHook(patch())).value.hookSpecificOutput.permissionDecision, 'deny');
  await task('Start', 'CODEX', codexSession);
  assert.equal((await codexHook(patch())).value.hookSpecificOutput.permissionDecision, 'allow');
  await task('Suspend', 'CODEX', codexSession);
  assert.equal((await codexHook(patch())).value.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal((await codexHook(readPayload)).value.hookSpecificOutput.permissionDecision, 'allow');
  await task('Resume', 'CODEX', codexSession);
  assert.equal((await codexHook(patch())).value.hookSpecificOutput.permissionDecision, 'allow');
  await task('Cancel', 'CODEX', codexSession);
  assert.equal((await codexHook(readPayload)).value.hookSpecificOutput.permissionDecision, 'allow');
  assert.equal((await codexHook(codexPayload('Bash', { command: writeCommand }))).value.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal(await readFile(file, 'utf8'), 'BEFORE');
  console.log('PASS: real wrapper processes, UTF-8/BOM/Chinese, Cursor/Pi/Codex task lifecycle, safe readonly command replay and write rejection');
} finally {
  const physical = await realpath(root);
  assert.equal(dirname(physical), await realpath(tmpdir()));
  assert.match(physical.split(/[\\/]/).at(-1), /^sop-hook-process-/);
  await rm(physical, { recursive: true, force: true });
}
