import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { boundedMap } from './fixtures/bounded-map.mjs';
import { runHookCommand } from './fixtures/hook-command.mjs';

const workers = Number(process.env.AI_SOP_TEST_WORKERS || '1');
assert([1, 2].includes(workers), 'Invalid reserved worker count');
const groups = workers === 2 ? ['cursor', 'other'] : ['all'];
const script = fileURLToPath(new URL('./hook-process.test.mjs', import.meta.url));
await boundedMap(groups, workers, async group => {
  try {
    const result = await runHookCommand(process.execPath, [script, group], {
      env: { ...process.env, AI_SOP_TEST_WORKERS: '1' }, timeoutMs: 900000
    });
    process.stdout.write(result.stdout); process.stderr.write(result.stderr);
    assert.equal(result.code, 0, `Hook group ${group} failed`);
  } catch (error) {
    if (error.stdout) process.stdout.write(error.stdout);
    if (error.stderr) process.stderr.write(error.stderr);
    if (error.terminationUnconfirmed) console.error('HOOK_GROUP_TERMINATION_UNCONFIRMED:' + JSON.stringify({ group, pid: error.pid }));
    throw error;
  }
});
console.log('HOOK_GROUPS_COMPLETE:' + JSON.stringify({ groups, workers }));
