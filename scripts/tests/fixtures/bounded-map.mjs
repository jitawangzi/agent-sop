// 等待所有已启动调用结束后才抛错，避免夹具先被清理；不复用业务进程或权限状态。
export async function boundedMap(items, capacity, action) {
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 2) throw new Error('Invalid worker budget');
  let next = 0, failed = false;
  const results = new Array(items.length);
  await Promise.all(Array.from({ length: Math.min(capacity, items.length) }, async () => {
    while (!failed && next < items.length) {
      const index = next++;
      try { results[index] = { value: await action(items[index], index) }; }
      catch (error) { failed = true; results[index] = { error }; }
    }
  }));
  const failure = results.find(result => result && Object.hasOwn(result, 'error'));
  if (failure) throw failure.error;
  return results.map(result => result.value);
}
