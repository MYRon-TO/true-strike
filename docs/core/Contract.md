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
- `ModeSessionId`、`inspection_id` 和 `frame_id` 在同一应用运行期间唯一且不得复用；标识空间耗尽或无法保证唯一时直接 `panic`；
- `ModeSessionId` 随检查申请、检查元数据和异步检查事件传递，并用于返回 Home 时限定会话级取消；
- `inspection_id` 由 Inspection Actor 接受检查申请时生成；
- `frame_id` 由 Camera Actor 生成。

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

Scheme Manager 的配置读取、校验、方案构建和保存是对 App Controller 的逻辑同步组件调用，不属于消息规约；可能阻塞的工作在独立执行环境中完成，App Controller 异步等待结果。

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
- GUI 预览 Frame、模式状态、完整只读草稿投影及配置临时资源的持有和释放；
- Inspection Plan、检查申请和完整任务上下文的所有权；
- Worker 输出、领域事件和 InspectionPresentation 的载荷转移；
- 状态投影、AppViewSnapshot 和优雅关机的资源释放顺序。

关键约束：

- 释放共享引用只结束当前持有者的所有权，底层对象在最后一个共享引用释放后销毁；
- 状态外准备只有在操作成功提交后才能成为领域状态资源，失败、拒绝或过滤必须释放未提交资源；
- App Controller 当前模式的 `optional_presentation` 是最近一次 InspectionPresentation 的唯一领域真值，GUI 只持有其最新状态快照；
- EditMode 的 Draft Config 是唯一权威可变草稿；编辑屏幕只发布完整、不可变且可独立存活的草稿值投影；
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

### 9.1 分类与公共规则

v1 将错误与结果分为四类：

1. **应用命令业务错误**：命令在当前业务条件下无法执行，通过命令响应返回；
2. **检查执行错误**：Inspection Core 无法正常完成算子或判定求值，以 `InspectionError` 作为 WorkerOutcome 载荷；
3. **检查终止事件**：Inspection Actor 对外发布的 `InspectionCompleted`、`InspectionFailed` 或 `InspectionTimedOut` 领域事实；
4. **致命错误**：内部契约、协议、不变量或基础设施失效，直接 `panic`。

`Completed(Pass)` 和 `Completed(Fail)` 都是正常完成。业务判定 `Fail`、没有检测到目标等正常业务事实、没有可视化数据、协作取消以及过期消息被丢弃均不得转换为业务错误。除本文另有规定外，业务错误不改变命令处理前的状态或已提交资源，系统不进行隐式重试。

### 9.2 应用命令业务错误

概念类型为：

```text
AppCommandError
├── Busy(active_metadata)
├── NoFrame
├── InvalidMode(command, actual_mode, expected_mode)
├── ConfigLoadFailed(config_path, phase, diagnostic)
├── ConfigInvalid(location?, code, diagnostic)
├── ConfigSaveFailed(config_path, phase, diagnostic)
└── ShuttingDown
```

上述字段是逻辑上的最小上下文，不限定 Rust 表示。`code` 用于稳定分类，`diagnostic` 用于诊断或展示，不得要求 GUI 解析任意诊断文本决定业务行为。

| 错误 | 产生边界 | 状态与资源 | 展示及再次操作 |
| --- | --- | --- | --- |
| `Busy` | Inspection Actor 在 `Running` 或 `Cancelling` 中拒绝申请 | 不改变 Actor 状态；释放被拒绝申请持有的引用 | 可以展示活动任务；Actor 回到 `Idle` 后可发起新申请 |
| `NoFrame` | App Controller 从 Latest Frame Store 固定检查帧 | 不提交检查申请，不改变状态 | 可以提示暂无完整帧；有帧后可发起新命令 |
| `InvalidMode` | App Controller 校验命令与当前 AppState | 不执行命令内容，不改变状态 | 可以提示操作已失效；进入期望模式后可发起新命令 |
| `ConfigLoadFailed` | Scheme Manager 读取并解析配置文件 | 不形成可提交的内存配置，释放读取和解析临时资源 | 可以展示路径、阶段和诊断；修复外部条件后可重试 |
| `ConfigInvalid` | App Controller 字段校验或 Scheme Manager 完整校验 | 不提交修改、模式或方案，释放校验临时资源 | 可以展示位置、错误码和诊断；修改配置后可重试 |
| `ConfigSaveFailed` | Scheme Manager 保存事务 | 原文件和内存草稿的已提交 revision 保持不变 | 可以展示路径、阶段和诊断；用户可以重新发起保存 |
| `ShuttingDown` | App Controller 已进入 `ShuttingDown` | 不执行普通命令，不改变关机流程 | GUI 不再提供业务操作；当前进程内不可重试普通命令 |

配置错误按处理阶段划分：

- `ConfigLoadFailed` 表示 Scheme Manager 未能从指定文件取得完整内容并将其解析为内存 `InspectionSchemeConfig`；
- `ConfigInvalid` 表示内存 `InspectionSchemeConfig` 已经形成，但未通过完整静态校验；
- 完整校验成功的配置无法构建为完整 Inspection Plan 不属于业务错误，直接 `panic`。

保存草稿仍必须在提交保存事务前实际构建一次完整 Inspection Plan。该方案不进入 EditMode，并在保存命令结束时释放。

### 9.3 检查执行错误与正常结果

Inspection Core 的终止类型为：

```text
InspectionCoreOutcome
├── Completed(InspectionCoreOutput)
├── Failed(InspectionError)
└── Cancelled
```

`InspectionError` 只表示已经构建的方案在执行算子或最终判定时无法正常完成，不包含业务判定 `Fail`、配置错误、超时或取消。其分类至少为：

```text
InspectionError
├── OperatorExecutionFailed
│   ├── stage_id
│   ├── operator_id
│   ├── code
│   └── diagnostic
└── DecisionEvaluationFailed
    ├── decision_rule_kind
    ├── code
    └── diagnostic
```

算子内部的算法库错误、输入格式不支持、派生产物计算失败或无法履行输出契约，按对应算子及 StageId 归入 `OperatorExecutionFailed`。每个具体算子必须声明稳定错误码及其上下文；错误诊断文本不得作为程序分支依据。

Inspection Actor 只在 `Running` 中处理匹配的 `Completed` 时构造：

```text
InspectionResult
├── decision: Pass | Fail
├── measurements
├── defects
└── optional_visualization
```

测量、缺陷和可视化数据必须按 StageId 关联来源；多阶段数据按可执行阶段顺序稳定排列。没有可视化数据使用明确的缺省表示。InspectionResult 不携带 InspectionMetadata 或 Frame。

### 9.4 检查领域事件与展示对象

正常完成和执行失败共享以下唯一组合边界：

```text
InspectionPresentation
├── metadata: InspectionMetadata
├── frame: Shared<Frame>
└── outcome
    ├── Completed(InspectionResult)
    └── Failed(InspectionError)
```

InspectionResult 和 InspectionError 不重复携带 InspectionMetadata。领域事件结构为：

```text
InspectionEvent
├── InspectionCompleted(presentation)
├── InspectionFailed(presentation)
└── InspectionTimedOut(metadata)
```

终止语义：

- `InspectionCompleted` 只由 `Running` 中匹配的 `Completed` 产生，包含 `Pass` 或 `Fail`；
- `InspectionFailed` 只由 `Running` 中匹配的 `Failed` 产生，并通过 Presentation 持有关联 Frame；
- `InspectionTimedOut` 只在执行超时首先触发 `Cancelling`、固定原因为 `Timeout`，且 Actor 在适用取消截止消息前处理到匹配 WorkerOutcome、释放任务资源并提交 `Idle` 后产生；
- `InspectionTimedOut` 只携带 metadata，不携带 Frame 或 Presentation，也不替换最近一次 Presentation；
- Actor 进入 `Cancelling` 后，匹配的 Completed 或 Failed 业务载荷必须丢弃，不得生成正常结果或失败展示；
- `ReturnHome` 或 `Shutdown` 取消不产生 InspectionEvent。

App Controller 按 ApplicationLifecycle、AppState 和事件中的 `mode_session_id` 过滤事件。Completed 和 Failed 从 `presentation.metadata` 取得会话标识，TimedOut 从自身 metadata 取得；不存在事件顶层 metadata 与 Presentation metadata 的重复副本。只有通过过滤的 Completed 或 Failed 才原子替换当前模式的 Presentation。

检查失败、超时或取消后，v1 不恢复或重放原任务。用户只能发起一次使用命令处理时最新输入的新检查。

### 9.5 致命错误

以下情况不属于可恢复业务错误，直接 `panic`：

- 任一组件、算子注册表或设备初始化失败；
- 摄像头采集、SDK 缓冲区复制、Frame 构造、采集循环停止或设备关闭失败；
- 完整校验成功的配置无法构建为完整 Inspection Plan；
- Worker 任务提交失败，或者 Worker、Inspection Core 或算子发生未声明的 panic；
- `Running` 中收到当前任务匹配的 `Cancelled`；
- Actor 在匹配 WorkerOutcome 之前先处理适用的取消截止消息；
- revision 溢出、注册表描述符无效、阶段输出违反已声明契约或其他内部不变量被破坏；
- 组件关闭协议顺序错误、组件关闭失败、组件关闭截止先于对应确认被处理，或内部通信基础设施失效。

致命错误不得转换为 `ConfigInvalid`、`InspectionError` 或伪造的 InspectionEvent。`panic` 是异常终止出口，不是 ApplicationLifecycle 的 `Terminated`，也不保证完成业务级回滚或优雅资源释放。

## 10. 系统级不变量

具体规约见 [Contract/SystemInvariants.md](./Contract/SystemInvariants.md)，整理和维护方法见 [Contract/SystemInvariantsGuide.md](./Contract/SystemInvariantsGuide.md)。

系统级不变量按以下九类性质组织：

1. 权威与状态所有权；
2. 状态合法性与守卫；
3. 身份、关联与作用域；
4. 原子性与提交一致性；
5. 顺序、串行化与竞争裁决；
6. 资源生命周期与隔离；
7. 协议基数与交付语义；
8. 不可变性、确定性与副作用边界；
9. 进展、终止与故障边界。

`SystemInvariants.md` 只定义跨组件核心不变量；识别边界、性质与流程双轴检查、覆盖矩阵、完整性判定和维护步骤只在 `SystemInvariantsGuide.md` 中定义。
