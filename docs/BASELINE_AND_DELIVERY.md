# 大型项目起点与证据交付

T1/T2 Start 默认仍为 500ms、8MiB。项目可在 `.ai-workspace/context/start-inputs.json` 声明 `budgetMilliseconds`（1 至 60000 的整数）和 `maxBytes`（正整数），例如 `{"budgetMilliseconds":15000,"maxBytes":134217728}`。预算只用于新 Start，记录在 startInputs.budget；超限或配置无效记 UNAVAILABLE，不阻塞普通验证，不保存部分起点。预算检查是协作式检查，底层一次 IO 不承诺硬超时。所有实际选中的输入仍计算内容摘要；不会按时间戳复用或缩小源码范围。

显式 Start -CaptureBaseline 和 T3 保留完整采集语义。Resume/Run 不读取新预算补拍起点。修改此配置本身不改档，不新增完成门禁；已有任务与旧引擎记录不追溯改写。

测试可复用 `scripts/tests/fixtures/owned-process.ps1`：New 创建登记集合，Register 在启动后立即持有独立进程身份，Close 补救终止并回收输出资源。登记失败仍保留原始启动对象；成功项移除，失败项保留以便重试。只处理本次登记对象，不能根据裸 PID 推断归属。结合 retained-fixture 保存原始异常、清理结果及失败现场。旧类型升级测试和 owned-process 测试已接入；不批量重写无关测试。

从项目根运行：

```powershell
& ./.ai-sop/scripts/pack-review-evidence.ps1 -WorkspacePath . -Feature Example -TaskId change -OutputPath ./.ai-workspace/specs/features/Example/tasks/change/evidence/review-package
```

替换功能、任务标识及对应输出路径，输出目录须不存在。使用现有任务证据目录；不要输出到项目根的普通目录，否则材料会进入输入扫描，使刚通过的验证过期。不要通过排除真实源码解决此问题。入口从任务记录收集起点、各次执行的输入清单、日志和报告，以及 evidence.json；按内容摘要命名对象，避免保留原始长路径。index.json 保留来源映射、缺失项、审查导航和观察摘要比较，manifest.json 同时声明对象及索引。缺失或变化不会伪装成功，不修改任务、暂存文件或上传。包中可能包含原始日志和命令，提交前检查实际内容。补充材料内部附件不会递归抓取。

输出排空超时表示后代退出未确认，即使本地句柄的 Cleanup.confirmed 为真，共用测试清理仍保留登记和原始诊断。再次清理不能消除此未知结论；测试须独立回收有可信身份的探针，不按裸 PID 或程序名称终止未知进程。

使用已有 export-review.ps1 -DeliveryManifest 对包内 manifest.json 检查实际 Git 入库情况；未跟踪、忽略、字节变化仍是非阻断诊断。复制字节一致不代表报告语义正确、推送完成或资源已清理。原始记录仍是权威来源。

## 显式补充附件

需要一起交付全量测试、干净检出等补充报告时，添加可选 `-AttachmentsManifest <工作区相对清单路径>`。清单为 JSON 字符串数组，逐项列出工作区相对文件，例如 `[".ai-workspace/specs/features/Example/tasks/change/evidence/full/results.json"]`。在运行验证前后已有的原始报告仍是权威来源；清单只描述复制范围，不证明测试有效。

清单读取一次，按同一份字节解析和归档；相同来源去重，大小写保持区分。不接受绝对路径、上级越界、链接后代或无效JSON结构；不递归扫描目录或补充对象里的任意字段。缺失或不可读文件逐项记 UNAVAILABLE，其他材料继续输出。清单自身与附件纳入同一 index/manifest，可复用交付字节检查。输出仍使用本任务 evidence 目录；工具不自动暂存、提交或上传。

## 全量并行调度

交付字节检查按实际最近仓库固定HEAD，最多16条显式路径合批查询目录项；长路径缩小批次以限制参数长度。仅用已校验对象OID向Git批量读取原始内容，每批内容总量不超过64MiB，每个对象仍有原64MiB限制。按头部OID/类型/大小、准确字节数、分隔符和尾部逐项校验，整批完整解析后才发布Git摘要；截断批标为未知，保留本地事实并继续其他批。输入写入计入原10秒执行预算，输出排空与清理预算仍为2秒，不运行过滤器、不跨调用缓存，末尾仍检查HEAD漂移。优化减少Git进程启动，不减少材料或哈希读取。

`run-all-tests.ps1 -Parallel -MaxParallel 4 -DurationReport <已有results.json>` 使用既有 DurationMs 把耗时较长的套件提前排队。未记录的新套件仍执行，旧报告中的已删除套件不会重新执行；相同名称重复记录取最大时长。历史仅为调度提示，不作为验证证据，不复用PASS，不改变断言、并发上限或每套默认900秒超时。DurationMs 不接受布尔值；true/false 不能转为 1/0 毫秒。报告损坏或含无效时长时提示并恢复名称顺序；串行执行保持原顺序。

结果目录新增 schedule.json（实际队列、并发及超时）和 summary.json（总耗时、发现/执行/通过数），原 results.json 与逐套输出不变。跨版本或跨机器的历史时长只能作为提示；收益需在实际环境测量，不保证每次加速。native-harness-adapters 输出各适配器和两个Node阶段的耗时，便于后续准确定位重复准备成本；全部生命周期断言、20次性能样本及原阈值保持。

真实 Hook 测试的隔离运行目录只复制运行所需 scripts/schemas/config，排除 scripts/tests 源码。三个独立目录复制并发执行，任何复制失败均等待其余写入结束再抛原错误，避免与清理竞争；不增加测试子进程并发。HOOK_PROCESS_METRICS 输出准备、清理及 hook/task/其他命令调用次数和累计耗时。所有真实 pwsh 进程、断言、每个调用25秒及整套900秒预算保留；准备优化只减少复制/删除成本，不能解释为整个慢套件都会显著提速。衡量时分别报告准备阶段和全套耗时，注明单次观测与负载差异。
