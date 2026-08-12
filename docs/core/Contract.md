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
- `ModeSessionId` 随检查申请、检查元数据和异步检查事件传递；
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
- 优雅关机期间的状态转换和取消确认。

## 5. 消息规约

### 5.1 App Controller 命令

需要定义统一的应用命令集合及各命令返回类型，至少包括：

- 进入编辑模式；
- 进入生产模式；
- 返回主页；
- 修改草稿；
- 校验草稿；
- 保存草稿；
- 发起测试检查；
- 发起生产检查；
- 优雅关机。

命令的具体类型、字段和响应形式待定义。优雅关机异步发起，其响应在 ApplicationLifecycle 进入 `Terminated` 后完成；重复关机请求附着到同一关机流程。

ApplicationLifecycle 进入 `ShuttingDown` 后，队列中尚未处理及之后到达的应用命令统一返回 `ShuttingDown`，不执行命令内容。优雅关机命令本身在 ApplicationLifecycle 进入 `Terminated` 后完成。

### 5.2 检查申请

App Controller 向 Inspection Actor 提交的检查申请至少包含：

- 固定的 `ModeSessionId`；
- 检查类型；
- 固定的 Frame；
- 不可变 Inspection Plan。

Inspection Actor 串行处理申请：

- 收到申请时处于 `Running` 或 `Cancelling`，立即返回 `Busy`；
- 收到申请时处于 `Idle`，生成 `inspection_id` 和 InspectionMetadata，读取业务展示时间 `started_at`，创建取消信号并向 Worker 提交任务；
- Worker 成功接受任务时读取单调时间，设置 `execution_started` 和 `execution_deadline`，单点提交 `Running` 并返回成功。

申请一旦被接受，应用模式、草稿、配置文件和 Latest Frame Store 的后续变化均不影响任务输入。Worker 任务提交失败属于内部基础设施失效，直接 `panic`。

需要补充：

- 申请成功响应的具体类型；
- 请求与响应的关联方式。

### 5.3 Worker 任务

Inspection Actor 向 Inspection Worker 提交的任务至少包含：

- InspectionMetadata；
- 固定的 Frame；
- 固定的 Inspection Plan；
- 取消信号。

Worker 接受任务是检查申请成功的必要条件。任务成功提交到 Worker 任务入口即定义为 Worker 已接受，不增加额外异步确认消息。

### 5.4 Worker 输出

Worker 输出分为：

- `Completed(InspectionCoreOutput)`；
- `Failed(InspectionError)`；
- `Cancelled`。

每个输出必须能够与当前任务的 `inspection_id` 关联。具体消息类型待定义。

### 5.5 Inspection Actor 事件

Inspection Actor 向 App Controller 发送的事件至少包括：

- 检查完成；
- 检查失败；
- 检查超时；
- 内部取消完成确认。

所有可能更新模式展示状态的事件必须携带 `ModeSessionId`。内部取消完成确认必须携带 `inspection_id` 和取消原因，用于返回 Home 后的后台清理或优雅关机等待；它不生成正常结果或展示。事件载荷及统一事件类型待定义。

Inspection Actor 还必须发布其最新状态投影，至少区分 `Idle`、`Running(metadata)` 和 `Cancelling(metadata, reason)`。App Controller 将该投影与当前 `ModeSessionId` 组合；旧会话任务尚未终止时，对当前模式投影为 `BusyWithPreviousSession`。具体实现可以使用 watch、订阅通道或其他最新值机制。

### 5.6 异步事件过滤

App Controller 仅在事件的 `ModeSessionId` 与当前 EditMode 或 ProductionMode 匹配时，允许事件更新当前模式的展示状态。

以下事件必须丢弃：

- App Controller 当前处于 Home；
- 当前模式的 `ModeSessionId` 与事件不一致。

丢弃事件不影响 Inspection Actor 自身的状态转换和资源释放。

### 5.7 检查取消与关闭

返回 Home 时，App Controller 使用 `inspection_id` 精确取消离开模式时正在执行的任务；请求同时携带 `ModeSessionId` 和 `ReturnHome` 原因。Inspection Actor 以 `inspection_id` 判断目标是否匹配，`ModeSessionId` 只用于一致性检查和诊断。

优雅关机在 Camera Actor 确认 `Stopped` 后发送 `CancelCurrentForShutdown`。该消息取消 Inspection Actor 当前唯一任务；取消完成确认携带实际 `inspection_id` 和固定的取消原因。

第一个触发 `Running → Cancelling` 的原因固定。重复取消只能附着等待，不得覆盖原因或延长最初的取消宽限期。Inspection Actor 只有在任务状态为 `Idle` 时才能关闭；具体取消、关闭和确认类型待定义。

## 6. 资源生命周期规约

### 6.1 Frame

Camera Actor 从 SDK 获得图像后：

1. 将图像数据复制到应用拥有的内存；
2. 生成 `frame_id` 并构造不可变 Frame；
3. 通过共享引用发布到 Latest Frame Store；
4. 新引用替换 Store 中的旧引用。

约束：

- 发布后的图像内存不得修改或复用；
- Latest Frame Store 只保存一个最新帧引用；
- 每次读取返回读取时最新 Frame 的独立共享引用；
- 尚未发布帧时，读取结果表示无帧；
- 替换最新帧不修改旧帧，也不等待消费者；
- Frame 在全部共享引用释放后销毁。

### 6.2 检查帧

App Controller 完成检查方案准备、准备提交检查申请时，从 Latest Frame Store 读取最新 Frame，并将其固定为本次检查输入。

- 没有可用帧时返回 `NoFrame`，不提交检查申请；
- Inspection Actor 不再次读取 Latest Frame Store；
- 后续发布的新帧不影响该检查；
- 申请失败时，申请对象销毁，其持有的 Frame 共享引用随之释放；
- 申请成功后，Inspection Actor 持有 Frame，直至任务终止；
- 检查完成或失败事件持有供展示使用的独立共享引用。

### 6.3 Draft Config

- Draft Config 由 EditMode 持有；
- 修改草稿只改变内存状态；
- 草稿变化不创建或修改生产方案；
- 返回 Home 时释放草稿；
- 保存成功后，内存草稿同步为已提交的新 `revision`；除 `revision` 外，其逻辑内容与磁盘配置一致。

### 6.4 Inspection Plan

方案的构建边界和所有权详见 [Contract/SchemeAndOperators.md](./Contract/SchemeAndOperators.md)。

- Scheme Manager 将有效配置构建为不可变可执行 Inspection Plan；
- Inspection Actor 和 Inspection Worker 均不构建或组装方案；
- 裸闭包不作为跨组件契约；
- 申请成功后，Inspection Actor 持有任务方案，直至任务终止；
- 申请被拒绝时，申请对象销毁，其持有的方案共享引用随之释放。

### 6.5 InspectionPresentation

GUI 只保留当前模式最近一次 InspectionPresentation。展示对象至少包含关联帧以及以下内容之一：

- 成功的 InspectionResult；
- 失败的 InspectionError 及对应元数据。

展示规则：

- 成功且存在可视化数据时，在关联帧上显示标记；
- 成功但没有可视化数据时，显示关联帧和文字结果；
- 失败时显示关联帧和错误；
- 新展示替换旧展示时释放旧帧引用；
- 离开当前模式时释放展示对象。

GUI 不持有或长期借用 AppState。App Controller 将领域状态纯投影为不可变 `AppViewSnapshot`，以替换式最新值语义发布；GUI 订阅快照并替换本地持有值，可以跳过中间版本。一次性命令结果使用事件传递，高频预览帧仍由 GUI 按刷新节奏从 Latest Frame Store 读取。Home 的文件选择对话框状态和候选路径属于 GUI 本地状态。详细规则见 [状态机规约](./Contract/StateMachines.md#33-gui-可观察状态投影)。

## 7. 执行、并发与取消规约

### 7.1 Inspection Core 执行

Inspection Worker 将固定的 Frame、Inspection Plan 和取消信号显式传入 Inspection Core。

Inspection Core：

- 按方案的线性顺序执行算子；
- 在阶段之间检查取消信号；
- 长时间运行的算子定期检查取消信号；
- 收到取消信号后尽快返回 `Cancelled`；
- 不读取外部业务状态；
- 不执行持久化或其他外部业务副作用。

### 7.2 正常完成

Inspection Actor 在 `Running` 状态处理匹配当前 `inspection_id` 的 `Completed` 时：

1. 使用 InspectionMetadata 和核心输出组装 InspectionResult；
2. 使用结果和固定帧组装 InspectionPresentation；
3. 向 App Controller 发送携带 `ModeSessionId` 的完成事件；
4. 释放 Actor 持有的帧和方案；
5. 切换为 `Idle`。

### 7.3 执行失败

Inspection Actor 在 `Running` 状态处理匹配当前 `inspection_id` 的 `Failed` 时：

1. 使用 InspectionMetadata、检查错误和固定帧组装失败展示对象；
2. 向 App Controller 发送携带 `ModeSessionId` 的失败事件；
3. 释放 Actor 持有的帧和方案；
4. 切换为 `Idle`。

失败展示对象持有关联检查帧，并按与成功结果相同的会话隔离规则更新最近一次展示对象。

### 7.4 取消来源

取消可由以下原因触发：

- 检查超时；
- 返回 Home；
- 应用优雅关机。

检查执行超时和取消宽限期使用应用级固定值。

### 7.5 进入 Cancelling

Inspection Actor 在 `Running` 状态处理首次匹配的取消时：

1. 切换为 `Cancelling`；
2. 保留原任务上下文、帧和方案；
3. 设置取消信号；
4. 固定取消原因并使用单调时钟设置取消截止时间；
5. 拒绝后续检查申请。

`Cancelling` 持续到 Worker 终止。重复取消只能附着等待，不得覆盖首次取消原因或延长取消截止时间。系统不强制终止 Worker 线程。

### 7.6 取消结果

Worker 对每个任务只产生一个终止输出：`Completed`、`Failed` 或 `Cancelled`。Inspection Actor 进入 `Cancelling` 后，匹配当前 `inspection_id` 的任一终止输出均证明 Worker 已停止；`Completed` 的核心输出和 `Failed` 的错误均被丢弃，不生成正常结果或失败展示。

因检查超时进入 `Cancelling` 后：

- Worker 在宽限期内停止时，Inspection Actor 发送携带 `ModeSessionId` 的 `InspectionTimedOut` 事件；
- 超时检查不生成正常 InspectionResult；
- Actor 释放固定帧和方案，并切换为 `Idle`；
- Worker 未在宽限期内停止时直接 `panic`。

返回 Home 或关机触发的取消不生成正常检查结果。Worker 停止后，Inspection Actor 释放任务资源、切换为 `Idle`，并发布内部取消完成确认。返回 Home 不等待该确认；优雅关机必须等待该确认或确认 Actor 已处于 `Idle`。

### 7.7 完成与取消的竞争

Inspection Actor 以串行事件处理顺序裁决完成与取消：

- 先处理完成或失败事件时，任务按对应结果结束；
- 先处理取消事件并进入 `Cancelling` 时，之后到达的匹配终止输出只用于证明 Worker 已停止，其业务载荷一律丢弃；
- 过期或 `inspection_id` 不匹配的 Worker 事件不得改变当前状态。

### 7.8 其他竞争场景

App Controller 收到的应用命令按串行处理顺序执行。配置保存与测试检查、重复 GUI 命令均不并行处理。

- 模式不匹配以 App Controller 开始处理命令时的 AppState 为准；
- 关机命令之前的应用命令先完成，之后的命令返回 `ShuttingDown`；
- 关机采用异步、严格分阶段的协调流程：先等待 Camera Actor 停止，再取消并等待检查任务，最后关闭 Worker 和各 Actor；
- 同一关机阶段内无依赖的关闭操作可以并行发起并统一等待，异步等待不得阻塞 Actor 或运行时执行线程；
- 关机与检查完成或失败的竞争由 Inspection Actor 的事件处理顺序裁决；
- `started_at` 使用业务 UTC 时间；执行超时从 Worker 成功接受任务时开始，使用进程内单调时钟。

## 8. 配置、方案与算子规约

详细规约见 [Contract/SchemeAndOperators.md](./Contract/SchemeAndOperators.md)。

该子文档定义：

- 配置有效性；
- Scheme Manager 构建不可变可执行 Inspection Plan 的边界；
- 方案所有权和申请被拒绝时的释放语义；
- Inspection Plan 与内部闭包实现的边界；
- 待细化的算子输入输出、判定规则和可视化数据。

## 9. 错误与结果语义

### 9.1 业务错误

- `Busy`：Inspection Actor 收到申请时已有检查正在运行或取消中；
- `NoFrame`：App Controller 固定检查帧时没有可用帧；
- `InvalidMode`：应用命令与 App Controller 当前 AppState 不匹配；至少携带命令、实际模式和期望模式；
- `ConfigLoadFailed`：配置读取或解析失败；
- `ConfigInvalid`：配置未通过校验；
- `PlanBuildFailed`：配置无法构建可执行方案；
- `ConfigSaveFailed`：配置未能按保存事务提交；
- `InspectionFailed`：Inspection Core 执行失败，并生成关联帧的失败展示；
- `InspectionTimedOut`：检查超时，且 Worker 已在取消宽限期内停止。
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
- Worker 未在取消宽限期内停止；
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
20. 生产方案和测试任务方案都不为空，但允许阶段列表为空。
21. `ShuttingDown` 不属于 AppState，且进入后不可恢复为 `Running`。
22. 关机开始后不再执行后续应用命令。
23. 优雅关机必须先停止 Camera Actor，再等待当前检查终止。
24. ApplicationLifecycle 只有在运行组件停止且运行期资源释放后才能进入 `Terminated`。
25. 返回 Home 以 `inspection_id` 精确取消任务，`ModeSessionId` 不承担任务取消标识职责。
26. 第一个触发 `Cancelling` 的原因固定，重复取消不得覆盖原因或延长取消截止时间。
27. Camera Actor 进入 `Stopping` 后不得再发布 Frame。
28. GUI 不持有或长期借用 AppState，只持有不可变的最新状态快照。

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

- [ ] 每条消息都有发送方、接收方和载荷；
- [ ] 每个请求都有接受、拒绝或丢弃条件；
- [ ] 每个异步响应都有身份关联字段；
- [ ] 每条消息的资源所有权变化明确。

### 11.4 错误与资源覆盖

- [ ] 每个副作用都定义失败语义；
- [ ] 每个错误都定义状态是否变化；
- [ ] 每个共享资源都定义创建、持有、转移和释放；
- [ ] 每个已接受任务都存在确定的资源终止路径。

## 12. 待讨论事项

1. 算子输入输出和阶段间数据传递模型；
2. 判定规则及空阶段方案语义；
3. 多阶段可视化数据的合并语义；
4. 消息和错误的具体类型结构。
