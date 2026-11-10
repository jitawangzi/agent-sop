import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, access, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { copyRuntime } from './fixtures/runtime-copy.mjs';

const root = await mkdtemp(join(tmpdir(), 'sop-runtime-copy-'));
try {
  const source = join(root, 'source'), destination = join(root, 'destination');
  for (const dir of ['scripts/tests', 'schemas', 'config']) await mkdir(join(source, dir), { recursive: true });
  for (const path of ['scripts/runtime.ps1', 'schemas/schema.json', 'config/settings.json', 'scripts/tests/unused.ps1'])
    await writeFile(join(source, path), path);
  await copyRuntime(source, destination);
  for (const path of ['scripts/runtime.ps1', 'schemas/schema.json', 'config/settings.json'])
    assert.equal(await readFile(join(destination, path), 'utf8'), path);
  await assert.rejects(access(join(destination, 'scripts/tests')));
  const primary = new Error('copy failed');
  let completed = 0;
  await assert.rejects(copyRuntime(source, destination, async path => {
    if (path.endsWith('scripts')) throw primary;
    await new Promise(resolve => setTimeout(resolve, 30));
    completed++;
  }), error => error === primary);
  assert.equal(completed, 2, 'copy failure returned while other writers were active');
  console.log('PASS: runtime copy preserves required files, excludes tests, waits for failed preparation writers');
} finally {
  await rm(root, { recursive: true, force: true });
}
