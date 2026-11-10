import assert from 'node:assert/strict';
import { boundedMap } from './fixtures/bounded-map.mjs';
for (const capacity of [1, 2]) {
  let active = 0, peak = 0;
  const seen = [];
  const values = await boundedMap([0, 1, 2, 3], capacity, async value => {
    peak = Math.max(peak, ++active);
    await new Promise(resolve => setTimeout(resolve, 5));
    seen.push(value); active--; return value * 2;
  });
  assert.equal(active, 0); assert.equal(peak, capacity);
  assert.deepEqual(values, [0, 2, 4, 6]); assert.equal(seen.length, 4);
  const finished = [];
  await assert.rejects(boundedMap([0, 1, 2], capacity, async value => {
    await new Promise(resolve => setTimeout(resolve, value === 0 ? 1 : 20));
    finished.push(value); if (value === 0) throw new Error('expected failure');
  }), /expected failure/);
  assert.deepEqual(finished.sort(), Array.from({length: capacity}, (_, index) => index), 'Failure started queued work or returned before peers settled');
}
for (const invalid of [0, 3, NaN]) await assert.rejects(boundedMap([], invalid, () => {}), /budget/);
console.log('PASS: bounded real-call scheduling, serial budget, complete coverage and failure drain');
