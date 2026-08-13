# 视觉检测系统行为规约

## 1. 文档目的

本文定义视觉检测系统的跨组件行为，包括：

- 外部用例与应用命令；
- 状态转换；
- 组件间消息；
- 资源持有与释放；
- 并发、超时与事件裁决；
- 错误和结果语义；
- 系统级不变量。

本文不限定线程、通道、锁、智能指针或序列化格式等实现细节。文档术语、规范用语和默认行为见 [文档通用约定](../README.md#通用约定)。组件划分见 [Architecture.md](./Architecture.md)，版本边界见 [Scope.md](./Scope.md)。

## 2. 设计方法与基础约束

### 2.1 规约组织方式

本文按以下顺序定义行为：

1. 以用例和应用命令描述端到端行为；
2. 以状态机约束命令和异步事件；
3. 以消息规约明确组件边界；
4. 以资源生命周期明确所有权；
5. 以并发裁决和不变量检查完整性。

每个命令必须定义以下内容：

- 触发方与接收方；
- 前置状态与输入；
- 处理过程；
- 成功与失败结果；
- 状态转换；
- 完成边界；
- 异步后续；
- 资源变化；
- 与并发命令或异步事件的关系。

### 2.2 状态所有权

- App Controller 是 `AppState` 的唯一所有者；
- 所有模式相关命令由 App Controller 串行处理；
- 命令是否合法，以 App Controller 处理该命令时的当前状态为准；
- GUI、Scheme Manager 和 Inspection Actor 不持有或自行转换 `AppState`；
- Inspection Actor 不通过共享状态推断当前应用模式。

### 2.3 标识

- 每次进入 EditMode 或 ProductionMode，App Controller 生成新的 `ModeSessionId`；
- `ModeSessionId` 随检查申请、检查元数据和异步检查事件传递，并用于返回 Home 时限定会话级取消；
- `inspection_id` 由 Inspection Actor 接受检查申请时生成；
- `frame_id` 由 Camera Actor 生成，且在应用运行期间唯一。

## 3. 用例与命令规约

详细规约见 [Contract/UseCases.md](./Contract/UseCases.md)。

v1 用例包括：

1. 启动应用；
2. 进入编辑模式；
3. 进入生产模式；
4. 返回主页；
5. 修改配置草稿；
6. 校验配置草稿；
7. 保存配置草稿；
8. 发起测试检查；
9. 发起生产检查；
10. 优雅关机。

模式不匹配不是独立用例，而是所有模式相关命令的公共拒绝分支；Home 中的返回主页命令除外，它幂等成功。

## 4. 状态机规约

详细规约见 [Contract/StateMachines.md](./Contract/StateMachines.md)。

该子文档定义：

- 独立于 AppState 的 ApplicationLifecycle；
- AppState 模式转换；
- Inspection Actor 状态机；
- Camera Actor 生命周期；
- 优雅关机期间的状态转换和取消等待。

## 5. 消息规约

详细规约见 [Contract/Messages.md](./Contract/Messages.md)。

该子文档定义：

- App Controller 命令及各命令的成功和业务失败响应；
- 检查申请、Worker 任务与终止输出；
- 返回 Home 的会话级取消和关机取消等待；
- Inspection Actor 领域事件、计时器消息和组件关闭消息；
- 请求响应关联、投递顺序、资源所有权和最新值投影语义。

Scheme Manager 的配置读取、校验、方案构建和保存属于同步组件调用，不属于消息规约。

关键约束：

- `inspection_id` 由 Inspection Actor 维护，用于具体任务、Worker 输出和计时器关联；
- App Controller 不在 AppState 中维护活动 `inspection_id`，也不把申请响应或状态投影当作 Inspection Actor 运行状态的第二可信来源；
- 返回 Home 时按被关闭的 `ModeSessionId` 请求取消当前属于该会话的任务，不等待取消完成；
- 优雅关机使用 `CancelCurrentForShutdown` 等待 Inspection Actor 实际回到 `Idle`；
- 模式领域事件受 ApplicationLifecycle、AppState 和 `ModeSessionId` 过滤，控制响应和关闭确认不受该过滤；
- `InspectionTimedOut` 不携带 Frame 或 InspectionPresentation，不替换最近一次展示对象。

## 6. 资源生命周期规约

详细规约见 [Contract/Resources.md](./Contract/Resources.md)。

该子文档定义：

- Frame、Camera SDK 缓冲区和 Latest Frame Store 的生命周期；
- GUI 预览 Frame、模式状态及配置临时资源的持有和释放；
- Inspection Plan、检查申请和完整任务上下文的所有权；
- Worker 输出、领域事件和 InspectionPresentation 的载荷转移；
- 状态投影、AppViewSnapshot 和优雅关机的资源释放顺序。

关键约束：

- 释放共享引用只结束当前持有者的所有权，底层对象在最后一个共享引用释放后销毁；
- 状态外准备只有在操作成功提交后才能成为领域状态资源，失败、拒绝或过滤必须释放未提交资源；
- App Controller 当前模式的 `optional_presentation` 是最近一次 InspectionPresentation 的唯一领域真值，GUI 只持有其最新状态快照；
- 每个被接受的检查在 Worker 终止前固定 Frame 和 Inspection Plan，并持有完整任务上下文；
- 优雅关机必须按 Camera、当前检查、Worker 与 Actor、应用状态和 Store 的依赖顺序释放资源。

## 7. 执行、并发与取消规约

详细规约见 [Contract/ExecutionAndCancellation.md](./Contract/ExecutionAndCancellation.md)。

该子文档定义：

- App Controller、各 Actor、Inspection Worker 和 Inspection Core 的串行及独立执行边界；
- Worker 接受任务、执行超时起点、单调截止时间和计时器身份；
- Inspection Core 的显式输入输出、通用取消检查点和算子内部取消责任；
- 执行超时、返回 Home 和优雅关机三种取消来源及其匹配规则；
- `Running` 与 `Cancelling` 中 WorkerOutcome 的终止处理和资源提交顺序；
- 完成、失败、执行截止、取消截止及多个取消来源之间的竞争裁决；
- 返回 Home 和优雅关机期间的并发规则。

关键约束：

- 竞争输入以对应状态所有者的实际处理顺序裁决，不以发送时间、Core 返回时间或业务 UTC 时间裁决；
- 执行和取消截止均为 Inspection Actor 可观察的裁决边界，先被 Actor 处理的适用输入胜出；
- 每个被 Worker 接受的任务必须恰好产生一个 WorkerOutcome，任务终止不表示 Worker 工作线程退出；
- 首次触发 `Cancelling` 的原因和取消截止时间固定，后续取消不得覆盖原因或延长截止时间；
- `Cancelling` 持续到匹配的 WorkerOutcome 被处理，系统不强制终止 Worker 工作线程；
- 进入 `Cancelling` 后，Completed 和 Failed 的业务载荷只能被丢弃，不得生成正常结果或失败展示；
- 正常终止、失败终止和取消终止都必须撤销或失效任务计时器、释放完整任务上下文并提交 `Idle`；
- 优雅关机必须先停止 Camera Actor，再取消并等待当前检查任务终止。

## 8. 配置、方案与算子规约

详细规约见 [Contract/SchemeAndOperators.md](./Contract/SchemeAndOperators.md)。

该子文档定义：

- 配置阶段、启用阶段、禁用阶段和空执行方案等术语；
- StageId、阶段顺序、阶段引用和禁用阶段的校验规则；
- 算子注册表、配置校验及方案构建的错误边界；
- Scheme Manager 完整构建不可变 Inspection Plan 的边界；
- DecisionRule 的 Expression、AlwaysPass 和 AlwaysFail 三种形式；
- 基于 Bind 短路语义的不可变累计阶段输出；
- 单次检查内通用派生产物的不可变共享缓存；
- 算子的显式输入、副作用、错误、取消和输出公共契约；
- 空执行方案、阶段输出和多阶段可视化数据的公共语义；
- Inspection Plan 内部动态分派实现与跨组件契约的边界。

## 9. 错误与结果语义

### 9.1 业务错误

- `Busy`：Inspection Actor 收到申请时已有检查正在运行或取消中；
- `NoFrame`：App Controller 固定检查帧时没有可用帧；
- `InvalidMode`：应用命令与 App Controller 当前 AppState 不匹配；至少携带命令、实际模式和期望模式；
- `ConfigLoadFailed`：配置文件读取或解析失败；
- `ConfigInvalid`：配置结构、字段、算子或阶段引用、参数或判定规则未通过静态校验；
- `PlanBuildFailed`：已通过完整校验的配置无法构建为完整可执行方案；
- `ConfigSaveFailed`：配置未能按临时写入和原子替换的保存事务提交；
- `InspectionFailed`：已构建方案中的算子或判定规则执行失败，并生成关联帧的失败展示；
- `InspectionTimedOut`：检查因执行超时进入取消，且 Actor 在适用的取消截止消息之前处理到匹配 WorkerOutcome。
- `ShuttingDown`：应用已开始关机，当前命令不再执行。

需要为每项错误补充：

- 产生组件；
- 携带上下文；
- 是否可展示；
- 是否改变状态；
- 是否允许重试。

### 9.2 致命错误

以下错误不属于可恢复业务错误，直接 `panic`：

- 任一组件初始化失败；
- 摄像头采集或关闭失败；
- Actor 在匹配 WorkerOutcome 之前先处理适用的取消截止消息；
- 组件关闭失败或内部通信基础设施失效。

其他内部不变量被破坏时的处理待定义。

### 9.3 检查结果

需要补充：

- InspectionResult 的完整字段；
- InspectionError 的分类与上下文；
- 成功、失败、取消和超时之间的类型关系；
- 对 GUI 暴露的结果投影。

## 10. 系统级不变量

当前已确定的不变量：

1. App Controller 是 AppState 的唯一所有者。
2. 模式相关命令由 App Controller 串行处理。
3. 每次进入 EditMode 或 ProductionMode 都生成新的 `ModeSessionId`。
4. 过期模式会话的异步事件不得修改当前展示状态。
5. Camera Actor 是摄像头的唯一访问者。
6. Camera Actor 是 Latest Frame Store 的唯一写入者。
7. Camera Actor 不等待帧消费者。
8. 已发布 Frame 始终不可变。
9. GUI 不积压预览帧。
10. Inspection Actor 不读取或持有 AppState。
11. Inspection Actor 串行处理检查申请和任务事件。
12. `Running` 和 `Cancelling` 均拒绝新检查申请。
13. 同一时间最多执行一个检查任务。
14. 检查期间固定 Frame 和 Inspection Plan。
15. Inspection Core 只在 Inspection Worker 中执行。
16. Inspection Core 及其算子不执行外部业务副作用。
17. 检查完成与取消的竞争由 Inspection Actor 的事件处理顺序裁决。
18. 每个被接受的检查最终必须释放 Actor 持有的 Frame 和 Inspection Plan，或因致命错误终止进程。
19. InspectionPresentation 持有关联检查帧。
20. 生产方案和测试任务方案都不使用空引用表示缺少方案；其可执行阶段列表可以为空，但判定规则始终存在。
21. 配置中的禁用阶段必须完整校验，但不得构建、执行、产生输出或被引用。
22. 启用阶段只能引用执行顺序中更早的启用阶段，v1 不自动重排阶段。
23. 空执行方案必须执行已声明的判定规则，不存在隐式默认判定。
24. 阶段输出提交后不可变；失败或取消不得提交当前阶段的部分输出。
25. 通用派生产物缓存只属于单次检查，相同 ArtifactKey 至多成功计算一次。
26. `ShuttingDown` 不属于 AppState，且进入后不可恢复为 `Running`。
27. 关机开始后不再执行后续应用命令。
28. 优雅关机必须先停止 Camera Actor，再等待当前检查终止。
29. ApplicationLifecycle 只有在运行组件停止且运行期资源释放后才能进入 `Terminated`。
30. 返回 Home 使用被关闭的 `ModeSessionId` 请求取消当前属于该会话的任务；迟到的旧会话取消不得影响其他会话任务。
31. 第一个触发 `Cancelling` 的原因固定，重复取消不得覆盖原因或延长取消截止时间。
32. Camera Actor 进入 `Stopping` 后不得再发布 Frame。
33. GUI 不持有或长期借用 AppState，只持有不可变的最新状态快照。

后续每增加一个命令、状态或消息，都应检查其是否保持以上不变量。

## 11. 完整性检查清单

### 11.1 用例覆盖

- [ ] 每个 Scope 功能都有对应命令或明确的后台行为；
- [ ] 每个命令都定义前置状态、成功和失败结果；
- [ ] 每个异步用例都定义终止路径；
- [ ] 每个退出路径都定义资源释放。

### 11.2 状态机覆盖

- [ ] 每个命令在所有 AppState 下都有确定结果；
- [ ] Inspection Actor 的每种输入在所有状态下都有确定结果；
- [ ] 所有过渡状态都有成功、失败、取消和超时出口；
- [ ] 过期及重复消息不会破坏当前状态。

### 11.3 消息覆盖

- [x] 每条消息都有发送方、接收方和载荷；
- [x] 每个请求都有接受、拒绝或丢弃条件；
- [x] 每个异步响应都有身份关联字段；
- [x] 每条消息的资源所有权变化明确。

### 11.4 错误与资源覆盖

- [ ] 每个副作用都定义失败语义；
- [ ] 每个错误都定义状态是否变化；
- [ ] 每个共享资源都定义创建、持有、转移和释放；
- [ ] 每个已接受任务都存在确定的资源终止路径。

## 12. 待讨论事项

1. 错误的具体类型结构。
