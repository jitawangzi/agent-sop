import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { boundedMap } from './fixtures/bounded-map.mjs';
import { runHookCommand } from './fixtures/hook-command.mjs';

const capacity = Number(process.env.AI_SOP_TEST_WORKERS || '1');
assert([1, 2].includes(capacity), 'Invalid reserved cleanup-test workers');
const children = new Set();
const launch = (...args) => {
  const child = spawn(...args); children.add(child);
  child.once('close', () => children.delete(child)); return child;
};
try {
  const normal = await runHookCommand(process.execPath, ['-e', "process.stdout.write('中文');process.stderr.write('diagnostic')"], { launch });
  assert.deepEqual(normal, { code: 0, stdout: '中文', stderr: 'diagnostic' });
  const failed = await runHookCommand(process.execPath, ['-e', 'process.exit(23)'], { launch });
  assert.equal(failed.code, 23);
  // 实际进程保持存活；故障后延迟执行 kill，验证 Promise 不会提前释放名额。
  for (const mode of ['timeout', 'stdin']) {
    let closed = false, stopRequested = false;
    const started = performance.now();
    await assert.rejects(runHookCommand(process.execPath, ['-e', 'setInterval(()=>{},1000)'], {
      launch: (...args) => {
        const child = launch(...args); child.once('close', () => { closed = true; });
        if (mode === 'stdin') child.once('spawn', () => child.stdin.destroy(new Error('injected stdin failure')));
        return child;
      },
      timeoutMs: mode === 'timeout' ? 30 : 25000, cleanupMs: 1000,
      terminate: child => { stopRequested = true; assert.equal(closed, false); setTimeout(() => child.kill(), 100); }
    }), error => {
      assert.match(error.message, mode === 'timeout' ? /exceeded/ : /stdin failure/);
      assert.equal(error.cleanupConfirmed, true); assert.equal(error.terminationUnconfirmed, false);
      assert.equal(closed, true); assert(stopRequested); assert(performance.now() - started >= 100); return true;
    });
  }
  // 补救失败不能抹掉原超时；保留未知身份供独立清理，不假装进程已退出。
  let unconfirmed;
  await assert.rejects(runHookCommand(process.execPath, ['-e', 'setInterval(()=>{},1000)'], {
    launch: (...args) => { unconfirmed = launch(...args); return unconfirmed; },
    timeoutMs: 30, cleanupMs: 50, terminate: () => { throw new Error('injected kill failure'); }
  }), error => {
    assert.match(error.message, /exceeded/); assert.match(error.cleanupDiagnostic, /kill failure/);
    assert.equal(error.cleanupConfirmed, false); assert.equal(error.terminationUnconfirmed, true);
    assert.equal(error.pid, unconfirmed.pid); assert.equal(unconfirmed.exitCode, null); return true;
  });
  const closed = once(unconfirmed, 'close'); unconfirmed.kill(); await closed;
  assert.equal(children.size, 0);
  // 真实进程终止未知时，不得继续派发剩余项；回归自身也遵守继承额度。
  let launched = 0;
  await assert.rejects(boundedMap(Array.from({ length: capacity + 1 }, (_, i) => i), capacity, () => runHookCommand(process.execPath, ['-e', 'setInterval(()=>{},1000)'], {
    launch: (...args) => { launched++; return launch(...args); },
    timeoutMs: 30, cleanupMs: 50, terminate: () => false
  })), error => error.terminationUnconfirmed === true);
  assert.equal(launched, capacity); assert.equal(children.size, capacity);
  await Promise.all([...children].map(async child => {
    const closed = once(child, 'close'); child.kill(); await closed;
  }));
  assert.equal(children.size, 0);
  console.log('HOOK_CLEANUP_WORKERS:' + capacity);
  console.log('PASS: real command success/failure, delayed timeout/stdin cleanup, unknown termination and independent recovery');
} finally {
  await Promise.all([...children].map(async child => {
    const closed = once(child, 'close'); child.kill(); await closed;
  }));
}
