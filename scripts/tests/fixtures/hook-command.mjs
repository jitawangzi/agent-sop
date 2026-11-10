import { spawn } from 'node:child_process';

// 超时属于执行失败，随后只做有界收尾；未确认 close 时不宣称资源已释放。
export function runHookCommand(file, args, options = {}) {
  const { input = Buffer.alloc(0), timeoutMs = 25000, cleanupMs = 2000,
    launch = spawn, terminate = child => child.kill(), ...spawnOptions } = options;
  return new Promise((resolve, reject) => {
    let child, timer, cleanupTimer, failure, settled = false;
    const stdout = [], stderr = [];
    const decoder = new TextDecoder('utf-8', { fatal: true });
    function finish(confirmed, code) {
      if (settled) return;
      settled = true; clearTimeout(timer); clearTimeout(cleanupTimer);
      if (failure) {
        failure.cleanupConfirmed = confirmed; failure.pid = child?.pid;
        failure.terminationUnconfirmed = !confirmed;
        failure.stdout = Buffer.concat(stdout).toString('utf8');
        failure.stderr = Buffer.concat(stderr).toString('utf8');
        return reject(failure);
      }
      try { resolve({ code, stdout: decoder.decode(Buffer.concat(stdout)), stderr: decoder.decode(Buffer.concat(stderr)) }); }
      catch (error) { error.cleanupConfirmed = confirmed; reject(error); }
    }
    function stop(error) {
      if (settled || failure) return;
      failure = error;
      clearTimeout(timer);
      // 即使 kill 返回 false 或抛错，也等待 close；原故障不能被补救故障覆盖。
      cleanupTimer = setTimeout(() => finish(false), cleanupMs);
      try { terminate(child); } catch (cleanupError) { failure.cleanupDiagnostic = cleanupError.message; }
    }
    try { child = launch(file, args, { ...spawnOptions, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] }); }
    catch (error) { failure = error; finish(true); return; }
    timer = setTimeout(() => stop(new Error(`Hook process exceeded ${timeoutMs / 1000} seconds`)), timeoutMs);
    child.on('error', stop);
    child.stdin.on('error', stop);
    child.stdout.on('data', data => stdout.push(data));
    child.stderr.on('data', data => stderr.push(data));
    child.on('close', code => finish(true, code));
    try { child.stdin.end(input); } catch (error) { stop(error); }
  });
}
