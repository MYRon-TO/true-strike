# 用例与命令规约

本文定义 v1 的端到端用例。整体规约索引见 [行为规约](../Contract.md)。

App Controller 串行处理命令和相关事件。模式切换是不可中断的原子操作：准备期间保持原状态，全部准备成功后一次性提交新状态。未提交的中间资源在失败时释放。

除重复关机请求外，ApplicationLifecycle 不是 `Running` 时，应用命令按生命周期规则拒绝。ApplicationLifecycle 为 `Running`、但命令与当前 AppState 不匹配时，统一返回携带命令、实际模式和期望模式的 `InvalidMode`；Home 中的返回主页命令除外，它幂等成功。状态不匹配时不执行命令内容。ApplicationLifecycle 为 `ShuttingDown` 时，重复关机请求附着到当前关机流程。

## 1. 启动应用

- **触发方**：应用运行环境。
- **接收方**：应用入口及各应用组件。
- **前置状态**：应用尚未运行。
- **输入**：应用级固定配置。
- **处理过程**：初始化应用组件，Camera Actor 初始化摄像头并开始采集。具体初始化顺序由实现根据依赖关系决定。
- **成功结果**：应用进入 Home，Camera Actor 已开始采集。
- **失败结果**：v1 中任何组件初始化失败均直接 `panic`。
- **状态转换**：ApplicationLifecycle 从 `Starting` 转入 `Running`，AppState 从无转为 Home；二者在同一启动成功边界提交。
- **完成边界**：Home 已提交，Camera Actor 已成功开始采集；不等待首帧发布。
- **异步后续**：Camera Actor 持续发布最新帧。首帧发布前，预览为空，检查命令可能返回 `NoFrame`。
- **资源变化**：各组件取得其运行期资源；具体持有关系在资源生命周期规约中定义。
- **并发关系**：应用完成启动前不处理 GUI 命令。

## 2. 进入编辑模式

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：Home。
- **输入**：用户选择的配置文件路径。
- **处理过程**：
  1. Scheme Manager 读取并解析配置文件；
  2. Scheme Manager 校验配置；
  3. App Controller 根据有效配置创建 Draft Config；
  4. App Controller 生成新的 `ModeSessionId`；
  5. App Controller 一次性提交 EditMode。
- **成功结果**：进入 EditMode，并持有配置路径和 Draft Config。
- **失败结果**：AppState 不是 Home 时返回 `InvalidMode`；否则返回 `ConfigLoadFailed` 或 `ConfigInvalid`，并保留 Home。
- **状态转换**：Home → EditMode；失败时保持命令处理前的 AppState。
- **完成边界**：EditMode 已提交。
- **异步后续**：无。
- **资源变化**：EditMode 取得配置路径和草稿；失败时释放全部临时资源。
- **并发关系**：处理期间不处理后续应用命令；相关命令按 App Controller 的串行顺序执行。

v1 不允许使用可解析但校验失败的配置进入 EditMode。

## 3. 进入生产模式

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：Home。
- **输入**：用户选择的配置文件路径。
- **处理过程**：
  1. Scheme Manager 读取并解析配置文件；
  2. Scheme Manager 校验配置；
  3. Scheme Manager 构建不可变可执行 Inspection Plan；
  4. App Controller 生成新的 `ModeSessionId`；
  5. App Controller 一次性提交 ProductionMode。
- **成功结果**：进入 ProductionMode，并持有配置、配置路径和有效生产方案。
- **失败结果**：AppState 不是 Home 时返回 `InvalidMode`；否则按处理阶段返回 `ConfigLoadFailed`、`ConfigInvalid` 或 `PlanBuildFailed`，并保留 Home。
- **状态转换**：Home → ProductionMode；失败时保持命令处理前的 AppState。
- **完成边界**：ProductionMode 已提交。
- **异步后续**：无。
- **资源变化**：ProductionMode 取得配置和生产方案；失败时释放已读取配置、部分构建结果等临时资源。
- **并发关系**：处理期间不处理后续应用命令；相关命令按 App Controller 的串行顺序执行。

ProductionMode 运行期间不自动重新读取配置文件。配置读取、校验或方案构建失败属于业务错误；内部不变量破坏或内部通信基础设施失效可以直接 `panic`。

## 4. 返回主页

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：任意 AppState。
- **输入**：无。
- **处理过程**：
  1. 当前已为 Home 时直接完成，不执行取消或资源释放；
  2. 当前为 EditMode 或 ProductionMode 时，记录该模式正在执行的 `inspection_id` 和 `ModeSessionId`，再将状态切换为 Home；
  3. 释放原模式持有的配置、方案和展示对象；
  4. 如果记录了正在执行的检查，则向 Inspection Actor 发送携带 `inspection_id`、`ModeSessionId` 和 `ReturnHome` 原因的精确取消请求。
- **成功结果**：进入或保持 Home，不等待取消结束。
- **失败结果**：无业务失败；内部取消通信失效时直接 `panic`。
- **状态转换**：EditMode 或 ProductionMode → Home；Home → Home 幂等成功。
- **完成边界**：Home 已提交，模式资源已释放，必要的精确取消请求已发出。
- **异步后续**：Inspection Actor 可能继续执行取消流程。
- **资源变化**：原模式资源被释放；任务资源继续由 Inspection Actor 持有，直至任务终止。
- **并发关系**：检查事件和返回主页命令按 App Controller 的串行处理顺序裁决。Home 提交后处理的旧会话事件不得更新展示状态。迟到或目标不匹配的精确取消不得影响其他任务。

## 5. 修改配置草稿

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：EditMode。
- **输入**：一个结构化字段修改操作。
- **处理过程**：对目标字段执行字段级校验；校验成功后，将修改原子地应用到 Draft Config。
- **成功结果**：内存草稿包含新字段值。
- **失败结果**：AppState 不是 EditMode 时返回 `InvalidMode`；否则返回字段校验失败原因，原草稿保持不变。
- **状态转换**：成功时保持 EditMode，仅更新其 Draft Config；失败时保持命令处理前的 AppState。
- **完成边界**：修改后的 Draft Config 已提交。
- **异步后续**：无。
- **资源变化**：不修改配置文件，不创建或修改生产方案，也不清除现有展示对象。
- **并发关系**：修改、校验、保存和测试命令按 App Controller 的串行顺序执行；单次修改不可被其他命令或事件打断。

字段级校验只保证该字段修改合法，不替代完整配置校验。

## 6. 校验配置草稿

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：EditMode。
- **输入**：当前 Draft Config。
- **处理过程**：对草稿执行纯配置校验，遇到首个问题时停止并返回。
- **成功结果**：返回成功。
- **失败结果**：AppState 不是 EditMode 时返回 `InvalidMode`；否则返回首个 `ConfigInvalid` 原因。
- **状态转换**：无。
- **完成边界**：校验结果已返回。
- **异步后续**：无。
- **资源变化**：不修改草稿、配置文件、展示对象或任何缓存。
- **并发关系**：按 App Controller 的串行顺序读取命令处理时的当前草稿。

该命令不构建 Inspection Plan。方案可构建性由保存配置或发起测试检查时验证。

## 7. 保存配置草稿

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：EditMode。
- **输入**：当前 Draft Config 和原配置文件路径。
- **处理过程**：
  1. 校验草稿；
  2. Scheme Manager 构建一次不可变可执行 Inspection Plan，以验证可构建性；
  3. 计算单调递增的新 `revision`；
  4. 使用新 `revision` 生成待保存配置；
  5. 写入临时文件；
  6. 原子替换原配置文件；
  7. 将内存草稿同步为已提交的新 `revision`。
- **成功结果**：磁盘配置与内存草稿逻辑一致，并具有相同的新 `revision`；应用继续处于 EditMode。
- **失败结果**：AppState 不是 EditMode 时返回 `InvalidMode`；否则按处理阶段返回 `ConfigInvalid`、`PlanBuildFailed` 或 `ConfigSaveFailed`。
- **状态转换**：成功时保持 EditMode 并更新 Draft Config 的 `revision`；失败时保持命令处理前的 AppState。
- **完成边界**：原子替换成功，且内存草稿已同步为新 `revision`。
- **异步后续**：无。
- **资源变化**：构建出的验证方案不进入模式状态；失败时原文件及内存草稿的 `revision` 保持不变。
- **并发关系**：修改、校验、保存和测试命令按 App Controller 的串行顺序执行。

`revision` 从 `1` 开始，使用 `u64` 单调递增，不循环复用；发生整数溢出时直接 `panic`。保存时覆盖路径当前指向的配置文件，不检测编辑期间发生的外部文件修改。

## 8. 发起测试检查

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：ApplicationLifecycle 为 `Running`，且 AppState 为 EditMode。
- **输入**：无；使用命令处理时的当前 Draft Config。
- **处理过程**：
  1. Scheme Manager 校验当前草稿；
  2. Scheme Manager 构建临时的不可变可执行 Inspection Plan；
  3. App Controller 固定当前 `ModeSessionId`；
  4. App Controller 从 Latest Frame Store 固定最新 Frame；
  5. App Controller 向 Inspection Actor 提交检查申请。
- **成功结果**：Inspection Actor 接受申请、进入 `Running`，并成功将任务提交给 Inspection Worker。
- **失败结果**：AppState 不匹配时先返回 `InvalidMode`；模式匹配后，按处理顺序可能返回 `ConfigInvalid`、`PlanBuildFailed`、`NoFrame` 或 `Busy`。
- **状态转换**：成功时 AppState 保持 EditMode，Inspection Actor 从 `Idle` 转入 `Running`；失败时保持命令处理前的状态。
- **完成边界**：Inspection Actor 已进入 `Running`，且 Worker 已接受任务。Worker 成功接受任务时，Inspection Actor 读取单调时间并开始计算执行超时；业务展示时间 `started_at` 在 Actor 接受申请时读取。
- **异步后续**：发布最新检查状态；后续产生检查完成、检查失败或检查超时事件。
- **资源变化**：临时方案只属于本次命令和对应任务，不进入 EditMode；申请被拒绝时，申请携带的 Frame 和 Inspection Plan 共享引用随申请销毁而释放。
- **并发关系**：App Controller 开始处理命令后先校验模式；模式不匹配时不校验草稿、不构建方案、不读取帧，也不联系 Inspection Actor。模式匹配时，方案构建完成后才申请检查并判断 `Busy`。旧展示在新结果或失败展示到达前继续保留。

内部任务提交失败不允许在命令成功后发生；v1 将该情况视为内部基础设施失效并直接 `panic`。

## 9. 发起生产检查

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：ApplicationLifecycle 为 `Running`，且 AppState 为 ProductionMode。
- **输入**：无；使用命令处理时的当前生产方案。
- **处理过程**：
  1. App Controller 固定当前 `ModeSessionId`；
  2. 取得当前不可变生产方案的共享引用；
  3. 从 Latest Frame Store 固定最新 Frame；
  4. 向 Inspection Actor 提交检查申请。
- **成功结果**：Inspection Actor 接受申请、进入 `Running`，并成功将任务提交给 Inspection Worker。
- **失败结果**：AppState 不匹配时先返回 `InvalidMode`；模式匹配后，按处理顺序可能返回 `NoFrame` 或 `Busy`。
- **状态转换**：成功时 AppState 保持 ProductionMode，Inspection Actor 从 `Idle` 转入 `Running`；失败时保持命令处理前的状态。
- **完成边界**：Inspection Actor 已进入 `Running`，且 Worker 已接受任务。Worker 成功接受任务时，Inspection Actor 读取单调时间并开始计算执行超时；业务展示时间 `started_at` 在 Actor 接受申请时读取。
- **异步后续**：发布最新检查状态；后续产生检查完成、检查失败或检查超时事件。
- **资源变化**：任务获得 Frame 和生产方案的独立共享引用；申请被拒绝时只释放本次申请持有的引用，ProductionMode 继续持有生产方案。
- **并发关系**：App Controller 开始处理命令后先校验模式；模式不匹配时不取得方案、不读取帧，也不联系 Inspection Actor。模式匹配时，检查申请到达 Inspection Actor 后才判断 `Busy`。旧展示在新结果或失败展示到达前继续保留。

模式匹配检查以 App Controller 开始处理命令时的 AppState 为准。“立即返回 `InvalidMode`”不越过此前排队的命令。

## 10. 优雅关机

- **触发方**：应用运行环境或 GUI。
- **接收方**：App Controller。
- **前置状态**：ApplicationLifecycle 为 `Running` 或 `ShuttingDown`；首次请求时 AppState 可以为任意模式。
- **输入**：无。
- **处理过程**：
  1. ApplicationLifecycle 已为 `ShuttingDown` 时，将请求附着到当前关机流程并跳过后续启动步骤；
  2. ApplicationLifecycle 为 `Running` 时，App Controller 将其原子地切换为 `ShuttingDown`，异步启动唯一的关机协调流程；
  3. 拒绝队列中排在首次关机命令之后及之后新到达的普通应用命令；
  4. 请求 Camera Actor 停止采集并关闭摄像头，异步等待其确认 `Stopped`；
  5. Camera Actor 停止后，如果检查正在运行，则发送 `CancelCurrentForShutdown` 并异步等待 Inspection Actor 回到 `Idle`；
  6. 关闭 Inspection Worker 和各 Actor；同一阶段内无依赖的关闭操作可以并行发起并统一等待；
  7. 释放原 AppState、Latest Frame Store 及其他应用资源；
  8. 将 ApplicationLifecycle 切换为 `Terminated`，完成所有附着的关机请求。
- **成功结果**：应用全部组件已停止，运行期资源已释放。
- **失败结果**：无业务失败；组件关闭失败、内部通信失效或取消宽限期耗尽时直接 `panic`。
- **状态转换**：首次请求使 ApplicationLifecycle 从 `Running` 经 `ShuttingDown` 转入 `Terminated`；重复请求保持 `ShuttingDown` 并等待同一转换。`ShuttingDown` 不属于 AppState。
- **完成边界**：ApplicationLifecycle 已进入 `Terminated`。
- **异步后续**：关机命令发起后由异步协调流程推进，直到进入 `Terminated`；等待不得阻塞 Actor 或异步运行时执行线程。
- **资源变化**：按处理过程释放全部应用资源。当前 AppState 不必先转换为 Home。
- **并发关系**：关机命令之前的命令先完成；之后的普通命令返回 `ShuttingDown`；重复关机请求等待同一完成结果。关机开始后不可撤销，Camera Actor 停止前不得发送检查取消。

关机与检查完成或失败的竞争由 Inspection Actor 的串行处理顺序裁决：

- Actor 先处理完成或失败输出时，任务正常结束，随后关机流程确认其为 `Idle`；
- Actor 先处理关机取消请求时，进入 `Cancelling`；之后到达的匹配 `Completed`、`Failed` 或 `Cancelled` 均证明 Worker 已停止，其中完成输出和失败错误一律丢弃；
- 因关机取消的检查不生成正常结果、失败展示或面向 GUI 的超时结果；
- Worker 的匹配终止输出到达后，Inspection Actor 释放任务资源、回到 `Idle`，并向关机流程确认取消完成。

摄像头先于检查取消停止。检查已经固定 Frame，不依赖后续采集。
