# 用例与命令规约

本文定义 v1 的端到端用例。整体规约索引见 [行为规约](../Contract.md)。

App Controller 按命令接收顺序串行处理应用命令。可能阻塞的 Scheme Manager 操作在独立执行环境中完成，App Controller 异步等待期间可以处理 InspectionEvent 和维持 GUI 状态发布，但不得开始处理后续应用命令；后续命令包括 ReturnHome 和 Shutdown 均保持排队。v1 不为该等待设置截止时间，操作永久不返回时，当前命令及其后的命令可以永久等待，但不得阻塞 GUI、Actor 或异步运行时执行线程。模式切换仍是不可中断的原子提交：准备期间保持原状态，全部准备成功后一次性提交新状态，失败时释放未提交资源。

除重复关机请求外，ApplicationLifecycle 不是 `Running` 时，应用命令按生命周期规则拒绝。ApplicationLifecycle 为 `Running`、但命令与当前 AppState 不匹配时，统一返回携带命令、实际模式和期望模式的 `InvalidMode`；Home 中的返回主页命令除外，它幂等成功。状态不匹配时不执行命令内容。ApplicationLifecycle 为 `ShuttingDown` 时，重复关机请求附着到当前关机流程。

ApplicationLifecycle 为 `Running` 时，App Controller 开始和结束前台命令必须按消息规约发布 `Executing(command_seq, operation)` 和 `Idle`。该投影只用于 GUI 展示，不改变命令串行顺序，也不替代可靠命令响应。

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
  3. App Controller 根据有效配置创建 Draft Config，并将编辑会话 `draft_version` 初始化为 `0`；
  4. App Controller 生成新的 `ModeSessionId`；
  5. App Controller 一次性提交 EditMode；
  6. App Controller 根据已提交的完整 Draft Config 和 `draft_version = 0` 生成并提交编辑屏幕快照发布；
  7. 按命令状态终止边界发布 `Idle`，返回 `EnteredEditMode(mode_session_id)`。
- **成功结果**：进入 EditMode，并持有配置路径、Draft Config 和 `draft_version = 0`；完整草稿及其版本通过编辑屏幕快照对 GUI 可观察。
- **失败结果**：AppState 不是 Home 时返回 `InvalidMode`；否则返回 `ConfigLoadFailed` 或 `ConfigInvalid`，并保留 Home。
- **状态转换**：Home → EditMode；失败时保持命令处理前的 AppState。
- **完成边界**：EditMode 和对应编辑屏幕快照发布已经依次提交，成功响应随后完成。
- **异步后续**：GUI 对快照与响应的观察顺序不确定。
- **资源变化**：EditMode 取得配置路径和草稿；快照取得完整草稿的不可变值投影；失败时释放全部临时资源。
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
- **失败结果**：AppState 不是 Home 时返回 `InvalidMode`；否则按处理阶段返回 `ConfigLoadFailed` 或 `ConfigInvalid`，并保留 Home。
- **状态转换**：Home → ProductionMode；失败时保持命令处理前的 AppState。
- **完成边界**：ProductionMode 已提交。
- **异步后续**：无。
- **资源变化**：ProductionMode 取得配置和生产方案；业务失败时释放已读取配置等临时资源。
- **并发关系**：处理期间不处理后续应用命令；相关命令按 App Controller 的串行顺序执行。

ProductionMode 运行期间不自动重新读取配置文件。配置读取或校验失败属于业务错误；完整校验成功的配置无法构建为完整 Inspection Plan 时表示内部契约被破坏，直接 `panic`。内部通信基础设施失效同样直接 `panic`。

## 4. 返回主页

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：任意 AppState。
- **输入**：无。
- **处理过程**：
  1. 当前已为 Home 时直接完成，不执行取消或资源释放；
  2. 当前为 EditMode 或 ProductionMode 时，记录该模式的 `ModeSessionId`，再将状态切换为 Home；
  3. 释放原模式持有的配置、方案和展示对象；
  4. 向 Inspection Actor 无条件发送携带该 `ModeSessionId` 和 `ReturnHome` 原因的会话级取消通知。
- **成功结果**：进入或保持 Home，不等待取消结束。
- **失败结果**：无业务失败；内部取消通信失效时直接 `panic`。
- **状态转换**：EditMode 或 ProductionMode → Home；Home → Home 幂等成功。
- **完成边界**：Home 已提交，模式资源已释放，会话级取消通知已发出。
- **异步后续**：Inspection Actor 可能继续执行取消流程。
- **资源变化**：原模式资源被释放；任务资源继续由 Inspection Actor 持有，直至任务终止。
- **并发关系**：检查事件和返回主页命令按 App Controller 的串行处理顺序裁决。Home 提交后处理的旧会话事件不得更新展示状态。迟到或会话不匹配的取消通知不得影响其他任务。

## 5. 修改配置草稿

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：EditMode。
- **输入**：`expected_draft_version` 和一个 DraftMutation 变体。具体变体与字段权限见配置、方案与算子规约。
- **处理过程**：
  1. 确认当前 AppState 为 EditMode；
  2. 比较 `expected_draft_version` 与当前 `draft_version`；不一致时停止；
  3. 基于当前草稿形成只包含该 mutation 的候选值；
  4. 按 mutation 类型执行字段级校验；
  5. 校验成功后，将候选 Draft Config 和递增后的 `draft_version` 原子地提交；
  6. 根据同一提交后的完整草稿和版本生成并提交新的编辑屏幕快照；
  7. 按命令状态终止边界发布 `Idle`，返回 `DraftModified(draft_version)`。
- **成功结果**：内存草稿和新编辑屏幕快照均包含新字段值及相同的新 `draft_version`。
- **失败结果**：AppState 不是 EditMode 时返回 `InvalidMode`；版本不一致时返回 `DraftVersionConflict(expected, actual)`；否则返回字段级 `ConfigInvalid`。失败时原草稿和 `draft_version` 保持不变，不发布包含失败修改的草稿快照。
- **状态转换**：成功时保持 EditMode，原子更新其 Draft Config 和 `draft_version`；失败时保持命令处理前的 AppState。
- **完成边界**：修改后的 Draft Config、`draft_version`、对应编辑屏幕快照和 `Idle` 已经依次提交，`DraftModified(draft_version)` 随后完成。
- **异步后续**：GUI 对快照与响应的观察顺序不确定；最新值通道可以跳过中间快照。
- **资源变化**：不修改配置文件，不创建或修改生产方案，也不清除现有展示对象；新快照持有完整草稿和版本的不可变值投影。
- **并发关系**：修改、校验、保存和测试命令按 App Controller 的串行顺序执行；单次修改不可被其他命令或事件打断。v1 GUI 同一时间最多允许一个 `ModifyDraft` 在途；成功时须收到可靠响应并观察到 `draft_version` 等于响应版本的快照后才能发起下一次草稿编辑，已经观察到更高版本时也视为目标提交已被观察；失败时收到失败响应即可基于未改变的当前快照恢复编辑。

字段级校验允许草稿暂时存在跨阶段引用错误，不替代完整配置校验；每种 mutation 的输入、校验范围、稳定错误码和原子边界由配置、方案与算子规约定义。

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

该命令不构建 Inspection Plan。保存配置和发起测试检查仍按各自用例实际构建方案。

## 7. 保存配置草稿

- **触发方**：GUI。
- **接收方**：App Controller。
- **前置状态**：EditMode。
- **输入**：当前 Draft Config 和原配置文件路径。
- **处理过程**：
  1. 校验草稿；
  2. Scheme Manager 构建一次不可变可执行 Inspection Plan，使保存提交以实际编译成功为前提；
  3. 计算单调递增的新 `revision` 和新 `draft_version`；
  4. 使用新 `revision` 生成待保存配置；
  5. 写入临时文件；
  6. 原子替换原配置文件；
  7. 将内存草稿的 `revision` 和编辑会话 `draft_version` 原子地同步为新值；
  8. 根据同一提交后的完整 Draft Config 和 `draft_version` 生成并提交新的编辑屏幕快照；
  9. 按命令状态终止边界发布 `Idle`，返回 `DraftSaved(scheme_id, revision, draft_version)`。
- **成功结果**：磁盘配置、内存草稿和新编辑屏幕快照逻辑一致并具有相同的新 `revision`；内存草稿和快照具有相同的新 `draft_version`；应用继续处于 EditMode。
- **失败结果**：AppState 不是 EditMode 时返回 `InvalidMode`；否则按处理阶段返回 `ConfigInvalid` 或 `ConfigSaveFailed`，且不发布包含未提交 `revision` 或 `draft_version` 的快照。
- **状态转换**：成功时保持 EditMode，并原子更新 Draft Config 的 `revision` 与 `draft_version`；失败时保持命令处理前的 AppState。
- **完成边界**：原子替换、内存草稿 `revision` 与 `draft_version` 更新、对应编辑屏幕快照和 `Idle` 已经依次提交，成功响应随后完成。
- **异步后续**：GUI 对快照与响应的观察顺序不确定。
- **资源变化**：构建出的方案不进入模式状态；新快照持有完整草稿和版本的不可变值投影；业务失败时原文件及内存草稿的 `revision` 和 `draft_version` 保持不变。
- **并发关系**：修改、校验、保存和测试命令按 App Controller 的串行顺序执行。

`revision` 从 `1` 开始，使用 `u64` 单调递增，不循环复用；编辑会话 `draft_version` 的规则见配置、方案与算子规约。App Controller 必须在产生保存副作用前计算并确认两个新值均不溢出，发生溢出时直接 `panic`。保存时覆盖路径当前指向的配置文件，不检测编辑期间发生的外部文件修改。

完整校验成功的草稿无法构建为完整 Inspection Plan 时直接 `panic`，不返回业务错误。构建出的方案在保存命令结束时释放。

保存成功只保证同一运行环境中原子替换后的文件对后续读取可见，并与内存草稿逻辑一致；v1 不承诺掉电或操作系统崩溃后的持久性，不要求额外执行文件或目录同步。

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
- **失败结果**：AppState 不匹配时先返回 `InvalidMode`；模式匹配后，按处理顺序可能返回 `ConfigInvalid`、`NoFrame` 或 `Busy`。
- **状态转换**：成功时 AppState 保持 EditMode，Inspection Actor 从 `Idle` 转入 `Running`；失败时保持命令处理前的状态。
- **完成边界**：Inspection Actor 已进入 `Running`，且 Worker 已接受任务。Worker 成功接受任务时，Inspection Actor 读取单调时间并开始计算执行超时；业务展示时间 `started_at` 在 Actor 接受申请时读取。
- **异步后续**：发布最新检查状态；后续产生检查完成、检查失败或检查超时事件。
- **资源变化**：临时方案只属于本次命令和对应任务，不进入 EditMode；申请被拒绝时，申请携带的 Frame 和 Inspection Plan 共享引用随申请销毁而释放。
- **并发关系**：App Controller 开始处理命令后先校验模式；模式不匹配时不校验草稿、不构建方案、不读取帧，也不联系 Inspection Actor。模式匹配时，方案构建完成后才申请检查并判断 `Busy`。旧展示在新结果或失败展示到达前继续保留。

完整校验成功的草稿无法构建为完整 Inspection Plan 时直接 `panic`。内部任务提交失败属于内部基础设施失效，同样直接 `panic`。

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
  4. 请求 Camera Actor 停止采集并关闭摄像头，启动应用级固定 Camera 停止截止，异步等待其确认 `Stopped`；
  5. Camera Actor 停止后发送 `CancelCurrentForShutdown`，异步等待 `InspectionBecameIdle`；Actor 已为 `Idle` 时立即响应；
  6. 关闭 Inspection Worker 和各 Actor，并为每个关闭操作启动应用级固定截止；同一阶段内无依赖的关闭操作可以并行发起并统一等待；
  7. 释放原 AppState、Latest Frame Store、状态发布边界及其他核心应用资源；
  8. 将 ApplicationLifecycle 切换为 `Terminated`，完成所有附着的关机请求。
- **成功结果**：应用核心运行组件已停止，核心所有者持有的运行期资源已释放；不等待 GUI 本地不可变共享引用物理销毁。
- **失败结果**：无业务失败；组件关闭失败、内部通信失效、取消宽限期耗尽，或 Camera、Worker、Actor 的关闭截止先于对应确认被协调方处理时直接 `panic`。
- **状态转换**：首次请求使 ApplicationLifecycle 从 `Running` 经 `ShuttingDown` 转入 `Terminated`；重复请求保持 `ShuttingDown` 并等待同一转换。`ShuttingDown` 不属于 AppState。
- **完成边界**：ApplicationLifecycle 已进入 `Terminated`。
- **异步后续**：关机命令发起后由异步协调流程推进，直到进入 `Terminated`；等待不得阻塞 Actor 或异步运行时执行线程。
- **资源变化**：按处理过程释放核心应用所有者持有的运行期资源。当前 AppState 不必先转换为 Home。GUI 本地快照和预览 Frame 可以存活到 GUI 替换或退出，但从进入 `ShuttingDown` 起不再具有业务逻辑有效性，也不得触发业务操作。
- **并发关系**：关机命令之前的命令先完成；之后的普通命令返回 `ShuttingDown`；重复关机请求等待同一完成结果。关机开始后不可撤销，Camera Actor 停止前不得发送检查取消。

关机与检查完成或失败的竞争由 Inspection Actor 的串行处理顺序裁决：

- Actor 先处理完成或失败输出时，任务正常结束，随后关机取消请求立即响应 `InspectionBecameIdle(None)`；
- Actor 先处理关机取消请求时，进入 `Cancelling`；之后到达的匹配 `Completed`、`Failed` 或 `Cancelled` 均证明当前检查任务执行已经终止，其中完成输出和失败错误一律丢弃；
- 因关机取消的检查不生成正常结果、失败展示或面向 GUI 的超时结果；
- Worker 的匹配终止输出到达后，Inspection Actor 释放任务资源、回到 `Idle`，并完成 `InspectionBecameIdle` 响应。

摄像头先于检查取消停止。检查已经固定 Frame，不依赖后续采集。
