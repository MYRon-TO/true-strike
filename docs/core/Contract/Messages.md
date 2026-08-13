# 消息规约

本文定义视觉检测系统 v1 的异步组件消息、请求响应、领域事件和最新值投影。整体规约索引见 [行为规约](../Contract.md)，状态转换见 [状态机规约](./StateMachines.md)。

Scheme Manager 的配置读取、校验、方案构建和保存属于同步组件调用，不属于本文所称消息。

## 1. 通用约定

### 1.1 消息类别

本文使用以下类别：

- **命令**：GUI 或应用运行环境向 App Controller 发出的操作请求；
- **申请**：App Controller 向 Actor 发出的、可能被业务状态拒绝的操作请求；
- **控制请求**：应用生命周期协调方要求组件停止或关闭的请求；
- **任务**：Actor 向 Worker 提交的工作；
- **输出**：Worker 向 Actor 返回的任务终止结果；
- **事件**：Actor 向 App Controller 发送的领域事实；
- **投影**：组件或 App Controller 发布的可替换最新状态。

请求与响应是逻辑契约，不限定使用一次性通道、Actor 回复句柄或其他实现形式。消息类型不限定 Rust 枚举、结构体或序列化表示。

### 1.2 请求、响应与关联

- 每个命令、申请和控制请求都携带逻辑上的一次性响应句柄，因此不额外要求 `request_id`；
- 每个被接收的请求必须恰好完成一次响应，进程因致命错误终止时除外；
- 请求响应只交付给请求方，不作为广播领域事件；
- 检查任务及其异步输出使用 `inspection_id` 关联；
- 模式领域事件使用其中 InspectionMetadata 的 `mode_session_id` 隔离模式会话；
- 实现不得依赖状态投影确认请求是否成功、任务是否终止或组件是否已经关闭。

系统不进行隐式重试。内部通信基础设施失效直接 `panic`；调用方不得通过自动重发制造重复副作用。

### 1.3 顺序与投递

- App Controller 和各 Actor 分别按自身串行处理顺序裁决收到的消息；
- 同一接收方从不同来源收到的消息不定义全局产生时间顺序，以接收方实际处理顺序为准；
- 命令响应、申请响应、控制响应、Worker 终止输出和领域事件不得通过可丢弃的最新值通道传递；
- 状态投影采用替换式最新值语义，可以合并或跳过中间版本，不形成待处理历史队列；
- 过期或身份不匹配的内部输出和计时器消息按本文规则丢弃，不发送补偿消息。

### 1.4 资源所有权

- Frame 和 Inspection Plan 在跨组件消息中使用不可变共享引用；
- 发送消息不修改共享对象，接收方只持有自己取得的共享引用；
- 请求被拒绝或消息被丢弃时，其携带的共享引用随消息销毁而释放；
- Worker 输出中的业务载荷向 Inspection Actor 转移所有权；Actor 丢弃输出时必须同时释放载荷；
- 状态投影和领域事件中的值必须可独立于发送方后续状态继续存活，不得携带发送方状态的借用。

## 2. 公共标识与元数据

### 2.1 标识职责

- `ModeSessionId` 由 App Controller 在每次进入 EditMode 或 ProductionMode 时生成，用于模式事件隔离和返回 Home 时的会话级取消；
- `inspection_id` 由 Inspection Actor 接受检查申请时生成，是具体任务、Worker 输出和计时器的唯一关联标识；
- `frame_id` 由 Camera Actor 生成，在应用运行期间唯一。

`ModeSessionId` 不替代 `inspection_id` 标识具体检查；会话级取消只匹配 Actor 当前唯一任务，不表示取消该会话及以前的任务集合。

### 2.2 InspectionMetadata

```text
InspectionMetadata
├── inspection_id: InspectionId
├── mode_session_id: ModeSessionId
├── inspection_kind: Test | Production
├── frame_id: FrameId
├── scheme_id: SchemeId
├── scheme_revision: u64
└── started_at: UtcTimestamp
```

InspectionMetadata 在一次检查中不可变。`started_at` 由 Inspection Actor 接受申请时读取，用于业务展示；执行和取消的单调时间不进入该对象。

## 3. App Controller 命令

### 3.1 命令集合

```text
AppCommand
├── EnterEditMode(config_path)
├── EnterProductionMode(config_path)
├── ReturnHome
├── ModifyDraft(mutation)
├── ValidateDraft
├── SaveDraft
├── StartTestInspection
├── StartProductionInspection
└── Shutdown
```

`mutation` 是用例规约定义的结构化字段修改操作。文件选择对话框及候选路径属于 GUI 本地状态，不是 AppCommand。

除 `Shutdown` 外，上述命令的发送方是 GUI；`Shutdown` 的发送方是 GUI 或应用运行环境。接收方均为 App Controller，每条命令都携带第 1.2 节定义的一次性响应句柄。

### 3.2 命令响应

| 命令 | 成功响应 | 业务失败响应 |
| --- | --- | --- |
| `EnterEditMode` | `EnteredEditMode(mode_session_id)` | `InvalidMode`、`ConfigLoadFailed`、`ConfigInvalid` |
| `EnterProductionMode` | `EnteredProductionMode(mode_session_id)` | `InvalidMode`、`ConfigLoadFailed`、`ConfigInvalid` |
| `ReturnHome` | `ReturnedHome` | 无 |
| `ModifyDraft` | `DraftModified` | `InvalidMode`、`ConfigInvalid` |
| `ValidateDraft` | `DraftValid` | `InvalidMode`、`ConfigInvalid` |
| `SaveDraft` | `DraftSaved(scheme_id, revision)` | `InvalidMode`、`ConfigInvalid`、`ConfigSaveFailed` |
| `StartTestInspection` | `InspectionAccepted(metadata)` | `InvalidMode`、`ConfigInvalid`、`NoFrame`、`Busy(active_metadata)` |
| `StartProductionInspection` | `InspectionAccepted(metadata)` | `InvalidMode`、`NoFrame`、`Busy(active_metadata)` |
| `Shutdown` | `ShutdownCompleted` | 无 |

除 `Shutdown` 外，ApplicationLifecycle 不是 `Running` 时先按生命周期规则处理；进入 `ShuttingDown` 后统一返回 `ShuttingDown`，不执行命令内容。首次 `Shutdown` 异步启动唯一关机流程，重复请求附着等待同一个 `ShutdownCompleted`。

`InspectionAccepted` 中的 metadata 可用于命令结果展示和诊断，但 App Controller 不以其中的 `inspection_id` 缓存 Inspection Actor 的运行状态，也不使用它发起返回 Home 取消。

## 4. 检查申请

### 4.1 SubmitInspection

```text
SubmitInspection
├── mode_session_id: ModeSessionId
├── inspection_kind: Test | Production
├── frame: Shared<Frame>
└── plan: Shared<InspectionPlan>

SubmitInspectionResponse
├── Accepted(metadata: InspectionMetadata)
└── Busy(active_metadata: InspectionMetadata)
```

发送方是 App Controller，接收方是 Inspection Actor。

处理规则：

- Actor 处于 `Idle` 时生成 `inspection_id`，读取 `started_at`，从请求和方案构造完整且不可变的 InspectionMetadata；
- Actor 创建取消信号并向 Worker 提交任务；
- Worker 成功接受任务后，Actor 读取单调时间，设置 `execution_started` 和 `execution_deadline`，单点提交 `Running`，发布状态投影并返回 `Accepted`；
- Actor 处于 `Running` 或 `Cancelling` 时返回 `Busy`，不生成新 `inspection_id`，也不提交 Worker 任务；
- `Accepted` 返回时 Actor 已处于 `Running`，Worker 已接受任务；
- Worker 任务提交失败属于内部通信基础设施失效，直接 `panic`。

Actor 接受申请后，固定 Frame 和 Inspection Plan 的后续外部变化均不影响任务。申请被拒绝时，申请持有的共享引用随申请销毁而释放。

## 5. Worker 消息

### 5.1 执行任务

```text
ExecuteInspection
├── metadata: InspectionMetadata
├── frame: Shared<Frame>
├── plan: Shared<InspectionPlan>
└── cancellation: CancellationSignal
```

发送方是 Inspection Actor，接收方是 Inspection Worker。任务成功提交到 Worker 任务入口即为 Worker 已接受，不增加异步接受确认。

WorkerOutcome 的发送方是 Inspection Worker，接收方是 Inspection Actor。

Worker 对每个已接受任务必须恰好产生一个终止输出：

```text
WorkerOutcome
├── Completed(inspection_id, InspectionCoreOutput)
├── Failed(inspection_id, InspectionError)
└── Cancelled(inspection_id)
```

Worker 不发送进度消息。Inspection Actor 只处理与当前任务 `inspection_id` 匹配的输出；不匹配或 Actor 已为 `Idle` 时丢弃整个输出及其载荷。

### 5.2 关闭 Worker

```text
CloseInspectionWorker -> InspectionWorkerClosed
```

该控制请求只在 Inspection Actor 已为 `Idle`、不存在尚待交付的 Worker 输出时发送。响应表示任务入口已经关闭且工作线程已经退出。重复关闭幂等返回 `InspectionWorkerClosed`；关闭期间提交新任务属于内部协议错误，直接 `panic`。

发送方是 App Controller 的关机协调流程，接收方是 Inspection Worker。

## 6. Inspection Actor 消息

### 6.1 返回 Home 的会话级取消

```text
CancelInspectionForSession
├── mode_session_id: ModeSessionId
└── reason: ReturnHome
```

该消息是 App Controller 离开 EditMode 或 ProductionMode 后发送的无需响应通知。App Controller 不先查询 Actor 状态，也不等待取消完成。

处理规则：

- `Idle`：忽略；
- `Running` 且当前 metadata 的 `mode_session_id` 匹配：进入 `Cancelling`；
- `Running` 但会话不匹配：作为过期通知忽略；
- `Cancelling` 且会话匹配：保持当前取消原因和截止时间；
- `Cancelling` 但会话不匹配：作为过期通知忽略。

该消息只匹配当前唯一任务，不维护会话任务集合，也不使用“该会话及以前”的范围取消语义。迟到的旧会话取消不得影响新会话任务。

### 6.2 关机取消与等待

```text
CancelCurrentForShutdown
    -> InspectionBecameIdle(terminated_task?)

TerminatedTask
├── inspection_id: InspectionId
└── fixed_cancellation_reason: Timeout | ReturnHome | Shutdown
```

该控制请求由关机协调流程在 Camera Actor 确认 `Stopped` 后发送：

- Actor 为 `Idle` 时立即响应 `InspectionBecameIdle(None)`；
- Actor 为 `Running` 时进入 `Cancelling`，固定原因为 `Shutdown`，在任务终止并释放资源后响应；
- Actor 已为 `Cancelling` 时，关机等待附着到当前取消流程，不覆盖原因，不延长取消截止时间；任务终止后响应实际 `inspection_id` 和最先固定的取消原因；
- 多个等待者附着到同一取消流程时，在同一 `Idle` 边界全部完成。

该响应是控制响应，不是模式领域事件，不受 Home、`ModeSessionId` 或 GUI 事件过滤规则影响。

### 6.3 计时器消息

```text
ExecutionDeadlineElapsed(inspection_id)
CancellationDeadlineElapsed(inspection_id)
```

计时器向 Inspection Actor 发送消息：

- `Running` 中匹配的执行超时使 Actor 进入 `Cancelling`，固定原因为 `Timeout`；
- `Cancelling` 中匹配的取消宽限期超时直接 `panic`；
- 状态不适用、已经过期或 `inspection_id` 不匹配时丢弃；
- 首次进入 `Cancelling` 后必须撤销或忽略原执行计时器；任务终止后必须撤销或忽略全部任务计时器。

### 6.4 关闭 Inspection Actor

```text
CloseInspectionActor -> InspectionActorClosed
```

发送方是 App Controller 的关机协调流程，接收方是 Inspection Actor。

- 只有任务状态为 `Idle` 时才能接受关闭请求并从 `Active` 进入 `Closing`；
- 响应表示 Actor 已进入 `Closed`、内部计时器已取消且通信资源已释放；
- `Running` 或 `Cancelling` 时收到关闭请求表示关机协调顺序错误，直接 `panic`；
- 重复关闭幂等返回 `InspectionActorClosed`。

## 7. Inspection Actor 领域事件

```text
InspectionEvent
├── InspectionCompleted
│   └── presentation: InspectionPresentation
├── InspectionFailed
│   └── presentation: InspectionPresentation
└── InspectionTimedOut
    └── metadata: InspectionMetadata
```

发送方是 Inspection Actor，接收方是 App Controller。

- `InspectionCompleted` 只由 `Running` 中匹配的 `Completed` 输出产生；
- `InspectionFailed` 只由 `Running` 中匹配的 `Failed` 输出产生；
- `InspectionTimedOut` 只在取消原因为 `Timeout`，且 Actor 在适用的取消截止消息之前处理到匹配 WorkerOutcome 后产生；
- `InspectionTimedOut` 不携带 Frame 或 InspectionPresentation，不替换当前模式已有的最近一次展示对象；
- 因 `ReturnHome` 或 `Shutdown` 取消的任务不产生领域事件；
- Actor 进入 `Cancelling` 后收到的匹配 `Completed` 或 `Failed` 只证明当前检查任务执行已经终止，其业务载荷被丢弃。

`InspectionCompleted` 和 `InspectionFailed` 的 `mode_session_id` 通过 `presentation.metadata` 携带；`InspectionTimedOut` 直接通过 metadata 携带。事件一经构造便不再依赖 Actor 持有的任务资源。

## 8. 领域事件过滤

App Controller 只有同时满足以下条件时，才允许 InspectionEvent 更新当前模式的展示或提示状态：

1. ApplicationLifecycle 为 `Running`；
2. AppState 为 EditMode 或 ProductionMode；
3. `InspectionCompleted` 或 `InspectionFailed` 的 `presentation.metadata.mode_session_id`，或者 `InspectionTimedOut` 的 `metadata.mode_session_id`，与当前模式一致。

其他 InspectionEvent 一律丢弃。丢弃事件只释放事件载荷，不影响 Inspection Actor 已经完成的状态转换和资源释放。

请求响应、关机等待响应和组件关闭确认不属于 InspectionEvent，不应用上述过滤规则。

## 9. 状态投影

### 9.1 Inspection Actor 投影

```text
InspectionActorProjection
├── Idle
├── Running(metadata)
└── Cancelling(metadata, fixed_cancellation_reason)
```

Inspection Actor 在任务状态提交后发布对应投影。App Controller 将该投影与当前模式纯组合：投影中的会话与当前模式不一致且 Actor 非 `Idle` 时，对 GUI 展示为 `BusyWithPreviousSession`。

投影发送方是 Inspection Actor，接收方是 App Controller。

投影只用于观察和 GUI 组合，不用于决定是否发送取消、是否接受检查、任务是否终止或关机是否可以继续。

### 9.2 Camera Actor 投影

```text
CameraActorProjection
├── NotStarted
├── Capturing
├── Stopping
└── Stopped
```

GUI 所见 `Starting` 由 ApplicationLifecycle 和 CameraActorProjection 组合得到，不是 Camera Actor 内部状态。

投影发送方是 Camera Actor，接收方是 App Controller。

### 9.3 AppViewSnapshot

```text
AppViewSnapshot
├── lifecycle
├── screen
├── camera_status
├── inspection_status
└── command_status
```

App Controller 将 AppState、ApplicationLifecycle 和组件投影纯组合为不可变 AppViewSnapshot，以替换式最新值语义发布给 GUI。发送方是 App Controller，接收方是 GUI；GUI 可以跳过中间快照。

一次性命令响应不得放入可跳过的快照；高频预览 Frame 也不进入快照，GUI 按刷新节奏从 Latest Frame Store 读取。

## 10. Camera Actor 控制消息

```text
StartCamera -> CameraCapturing

StopCameraResponse
├── CameraWasNotStarted
└── CameraStopped

StopCamera -> StopCameraResponse
```

发送方是 App Controller，接收方是 Camera Actor。

- `StartCamera` 只在应用启动期间发送；成功响应表示摄像头初始化完成、采集循环已启动且 Actor 为 `Capturing`，不等待首帧；
- `StopCamera` 在 `NotStarted` 时返回 `CameraWasNotStarted`，状态保持不变；在 `Stopped` 时幂等返回 `CameraStopped`；
- `Capturing` 中收到 `StopCamera` 后先进入 `Stopping`，停止发布 Frame，再关闭采集循环和 SDK，最后响应 `CameraStopped`；
- `Stopping` 中的重复停止附着到同一停止流程；
- `CameraStopped` 只对应 Actor 的 `Stopped` 状态，表示此后不会再发布 Frame；ApplicationLifecycle 已为 `Running` 时发起的正常关机必须得到该响应；
- 摄像头初始化、采集或关闭失败直接 `panic`。

Camera Actor 的采集结果和 Latest Frame Store 更新属于组件内部数据流，不是应用命令或检查消息。GUI 和 App Controller 均不向 Camera Actor 请求单帧。