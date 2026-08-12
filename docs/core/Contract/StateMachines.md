# 状态机规约

本文定义应用生命周期、应用模式、Inspection Actor 和 Camera Actor 的状态转换。整体规约索引见 [行为规约](../Contract.md)。

## 1. 通用约定

### 1.1 状态所有权与裁决

- App Controller 串行处理应用命令及其接收的异步事件，并唯一裁决 `ApplicationLifecycle` 和 `AppState` 的转换；
- Inspection Actor 串行处理检查申请、取消请求、计时器事件和 Worker 输出，并唯一裁决检查任务状态；
- Camera Actor 串行处理启动、停止和采集事件，并唯一裁决摄像头状态；
- 竞争事件的先后以对应状态所有者的处理顺序为准，不以事件产生时间为准；
- 状态投影和资源准备可以在状态外完成，但状态转换必须由所有者单点提交。

### 1.2 转换与致命错误

一次状态转换可以包含以下动作：校验守卫条件、取得或释放资源、设置取消信号、发布状态投影、发送响应或事件。转换提交后，对外状态和所持资源必须一致。

`panic` 是异常终止出口，不是 `Terminated` 状态。`Terminated` 仅表示优雅关机完成。过期或身份不匹配的内部事件除非另有规定，均被丢弃且不得改变状态。

### 1.3 时间语义

检查使用两类时间：

- `started_at` 是业务展示时间，使用可展示和可序列化的 UTC 时间，随检查元数据和结果传递；
- `execution_started`、`execution_deadline` 和 `cancellation_deadline` 使用进程内单调时钟，仅用于超时裁决，不进入业务结果。

Inspection Actor 接受申请时读取业务时间并写入 InspectionMetadata。Worker 成功接受任务时读取单调时间并计算执行截止时间。首次进入 `Cancelling` 时读取单调时间并计算取消截止时间；重复取消不得延长该截止时间。计时器事件必须携带 `inspection_id`，过期或身份不匹配的计时器事件直接丢弃。

## 2. ApplicationLifecycle

应用生命周期独立于 `AppState`：

```text
Starting → Running → ShuttingDown → Terminated
```

- `Starting`：初始化组件，尚不处理 GUI 命令；
- `Running`：`AppState` 有效，正常处理应用命令；
- `ShuttingDown`：关机流程已开始，不再接受新的应用命令；
- `Terminated`：组件已关闭，应用资源已释放。

转换规则：

| 当前状态 | 输入 | 下一状态 | 条件与动作 |
| --- | --- | --- | --- |
| Starting | 初始化完成 | Running | Camera Actor 已进入 `Capturing`，Home 与 `Running` 在同一启动成功边界提交；不等待首帧 |
| Starting | 初始化失败 | 异常终止 | `panic` |
| Running | 首个优雅关机请求 | ShuttingDown | 原子提交状态并异步启动关机协调流程 |
| ShuttingDown | 应用命令 | ShuttingDown | 返回 `ShuttingDown`，不执行命令内容 |
| ShuttingDown | 重复关机请求 | ShuttingDown | 附着到同一关机流程，等待同一完成结果 |
| ShuttingDown | 全部关闭步骤完成 | Terminated | 运行组件已停止，运行期资源已释放 |
| ShuttingDown | 组件关闭失败或取消宽限期耗尽 | 异常终止 | `panic` |
| Terminated | 迟到的运行期事件 | Terminated | 丢弃 |

### 2.1 关机协调

关机采用异步、严格分阶段的协调流程。等待是逻辑异步等待，不得阻塞 Actor 或异步运行时的执行线程：

1. 请求 Camera Actor 停止采集并关闭摄像头，等待 `Stopped` 确认；
2. Camera Actor 停止后，发送 `CancelCurrentForShutdown` 并等待 `InspectionBecameIdle`；Actor 已为 `Idle` 时立即响应；
3. 关闭 Inspection Worker 和各 Actor；同一阶段内无依赖的关闭操作可以并行发起并统一等待；
4. 释放原 AppState、Latest Frame Store 及其他应用资源；
5. 提交 `Terminated`，完成所有附着到本次关机的等待者。

如果关机取消首次触发 `Running → Cancelling`，取消宽限期从 Actor 实际处理 `CancelCurrentForShutdown` 时开始，不包含等待 Camera Actor 停止的时间；如果 Actor 已在取消中，关机等待附着到原流程且不重置截止时间。进入 `ShuttingDown` 后，正常命令接收边界必须继续能够立即拒绝后续命令，不得等到关机完成后才返回。

`ShuttingDown` 不属于 GUI 业务模式，进入后不可返回 `Running`。原 `AppState` 不再是有效业务状态，不再接受观察或操作；App Controller 只为完成关机而持有并释放其资源，不需要先转换为 Home。

## 3. AppState

`AppState` 仅在 ApplicationLifecycle 为 `Running` 时有效：

```text
Home
EditMode(mode_session_id, config_path, draft_config, optional_presentation)
ProductionMode(mode_session_id, config_path, loaded_config, production_plan, optional_presentation)
```

模式转换：

| 当前状态 | 输入 | 下一状态 | 条件 |
| --- | --- | --- | --- |
| Home | 进入编辑模式 | EditMode | 配置读取、解析和校验成功 |
| Home | 进入生产模式 | ProductionMode | 配置读取、校验和方案构建成功 |
| Home | 返回主页 | Home | 幂等成功 |
| EditMode | 返回主页 | Home | 无 |
| ProductionMode | 返回主页 | Home | 无 |

模式进入采用状态外准备和单点提交，不增加显式过渡状态。准备期间 App Controller 保持原状态并继续占有串行处理权，后续命令和异步事件等待处理。准备失败时释放临时资源并保留原状态。GUI 如需展示命令正在执行，应使用命令状态投影，不增加 AppState 过渡状态。

### 3.1 命令与状态矩阵

| 命令 | Home | EditMode | ProductionMode |
| --- | --- | --- | --- |
| 进入编辑模式 | 执行 | `InvalidMode` | `InvalidMode` |
| 进入生产模式 | 执行 | `InvalidMode` | `InvalidMode` |
| 返回主页 | 幂等成功 | 执行 | 执行 |
| 修改草稿 | `InvalidMode` | 执行 | `InvalidMode` |
| 校验草稿 | `InvalidMode` | 执行 | `InvalidMode` |
| 保存草稿 | `InvalidMode` | 执行 | `InvalidMode` |
| 发起测试检查 | `InvalidMode` | 执行 | `InvalidMode` |
| 发起生产检查 | `InvalidMode` | `InvalidMode` | 执行 |

表中的“执行”仍可产生对应命令定义的业务错误。`InvalidMode` 至少应包含命令、实际模式和期望模式。ApplicationLifecycle 不是 `Running` 时，先按生命周期规则拒绝命令，不进入本矩阵裁决。

### 3.2 Home 文件选择状态

Home 不持有文件选择结果。文件选择对话框状态、候选路径和取消结果属于 GUI 本地交互状态。进入编辑模式或生产模式时，GUI 将选定路径作为命令输入提交；只有转换成功后，路径才由新模式持有。

### 3.3 GUI 可观察状态投影

GUI 不持有或长期借用 App Controller 的 `AppState`。各 Actor 以替换式最新值语义发布不可变的组件状态投影，App Controller 将自身领域状态与这些投影纯组合为不可变 `AppViewSnapshot`；GUI 通过订阅接收快照并替换其本地持有值：

```text
AppViewSnapshot
├── lifecycle
├── screen
├── camera_status
├── inspection_status
└── command_status
```

约束：

- 组件投影和 AppViewSnapshot 的组合计算本身不产生副作用；发布投影或快照是独立的边界副作用；
- GUI 只在单次 `view` 构造期间读取其本地快照，不持有领域状态的锁或借用；
- 快照使用替换式最新值语义，允许跳过中间版本，不得积压状态更新；
- 一次性命令结果和提示使用事件传递，当前模式、摄像头状态和检查状态使用最新值快照；
- 高频预览帧不放入完整快照，GUI 按刷新节奏从 Latest Frame Store 取得不可变 Frame 的共享引用；
- 从旧模式返回 Home 后仍在取消的任务，以及随后进入新模式时遗留任务造成的占用，应投影为 `BusyWithPreviousSession`，不得错误显示为可发起检查；
- ApplicationLifecycle 为 `Starting`、`ShuttingDown` 或 `Terminated` 时，不提供可操作的业务模式界面。

## 4. Inspection Actor

Inspection Actor 的组件生命周期与任务状态分离：

```text
InspectionActorLifecycle:
Active → Closing → Closed

InspectionTaskState（仅 Active 时有效）:
Idle

Running
├── metadata
├── execution_started
├── execution_deadline
├── cancellation
├── pinned_frame
└── pinned_plan

Cancelling
├── running_context
├── cancellation_reason
└── cancellation_deadline
```

### 4.1 申请与 Worker 提交

Inspection Actor 在 `Idle` 中接受合法申请时：

1. 生成 `inspection_id` 并读取业务时间 `started_at`；
2. 使用申请字段、`inspection_id` 和 `started_at` 构造完整且不可变的 InspectionMetadata；
3. 创建取消信号并准备固定帧和固定方案的任务；
4. 向 Worker 提交任务；
5. Worker 成功接受任务时读取单调时间，设置执行截止时间并单点提交 `Running`；
6. 发布最新状态投影并返回包含 InspectionMetadata 的申请成功响应。

Worker 成功接收任务即定义为 Worker 接受任务，不增加 `Submitting` 状态。任务提交失败属于内部基础设施失效，直接 `panic`，不执行状态回滚。

| 当前状态 | 检查申请 | 结果 |
| --- | --- | --- |
| Idle | 合法申请 | 接受并转入 `Running` |
| Running | 任意申请 | 保持 `Running`，返回 `Busy` |
| Cancelling | 任意申请 | 保持 `Cancelling`，返回 `Busy` |

### 4.2 运行终止

| 当前状态 | 输入 | 下一状态 | 对外结果 |
| --- | --- | --- | --- |
| Running | 匹配的 `Completed` | Idle | 发布检查完成事件 |
| Running | 匹配的 `Failed` | Idle | 发布检查失败事件 |
| Running | 匹配的 `Cancelled` | 异常终止 | 未请求取消却收到取消结果，视为内部不变量破坏 |
| Running | 匹配的执行超时事件 | Cancelling | 设置取消信号，原因固定为 `Timeout` |
| Idle | Worker 输出或计时器事件 | Idle | 作为过期事件丢弃 |
| 任意任务状态 | 身份不匹配的 Worker 输出或计时器事件 | 保持原状态 | 丢弃 |

正常完成或失败时，Actor 组装对应事件、释放其持有的帧和方案，并发布 `Idle` 投影。

### 4.3 会话级取消与关机取消

`ModeSessionId` 用于模式事件隔离，并在返回 Home 时限定取消意图；`inspection_id` 用于唯一标识具体任务、Worker 输出和计时器。两者不得互相替代。

返回 Home 时，App Controller 离开原模式并无条件发送：

```text
CancelInspectionForSession(mode_session_id, ReturnHome)
```

该通知不携带 `inspection_id`，也不要求响应。Inspection Actor 只将 `mode_session_id` 与当前唯一任务的 metadata 比较；它不维护会话任务集合，不使用“取消该会话及以前任务”的范围语义。

优雅关机在 Camera Actor 已停止后发送：

```text
CancelCurrentForShutdown -> InspectionBecameIdle
```

该请求取消 Actor 当前唯一任务或在 `Idle` 时立即响应。响应在任务终止、资源释放且 Actor 回到 `Idle` 后完成；如果 Actor 已在取消中，关机等待附着到原取消流程。

取消处理规则：

| 当前状态 | 输入 | 下一状态 | 结果 |
| --- | --- | --- | --- |
| Idle | 会话取消 | Idle | 忽略 |
| Idle | 关机取消 | Idle | 立即响应 `InspectionBecameIdle(None)` |
| Running | 会话匹配的会话取消 | Cancelling | 设置取消信号，原因固定为 `ReturnHome` |
| Running | 会话不匹配的会话取消 | Running | 作为过期通知忽略 |
| Running | 关机取消 | Cancelling | 设置取消信号，原因固定为 `Shutdown`，关机请求等待 |
| Cancelling | 会话匹配的会话取消 | Cancelling | 保持原原因和截止时间 |
| Cancelling | 会话不匹配的会话取消 | Cancelling | 作为过期通知忽略 |
| Cancelling | 关机取消 | Cancelling | 关机请求附着等待；不覆盖原因，不延长截止时间 |

第一个被 Actor 处理并触发 `Running → Cancelling` 的原因固定为最终取消原因。后续取消只能保持或附着等待。迟到的旧会话取消不得影响新会话任务。

### 4.4 Cancelling 的终止语义

Worker 对每个任务只产生一个终止输出：`Completed`、`Failed` 或 `Cancelled`。Actor 已进入 `Cancelling` 后，匹配当前 `inspection_id` 的任一终止输出都证明当前检查任务执行已经终止：

| 输入 | 下一状态 | 处理 |
| --- | --- | --- |
| 匹配的 `Completed` | Idle | 丢弃核心输出，完成取消 |
| 匹配的 `Failed` | Idle | 丢弃执行错误，完成取消 |
| 匹配的 `Cancelled` | Idle | 完成取消 |
| 匹配的取消宽限期超时 | 异常终止 | `panic` |
| 不匹配的终止输出或计时器事件 | Cancelling | 丢弃 |

进入 `Cancelling` 后不得再生成正常检查结果或失败展示。Actor 在 Worker 停止后释放任务资源、切换为 `Idle`，并完成附着的关机等待响应。

- 取消原因为 `Timeout` 时，发布携带 InspectionMetadata 的 `InspectionTimedOut`；该事件只在 Worker 已于宽限期内停止后发布，不携带 Frame 或 InspectionPresentation，也不替换最近一次展示对象；
- 取消原因为 `ReturnHome` 或 `Shutdown` 时，不生成领域事件；
- 返回 Home 不等待取消完成；
- 优雅关机必须等待 `InspectionBecameIdle` 响应。

### 4.5 完成与取消的竞争

- Actor 先处理匹配的完成或失败输出时，任务按对应结果结束；随后到达的会话取消被忽略，关机取消立即响应 `InspectionBecameIdle(None)`；
- Actor 先处理取消请求并进入 `Cancelling` 时，之后到达的任一匹配终止输出只用于证明当前检查任务执行已经终止，其业务输出一律丢弃；
- Actor 先处理执行超时时，超时成为固定取消原因；
- App Controller 进入 `ShuttingDown` 后不得用迟到的检查事件更新 GUI。

### 4.6 Actor 关闭

- 只有任务状态为 `Idle` 时才能从 `Active` 进入 `Closing`；
- `Running` 或 `Cancelling` 时的关闭请求表示关机协调顺序错误；
- `Closed` 表示不再接收检查请求、内部计时器已取消、通信资源已释放；
- 重复关闭可以幂等确认 `Closed`；
- 具体关闭消息和确认类型在消息规约中定义。

## 5. Camera Actor

Camera Actor 状态：

```text
NotStarted → Capturing → Stopping → Stopped
```

- `NotStarted`：尚未取得摄像头资源，允许在应用启动期间执行一次启动；
- `Capturing`：持续采集并发布不可变 Frame；
- `Stopping`：已处理停止请求，正在停止采集循环并关闭 SDK 资源；
- `Stopped`：采集循环和 SDK 已关闭，不会再发布 Frame，v1 不允许重新启动。

不设置独立 `Starting` 状态；Camera Actor 的初始化过程由 ApplicationLifecycle 的 `Starting` 覆盖。`NotStarted` 与 `Stopped` 不合并，因为二者允许的后续转换不同，合并后启动是否合法将依赖隐藏历史。

转换规则：

| 当前状态 | 输入 | 下一状态 | 结果 |
| --- | --- | --- | --- |
| NotStarted | 启动 | Capturing | 初始化摄像头并开始采集 |
| NotStarted | 停止 | NotStarted | 幂等确认尚未运行 |
| Capturing | 停止 | Stopping | 停止发布新帧，开始关闭采集循环和 SDK |
| Stopping | 重复停止 | Stopping | 附着到已有停止流程，不重复关闭 |
| Stopping | 关闭完成 | Stopped | 发布停止确认 |
| Stopping 或 Stopped | 迟到采集结果 | 保持原状态 | 丢弃，不发布 Frame |
| Stopped | 重复停止 | Stopped | 幂等确认已停止 |
| Stopped | 启动 | Stopped | 拒绝；v1 不支持摄像头重启 |
| 任意相关状态 | 初始化、采集或关闭失败 | 异常终止 | `panic` |

应用启动成功前，Camera Actor 必须进入 `Capturing`。一旦处理停止请求并进入 `Stopping`，不得再向 Latest Frame Store 发布新帧。`Stopped` 确认表示：

- 采集循环已经停止；
- 摄像头 SDK 资源已经关闭；
- 不会再发布新 Frame；
- 之前发布或由检查固定的 Frame 仍可通过共享引用继续存活。

GUI 摄像头状态投影至少区分 `Starting`、`Capturing`、`Stopping` 和 `Stopped`。其中 `Starting` 是 ApplicationLifecycle 与 Camera Actor 状态组合得到的展示状态，不是 Camera Actor 的内部状态。v1 的摄像头故障直接终止进程，不设置可恢复的 `Error` 展示状态。
