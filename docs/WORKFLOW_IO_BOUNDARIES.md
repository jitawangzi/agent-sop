# 工作流并发 IO 与时间预算

工作流锁以独占句柄表示占用，所有平台释放时仅关闭句柄，保留空 `.lock` 哨兵；文件存在不表示仍被占用。Windows 释放后删除与其他进程重新打开交错，会产生 UnauthorizedAccessException / 0x80070005。授权索引和 Hook 关联锁同样保留哨兵，过期 JSON 仍按原规则清理。仅可在对应注册表所有使用者停止后离线清理空哨兵，运行中不按年龄删除。

权威记录、镜像与共享清单读者通过 `Read-AiSopWorkflowText` 使用 Read/Delete 共享句柄。允许发布后旧读者读完完整旧版本，但不允许与原地写入流同时读取。可变状态仍由原有事务锁协调；所有归属镜像写入口还共用镜像锁，涵盖 legacy 完成和恢复路径。读取不要求创建额外锁或取得目录写权限。

写者先写并关闭同目录临时文件，再单步发布。Windows 使用 `SetFileInformationByHandle(FileRenameInfoEx)`，仅设置 REPLACE_IF_EXISTS 和 POSIX_SEMANTICS；Unix 使用 `File.Move(overwrite)` 的原生重命名。旧句柄继续指向旧版本，新打开的句柄指向完整新版，不先删除目标。Windows 实现处理 UTF-16 终止符、32/64 位布局和扩展长路径。不支持该接口/语义的系统或文件系统直接报告原生错误，不降级为有名称缺口的 Replace/delete+move，不吞权限拒绝。Windows 本机 NTFS 已运行验收；Linux/macOS、UNC/其他文件系统及32位运行时未在本轮执行。

该方案沿用原 Move 的替换契约，不承诺保留被替换目标的 DACL、附加流等 File.Replace 特有元数据；新文件继承同目录临时文件的属性。没有设置忽略只读或ACL的标志。发布失败保留原目标和候选临时文件，报错并输出路径；临时文件不代表权威状态。原事务日志继续负责提交/回滚恢复。[Windows重命名语义](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/4217551b-d2c0-42cb-9dc1-69a716cf6d0c)。

`workflow-state.ps1` 在依赖加载及验证上下文初始化之后开始操作期限。默认预算、环境变量覆盖和后续绝对截止检查不变；首次类型编译不再提前消耗操作预算。外层进程超时仍覆盖整个启动及运行生命周期。

`scripts/tests/workflow-concurrency-boundaries.tests.ps1` 使用独立临时目录和注册表，启动并回收自己的 PowerShell 子进程，不连接业务存储。覆盖默认锁互斥、崩溃释放、Windows只读属性拒绝、并发复用、旧句柄跨多次发布、连续名称可见性与完整读取、精确目标和无异常文件名、并发首次创建、中文长路径、冷启动/真实入口过期、正式读取函数开流后暂停时的真实runner启动。夹具和诊断保留。压力验证不证明所有调度均已枚举；属性拒绝不是DACL切换验收。

状态入口过期反例仅在一次性副本替换截止时间构造，读取屏障仅在正式函数打开流后暂停；不能把注入和真实OS故障混为一谈。没有原始底层诊断的历史事故不能逐次还原，历史事实、受控反例和最终回归分别记录。