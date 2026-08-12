# 视觉检测系统架构

## 1. 文档目的

本文定义视觉检测系统的组件划分、状态所有权、依赖方向和执行边界。

具体的跨组件行为、状态转换、并发裁决和资源生命周期见 [Contract.md](./Contract.md)。版本目标与范围见 [Scope.md](./Scope.md)。

## 2. 总体结构

```text
Camera Actor
    │ 发布不可变帧
    ▼
Latest Frame Store
    ├────────────────────────────→ GUI 预览
    └────────────────────────────→ App Controller 固定检查帧

GUI
    │ 应用命令
    ▼
App Controller
    ├────────────────────────────→ Scheme Manager ──→ 配置文件
    └────────────────────────────→ Inspection Actor
                                       │ 固定的帧与检查方案
                                       ▼
                                Inspection Worker
                                       │
                                       ▼
                                Inspection Core
                                       │
                                       ▼
                                Inspection Actor
                                       │ 检查事件
                                       ▼
                                App Controller
                                       │ 当前模式的展示状态
                                       ▼
                                      GUI
```

组件分工：

- App Controller 唯一持有应用模式状态，串行处理模式相关命令；
- Actor 管理设备或检查执行状态及其副作用；
- Latest Frame Store 发布最新的不可变帧；
- Scheme Manager 提供配置文件和方案构建操作；
- Inspection Worker 隔离同步检查计算；
- Inspection Core 执行无外部业务副作用的图像处理；
- GUI 发送应用命令并展示状态和结果。

## 3. 应用状态与控制

### 3.1 ApplicationLifecycle

```text
Starting → Running → ShuttingDown → Terminated
```

ApplicationLifecycle 描述应用进程生命周期，独立于 GUI 业务模式。`AppState` 仅在 `Running` 期间有效。进入 `ShuttingDown` 后拒绝后续普通命令，并启动异步、严格分阶段的关机协调：先停止 Camera Actor，再取消并等待当前检查，随后关闭 Worker 和 Actor、释放应用资源。异步等待不得阻塞 Actor 或运行时执行线程。

### 3.2 AppState

```text
AppState
├── Home
├── EditMode
└── ProductionMode
```

三个状态互斥，由 App Controller 唯一持有。应用状态的定义和转换不属于 GUI 展示逻辑。

```text
EditMode
├── mode_session_id: ModeSessionId
├── config_path
├── draft_config
└── optional_presentation

ProductionMode
├── mode_session_id: ModeSessionId
├── config_path
├── loaded_config
├── production_plan
└── optional_presentation
```

Home 不持有文件选择结果、检查配置、检查方案或 `ModeSessionId`。文件选择对话框和候选路径属于 GUI 本地交互状态。ProductionMode 的方案始终有效且不可变。

### 3.3 App Controller

App Controller 的职责：

- 持有唯一的 `AppState`；
- 持有并转换 `ApplicationLifecycle`；
- 串行执行模式转换并维护模式资源；
- 创建和管理 `ModeSessionId`；
- 调用 Scheme Manager 完成配置操作；
- 从 Latest Frame Store 固定检查使用的帧；
- 向 Inspection Actor 提交已经完成模式级准备的检查请求；
- 接收检查事件，将领域状态纯投影为不可变的 GUI 最新值快照；
- 返回主页时按 `inspection_id` 精确取消任务，关机时在摄像头停止后取消当前任务。

GUI、Scheme Manager 和 Inspection Actor 均不持有 `AppState` 副本。Inspection Actor 不读取共享的应用模式。

## 4. 帧与采集

### 4.1 Frame

```text
Frame
├── frame_id
├── captured_at
├── image_data
└── camera_metadata
```

Frame 在发布后不可变，通过共享引用在组件之间传递。图像内存归应用所有，不依赖 Camera SDK 缓冲区的后续生命周期。

### 4.2 Camera Actor

Camera Actor 是摄像头及其 SDK 的唯一访问者，负责：

- 初始化和关闭摄像头；
- 在独立执行环境中执行阻塞采集；
- 复制采集图像并构造不可变 Frame；
- 分配唯一 `frame_id`；
- 更新 Latest Frame Store；
- 暴露运行状态。

Camera Actor 不等待 GUI 或检查任务，不执行检查逻辑，不读写配置，也不建立待处理帧队列。

状态模型：

```text
NotStarted → Capturing → Stopping → Stopped
```

- `NotStarted` 只在应用启动期间允许启动；
- `Capturing` 跨所有 AppState 持续采集；
- `Stopping` 停止采集循环并关闭 SDK，进入后不再发布新 Frame；
- `Stopped` 表示 SDK 已关闭且不会再发布 Frame，v1 不允许重新启动。

Camera Actor 不设置独立 `Starting` 状态，初始化过程由 ApplicationLifecycle 的 `Starting` 覆盖。初始化、采集或关闭失败时直接 `panic`。已发布或由检查固定的 Frame 不受摄像头停止影响。

### 4.3 Latest Frame Store

Latest Frame Store 是当前最新帧的唯一可信入口：

- Camera Actor 是唯一写入者；
- GUI 和 App Controller 可以读取；
- Store 只保存一个最新帧共享引用；
- 替换不修改旧帧，也不等待消费者。

GUI 用其预览，App Controller 用其固定检查输入。

## 5. 配置与检查方案

### 5.1 配置模型

```text
InspectionSchemeConfig
├── scheme_id
├── revision
├── name
├── stages[]
└── decision_rule

StageConfig
├── operator_id
├── enabled
└── parameters
```

程序维护固定的检查算子注册表。配置只引用已注册算子，不包含可执行代码或任意函数地址。

### 5.2 Inspection Plan

Inspection Plan 是从有效配置构建的不可变执行方案。它按线性顺序描述要执行的算子及最终判定规则。

生产方案由 ProductionMode 持有；测试方案只由对应的单次检查任务持有。两者均不使用空值表示缺少方案，但阶段列表可以为空。

### 5.3 Scheme Manager

Scheme Manager 不持有 AppState、当前模式、编辑草稿或当前方案。其职责：

- 读取和解析指定配置文件；
- 校验配置；
- 构建不可变 Inspection Plan；
- 保存 App Controller 提供的有效草稿；
- 返回配置与方案构建错误。

文件访问和持久化副作用集中在该边界内。

## 6. 检查执行

### 6.1 Inspection Actor

Inspection Actor 串行管理测试检查和生产检查。其组件生命周期与任务状态分离：

```text
InspectionActorLifecycle:
Active → Closing → Closed

InspectionTaskState（仅 Active 时有效）:
Idle

Running
├── metadata
├── started_at
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

`started_at` 是业务 UTC 时间；执行起点和两个截止时间使用进程内单调时钟。Inspection Actor 接收已经固定帧和方案的请求，不读取 AppState、Latest Frame Store 或配置文件。

`Running` 和 `Cancelling` 均持有任务资源并拒绝新检查。第一个触发 `Cancelling` 的原因固定，重复取消不覆盖原因或延长截止时间。`Cancelling` 持续到收到当前任务匹配的 `Completed`、`Failed` 或 `Cancelled`；三者均证明 Worker 已停止，但取消后的完成输出和失败错误不进入业务结果。任务回到 `Idle` 后，Actor 才能关闭。

### 6.2 InspectionMetadata

```text
InspectionMetadata
├── inspection_id
├── mode_session_id
├── inspection_kind
├── frame_id
├── scheme_id
└── scheme_revision
```

`inspection_kind` 为 `Test` 或 `Production`。元数据随请求结果和异步事件传递。

### 6.3 Inspection Worker

Inspection Worker 在独立工作线程中同步执行 Inspection Core，同一时间只执行一个任务。

它接收 Actor 固定的帧、方案和取消信号，每个任务只返回一个终止输出：核心输出、检查错误或取消结果。任务成功提交到 Worker 任务入口即定义为 Worker 已接受。Worker 不管理应用状态，不访问帧存储、GUI 或配置文件，也不强制终止工作线程。

### 6.4 Inspection Core

概念接口：

```text
inspect(frame, inspection_plan, cancellation) -> inspection_core_outcome
```

Inspection Core：

- 按 Inspection Plan 的线性顺序执行算子；
- 只使用显式输入；
- 不访问摄像头、帧存储、配置文件或 GUI；
- 不执行持久化或修改全局业务状态；
- 通过显式取消信号协作取消。

概念输出：

```text
InspectionCoreOutcome
├── Completed(InspectionCoreOutput)
├── Cancelled
└── Failed(InspectionError)

InspectionCoreOutput
├── decision
├── measurements
├── defects
└── optional_visualization
```

Inspection Actor 将核心输出与元数据组装为应用层检查结果。

## 7. GUI

GUI 使用 iced 实现，负责：

- 展示应用模式对应的界面；
- 显示摄像头状态；
- 选择配置文件；
- 预览最新帧；
- 编辑配置草稿；
- 发起测试或生产检查；
- 显示检查状态、结果和错误。

GUI 不直接转换 AppState，不直接访问 Camera Actor 或 Inspection Actor，也不执行 Inspection Core。

GUI 按自身刷新节奏读取最新帧，允许跳帧且不维护待显示帧队列。

GUI 不持有或长期借用 AppState。各 Actor 以替换式最新值语义发布不可变的组件状态投影，App Controller 将其与自身领域状态纯组合为不可变 `AppViewSnapshot`；GUI 订阅快照并替换本地持有值，允许跳过中间版本。一次性命令结果使用事件传递，预览帧不进入完整快照。旧模式任务尚未终止时，当前模式的检查状态投影为 `BusyWithPreviousSession`。

## 8. 依赖与所有权约束

1. Camera Actor 是摄像头的唯一访问者，也是 Latest Frame Store 的唯一写入者。
2. 已发布的 Frame 和已构建的 Inspection Plan 始终不可变。
3. App Controller 是 AppState 的唯一所有者。
4. Scheme Manager 不持有模式状态或当前方案。
5. Inspection Actor 不读取 AppState、Latest Frame Store 或配置文件。
6. Inspection Core 只在 Inspection Worker 中运行。
7. 同一时间最多运行一个检查任务。
8. 检查任务持有自身固定的帧和方案。
9. Inspection Core 及其算子不执行外部业务副作用。
10. GUI 不积压预览帧，也不承载检查计算。
11. GUI 不持有或长期借用 AppState，只持有不可变的最新状态快照。
12. 返回 Home 使用 `inspection_id` 精确取消任务；`ModeSessionId` 只负责模式会话隔离。
13. Camera Actor 进入 `Stopping` 后不再发布 Frame。
