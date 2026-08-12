# 资源生命周期规约

本文定义视觉检测系统 v1 运行期资源的创建、持有、共享、转移和释放边界。整体规约索引见 [行为规约](../Contract.md)，所有权术语见 [文档通用约定](../../README.md#资源与所有权术语)。

资源的逻辑有效期与底层对象的物理存活期相互独立。组件释放自身持有的共享引用后，不得再把对应资源视为当前领域状态；其他事件、快照或 GUI 本地值持有的共享引用可以使不可变对象继续存活。

## 1. 通用约束

- 跨组件传递的 Frame、Inspection Plan、InspectionPresentation 和状态快照必须不可变，不得携带发送方内部状态的借用；
- 状态所有者必须使状态转换与资源变化在同一提交边界保持一致；
- 状态外准备产生的临时资源只有在操作成功提交后才能成为领域状态资源；
- 操作失败、申请被拒绝、消息被丢弃或事件被过滤时，未提交资源随当前操作或消息释放；
- 释放共享引用只结束当前持有者的所有权；底层对象在最后一个共享引用释放后销毁；
- 借用不得越过所属同步调用、采集回调或单次 GUI `view` 构造边界；
- App Controller、Actor 和 GUI 不得依靠对象仍然存活来推断对应模式、任务或组件仍然有效；
- 内部通信基础设施失效或既定的组件致命错误可以直接 `panic`，不要求执行可观察的业务级资源回滚。

## 2. Frame 与采集缓冲区

### 2.1 创建与发布

Camera Actor 是 Camera SDK 及其采集缓冲区的唯一访问者。每次成功采集后：

1. 在 SDK 允许复用或释放采集缓冲区前，将完整图像复制到应用拥有的内存；
2. 复制摄像头元数据，生成应用运行期间唯一的 `frame_id`；
3. 构造不可变 Frame；
4. 取得 Frame 的共享引用并发布到 Latest Frame Store。

Frame 不得保存对 SDK 缓冲区的借用。复制、元数据构造或 Frame 构造未完成时不得发布部分 Frame；摄像头初始化、采集、复制或关闭失败按摄像头致命错误处理。

### 2.2 发布后的所有权

- 已发布 Frame 的图像数据和元数据不得修改或复用；
- Camera Actor 发布后不等待消费者，也不维护待消费帧队列；
- Store、GUI 预览、检查任务、InspectionPresentation 和状态快照可以分别持有同一 Frame 的独立共享引用；
- 任一持有者释放自己的引用不影响其他持有者；
- Frame 在最后一个共享引用释放后销毁；
- Camera Actor 停止不使已经发布或固定的 Frame 失效。

### 2.3 Camera SDK 资源

- `NotStarted` 不持有已初始化的 Camera SDK 设备资源；
- 处理启动请求时，Camera Actor 临时取得初始化资源；只有设备初始化完成且采集循环已启动后，才提交 `Capturing`；
- `Capturing` 期间 Camera Actor 唯一持有设备和采集循环资源；
- 处理停止请求并提交 `Stopping` 后，Camera Actor 停止发布，结束采集循环并关闭 SDK；该关闭流程只执行一次；
- `Stopped` 表示采集循环和 SDK 资源均已释放，v1 不允许重新取得设备资源；
- 初始化、采集或关闭失败直接 `panic`。

## 3. Latest Frame Store

Latest Frame Store 在 Camera Actor 启动前创建，初始为空。Camera Actor 是唯一写入者；GUI 和 App Controller 只能读取。

- Store 只持有一个最新 Frame 的共享引用；
- 发布新帧时，以新引用原子替换旧引用，并释放 Store 对旧帧的引用；
- 替换不得修改旧帧，也不得等待仍持有旧帧的消费者；
- 每次读取返回读取边界上最新 Frame 的独立共享引用；尚未发布帧时返回无帧；
- Camera Actor 进入 `Stopping` 后不得再更新 Store；迟到的采集结果必须丢弃；
- Camera Actor 进入 `Stopped` 时 Store 可以继续持有最后一帧；
- 关机资源释放阶段清空并释放 Store。该操作只释放 Store 自己的引用，不使其他持有者的 Frame 失效。

## 4. GUI 预览 Frame

高频预览 Frame 不进入 AppViewSnapshot。GUI 按自身刷新节奏从 Latest Frame Store 读取，并使用替换式最新值语义：

- GUI 最多持有一个当前预览 Frame 的共享引用，不建立预览历史队列；
- 读取到新的 `frame_id` 时，以新引用替换旧引用并释放旧引用；
- `frame_id` 未变化时可以继续使用已有引用；
- Store 为空时，GUI 释放本地预览引用并展示无预览帧；
- GUI 退出或不再提供预览界面时释放本地预览引用；
- 预览引用与检查固定引用互不转移，也互不影响。

## 5. 模式状态资源

App Controller 是 AppState 及其模式资源的唯一领域所有者。

| AppState | 持有的模式资源 |
| --- | --- |
| Home | 不持有配置路径、配置、草稿、方案、展示对象或 `ModeSessionId` |
| EditMode | `ModeSessionId`、配置路径、Draft Config、可选 InspectionPresentation |
| ProductionMode | `ModeSessionId`、配置路径、已加载配置、不可变生产 Inspection Plan、可选 InspectionPresentation |

### 5.1 进入模式

进入 EditMode 或 ProductionMode 时，配置读取、解析、校验、方案构建以及新 `ModeSessionId` 的创建均属于状态外准备：

- 准备期间 App Controller 保持 Home，并临时持有准备结果；
- 只有全部步骤成功后，临时资源才随新 AppState 一次性提交为模式资源；
- 任一步骤失败时释放全部临时资源，Home 及其资源保持不变；
- GUI Home 中的文件选择对话框状态和候选路径始终属于 GUI 本地资源，只有命令成功后，命令输入的路径值才成为模式资源。

### 5.2 离开模式

返回 Home 时，App Controller：

1. 记录被关闭模式的 `ModeSessionId`；
2. 提交 Home；
3. 释放原模式持有的配置路径、配置或草稿、生产方案及 InspectionPresentation；
4. 发送该会话的取消通知。

模式资源的释放不影响 Inspection Actor 已经为任务固定的 Frame 和 Inspection Plan。Home 中重复返回 Home 不创建或释放模式资源，也不发送取消通知。

进入 `ShuttingDown` 后，原 AppState 不再是有效业务状态。App Controller 只为推进关机而暂时持有其资源，并在关机资源释放阶段统一释放，不必先转换为 Home。

## 6. Draft Config 与配置临时资源

- Draft Config 由 EditMode 唯一持有；
- 修改草稿采用先校验、后提交，失败的字段修改不得改变现有草稿；
- 修改、校验和测试检查不写配置文件，也不创建或修改生产方案；
- 测试检查的方案构建输入来自命令处理边界上的当前草稿快照；后续草稿修改不影响已接受任务；
- 返回 Home 或关机资源释放时，EditMode 释放 Draft Config；
- 配置读取结果、解析中间值、部分构建结果和待保存配置均为同步操作的临时资源，失败时不得进入 AppState。

保存草稿时：

1. 为可构建性验证创建的 Inspection Plan 只属于当前保存命令，不进入 EditMode；
2. 临时文件在原子替换成功前属于保存事务资源；
3. 保存失败时释放验证方案及临时资源，内存草稿和原文件保持未提交状态；
4. 原子替换成功后，内存草稿的 `revision` 在同一命令完成边界同步为已提交值；
5. 验证方案在保存命令结束时释放，不成为生产方案。

## 7. Inspection Plan

Inspection Plan 由 Scheme Manager 从有效配置完整构建，是不可变的跨组件资源。部分构建结果不得作为 Inspection Plan 发布。

### 7.1 生产方案

- ProductionMode 持有生产方案的共享引用；
- 发起生产检查时，申请取得独立共享引用；
- 申请返回 `Busy` 时只释放申请引用，ProductionMode 继续持有生产方案；
- 返回 Home 或关机释放 ProductionMode 时，释放模式引用；已接受任务持有的引用继续有效。

### 7.2 测试方案

- 测试方案在 `StartTestInspection` 命令中根据当前草稿临时构建；
- 方案构建失败时不得提交检查申请；
- 申请被拒绝时，申请引用释放；没有其他持有者时方案随之销毁；
- 申请成功后，方案只由对应任务相关持有者继续持有，不进入 EditMode。

生产方案和测试方案均不得使用空引用表示缺少方案，但其可执行阶段列表可以为空。Inspection Actor 和 Inspection Worker 不构建或组装方案。

## 8. 检查申请与任务上下文

### 8.1 提交前

App Controller 完成模式级准备后，从 Latest Frame Store 读取最新 Frame，并将其固定为申请输入：

- 没有可用 Frame 时返回 `NoFrame`，不构造或提交检查申请；
- Inspection Actor 不再次读取 Latest Frame Store；
- 后续发布的新帧不影响该申请或已接受任务；
- SubmitInspection 独立持有 Frame 和 Inspection Plan 的共享引用；
- 申请返回 `Busy` 时，申请及其共享引用随响应处理结束而释放。

### 8.2 接受与运行

Inspection Actor 在 `Idle` 接受申请后创建完整任务上下文：

```text
InspectionTaskContext
├── InspectionMetadata
├── pinned_frame: Shared<Frame>
├── pinned_plan: Shared<InspectionPlan>
├── CancellationSignal
├── execution timer
├── optional cancellation timer
└── attached shutdown waiters
```

- Actor 向 Worker 提交 metadata、Frame、Inspection Plan 和取消信号；Actor 与 Worker 分别持有执行期间所需的独立引用；
- Worker 成功接受任务后，Actor 才将任务上下文提交为 `Running`；
- 申请成功响应中的 InspectionMetadata 是不可变值，不向 App Controller 转移任务资源，也不得被用作任务状态的第二可信来源；
- Worker 提交失败属于内部通信基础设施失效，直接 `panic`，不定义业务级回滚。

CancellationSignal 是单任务、协作式同步资源：

- Inspection Actor 持有触发端，Worker 和 Inspection Core 只持有观察端；
- 只有 Inspection Actor 可以设置取消状态，Worker 和 Inspection Core 不得复位或替换该状态；
- 信号不得存入全局状态，也不得跨任务复用；
- 任务结束后，Actor 与 Worker 分别释放自身句柄；最后一个句柄释放后销毁信号。

### 8.3 取消期间

进入 `Cancelling` 时保留完整运行上下文，并增加固定取消原因和取消截止时间：

- 首次取消设置现有 CancellationSignal，不创建第二个任务上下文；
- 重复取消不覆盖原因、不延长截止时间，也不增加 Frame 或 Inspection Plan 的持有副本；
- 关机等待者只附着到当前取消流程，不取得任务资源所有权；
- `Cancelling` 持续到收到当前 `inspection_id` 匹配的 Worker 终止输出；系统不强制终止 Worker 线程。

### 8.4 任务终止

Worker 对每个已接受任务只产生一个终止输出，并在执行结束后释放自身持有的 Frame、Inspection Plan 和执行资源。Inspection Actor 处理输出时：

- 不匹配、过期或 Actor 已为 `Idle` 的输出整体丢弃，并释放其中的核心输出或错误载荷；
- `Running` 中匹配的 `Completed` 或 `Failed` 先构造独立的领域事件，再撤销或失效任务计时器、释放 Actor 的任务上下文并进入 `Idle`；
- `Cancelling` 中匹配的任一终止输出只证明 Worker 已停止，Completed 的核心输出和 Failed 的错误均被释放，不构造正常结果或失败展示；
- 取消完成后撤销或失效全部任务计时器，释放 Actor 的任务上下文并进入 `Idle`；
- 附着的关机等待响应只在任务资源已释放且 Actor 已进入 `Idle` 后完成；
- 因 Timeout 取消时，只发布不携带 Frame 或 InspectionPresentation 的 InspectionTimedOut；ReturnHome 或 Shutdown 取消不发布领域事件；
- Worker 未在取消宽限期内停止时直接 `panic`。

过期计时器消息只携带标识，不持有任务 Frame 或 Inspection Plan；撤销失败但可通过标识判定为过期的计时器消息必须被忽略。

Inspection Core 的阶段中间值和算子临时资源只由当前 Worker 调用持有，不进入 Actor、AppState 或全局缓存。正常完成时只有 InspectionCoreOutput 随终止输出转移；失败或取消时释放全部中间值。

## 9. Worker 输出与领域事件载荷

- WorkerOutcome 的业务载荷由 Worker 转移给 Inspection Actor；发送后 Worker 不再访问该载荷；
- Actor 丢弃 Completed 或 Failed 输出时必须同时释放对应的 InspectionCoreOutput 或 InspectionError；
- 正常完成或失败事件一经构造，必须能够独立于 Actor 的任务上下文继续存活；
- Inspection Actor 发送领域事件后不保留事件或 InspectionPresentation 的领域副本；
- App Controller 按 ApplicationLifecycle、AppState 和 `ModeSessionId` 过滤领域事件；被过滤事件的全部载荷随事件释放；
- 请求响应、关闭确认和关机等待响应不属于模式领域事件，不适用模式事件过滤规则。

## 10. InspectionPresentation

InspectionPresentation 是不可变展示对象，至少持有关联检查 Frame，并包含成功的 InspectionResult，或失败的 InspectionError 及对应元数据。

### 10.1 创建与转移

- Inspection Actor 只在 `Running` 中处理匹配的 Completed 或 Failed 输出时构造 InspectionPresentation；
- Presentation 取得关联 Frame 的独立共享引用，因此 Actor 随后释放任务引用不会使展示帧失效；
- Actor 通过领域事件将 Presentation 转移给 App Controller，不在 Actor 状态中保留副本；
- 超时、返回 Home 或关机取消均不构造 Presentation。

### 10.2 领域所有权与替换

App Controller 当前模式的 `optional_presentation` 是最近一次检查展示的唯一领域真值：

- 会话匹配的完成或失败事件使 App Controller 原子替换当前 Presentation；
- 替换时释放 AppState 对旧 Presentation 及关联 Frame 的共享引用；其他旧快照仍可使对象继续存活；
- 会话不匹配、当前为 Home 或 ApplicationLifecycle 不是 `Running` 时，事件被丢弃，不改变当前 Presentation；
- InspectionTimedOut 不替换现有 Presentation；
- 发起新检查、修改草稿、校验草稿或保存草稿不清除现有 Presentation；
- 返回 Home 或关机资源释放时，App Controller 释放模式持有的 Presentation。

展示规则：成功且存在可视化数据时在关联帧上显示标记；成功但没有可视化数据时显示关联帧和文字结果；失败时显示关联帧和错误。

## 11. 状态投影与 AppViewSnapshot

Actor Projection 和 AppViewSnapshot 是不可变最新值资源：

- Actor Projection 不得持有任务 Frame、Inspection Plan、CancellationSignal、计时器或响应句柄；
- App Controller 将领域状态和组件投影纯组合为 AppViewSnapshot；组合过程不产生副作用；
- AppViewSnapshot 不得借用 AppState，可以持有独立值或不可变共享引用；
- App Controller 的发布边界只保留最新快照，被替换或被跳过的快照释放其引用；
- GUI 收到快照后以替换方式更新本地值，不积压快照历史；
- GUI 只在单次 `view` 构造中借用本地快照；
- GUI 持有旧快照可以延长 Presentation 和 Frame 的物理生命周期，但不得延长旧模式或旧会话的逻辑有效期；
- 一次性命令响应不进入可跳过的快照，高频预览 Frame 也不进入完整快照；
- 发布方关闭和 GUI 退出时，各自释放持有的最新快照。

## 12. 组件资源与关机释放顺序

优雅关机严格按以下资源依赖顺序执行：

1. Camera Actor 进入 `Stopping` 后停止发布 Frame，停止采集循环并关闭 Camera SDK，最后进入 `Stopped`；
2. 摄像头停止后，Inspection Actor 取消当前任务或确认已经 `Idle`；任务终止后释放任务上下文和计时器资源；
3. 任务为 `Idle` 后关闭 Inspection Worker 和各 Actor；关闭确认表示任务入口、内部计时器、通信资源和对应执行线程已经释放；
4. App Controller 释放原 AppState 及其模式资源，清空并释放 Latest Frame Store，关闭状态投影发布边界并释放其他应用运行期资源；
5. 提交 ApplicationLifecycle 的 `Terminated`，完成关机等待者。

同一关闭阶段内无依赖的组件可以并行关闭，但不得颠倒上述资源依赖。GUI 本地快照或预览引用由 GUI 在替换或退出时释放；其短暂存活不得允许 GUI 在 `ShuttingDown` 或 `Terminated` 中继续执行业务操作。

组件关闭失败、内部通信基础设施失效或取消宽限期耗尽直接 `panic`；`panic` 不是资源正常释放完成或 `Terminated` 的替代状态。

## 13. 资源生命周期不变量

1. 已发布 Frame、Inspection Plan、InspectionPresentation 和状态快照始终不可变。
2. Camera SDK 缓冲区的借用不得进入 Frame。
3. Camera Actor 是 Latest Frame Store 的唯一写入者，且进入 `Stopping` 后不得再写入。
4. Latest Frame Store 和 GUI 均不积压 Frame。
5. App Controller 是 AppState 及模式资源的唯一领域所有者。
6. 状态外准备失败不得改变原状态或其已提交资源。
7. 每个被接受的检查在 Worker 终止前固定 Frame 和 Inspection Plan。
8. `Running` 和 `Cancelling` 均持有完整任务上下文并拒绝新任务。
9. 每个被接受的任务最终必须释放 Actor 和 Worker 持有的 Frame、Inspection Plan、取消及计时器资源，或因致命错误终止进程。
10. InspectionPresentation 的领域真值只存在于当前模式状态；GUI 快照不是第二状态所有者。
11. 过期 Worker 输出、计时器消息和领域事件不得恢复已释放资源或改变当前资源所有权。
12. ApplicationLifecycle 只有在组件停止且应用所有者已按关机顺序释放运行期资源后才能进入 `Terminated`。
