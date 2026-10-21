import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, cp, copyFile, writeFile, readFile, readdir, rm, realpath } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
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
async function task(op, agent = 'CURSOR', nativeSession = session, extra = []) {
  const args = ['-NoProfile', '-File', join(workspace, '.ai-sop/scripts/workflow-task.ps1'), '-Operation', op,
    '-WorkspacePath', workspace, '-Feature', 'Probe', '-TaskId', `${agent.toLowerCase()}-process-test`, '-Agent', agent, '-NativeSessionId', nativeSession];
  if (op === 'Start') args.push('-Objective', '真实进程验收');
  if (op === 'Start' && agent === 'CURSOR') args.push('-Tier', 'T3', '-UserRequest', '父任务按 T3 验证子会话只读隔离');
  args.push(...extra);
  const quote = x => "'" + x.replaceAll("'", "''") + "'";
  const parts = args.slice(2).map(x => x.startsWith('-') ? x : quote(x));
  const argumentIndex = args.slice(2).indexOf('-Arguments');
  if (argumentIndex >= 0) parts.splice(argumentIndex, 4, '-Arguments', "@('-NoProfile','-Command','exit 0')");
  const command = "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); try { & " + parts.join(' ') + '; exit $LASTEXITCODE } catch { [Console]::Error.WriteLine($_.ToString() + [Environment]::NewLine + $_.ScriptStackTrace); exit 1 }';
  const r = await run(['-NoProfile', '-Command', command]); assert.equal(r.code, 0, r.stdout + r.stderr);
}
// 只比较权限及任务的持久记录，关联/去重缓存不代表授权。
async function authoritySnapshot() {
  const records = {};
  async function visit(dir) {
    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); }
    catch (e) { if (e.code === 'ENOENT') return; throw e; }
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) await visit(path);
      else records[path] = (await readFile(path)).toString('base64');
    }
  }
  for (const kind of ['OWNER', 'SESSION', 'COMMAND_GRANT', 'TRANSACTION']) await visit(env[`AI_SOP_${kind}_REGISTRY`]);
  await visit(join(workspace, '.ai-workspace/specs'));
  return records;
}
try {
  await mkdir(workspace);
  await copyFile(join(source, 'distribution/templates/root/ai-sop.ps1'), join(workspace, 'ai-sop.ps1'));
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
  // 新版原生读取不登记或恢复会话；实际暂停任务后仍只读，不借任务获取写权限。
  const agReadSession = 'ag-readonly-native';
  const agTool = (name, args) => ({ conversationId: agReadSession, workspacePaths: [workspace],
    stepIdx: ++counter, toolCall: { name, args } });
  const readInputs = [{ Path: file }, { Path: file, StartLine: 1, EndLine: 20, ByteOffset: 0 }, { path: file, offset: 0 }];
  const listCommand = process.platform === 'win32' ? 'Get-ChildItem src -File' : 'rg --files src';
  const appData = join(await realpath(homedir()), '.gemini/antigravity');
  for (const phase of ['unregistered', 'paused']) {
    if (phase === 'paused') {
      await task('Start', 'ANTIGRAVITY', agReadSession);
      await task('Suspend', 'ANTIGRAVITY', agReadSession);
    }
    const beforeRead = await authoritySnapshot();
    for (const action of ['Verify','Doctor','Status -Feature Probe -Json','Inputs -ExplainOnly -InputPath src -Json','Preflight -Feature Probe -Json','Help']) {
      const payload=agTool('run_command',{CommandLine:`pwsh -NoProfile -File ./ai-sop.ps1 ${action}`,IsDaemon:false});
      for (let replay=0;replay<2;replay++) {
        const result=await hook('.agents','PRE_TOOL_USE',payload);
        assert.equal(result.value.decision,'allow',JSON.stringify(result));
        assert.equal(result.value.overwrite.Cwd,workspace);
        assert.equal(result.value.permissionOverrides,undefined);
      }
    }
    for (const args of readInputs) {
      const result = await hook('.agents', 'PRE_TOOL_USE', agTool('read_file', args), true);
      assert.equal(result.code, 0, JSON.stringify(result));
      assert.equal(result.value.decision, 'allow', JSON.stringify(result));
    }
    for (const path of [join(appData, 'builtin/skills/probe/SKILL.md'), join(appData, 'brain', agReadSession, 'upload.png')]) {
      assert.equal((await hook('.agents', 'PRE_TOOL_USE', agTool('read_file', { Path: path }))).value.decision, 'allow');
    }
    const shellPayload = agTool('run_command', { CommandLine: listCommand, WaitMsBeforeAsync: 1000, toolSummary: '列目录', IsDaemon: false });
    for (let replay = 0; replay < 2; replay++) {
      const result = await hook('.agents', 'PRE_TOOL_USE', shellPayload);
      assert.equal(result.value.decision, 'allow', JSON.stringify(result));
      assert.equal(result.value.overwrite.Cwd, workspace);
      assert.equal(result.value.overwrite.IsDaemon, false);
      assert.equal(result.value.permissionOverrides, undefined);
      assert.equal(result.value.hookSpecificOutput, undefined);
      assert.match(result.value.overwrite.CommandLine, /Microsoft.PowerShell.Management\\Get-ChildItem|rg --no-config/);
      const executed = await run(['-NoProfile', '-Command', '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); ' + result.value.overwrite.CommandLine]);
      assert.equal(executed.code, 0, executed.stderr);
      assert.match(executed.stdout, /中文.txt/);
    }
    for (const command of ['rg -n BEFORE src', 'git -C .ai-workspace status --short', 'git remote -v', 'git branch --show-current']) {
      const result = await hook('.agents', 'PRE_TOOL_USE', agTool('run_command', { CommandLine: command, Cwd: workspace, WaitMsBeforeAsync: 1000 }));
      assert.equal(result.value.decision, 'allow', JSON.stringify(result));
      assert.match(result.value.overwrite.CommandLine, /--no-config|--no-optional-locks/);
    }
    assert.deepEqual(await authoritySnapshot(), beforeRead, `${phase} 读取不能登记、续租、恢复或接管权限`);
  }
  for (const args of [
    { Path: file, StartLine: '1' }, { Path: file, EndLine: null }, { Path: file, ByteOffset: false },
    { Path: file, path: file }, { Path: file, ByteOffset: 0, offset: 0 },
    { Path: file, command: 'unexpected' }, { Path: join(root, 'outside.txt') }
  ]) assert.equal((await hook('.agents', 'PRE_TOOL_USE', agTool('read_file', args))).value.decision, 'deny');
  assert.equal((await hook('.agents', 'PRE_TOOL_USE', agTool('write_to_file', { TargetFile: file, CodeContent: 'UNAUTHORIZED', Overwrite: true }))).value.decision, 'deny');
  assert.equal((await hook('.agents', 'PRE_TOOL_USE', agTool('future_read_file', { Path: file }))).value.decision, 'deny');
  for (const args of [
    { CommandLine: 'git status', IsDaemon: true }, { CommandLine: 'git status', RunPersistent: true },
    { CommandLine: 'git status', RequestedTerminalID: 'existing' }, { CommandLine: 'git status', Cwd: root },
    { CommandLine: listCommand, command: 'echo BAD' }, { CommandLine: 'git remote set-url origin invalid' },
    { CommandLine: 'git branch new-branch' }, { CommandLine: 'git status; git reset --hard' }
    ,{ CommandLine: 'pwsh -NoProfile -File ./ai-sop.ps1 Verify -Operation Start' }
    ,{ CommandLine: 'pwsh -NoProfile -File ./ai-sop.ps1 Install' }
    ,{ CommandLine: 'pwsh -NoProfile -File ./ai-sop.ps1 Inputs -InputPath ../outside' }
  ]) assert.equal((await hook('.agents', 'PRE_TOOL_USE', agTool('run_command', args))).value.decision, 'deny');
  for (const path of [join(appData, 'brain/other-session/upload.png'), join(appData, 'credentials.json')]) {
    assert.equal((await hook('.agents', 'PRE_TOOL_USE', agTool('read_file', { Path: path }))).value.decision, 'deny');
  }
  const bootstrapCommand = "pwsh -NoProfile -File './.ai-sop/scripts/workflow-task.ps1' -Operation Start -Feature Probe -TaskId process-test -Agent CURSOR -NativeSessionId '" + visibleSession + "' -Objective '真实进程验收'";
  const bootstrap = await hook('.cursor', 'PRE_TOOL_USE', cursor('Shell', { command: bootstrapCommand, cwd: '', timeout: 30000 }, { cwd: '' }));
  assert.equal(bootstrap.value.permission, 'allow', JSON.stringify(bootstrap));
  await task('Start');
  const active = await hook('.cursor', 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: '修改' }));
  assert.equal(active.value.permission, 'allow', JSON.stringify(active));
  // Cursor 子 Agent 的外层模型为空；两条实际加载的 Hook 都必须接受合法载荷。
  const reviewInput = { description: 'Review design', prompt: '独立审查，不修改文件', model: 'review-model', subagent_type: 'design-reviewer' };
  for (const adapter of ['.cursor', '.claude']) {
    const review = await hook(adapter, 'PRE_TOOL_USE', cursor('Task', reviewInput, { model: '' }));
    assert.equal(review.value.permission, 'allow', JSON.stringify(review));
    const invalid = await hook(adapter, 'PRE_TOOL_USE', cursor('Task', reviewInput, { model: 42 }));
    assert.equal(invalid.value.permission, 'deny', JSON.stringify(invalid));
    assert.match(invalid.value.agent_message, /PAYLOAD_SHAPE_INVALID/);
  }
  // 真实子会话没有 sessionStart：读取不能登记、接管、续租或改动父 T3。
  const childId = 'review-child-without-lifecycle';
  const child = (name, input, extra = {}) => cursor(name, input, { conversation_id: childId, session_id: childId, ...extra });
  const contract = join(workspace, '.ai-workspace/specs/features/Probe/06_design_contract.md');
  await writeFile(contract, '审查夹具');
  const parentBefore = await authoritySnapshot();
  for (const adapter of ['.cursor', '.claude']) {
    for (const [name, input] of [
      ['Read', { file_path: contract }],
      ['Grep', { pattern: '审查', file_path: contract }],
      ['Glob', { glob_pattern: '**/*.md', target_directory: workspace }]
    ]) {
      const result = await hook(adapter, 'PRE_TOOL_USE', child(name, input));
      assert.equal(result.value.permission, 'allow', JSON.stringify(result));
    }
    for (const [name, input, extra] of [
      ['Read', { file_path: join(root, 'outside.txt') }],
      ['Read', { file_path: join(workspace, '..', 'outside.txt') }],
      ['Read', { file_path: contract }, { session_id: 'mismatched-child' }]
    ]) assert.equal((await hook(adapter, 'PRE_TOOL_USE', child(name, input, extra))).value.permission, 'deny');
  }
  assert.deepEqual(await authoritySnapshot(), parentBefore, '子会话读取或路径拒绝不应改动权限和父任务');
  for (const [name, input] of [
    ['Read', { file_path: contract, command: 'unrecognized' }],
    ['Write', { file_path: file, content: 'UNAUTHORIZED' }],
    ['Shell', { command: "Set-Content 'src/中文.txt' 'UNAUTHORIZED'" }],
    ['Task', reviewInput]
  ]) assert.equal((await hook('.cursor', 'PRE_TOOL_USE', child(name, input))).value.permission, 'deny');
  const pendingBefore = await authoritySnapshot();
  for (const [path, bytes] of Object.entries(parentBefore)) assert.equal(pendingBefore[path], bytes, `子会话拒绝写入不得改动父记录: ${path}`);
  assert(Object.keys(pendingBefore).length > Object.keys(parentBefore).length, '写入拒绝应建立子会话 PENDING，供只读兼容测试');
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', child('Read', { file_path: contract }))).value.permission, 'allow');
  assert.deepEqual(await authoritySnapshot(), pendingBefore, 'PENDING 子会话读取不得变更权限');
  // 父任务暂停后仍可审查，但不得恢复父任务或获得写权限。
  await task('Suspend');
  const suspendedBefore = await authoritySnapshot();
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', child('Read', { file_path: contract }))).value.permission, 'allow');
  assert.deepEqual(await authoritySnapshot(), suspendedBefore);
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', child('Write', { file_path: file, content: 'UNAUTHORIZED' }))).value.permission, 'deny');
  for (const adapter of ['.cursor', '.claude']) {
    const review = await hook(adapter, 'PRE_TOOL_USE', cursor('Task', reviewInput, { model: '' }));
    assert.equal(review.value.permission, 'deny', JSON.stringify(review));
    assert.doesNotMatch(review.value.agent_message, /PAYLOAD_SHAPE_INVALID/);
  }
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: '修改' }))).value.permission, 'deny');
  await task('Resume');
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: '修改' }))).value.permission, 'allow');
  // 显式实现委派：使用真实 Hook 进程，不用父会话标识冒充子会话。
  const implementer = 'implementation-child';
  const imp = (name, input) => cursor(name, input, { session_id: implementer, conversation_id: implementer });
  const entryPath = join(workspace, '.ai-sop/scripts/workflow-task.ps1');
  const joinCommand = `pwsh -NoProfile -File '${entryPath}' -Operation Join -Feature Probe -TaskId cursor-process-test -Agent CURSOR -NativeSessionId '${implementer}'`;
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', imp('Shell', { command: joinCommand }))).value.permission, 'allow');
  await task('Join', 'CURSOR', implementer);
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', imp('Write', { file_path: file, content: 'NO' }))).value.permission, 'deny');
  const ownerFile = join(env.AI_SOP_OWNER_REGISTRY, 'probe.json');
  const bindingBefore = JSON.parse(await readFile(ownerFile, 'utf8')).sessionBinding;
  const delegateCommand = `pwsh -NoProfile -File '${entryPath}' -Operation Delegate -Feature Probe -TaskId cursor-process-test -Agent CURSOR -NativeSessionId '${session}' -ChildNativeSessionId '${implementer}' -Reason 'implementation'`;
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', cursor('Shell', { command: delegateCommand }))).value.permission, 'allow');
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', imp('Shell', { command: delegateCommand }))).value.permission, 'deny');
  await task('Delegate', 'CURSOR', session, ['-ChildNativeSessionId', implementer, '-Reason', 'implementation']);
  assert.deepEqual(JSON.parse(await readFile(ownerFile, 'utf8')).sessionBinding, bindingBefore);
  for (const adapter of ['.cursor', '.claude']) {
    assert.equal((await hook(adapter, 'PRE_TOOL_USE', imp('Write', { file_path: file, content: 'AUTHORIZED' }))).value.permission, 'allow');
    assert.equal((await hook(adapter, 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: 'NO' }))).value.permission, 'deny');
    assert.equal((await hook(adapter, 'PRE_TOOL_USE', cursor('Task', reviewInput))).value.permission, 'allow');
    assert.equal((await hook(adapter, 'PRE_TOOL_USE', imp('Task', reviewInput))).value.permission, 'deny');
  }
  const shellWrite = await hook('.cursor', 'PRE_TOOL_USE', imp('Shell', { command: "Set-Content -LiteralPath 'src/中文.txt' -Value 'AUTHORIZED' -NoNewline" }));
  assert.equal(shellWrite.value.permission, 'allow');
  const actualWrite = await run(['-NoProfile', '-Command', "Set-Content -LiteralPath 'src/中文.txt' -Value 'AUTHORIZED' -NoNewline"]);
  assert.equal(actualWrite.code, 0); assert.equal(await readFile(file, 'utf8'), 'AUTHORIZED');
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', imp('Write', { file_path: join(root, 'outside.txt'), content: 'NO' }))).value.permission, 'deny');
  await task('Run', 'CURSOR', implementer, ['-Kind', 'compile', '-Executable', 'pwsh', '-Arguments', '-NoProfile', '-Command', 'exit 0', '-TimeoutSeconds', '20']);
  const execution = JSON.parse(await readFile(join(workspace, '.ai-workspace/specs/features/Probe/tasks/cursor-process-test/task.json'), 'utf8')).verifications.at(-1);
  assert.equal(execution.outcome, 'PASSED'); assert.ok(execution.context.delegationId);
  assert.deepEqual(JSON.parse(await readFile(ownerFile, 'utf8')).sessionBinding, bindingBefore);
  await task('RevokeDelegation', 'CURSOR', session, ['-Reason', 'implementation finished']);
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', imp('Write', { file_path: file, content: 'NO' }))).value.permission, 'deny');
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: 'BEFORE' }))).value.permission, 'allow');
  await writeFile(file, 'BEFORE');
  await task('Cancel');
  assert.equal((await hook('.cursor', 'PRE_TOOL_USE', cursor('Write', { file_path: file, content: '修改' }))).value.permission, 'deny');
  const piSession = 'pi-process-fixture';
  // Claude 实际子 Agent 载荷共用 session_id，用 agent_id 区分执行者。
  const claudeParent = 'claude-native-parent';
  const claude = (name, input, agentId) => ({ session_id: claudeParent, cwd: workspace,
    hook_event_name: 'PreToolUse', tool_name: name, tool_input: input, tool_use_id: `claude-${++counter}`,
    ...(agentId ? {agent_id: agentId, agent_type: 'implementation-engine'} : {}) });
  const chook = payload => hook('.claude', 'PRE_TOOL_USE', payload);
  await hook('.claude', 'SESSION_START', {session_id: claudeParent, cwd: workspace, hook_event_name: 'SessionStart', source: 'startup'});
  await task('Start', 'CLAUDE_CODE', claudeParent);
  const cedit = id => claude('Edit', {file_path:file,old_string:'BEFORE',new_string:'CHILD_OK'}, id);
  assert.equal((await chook(cedit())).value.hookSpecificOutput.permissionDecision, 'allow');
  const childDeny = (await chook(cedit('agent-one'))).value.hookSpecificOutput;
  assert.equal(childDeny.permissionDecision, 'deny');
  const childIdentity = /-Agent CLAUDE_CODE -NativeSessionId '([^']+)'/.exec(childDeny.permissionDecisionReason)?.[1];
  assert.match(childIdentity, /^claude-child:[a-f0-9]{64}$/);
  assert.notEqual(childIdentity, claudeParent);
  const forgedJoin = `pwsh -NoProfile -File ./.ai-sop/scripts/workflow-task.ps1 -WorkspacePath '${workspace.replaceAll("'", "''")}' -Operation Join -Feature Probe -TaskId claude_code-process-test -Agent CLAUDE_CODE -NativeSessionId '${claudeParent}'`;
  assert.equal((await chook(claude('Bash', {command:forgedJoin}, 'agent-one'))).value.hookSpecificOutput.permissionDecision, 'deny');
  const realJoin = forgedJoin.replace(claudeParent,childIdentity);
  assert.equal((await chook(claude('Bash', {command:realJoin}, 'agent-one'))).value.hookSpecificOutput.permissionDecision, 'allow');
  await task('Join', 'CLAUDE_CODE', childIdentity);
  await task('Delegate', 'CLAUDE_CODE', claudeParent, ['-ChildNativeSessionId',childIdentity,'-Reason','真实 Claude 子身份']);
  assert.equal((await chook(cedit('agent-one'))).value.hookSpecificOutput.permissionDecision, 'allow');
  assert.equal((await chook(cedit('agent-two'))).value.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal((await chook(cedit())).value.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal((await chook(claude('SendMessage',{to:'agent-one',message:'continue'}))).value.hookSpecificOutput.permissionDecision, 'allow');
  assert.equal((await chook(claude('SendMessage',{to:'agent-two',message:'continue'},'agent-one'))).value.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal((await chook(claude('Read',{file_path:file},'agent-one'))).value.hookSpecificOutput.permissionDecision, 'allow');
  assert.equal((await chook(claude('Write',{file_path:join(root,'outside.txt'),content:'NO'},'agent-one'))).value.hookSpecificOutput.permissionDecision, 'deny');
  await task('Run','CLAUDE_CODE',childIdentity,['-Kind','compile','-Executable','pwsh','-Arguments','-NoProfile','-Command','exit 0','-TimeoutSeconds','20']);
  await task('RevokeDelegation','CLAUDE_CODE',claudeParent,['-Reason','结束']);
  assert.equal((await chook(cedit('agent-one'))).value.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal((await chook(cedit())).value.hookSpecificOutput.permissionDecision, 'allow');
  await task('Cancel','CLAUDE_CODE',claudeParent);
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
  for (const name of ['collaborationspawn_agent','collaborationsend_message','collaborationfollowup_task','collaborationwait_agent','collaborationlist_agents']) {
    assert.equal((await codexHook(codexPayload(name,{message:'fixture'}))).value.hookSpecificOutput.permissionDecision, 'allow', name);
  }
  assert.equal((await codexHook(codexPayload('collaborationunknown_tool',{}))).value.hookSpecificOutput.permissionDecision,'deny');
  const codexChild='codex-native-child';
  const cxchild = (name,input,id=codexChild) => ({...codexPayload(name,input),agent_id:id,agent_type:'default'});
  const cxdeny=(await codexHook({...patch(),agent_id:codexChild,agent_type:'default'})).value.hookSpecificOutput;
  assert.equal(cxdeny.permissionDecision,'deny');
  assert.match(cxdeny.permissionDecisionReason,new RegExp(`-Agent CODEX -NativeSessionId '${codexChild}'`));
  const cxjoin=`pwsh -NoProfile -File ./.ai-sop/scripts/workflow-task.ps1 -WorkspacePath '${workspace.replaceAll("'", "''")}' -Operation Join -Feature Probe -TaskId codex-process-test -Agent CODEX -NativeSessionId '${codexChild}'`;
  assert.equal((await codexHook(cxchild('Bash',{command:cxjoin}))).value.hookSpecificOutput.permissionDecision,'allow');
  await task('Join','CODEX',codexChild);
  await task('Delegate','CODEX',codexSession,['-ChildNativeSessionId',codexChild,'-Reason','原生 Codex 子线程']);
  assert.equal((await codexHook({...patch(),agent_id:codexChild})).value.hookSpecificOutput.permissionDecision,'allow');
  assert.equal((await codexHook({...patch(),agent_id:'another-child'})).value.hookSpecificOutput.permissionDecision,'deny');
  assert.equal((await codexHook(patch())).value.hookSpecificOutput.permissionDecision,'deny');
  assert.equal((await codexHook(cxchild('collaborationspawn_agent',{message:'no'}))).value.hookSpecificOutput.permissionDecision,'deny');
  assert.equal((await codexHook(codexPayload('collaborationfollowup_task',{message:'continue'}))).value.hookSpecificOutput.permissionDecision,'allow');
  await task('Run','CODEX',codexChild,['-Kind','compile','-Executable','pwsh','-Arguments','-NoProfile','-Command','exit 0','-TimeoutSeconds','20']);
  await task('RevokeDelegation','CODEX',codexSession,['-Reason','结束']);
  assert.equal((await codexHook({...patch(),agent_id:codexChild})).value.hookSpecificOutput.permissionDecision,'deny');
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
  console.log('PASS: real wrapper processes, UTF-8/BOM/Chinese, Cursor T3 parent/child readonly isolation and path rejection, Pi/Codex task lifecycle, safe readonly command replay and write rejection');
} finally {
  const physical = await realpath(root);
  assert.equal(dirname(physical), await realpath(tmpdir()));
  assert.match(physical.split(/[\\/]/).at(-1), /^sop-hook-process-/);
  await rm(physical, { recursive: true, force: true });
}
