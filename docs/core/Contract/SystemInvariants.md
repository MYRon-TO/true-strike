# 系统级不变量规约

本文按 [系统级不变量整理与维护指南](./SystemInvariantsGuide.md) 的性质轴，汇总视觉检测系统 v1 必须跨组件共同保持的核心不变量。整体规约索引见 [行为规约](../Contract.md)。

本文只保留跨组件结论。组件内部约束及具体行为以对应状态、消息、资源和执行规约为准。

## 1. A1 权威与状态所有权

1. **SI-A1-01 应用状态单一权威**：App Controller 必须是 `ApplicationLifecycle`、`AppState` 及模式资源的唯一领域所有者，并串行裁决其转换；GUI、Scheme Manager 和各 Actor 不得持有或独立转换 `AppState`。
2. **SI-A1-02 检查状态单一权威**：Inspection Actor 必须是 InspectionTaskState 的唯一所有者，并串行裁决检查申请、取消请求、计时器消息和 WorkerOutcome；App Controller 不得以申请响应或状态投影维护第二份检查运行状态。
3. **SI-A1-03 摄像头状态与能力单一权威**：Camera Actor 必须是摄像头、Camera SDK 及其采集缓冲区的唯一访问者，并唯一裁决摄像头状态；GUI 和 App Controller 不得直接访问摄像头。
4. **SI-A1-04 最新帧单一写入者**：Camera Actor 必须是 Latest Frame Store 的唯一写入者；GUI 和 App Controller 只能读取 Store。
5. **SI-A1-05 展示对象单一领域真值**：App Controller 当前模式的 `optional_presentation` 必须是最近一次 InspectionPresentation 的唯一领域真值；GUI 只能持有不可变最新快照，不得成为第二状态所有者。
6. **SI-A1-06 取消信号单一控制者**：只有 Inspection Actor 可以设置当前任务的 CancellationSignal；Worker、Inspection Core 和算子只能观察，不得复位或替换该信号。

## 2. A2 状态合法性与守卫

1. **SI-A2-01 生命周期与业务状态一致**：`AppState` 只在 ApplicationLifecycle 为 `Running` 时有效；进入 `ShuttingDown` 后，原 AppState 不得继续作为可观察或可操作的业务状态，ApplicationLifecycle 不得恢复为 `Running`。
2. **SI-A2-02 命令守卫优先**：普通应用命令只有在 ApplicationLifecycle 为 `Running` 时才能进入 AppState 守卫裁决；生命周期或模式不匹配时不得执行命令内容，不得提交状态或资源变化。
3. **SI-A2-03 单一活动检查**：Inspection Actor 同一时间最多持有一个尚未终止的已接受任务；Inspection Worker 同一时间最多接受并执行一个检查任务。`Running` 和 `Cancelling` 均必须拒绝新检查申请。
4. **SI-A2-04 Actor 关闭守卫**：Inspection Actor 只有在任务状态为 `Idle` 时才能关闭；Inspection Worker 只有在不存在活动任务和待交付 WorkerOutcome 时才能关闭。
5. **SI-A2-05 Camera 停止不可逆**：Camera Actor 进入 `Stopping` 后不得再发布 Frame，进入 `Stopped` 后不得重新启动。
6. **SI-A2-06 Cancelled 状态约束**：当前任务匹配的 `Cancelled` 只能正常终结 `Cancelling` 中的任务；Inspection Actor 在 `Running` 中收到该输出必须视为内部不变量破坏并直接 `panic`。

## 3. A3 身份、关联与作用域

1. **SI-A3-01 标识生成与唯一性**：App Controller 必须在每次进入 EditMode 或 ProductionMode 时生成 `ModeSessionId`；Inspection Actor 必须在接受检查申请时生成 `inspection_id`；Camera Actor 必须为每个已发布 Frame 生成 `frame_id`。三类标识在同一应用运行期间必须唯一且不得复用；标识空间耗尽或无法保证唯一时直接 `panic`。
2. **SI-A3-02 会话与任务身份分离**：`ModeSessionId` 只能用于模式事件隔离和返回 Home 的会话级取消；`inspection_id` 只能用于具体任务、WorkerOutcome 和任务计时器关联，二者不得互相替代。
3. **SI-A3-03 任务身份完整传递**：Inspection Actor 构造的 InspectionMetadata 在单次检查中必须不可变，并随 Worker 任务和检查领域事件传递；WorkerOutcome 和任务计时器必须携带对应 `inspection_id`。
4. **SI-A3-04 返回 Home 取消作用域**：返回 Home 必须使用被关闭模式的 `ModeSessionId` 请求取消当前属于该会话的唯一任务；迟到或会话不匹配的取消通知不得影响其他会话任务。
5. **SI-A3-05 过期输入隔离**：身份不匹配、状态不适用或任务已经终止的 WorkerOutcome、计时器消息和会话级取消不得改变当前状态、资源或取消原因。
6. **SI-A3-06 领域事件会话隔离**：InspectionEvent 只有在 ApplicationLifecycle 为 `Running`、当前 AppState 为 EditMode 或 ProductionMode，且事件携带的 `ModeSessionId` 与当前模式一致时，才允许更新当前模式；其他 InspectionEvent 必须整体丢弃。

## 4. A4 原子性与提交一致性

1. **SI-A4-01 状态与资源同边界提交**：状态转换及其资源取得或释放必须由状态所有者在同一逻辑提交边界保持一致；状态外准备只有在操作成功后才能成为领域状态资源。
2. **SI-A4-02 失败不产生部分提交**：业务失败、申请拒绝、消息丢弃和事件过滤不得改变原状态或已提交资源，并必须释放未提交资源及被丢弃载荷。
3. **SI-A4-03 模式进入全有或全无**：进入 EditMode 或 ProductionMode 时，各自规定的配置读取、校验、草稿创建或方案构建及模式资源准备必须在新 AppState 提交前完成；任一步骤业务失败时必须保留 Home。
4. **SI-A4-04 方案发布全有或全无**：Inspection Plan 只有在所有可执行阶段和判定规则完整构建成功后才能跨组件发布；部分构建结果不得进入模式状态或检查申请。
5. **SI-A4-05 检查接受提交边界**：Worker 接受任务之前，Inspection Actor 不得提交 `Running` 或返回 `Accepted`；`Accepted` 返回时，Actor 必须已经处于 `Running`，Worker 必须已经接受任务并开始执行超时计时。
6. **SI-A4-06 检查终止提交边界**：Inspection Actor 必须先构造可独立存活的终止事件所需载荷，再释放任务上下文并提交 `Idle`；关机等待响应只能在任务资源已释放且 `Idle` 已提交后完成。
7. **SI-A4-07 Presentation 原子替换**：只有通过生命周期、模式和会话过滤的 InspectionCompleted 或 InspectionFailed 才能原子替换当前模式的 Presentation；InspectionTimedOut 不得替换 Presentation。
8. **SI-A4-08 启动成功提交边界**：应用启动成功时，Camera Actor 必须已经进入 `Capturing`，Home 与 ApplicationLifecycle 的 `Running` 必须在同一启动成功边界提交；启动完成不得等待首帧发布。
9. **SI-A4-09 保存提交一致性**：保存草稿只有在完整校验、方案实际构建和配置文件原子替换均成功后才能提交新的内存 `revision`；业务失败时原文件和内存草稿的已提交 revision 必须保持不变。保存成功只保证同一运行环境中的原子替换和后续读取一致，不承诺掉电或操作系统崩溃后的持久性。
10. **SI-A4-10 Frame 完整发布**：Camera Actor 只有在图像数据和摄像头元数据完整复制、`frame_id` 分配且不可变 Frame 构造完成后，才能将该 Frame 发布到 Latest Frame Store；部分 Frame 不得对消费者可见。
11. **SI-A4-11 最新值替换一致性**：Latest Frame Store 和 GUI 预览替换最新 Frame 时，必须在同一逻辑提交边界建立新引用并释放自身旧引用；替换不得修改旧 Frame 或使其他持有者失效。

## 5. A5 顺序、串行化与竞争裁决

1. **SI-A5-01 状态所有者顺序裁决**：应用命令与 InspectionEvent 由 App Controller 的实际处理顺序裁决；检查申请、取消、计时器和 WorkerOutcome 由 Inspection Actor 的实际处理顺序裁决；启动、停止和采集结果由 Camera Actor 的实际处理顺序裁决。
2. **SI-A5-02 不存在跨接收方全局顺序**：系统不得假定不同接收方或不同发送方之间存在统一的消息产生顺序，也不得用发送时间、Core 返回时间或业务 UTC 时间推翻状态所有者已经提交的裁决。
3. **SI-A5-03 截止与输出竞争**：WorkerOutcome、执行截止和取消截止之间的结果必须以 Inspection Actor 的实际处理顺序确定；截止时间是 Actor 可观察的裁决边界，不证明 Worker 的物理返回时刻。
4. **SI-A5-04 首次取消固定**：第一个被 Inspection Actor 处理并实际触发 `Running → Cancelling` 的取消来源必须固定取消原因和取消截止时间；后续取消不得覆盖原因或延长截止时间。
5. **SI-A5-05 返回 Home 与事件竞争**：检查事件和 ReturnHome 必须按 App Controller 的实际处理顺序裁决；Home 提交后处理的旧会话事件不得恢复原模式或更新展示。
6. **SI-A5-06 投影顺序不可作为协议依据**：领域事件、请求响应、WorkerOutcome、关闭确认与状态投影之间不得假定观察顺序；投影不得用于证明请求完成、任务终止或组件关闭。
7. **SI-A5-07 Scheme Manager 操作顺序**：可能阻塞的 Scheme Manager 操作必须在独立执行环境中完成；App Controller 异步等待期间可以处理 InspectionEvent 和维持 GUI 状态发布，但不得开始处理后续应用命令，ReturnHome 和 Shutdown 也不得越过当前命令。

## 6. A6 资源生命周期与隔离

1. **SI-A6-01 SDK 缓冲区隔离**：Frame 发布前必须完整复制图像数据和摄像头元数据，不得保存对 Camera SDK 缓冲区的借用；SDK 缓冲区复用或释放不得影响已发布 Frame。
2. **SI-A6-02 共享资源独立存活**：Frame、Inspection Plan、InspectionPresentation 和状态快照跨组件传递时不得借用发送方内部状态；释放一个持有者的共享引用不得使其他合法持有者的对象失效。
3. **SI-A6-03 最新值不积压**：Camera Actor 不得等待 Frame 消费者或建立待处理帧队列；Latest Frame Store 和 GUI 预览必须采用替换式最新值语义，不得积压 Frame。
4. **SI-A6-04 检查输入固定**：每个被接受的检查在 WorkerOutcome 产生前必须固定 Frame、Inspection Plan 和完整任务上下文；后续 Frame、配置文件、草稿、生产方案或应用模式变化不得改变任务输入。
5. **SI-A6-05 取消期间保留上下文**：`Cancelling` 必须继续持有完整任务上下文，直至当前任务匹配的 WorkerOutcome 被 Inspection Actor 处理；系统不得通过释放任务资源伪造取消完成。
6. **SI-A6-06 任务资源终止**：每个任务终止时，Inspection Actor 必须撤销或失效任务计时器，Actor 和 Worker 必须释放各自持有的 Frame、Inspection Plan、CancellationSignal 和执行临时资源；进程因致命错误终止时除外。
7. **SI-A6-07 过滤与丢弃释放**：申请被拒绝、WorkerOutcome 过期、消息被丢弃或 InspectionEvent 被过滤时，接收边界必须释放该申请或消息持有的全部载荷，不得恢复已经释放的领域资源。
8. **SI-A6-08 Presentation 独立存活**：InspectionPresentation 必须持有关联 Frame，并能独立于 Inspection Actor 的任务上下文继续存活；超时、返回 Home 和关机取消不得构造 Presentation。

## 7. A7 协议基数与交付语义

1. **SI-A7-01 请求响应基数**：每个被接收的命令、申请和控制请求必须恰好完成一次响应；进程因致命错误终止时除外。
2. **SI-A7-02 Worker 终止输出基数**：每个被 Worker 接受的任务必须恰好产生一个 WorkerOutcome；Worker 不得为同一任务发送多个终止输出或隐式重试任务。
3. **SI-A7-03 可靠交付与最新值分离**：命令响应、申请响应、控制响应、WorkerOutcome 和 InspectionEvent 不得通过可丢弃的最新值通道传递；状态投影和 AppViewSnapshot 可以替换、合并或跳过中间版本。
4. **SI-A7-04 返回 Home 取消无需响应**：CancelInspectionForSession 必须是无需响应的会话级通知；App Controller 不得等待该通知完成后才提交或完成 ReturnHome。
5. **SI-A7-05 重复关机附着**：首次 Shutdown 必须启动唯一关机流程；后续 Shutdown 必须附着到该流程并等待同一个完成结果，不得启动第二套关闭副作用。
6. **SI-A7-06 重复组件关闭幂等**：重复停止 Camera Actor、关闭 Inspection Worker 或关闭 Inspection Actor 必须按各自协议附着现有流程或幂等确认，不得重复执行设备和线程关闭副作用。
7. **SI-A7-07 投影不得替代可靠协议**：任何组件不得依据 Actor Projection 或 AppViewSnapshot 决定请求是否成功、任务是否终止、关闭是否完成或关机是否可以推进。
8. **SI-A7-08 可靠消息恰好一次入队**：进程内可靠消息基础设施对每次成功发送必须恰好入队一次，不得自行复制或重试；发送成功不表示已经处理，发送失败或接收能力意外关闭必须直接 `panic`。

## 8. A8 不可变性、确定性与副作用边界

1. **SI-A8-01 跨组件对象不可变**：已发布的 Frame、Inspection Plan、InspectionPresentation、InspectionMetadata、组件状态投影和 AppViewSnapshot 必须保持业务不可变。
2. **SI-A8-02 Core 显式输入**：Inspection Core 只能在 Inspection Worker 中执行，并且只能使用当前任务显式提供的 Frame、Inspection Plan、CancellationSignal 及执行上下文。
3. **SI-A8-03 Core 与算子副作用隔离**：Inspection Core 及其算子不得访问 AppState、Latest Frame Store、配置文件、GUI 或未声明的全局业务状态，不得执行设备控制、持久化或应用消息等外部业务副作用。
4. **SI-A8-04 方案执行稳定**：Inspection Actor、Inspection Worker 和 Inspection Core 不得构建或修改 Inspection Plan；完整校验成功后实际构建的方案必须完整成功，否则直接 `panic`。
5. **SI-A8-05 空执行方案显式判定**：生产方案和测试方案均不得以空引用表示缺少方案；可执行阶段列表可以为空，但判定规则必须存在，空执行方案不得采用隐式默认判定。
6. **SI-A8-06 阶段输出隔离**：已提交阶段输出和已发布派生产物不得修改；阶段失败或取消不得提交部分输出，任务级派生产物缓存不得跨检查共享。
7. **SI-A8-07 展示元数据无重复真值**：InspectionCompleted 和 InspectionFailed 的 InspectionMetadata 只能由其 InspectionPresentation 携带；InspectionTimedOut 的 InspectionMetadata 只能由事件自身携带；InspectionResult 和 InspectionError 不得保存重复副本。

## 9. A9 进展、终止与故障边界

1. **SI-A9-01 已接受任务终止**：每个被接受的检查最终必须通过匹配 WorkerOutcome 使 Inspection Actor 回到 `Idle`，或因已声明的致命错误终止进程；任务终止不表示 Worker 工作线程退出。
2. **SI-A9-02 Cancelling 终止条件**：`Cancelling` 必须持续到当前任务匹配的 WorkerOutcome 被处理；进入 `Cancelling` 后的 Completed 和 Failed 只能证明任务终止，其业务载荷必须丢弃，不得生成正常结果或失败展示。
3. **SI-A9-03 取消宽限期故障边界**：Inspection Actor 在匹配 WorkerOutcome 之前先处理适用且匹配的取消截止消息时，必须直接 `panic`；系统不得强制终止 Worker 工作线程并伪造正常取消完成。
4. **SI-A9-04 超时事件终点**：InspectionTimedOut 只能在固定取消原因为 `Timeout`、匹配 WorkerOutcome 已被处理、任务资源已释放且 `Idle` 已提交后产生；ReturnHome 或 Shutdown 取消不得产生 InspectionEvent。
5. **SI-A9-05 普通命令在关机期间终止**：首次 Shutdown 提交 `ShuttingDown` 后，后续普通应用命令必须立即返回 `ShuttingDown`，不得等待关机完成或执行业务内容。
6. **SI-A9-06 关机依赖顺序**：优雅关机必须先等待 Camera Actor 确认 `Stopped`，再取消并等待当前检查实际回到 `Idle`，随后关闭 Inspection Worker 和各 Actor，最后释放应用状态、Store 和发布边界。
7. **SI-A9-07 Terminated 完成条件**：ApplicationLifecycle 只有在核心运行组件已停止，任务入口、执行线程和通信资源已关闭，AppState、Latest Frame Store、状态发布边界及核心所有者持有的其他运行期资源已按依赖顺序释放后，才能进入 `Terminated`。`Terminated` 不等待 GUI 本地不可变共享引用物理销毁，但这些引用从 `ShuttingDown` 起不得再作为业务操作依据。
8. **SI-A9-08 致命错误不得降级**：内部契约、协议、不变量或基础设施失效不得转换为业务错误、InspectionError、伪造的 InspectionEvent 或 `Terminated`；`panic` 不保证业务级回滚或优雅资源释放。
9. **SI-A9-09 Scheme Manager 操作无截止**：v1 不为配置读取、解析、校验、方案构建和保存设置截止时间，也不保证其有界完成；操作及后续排队命令可以无限等待，但不得阻塞 GUI、Actor 或异步运行时执行线程。
10. **SI-A9-10 组件关闭截止**：Camera 停止、Inspection Worker 关闭和各 Actor 关闭必须分别使用应用级固定截止；对应确认与截止以关机协调方的实际处理顺序裁决，截止先被处理时直接 `panic`，且不得伪造 `Stopped`、`Closed` 或 `Terminated`。
