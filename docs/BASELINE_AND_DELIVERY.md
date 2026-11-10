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
