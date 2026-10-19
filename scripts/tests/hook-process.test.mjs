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
async function hook(adapter, event, payload, bom = false) {
  const input = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const bytes = Buffer.from((bom ? '\ufeff' : '') + input, 'utf8');
  // 模拟 Windows 客户端继承本地代码页；wrapper 必须自行恢复协议编码。
  const wrapper = join(workspace, adapter, 'hook-wrapper.ps1').replaceAll("'", "''");
  const command = `[Console]::InputEncoding=[Text.Encoding]::GetEncoding(936); [Console]::OutputEncoding=[Text.Encoding]::GetEncoding(936); & '${wrapper}' -EventHint ${event}; exit $LASTEXITCODE`;
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
async function task(op) {
  const args = ['-NoProfile', '-File', join(workspace, '.ai-sop/scripts/workflow-task.ps1'), '-Operation', op,
    '-WorkspacePath', workspace, '-Feature', 'Probe', '-TaskId', 'process-test', '-Agent', 'CURSOR', '-NativeSessionId', session];
  if (op === 'Start') args.push('-Objective', '真实进程验收');
  const command = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); & " + args.slice(2).map(x => x.startsWith('-') ? x : "'" + x.replaceAll("'", "''") + "'").join(' ') + '; exit $LASTEXITCODE';
  const r = await run(['-NoProfile', '-Command', command]); assert.equal(r.code, 0, r.stdout + r.stderr);
}
try {
  await mkdir(workspace);
  for (const dir of ['scripts', 'schemas', 'config']) await cp(join(source, dir), join(workspace, '.ai-sop', dir), { recursive: true });
  for (const adapter of ['.cursor', '.agents', '.claude']) {
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
  const imported = await hook('.claude', 'PRE_TOOL_USE', edit);
  assert.equal(imported.value.permission, 'deny'); assert.equal(imported.value.agent_message, denied.value.agent_message);
  const read = await hook('.cursor', 'PRE_TOOL_USE', cursor('Read', { file_path: file }, { cwd: '' }));
  assert.equal(read.value.permission, 'allow', JSON.stringify(read));
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
  const bootstrapCommand = "pwsh -NoProfile -File './.ai-sop/scripts/workflow-task.ps1' -Operation Start -Feature Probe -TaskId process-test -Agent CURSOR -NativeSessionId '" + session + "' -Objective '真实进程验收'";
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
  assert.equal(await readFile(file, 'utf8'), 'BEFORE');
  console.log('PASS: real wrapper processes, UTF-8/BOM/Chinese, native Cursor metadata, duplicate imported hook, malformed input and task lifecycle');
} finally {
  const physical = await realpath(root);
  assert.equal(dirname(physical), await realpath(tmpdir()));
  assert.match(physical.split(/[\\/]/).at(-1), /^sop-hook-process-/);
  await rm(physical, { recursive: true, force: true });
}
