import { cp } from 'node:fs/promises';
import { join } from 'node:path';

// 从source复制运行目录到destination；copy可注入故障替身。
// 仅重叠独立文件IO，等待全部写入结束后返回或抛首个复制错误，供调用者安全清理。
export async function copyRuntime(source, destination, copy = cp) {
  const results = await Promise.allSettled(['scripts', 'schemas', 'config'].map(dir =>
    copy(join(source, dir), join(destination, dir), {
      recursive: true, filter: path => path !== join(source, 'scripts', 'tests')
    })));
  const failure = results.find(result => result.status === 'rejected');
  if (failure) throw failure.reason;
}
