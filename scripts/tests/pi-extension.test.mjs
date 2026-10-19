import assert from 'node:assert/strict';
import { mkdtemp, writeFile, copyFile, mkdir, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const temp = await mkdtemp(join(tmpdir(), 'pi-adapter-test-'));
const originalSession = process.env.AI_SESSION_ID;
try {
  await mkdir(join(temp, 'extensions'));
  await writeFile(join(temp, 'package.json'), '{"type":"module"}');
  const extension = join(temp, 'extensions', 'ai-sop.js');
  await copyFile(fileURLToPath(new URL('../../distribution/templates/hooks/pi-extension.js', import.meta.url)), extension);
  const wrapper = join(temp, 'hook-wrapper.ps1');
  await writeFile(wrapper, `param($EventHint,$AgentHint)
$p=[Console]::In.ReadToEnd()|ConvertFrom-Json
if($AgentHint -ne 'PI'){exit 3}
if($p.tool_name -eq 'invalid'){Write-Output 'not json';exit 0}
if($p.tool_name -eq 'crash'){exit 7}
if($p.tool_name -eq 'slow'){Start-Sleep -Seconds 10}
if($EventHint -eq 'PRE_TOOL_USE'){@{block=($p.tool_name -eq 'write');reason='test-deny'}|ConvertTo-Json -Compress}else{Write-Output '{}'}
`);
  const module = await import(pathToFileURL(extension));
  const handlers = new Map();
  module.default({ on: (event, handler) => handlers.set(event, handler) });
  const ctx = { cwd: temp, sessionManager: { getSessionId: () => 'pi-native-test' } };
  await handlers.get('session_start')({}, ctx);
  assert.equal(process.env.AI_SESSION_ID, 'pi-native-test');
  for (const [toolName, expected] of [['read', false], ['write', true], ['invalid', true], ['crash', true]]) {
    const result = await handlers.get('tool_call')({ toolName, input: {}, toolCallId: 'tool-1' }, ctx);
    assert.equal(result.block, expected, toolName);
  }
  await assert.rejects(module.runGuard(wrapper, 'PRE_TOOL_USE', { tool_name: 'slow' }, 100), /TIMEOUT/);
  await handlers.get('session_shutdown')({}, ctx);
  assert.equal(process.env.AI_SESSION_ID, originalSession);
  console.log('Pi extension: native event wiring, deny, invalid JSON, process error, timeout and environment restoration passed');
} finally {
  if (originalSession === undefined) delete process.env.AI_SESSION_ID;
  else process.env.AI_SESSION_ID = originalSession;
  // 递归清理前检查物理临时目录，避免路径被替换后删除其他位置。
  const physical = await realpath(temp);
  assert.equal(dirname(physical), await realpath(tmpdir()));
  assert.match(physical.split(/[\\/]/).at(-1), /^pi-adapter-test-/);
  await rm(physical, { recursive: true, force: true });
}
