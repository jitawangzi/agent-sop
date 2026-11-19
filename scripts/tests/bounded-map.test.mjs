import assert from 'node:assert/strict';
import { boundedMap } from './fixtures/bounded-map.mjs';
for (const capacity of [1, 2, 3, 4]) {
  let active = 0, peak = 0;
  const seen = [];
  const inputs = [0, 1, 2, 3, 4, 5];
  const values = await boundedMap(inputs, capacity, async value => {
    peak = Math.max(peak, ++active);
    await new Promise(resolve => setTimeout(resolve, 10));
    seen.push(value); active--; return value * 2;
  });
  assert.equal(active, 0); assert.equal(peak, capacity);
  assert.deepEqual(values, [0, 2, 4, 6, 8, 10]); assert.equal(seen.length, inputs.length);
  const finished = [];
  const failureInputs = Array.from({ length: capacity + 1 }, (_, index) => index);
  await assert.rejects(boundedMap(failureInputs, capacity, async value => {
    await new Promise(resolve => setTimeout(resolve, value === 0 ? 1 : 25));
    finished.push(value); if (value === 0) throw new Error('expected failure');
  }), /expected failure/);
  assert.deepEqual(finished.sort((a, b) => a - b), Array.from({length: capacity}, (_, index) => index), 'Failure started queued work or returned before peers settled');
}
for (const invalid of [0, 5, NaN]) await assert.rejects(boundedMap([], invalid, () => {}), /budget/);
console.log('PASS: bounded real-call scheduling, serial budget, complete coverage and failure drain');
