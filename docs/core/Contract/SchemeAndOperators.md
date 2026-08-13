# 配置、方案与算子规约

本文定义视觉检测配置的有效性、不可变 Inspection Plan 的构建边界，以及不依赖具体算子类型的通用执行契约。整体规约索引见 [行为规约](../Contract.md)，方案和任务资源的完整生命周期见 [资源生命周期规约](./Resources.md)，Inspection Core 的取消检查点和终止语义见 [执行、并发与取消规约](./ExecutionAndCancellation.md)。

本文只规定所有算子必须遵守的公共契约，不定义 v1 注册哪些具体算子及其业务参数。

## 1. 配置模型与术语

配置的宏观结构为：

```text
InspectionSchemeConfig
├── scheme_id: SchemeId
├── revision: u64
├── name
├── stages: StageConfig[]
└── decision_rule: DecisionRule

StageConfig
├── stage_id: StageId
├── operator_id: OperatorId
├── enabled: bool
└── parameters

DecisionRule
├── Expression(expression)
├── AlwaysPass
└── AlwaysFail
```

本章使用以下术语：

- **配置阶段**：`stages` 中声明的一个 StageConfig；
- **启用阶段**：`enabled = true` 的配置阶段；
- **禁用阶段**：`enabled = false` 的配置阶段；
- **可执行阶段**：Scheme Manager 根据一个启用阶段完整构建的 Executable Stage；
- **无配置阶段**：配置的 `stages` 为空；
- **无启用阶段**：配置中不存在启用阶段；
- **空执行方案**：Inspection Plan 的 `executable_stages` 为空。

“无配置阶段”“无启用阶段”和“空执行方案”不得简称为含义不清的“空阶段”。判定规则不是阶段；`AlwaysPass` 或 `AlwaysFail` 不改变方案是否为空执行方案。

`stage_id` 的约束：

- 每个配置阶段必须具有 StageId；
- StageId 在同一份配置内唯一，禁用阶段也参与唯一性检查；
- 调整阶段顺序不得隐式改变 StageId；
- 阶段输出、执行错误和可视化数据使用 StageId 关联其来源；
- StageId 标识配置中的阶段实例，OperatorId 标识算子类型，二者不得互相替代。

配置数组顺序定义启用阶段的执行顺序。v1 不根据阶段引用自动重排阶段。

## 2. 配置有效性

### 2.1 校验层级

Scheme Manager 只对已经完整形成的内存 `InspectionSchemeConfig` 执行校验。校验必须按以下层级进行，遇到首个问题时停止并返回 `ConfigInvalid`：

1. `scheme_id`、`revision`、`name` 和 `stages` 满足字段值约束；
2. StageId 在整份配置中唯一；
3. 每个 OperatorId 均能在算子注册表中唯一查得；
4. 每个阶段的参数均能按对应算子声明解析为类型化参数并通过校验；
5. 启用阶段对其他阶段输出的引用有效；
6. DecisionRule 满足静态结构、类型和引用约束。

`revision` 从 `1` 开始。其递增和溢出规则由保存配置草稿用例规定，普通字段修改不得绕过该规则提交 revision。

配置不得包含：

- 可执行代码、脚本、任意函数地址或闭包；
- 未注册算子；
- 依赖运行期全局状态才能解释的参数；
- 对不存在阶段、禁用阶段或执行顺序中后续阶段输出的引用；
- 类型与被引用输出声明不匹配的引用。

### 2.2 禁用阶段

禁用阶段必须接受与启用阶段相同的结构、OperatorId、参数和 StageId 校验，但不构建为 Executable Stage。

禁用阶段：

- 不参与执行；
- 不产生阶段输出、测量、缺陷或可视化数据；
- 不得被启用阶段或 DecisionRule 引用；
- 不得因为当前禁用而掩盖未知算子、无效参数或重复 StageId。

启用阶段只允许引用执行顺序中更早的启用阶段。前向引用和循环依赖均为 `ConfigInvalid`；Scheme Manager 不通过自动重排修复引用顺序。

### 2.3 判定规则有效性

`decision_rule` 是必填字段，不存在空值或隐式默认规则：

- `Expression(expression)` 是类型化声明式表达式；
- `AlwaysPass` 是始终产生 `Pass` 的规则；
- `AlwaysFail` 是始终产生 `Fail` 的规则。

Expression 可以读取其声明允许的检查输入和已完成阶段输出。其每个阶段输出引用必须指向一个启用阶段，并与该阶段声明的输出类型一致；所有启用阶段均在最终判定前按顺序完成。

配置校验不得执行算子或读取实际 Frame。依赖实际图像内容的业务结果属于检查执行，不属于配置有效性。

## 3. 算子注册表

程序维护固定的算子注册表。注册表在应用初始化完成后必须不可变，并至少为每种算子提供：

```text
OperatorDescriptor
├── operator_id: OperatorId
├── parameter_schema
├── input_contract
├── output_contract
├── build_contract
└── cancellation_contract
```

公共约束：

- OperatorId 在注册表中唯一；
- 查询注册表是确定性的，不产生外部业务副作用；
- 参数解析不得进行未声明的隐式类型转换；
- 输入和输出契约必须足以在构建期检查阶段引用；
- 构建成功的 Executable Stage 不得依赖注册表后续变化；
- 重复 OperatorId、无效描述符或注册表初始化失败属于组件初始化失败，直接 `panic`，不作为 `ConfigInvalid`；
- 未在注册表中找到配置引用的 OperatorId 属于 `ConfigInvalid`。

每个具体算子必须另行声明：参数模式、可读取的输入、输出类型、执行错误、取消检查方式，以及从取消信号设置到调用返回的最坏时间上界。尚未给出有界取消保证的算子不得声称支持有界优雅取消。

## 4. 方案构建

### 4.1 构建流程

Scheme Manager 负责执行以下同步流程：

```text
InspectionSchemeConfig
    → 完整校验
    → 解析启用阶段的类型化参数
    → 按配置顺序构建 Executable Stage
    → 构建 DecisionRule
    → Immutable Executable Inspection Plan
```

Inspection Plan 的宏观结构至少包含：

```text
InspectionPlan
├── scheme_id: SchemeId
├── revision: u64
├── executable_stages: ExecutableStage[]
└── decision_rule: ExecutableDecisionRule
```

构建必须是全有或全无的：

- 只有所有可执行阶段和判定规则均构建成功后，才能发布 Inspection Plan；
- 部分阶段、部分解析参数或部分判定结构不得作为 Inspection Plan 返回；
- App Controller 只接收完整 Inspection Plan，不接收部分构建结果；
- 完整校验成功的配置无法构建为完整 Inspection Plan 时，必须释放全部构建临时资源并直接 `panic`；
- 构建未完成时不得向 Inspection Actor 提交检查申请。

### 4.2 错误边界

配置处理按操作边界分为三个阶段：

- `ConfigLoadFailed`：Scheme Manager 未能从指定文件取得完整内容并将其解析为内存 `InspectionSchemeConfig`；
- `ConfigInvalid`：已经形成内存 `InspectionSchemeConfig`，但未通过完整静态校验；
- 方案构建致命错误：已经通过完整校验的配置无法构建为完整 Inspection Plan，表示校验器、算子描述符或构建器之间的内部契约被破坏，直接 `panic`。

`ConfigSaveFailed` 只表示保存事务中的序列化、临时文件写入或原子替换失败。方案已经构建并开始执行后，算子或判定求值失败产生 `InspectionError`，并由 Inspection Actor 在适用条件下发布 `InspectionFailed`。

配置校验成功不产生 Inspection Plan。保存草稿和发起测试检查仍必须按各自用例实际构建方案；保存草稿以实际构建成功为提交前提，构建出的方案不进入模式状态。

### 4.3 可检查性和实现边界

Inspection Plan 是不可变的跨组件契约，其方案身份、revision、阶段顺序、StageId、OperatorId 和判定规则种类必须可检查。

函数指针、trait object、闭包或其他动态分派机制可以作为 Plan 的内部实现，但不得：

- 作为配置数据或跨组件宏观契约；
- 隐式捕获可变业务状态；
- 捕获摄像头、配置文件、GUI、持久化入口或其他外部业务能力；
- 绕过 StageId、输入输出声明、取消或错误契约。

Inspection Actor 和 Inspection Worker 不构建或组装方案；Inspection Core 只执行已经完整构建的 Plan。

## 5. 空执行方案与判定

生产方案和测试方案都允许 `executable_stages` 为空，但 DecisionRule 始终存在。

空执行方案的执行语义为：

1. 不调用任何算子；
2. 在最终判定前按执行与取消规约观察取消信号；
3. 求值已声明的 DecisionRule；
4. 正常产生 `Completed(Pass)` 或 `Completed(Fail)`。

具体结果完全服从已声明规则：

```text
[] + AlwaysPass → Completed(Pass)
[] + AlwaysFail → Completed(Fail)
```

不存在“空执行方案默认 Pass”的隐式行为。需要空执行方案通过时，配置必须显式声明 `AlwaysPass`；实现不得忽略或覆盖 `AlwaysFail`。Expression 若引用任何阶段输出，则至少必须存在满足引用约束的启用阶段，否则配置无效。

`Pass` 和 `Fail` 都表示检查正常完成：

- `Completed(Pass)`：执行正常完成且判定通过；
- `Completed(Fail)`：执行正常完成且判定未通过；
- `Failed(InspectionError)`：算子或判定无法正常执行；
- `Cancelled`：检查按协作式取消终止。

业务判定 `Fail` 不得转换为 InspectionError。

## 6. 算子执行与阶段组合

### 6.1 显式输入与副作用边界

算子只能读取当前调用显式提供的能力：

```text
OperatorInput
├── frame
├── typed_parameters
├── declared_prior_outputs
├── derived_artifact_provider
└── cancellation
```

算子不得：

- 读取 AppState、Latest Frame Store、配置文件、GUI 或未声明的全局状态；
- 控制摄像头、写文件、访问数据库、发送应用消息或执行其他外部业务副作用；
- 修改 Frame、此前阶段输出或已发布的派生产物；
- 在调用结束后保留对执行上下文的借用；
- 隐式执行未在输入契约中声明的其他阶段。

读取 CancellationSignal 和请求任务级派生产物是显式允许的受控执行能力，不视为外部业务副作用。

### 6.2 不可变累计输出

Inspection Core 按 Plan 的线性顺序执行阶段，并维护逻辑上不可变的累计上下文：

```text
InspectionExecutionContext
├── frame
├── stage_outputs: StageId → StageOutput
└── derived_artifacts: ArtifactKey → ImmutableArtifact
```

阶段组合采用 Monad Bind 的短路语义，可概念化为：

```text
initial_context
    bind execute_stage_1
    bind execute_stage_2
    bind ...
    bind evaluate_decision
```

这里的 Bind 是行为语义，不要求实现定义特定名称的 Monad 类型：

- 前一步成功后，下一步才执行；
- 阶段成功时，以旧上下文和本阶段输出形成新的逻辑上下文；
- 已提交的先前阶段输出不得修改或覆盖；
- `Failed(error)` 立即短路，后续阶段和判定不再执行；
- `Cancelled` 立即短路，后续阶段和判定不再执行；
- 本阶段失败或取消时，本阶段尚未提交的输出和临时资源全部释放；
- 所有阶段成功后才求值 DecisionRule。

每个 Executable Stage 恰好对应一个启用配置阶段，并保留其 StageId。一个阶段成功后必须恰好向累计输出表提交一个符合其输出契约的 StageOutput；重复 StageId 或输出类型不符属于内部不变量破坏。

## 7. 通用派生产物缓存

多个算子需要相同通用中间产物时，例如使用相同转换参数的灰度图，不应重复计算。Inspection Core 为单次检查提供任务级派生产物缓存。

```text
ArtifactKey
├── artifact_kind
└── all_result_affecting_parameters
```

缓存契约：

- 缓存只属于当前一次 Inspection Core 调用，不跨检查任务共享；
- ArtifactKey 必须包含所有影响计算结果的参数；
- 同一键在一次检查中至多成功计算一次；
- 成功发布的派生产物不可变，多个算子可以共享读取；
- 计算失败或观察到取消时，不得发布部分产物或失败缓存项；
- 算子只能通过显式 provider 请求产物，不得删除、覆盖或修改缓存项；
- 派生产物不是阶段输出，不得被 DecisionRule 或其他阶段通过 StageId 引用；
- Core 调用完成、失败或取消后释放整个缓存及其中间资源。

实现可以在 Core 调用内部使用受控可变性、惰性初始化或共享引用避免重复计算，但对算子暴露的语义必须等价于从不可变映射读取。并发初始化若未来被允许，也必须保证同一键只发布一个确定结果；v1 的线性执行不要求并发计算派生产物。

## 8. 判定规则执行

DecisionRule 在所有可执行阶段成功后求值：

- `Expression` 只读取其静态声明允许的输入和累计阶段输出；
- `AlwaysPass` 产生 `Pass`；
- `AlwaysFail` 产生 `Fail`；
- 判定求值不得修改累计输出或派生产物缓存；
- 判定求值失败产生 `InspectionError`，不得伪装为业务 `Fail`；
- 判定前和构造 Completed 输出前必须执行第七章规定的取消检查。

Expression 是配置中的类型化声明式数据，不是脚本、闭包或任意可执行代码。Scheme Manager 可以将其构建为内部可执行表示，但该表示必须保持原规则的可检查结构和确定语义。

## 9. 阶段输出与可视化公共契约

本章不规定具体算子的 StageOutput 字段，只规定公共约束：

- StageOutput 必须符合注册表中该算子的输出契约；
- StageOutput 在提交到累计上下文后不可变；
- 输出中的测量、缺陷和可视化数据必须能够关联到来源 StageId；
- 后续阶段只能按声明的类型读取更早阶段输出；
- 未检测到目标等正常业务事实应表达为算子声明的正常输出，不应仅因判定可能为 Fail 就产生 InspectionError；
- 算法库错误、输入格式不支持或算子无法履行输出契约属于执行错误。

可视化数据是可选的正常输出数据：

- 没有可视化数据必须使用明确的缺省表示，不构造虚假图元；
- 可视化数据不得持有 GUI 对象或执行 GUI 操作；
- 多阶段可视化按可执行阶段顺序稳定合并，阶段内保持算子输出顺序；
- 算子失败或取消时，本阶段未提交的可视化数据随其他临时输出释放；
- 最终可视化必须能够映射到关联 Frame；具体图元种类和坐标表示由后续具体算子及展示契约定义。

## 10. 方案所有权摘要

Inspection Plan 的详细资源规则以 [资源生命周期规约](./Resources.md#7-inspection-plan) 为准。本章只重申构建相关边界：

- ProductionMode 持有不可变生产方案；
- 测试方案只属于单次测试命令和对应任务，不进入 EditMode；
- 检查申请通过不可变共享引用携带完整 Plan；
- Worker 接受任务后，Actor 和 Worker 分别持有执行所需引用，Actor 随后提交 `Running`；
- 申请返回 `Busy` 时释放申请持有的 Frame 和 Plan 引用；
- 被拒绝的生产申请不影响 ProductionMode 持有的生产方案；
- Plan 不使用空引用表示缺少方案，但其 executable_stages 可以为空。

## 11. 本章不变量

1. 配置不包含可执行代码、任意函数地址或未注册算子。
2. StageId 在同一配置中唯一，且独立于阶段顺序和 OperatorId。
3. 禁用阶段完整校验但不构建、不执行、不产生输出且不得被引用。
4. 启用阶段只能引用执行顺序中更早的启用阶段，v1 不自动重排。
5. DecisionRule 始终存在，并且只能是 Expression、AlwaysPass 或 AlwaysFail。
6. 空执行方案仍执行其已声明的 DecisionRule，不存在隐式默认判定。
7. Inspection Plan 只有完整构建成功后才能发布，发布后始终不可变。
8. Inspection Actor、Inspection Worker 和 Inspection Core 不构建或修改 Plan。
9. 算子只使用显式输入，不执行外部业务副作用。
10. 阶段输出提交后不可变；失败或取消不得提交本阶段部分输出。
11. 阶段组合遵循成功继续、失败或取消短路的 Bind 语义。
12. 相同 ArtifactKey 的通用派生产物在单次检查中至多成功计算一次，且不跨任务共享。
13. Pass 和 Fail 都是正常判定结果，不得与执行失败或取消混淆。
14. 具体算子必须满足其声明的输入、输出、错误和取消契约。
15. 完整校验成功的配置必须构建为完整 Inspection Plan，否则直接 `panic`。
