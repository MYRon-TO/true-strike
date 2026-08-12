# 执行、并发与取消规约

本文定义视觉检测系统 v1 的执行边界、串行裁决、时间语义、协作式取消和竞争处理规则。整体规约索引见 [行为规约](../Contract.md)，状态及转换见 [状态机规约](./StateMachines.md)，消息关联与投递见 [消息规约](./Messages.md)，任务资源的持有和释放见 [资源生命周期规约](./Resources.md)。

本文所称“任务终止”只表示当前检查任务的同步执行已经返回并产生终止输出，不表示 Inspection Worker 工作线程已经退出。工作线程只在关机阶段处理 `CloseInspectionWorker` 后退出。

## 1. 执行与串行化模型

### 1.1 状态所有者

以下组件分别拥有独立的串行裁决边界：

- App Controller 串行处理应用命令和 InspectionEvent，并唯一裁决 `ApplicationLifecycle` 与 `AppState`；
- Inspection Actor 串行处理检查申请、取消、计时器消息和 WorkerOutcome，并唯一裁决 InspectionTaskState；
- Camera Actor 串行处理启动、停止和采集事件，并唯一裁决摄像头状态；
- 每个状态所有者一次只提交一个逻辑状态转换，转换中的状态与资源变化必须保持一致。

“串行处理”不限定专用线程、邮箱或运行时实现，也不要求耗时工作在状态所有者的执行线程上完成。异步等待不得阻塞 Actor 或异步运行时执行线程。

### 1.2 独立执行边界

- Camera Actor 的阻塞采集在独立执行环境中进行，不等待 GUI、App Controller 或检查任务；
- Inspection Worker 在独立工作线程中同步调用 Inspection Core；
- Inspection Worker 同一时间最多接受并执行一个检查任务；
- Inspection Core 不在 GUI、App Controller 或 Inspection Actor 的执行边界中运行；
- Scheme Manager 的同步调用由 App Controller 按命令顺序发起，调用期间不并行处理后续应用命令。

### 1.3 顺序定义

同一状态所有者收到的竞争输入，以该所有者的实际处理顺序裁决，不以发送时间、业务 UTC 时间或不同线程上的实际发生时间裁决。

不同发送方之间不定义全局消息顺序。状态投影可以合并或跳过中间版本，不得用于证明请求完成、任务终止或组件关闭；这些边界必须由对应响应或终止输出证明。

## 2. 任务接受与时间语义

### 2.1 接受边界

Inspection Actor 在 `Idle` 中处理合法的 SubmitInspection 时：

1. 生成 `inspection_id`，读取业务 UTC 时间 `started_at`，构造完整的 InspectionMetadata；
2. 创建单任务 CancellationSignal，并准备固定 Frame 和 Inspection Plan 的任务上下文；
3. 向 Inspection Worker 提交 ExecuteInspection；
4. Worker 任务成功提交到任务入口即视为 Worker 已接受；
5. Actor 随即读取单调时间，设置 `execution_started` 和 `execution_deadline`，启动对应执行计时器并提交 `Running`；
6. 发布 `Running` 投影并返回 `Accepted(metadata)`。

Actor 在上述处理完成前不会处理 WorkerOutcome。因此，即使 Core 立即返回，对应输出也只能在 `Running` 提交后参与裁决。Worker 提交失败属于内部通信基础设施失效，直接 `panic`。

### 2.2 两类时间

- `started_at` 使用业务 UTC 时间，只用于展示、记录和结果关联，不参与超时裁决；
- `execution_started`、`execution_deadline` 和 `cancellation_deadline` 使用进程内单调时钟，只属于 Actor 的任务上下文；
- 执行超时和取消宽限期使用应用级固定值；
- 计时器不得早于对应单调截止时间产生截止消息。

执行超时从 Worker 接受任务时开始。取消宽限期从首次触发 `Running → Cancelling` 的取消输入被 Inspection Actor 实际处理时开始；关机流程等待 Camera Actor 停止的时间不计入取消宽限期。

### 2.3 计时器身份

ExecutionDeadlineElapsed 和 CancellationDeadlineElapsed 必须携带 `inspection_id`。Inspection Actor 只处理与当前任务匹配且适用于当前状态的计时器消息；状态不适用、身份不匹配或任务已经终止时一律丢弃。

首次进入 `Cancelling` 后，原执行计时器必须撤销或失效。任务终止后，全部任务计时器必须撤销或失效。撤销失败但可通过状态和 `inspection_id` 识别为过期的消息不得改变状态。

## 3. Inspection Core 执行

### 3.1 显式输入与输出

Inspection Worker 将固定的 Frame、Inspection Plan 和 CancellationSignal 的观察端显式传给 Inspection Core：

```text
inspect(frame, inspection_plan, cancellation) -> InspectionCoreOutcome

InspectionCoreOutcome
├── Completed(InspectionCoreOutput)
├── Failed(InspectionError)
└── Cancelled
```

Inspection Core：

- 只使用本次调用的显式输入；
- 按 Inspection Plan 的线性顺序执行已启用阶段；
- 不读取 AppState、Latest Frame Store、配置文件、GUI 或其他外部业务状态；
- 不执行持久化、设备控制或修改全局业务状态等外部业务副作用；
- 阶段中间值和算子临时资源只存在于当前调用中。

### 3.2 协作式取消检查点

Inspection Core 必须至少在以下边界观察 CancellationSignal：

1. 开始执行第一个阶段前；
2. 每个阶段返回后、开始下一阶段前；
3. 全部阶段完成后、执行最终判定前；
4. 构造 Completed 输出前。

在任一检查点观察到取消后，Core 必须停止后续阶段和判定，释放中间资源并返回 `Cancelled`。

Core 无法在一个同步算子调用内部代替算子观察取消。可能单次运行超过取消宽限期的算子必须自行观察同一个 CancellationSignal；其算子契约必须给出从信号设置到调用返回的最坏时间上界，该上界加 Core 边界处理余量必须小于取消宽限期。尚未给出该保证的算子不得声称支持有界优雅取消；系统仍不强制终止线程，取消截止消息被优先裁决时会直接 `panic`。

### 3.3 Worker 终止输出

Worker 对每个已接受任务必须恰好产生一个 WorkerOutcome：

- Core 返回 Completed 时发送 `Completed(inspection_id, output)`；
- Core 返回 Failed 时发送 `Failed(inspection_id, error)`；
- Core 返回 Cancelled 时发送 `Cancelled(inspection_id)`。

WorkerOutcome 产生后，Worker 释放自身持有的 Frame、Inspection Plan、CancellationSignal 观察端和调用临时资源。Worker 不发送进度消息，也不重试任务。

## 4. 取消来源与匹配

v1 有三种取消来源：

| 来源 | 输入 | 匹配依据 | `Idle` 中处理 | `Running` 中处理 | `Cancelling` 中处理 |
| --- | --- | --- | --- | --- | --- |
| 执行超时 | ExecutionDeadlineElapsed | `inspection_id` | 丢弃 | 匹配时触发取消 | 作为失效的执行计时器丢弃 |
| 返回 Home | CancelInspectionForSession | `ModeSessionId` | 忽略 | 会话匹配时触发取消；不匹配时忽略 | 会话匹配时保持原取消；不匹配时忽略 |
| 优雅关机 | CancelCurrentForShutdown | 当前唯一任务 | 立即响应 `InspectionBecameIdle(None)` | 触发取消并附着等待 | 附着等待现有取消流程 |

返回 Home 的取消是无需响应的会话级通知，只匹配 Actor 当前唯一任务，不表示取消一个任务集合。迟到的旧会话取消不得影响新会话任务。

## 5. 进入和保持 Cancelling

### 5.1 首次取消

Inspection Actor 在 `Running` 中处理首个匹配且有效的取消输入时，必须在同一处理边界：

1. 固定取消原因为 `Timeout`、`ReturnHome` 或 `Shutdown`；
2. 读取单调时间，设置 `cancellation_deadline` 并启动对应取消计时器；
3. 保留完整任务上下文，不替换固定 Frame、Inspection Plan 或 CancellationSignal；
4. 设置现有 CancellationSignal；
5. 撤销或失效执行计时器；
6. 提交 `Cancelling` 并发布对应状态投影；
7. 若输入为 CancelCurrentForShutdown，将其响应等待者附着到当前取消流程。

进入 `Cancelling` 后继续拒绝所有检查申请，并持续到当前任务匹配的 WorkerOutcome 被处理。系统不得强制终止 Worker 工作线程。

### 5.2 后续取消

首次取消原因和取消截止时间一经固定便不可改变：

- 重复或后续执行超时消息不得重置截止时间；
- 匹配的返回 Home 通知只保持现有取消流程，不增加等待者；
- CancelCurrentForShutdown 可以附着一个或多个等待者，但不得覆盖取消原因或延长截止时间；
- 会话不匹配的返回 Home 通知作为过期通知丢弃。

## 6. WorkerOutcome 与任务终止

### 6.1 Running 中的裁决

| WorkerOutcome | 下一状态 | 处理结果 |
| --- | --- | --- |
| 匹配的 Completed | `Idle` | 构造 InspectionResult、InspectionPresentation 和 InspectionCompleted |
| 匹配的 Failed | `Idle` | 构造失败 InspectionPresentation 和 InspectionFailed |
| 匹配的 Cancelled | 异常终止 | 未进入取消却收到取消结果，视为内部不变量破坏并 `panic` |
| 不匹配或过期输出 | 保持原状态 | 丢弃整个输出及其业务载荷 |

正常完成或执行失败的提交顺序为：

1. 使用 WorkerOutcome 载荷、InspectionMetadata 和固定 Frame 构造可独立存活的领域事件；
2. 撤销或失效全部任务计时器；
3. 释放 Actor 持有的完整任务上下文并提交 `Idle`；
4. 发布 `Idle` 投影；
5. 发送 InspectionCompleted 或 InspectionFailed。

领域事件与 `Idle` 投影使用不同交付语义，App Controller 不得依赖二者的观察顺序。领域事件一经构造便不得借用 Actor 的任务上下文。

### 6.2 Cancelling 中的裁决

`Cancelling` 中匹配当前 `inspection_id` 的 Completed、Failed 或 Cancelled 均只证明当前检查任务已经终止：

- Completed 的 InspectionCoreOutput 和 Failed 的 InspectionError 必须丢弃并释放；
- 不得构造正常 InspectionResult 或失败 InspectionPresentation；
- 在释放上下文前移出构造取消事件和关机响应所需的 InspectionMetadata、固定取消原因及等待者；
- 撤销或失效全部任务计时器；
- 释放 Actor 持有的完整任务上下文并提交 `Idle`；
- 发布 `Idle` 投影；
- 在 `Idle` 与任务资源释放边界之后完成全部关机等待响应。

固定取消原因为 `Timeout` 时，Actor 在 `Idle` 提交后发送只携带 InspectionMetadata 的 InspectionTimedOut。该事件不携带 Frame 或 InspectionPresentation，也不替换当前模式已有的最近一次展示对象。固定原因为 `ReturnHome` 或 `Shutdown` 时不发送 InspectionEvent。

关机等待响应中的 TerminatedTask 必须报告实际 `inspection_id` 和最先固定的取消原因，即使关机请求不是首次取消来源。

## 7. 竞争裁决

### 7.1 完成、失败与首次取消

- Actor 先处理匹配的 Completed 或 Failed 时，任务按正常完成或执行失败终止；之后到达的返回 Home 通知被忽略，关机取消立即得到 `InspectionBecameIdle(None)`；
- Actor 先处理有效取消输入并进入 `Cancelling` 时，之后处理的匹配 WorkerOutcome 只用于结束取消，其业务载荷不得进入正常结果；
- Actor 先处理匹配的执行超时消息时，`Timeout` 成为固定取消原因；
- 不使用 WorkerOutcome 的产生时间、Core 返回时间或 UTC 时间推翻 Actor 已作出的裁决。

### 7.2 执行截止与 WorkerOutcome

执行是否超时，以 Inspection Actor 的实际处理顺序为准：

- 先处理匹配 WorkerOutcome：任务按该输出终止；随后到达的执行截止消息过期；
- 先处理匹配 ExecutionDeadlineElapsed：任务进入 `Cancelling`；随后到达的 WorkerOutcome 按取消终止处理。

因此，`execution_deadline` 是 Actor 可观察的裁决期限，不是对 Core 实际完成时刻的独立测量。即使 WorkerOutcome 已经产生，只要 Actor 先处理执行截止消息，仍按超时取消裁决。

### 7.3 取消截止与 WorkerOutcome

Inspection Actor 在 `Cancelling` 中：

- 先处理匹配 WorkerOutcome：完成取消并进入 `Idle`；随后到达的 CancellationDeadlineElapsed 过期；
- 先处理匹配 CancellationDeadlineElapsed：直接 `panic`，不再等待可能已经产生但尚未处理的 WorkerOutcome。

因此，取消宽限期同样以 Actor 的实际处理顺序执行，不证明 Worker 的物理返回时刻。文档中“取消宽限期耗尽”均指 Actor 优先处理了适用且匹配的 CancellationDeadlineElapsed。

### 7.4 多个取消来源

多个取消来源竞争时，第一个被 Inspection Actor 处理并实际触发 `Running → Cancelling` 的来源胜出：

- `Timeout` 先触发，之后返回 Home 或关机不改变原因；任务终止后仍生成 InspectionTimedOut，但 App Controller 可以因生命周期或会话不匹配将其过滤；
- `ReturnHome` 先触发，之后执行超时消息失效，关机只附着等待，不产生 InspectionTimedOut；
- `Shutdown` 先触发，之后执行超时或返回 Home 不改变原因，也不产生模式领域事件。

### 7.5 过期输入

以下输入必须整体丢弃且不得改变当前状态或资源：

- `inspection_id` 与当前任务不匹配的 WorkerOutcome 或计时器消息；
- Actor 已为 `Idle` 时到达的 WorkerOutcome 或任务计时器消息；
- `ModeSessionId` 与当前任务不匹配的返回 Home 取消通知；
- 任务终止后迟到的旧任务输入。

丢弃 Completed 或 Failed 时必须同时释放其中的业务载荷。

## 8. 返回 Home 的并发规则

App Controller 处理 ReturnHome 时，先记录被关闭模式的 `ModeSessionId`，提交 Home 并释放模式资源，再发送 CancelInspectionForSession；不查询 Inspection Actor 投影，也不等待取消完成。

检查事件和 ReturnHome 由 App Controller 按实际处理顺序裁决：

- 先处理会话匹配的完成或失败事件时，可以更新原模式的最近一次展示对象；随后 ReturnHome 会释放该展示对象；
- 先提交 Home 时，之后到达的旧会话 InspectionEvent 被过滤；
- ReturnHome 完成后可以进入新模式，但旧任务终止前 Inspection Actor 仍返回 `Busy`，GUI 应将不匹配当前会话的非 Idle 投影展示为 `BusyWithPreviousSession`；
- 迟到的旧会话取消通知只按当前任务的 `ModeSessionId` 匹配，不得取消新会话任务。

## 9. 优雅关机的并发规则

首次 Shutdown 由 App Controller 在其串行命令顺序中提交 `ShuttingDown`，随后启动唯一的异步关机流程。此前已经开始处理的命令先完成；之后的普通命令返回 `ShuttingDown`；重复 Shutdown 附着等待同一 `ShutdownCompleted`。

关机严格按以下顺序推进：

1. 请求 Camera Actor 停止，异步等待 `CameraStopped`；
2. 摄像头停止后发送 CancelCurrentForShutdown，异步等待 `InspectionBecameIdle`；
3. Actor 已为 `Idle` 后关闭 Inspection Worker 和各 Actor；同阶段无依赖的关闭可以并行发起并统一等待；
4. 释放 AppState、Latest Frame Store、状态发布边界及其他应用运行期资源；
5. 提交 `Terminated` 并完成所有关机请求。

关机与检查终止的竞争仍由 Inspection Actor 的处理顺序裁决。进入 `ShuttingDown` 后到达的 InspectionEvent 不得更新 GUI 或模式展示；控制响应和关闭确认不应用模式事件过滤规则。

## 10. 执行与取消不变量

1. App Controller、Inspection Actor 和 Camera Actor 只由各自所有者串行提交状态转换。
2. Inspection Core 只在 Inspection Worker 中运行，并只使用显式输入。
3. Inspection Core 及算子不得执行外部业务副作用。
4. 同一时间最多执行一个检查任务。
5. Worker 接受任务后，Actor 才能提交 `Running` 和返回 `Accepted`。
6. 每个被接受的任务必须恰好产生一个 WorkerOutcome，或因致命错误终止进程。
7. `Running` 和 `Cancelling` 均拒绝新检查申请并持有完整任务上下文。
8. 只有 Inspection Actor 可以设置单任务 CancellationSignal；该信号不得复位、替换或跨任务复用。
9. 首次触发 `Cancelling` 的原因和截止时间固定，后续取消不得覆盖或延长。
10. `Cancelling` 必须持续到匹配 WorkerOutcome 被处理；系统不得强制终止 Worker 工作线程。
11. 进入 `Cancelling` 后不得再生成正常结果或失败展示。
12. 竞争输入以状态所有者的实际处理顺序裁决，不以产生时间推翻既有裁决。
13. 过期或身份不匹配的输出、计时器和取消通知不得改变当前状态或资源。
14. 关机必须先停止 Camera Actor，再取消并等待当前检查任务终止。
15. Inspection Worker 工作线程只在任务已经 `Idle` 后关闭。