# 配置、方案与算子规约

本文定义视觉检测配置的有效性、不可变 Inspection Plan 的构建边界，以及不依赖具体算子类型的通用执行契约。DecisionRule.Expression 的封闭抽象语法和静态类型系统见[判定表达式语法与类型规约](./DecisionExpression.md)。整体规约索引见[行为规约](../Contract.md)，方案和任务资源的完整生命周期见[资源生命周期规约](./Resources.md)，Inspection Core 的取消检查点和终止语义见[执行、并发与取消规约](./ExecutionAndCancellation.md)。

本文规定所有算子必须遵守的公共契约；完整 `OperatorDescriptor`、稳定错误码和派生产物声明见[算子描述符规约](./OperatorDescriptor.md)。v1 注册的具体算子由独立算子文档定义。

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

### 1.1 草稿字段权限与版本

EditMode 中只有 `name`、`stages` 和 `decision_rule` 可以通过 `ModifyDraft` 修改。`scheme_id` 和 `revision` 是只读字段：`scheme_id` 在整个编辑会话中保持不变；`revision` 只能由成功的 `SaveDraft` 按保存用例递增。v1 不支持克隆方案、另存为或改变方案身份。

EditMode 另外持有不写入配置文件的 `draft_version: u64`。进入 EditMode 时其值为 `0`；每次成功提交 `ModifyDraft`，以及每次成功执行 `SaveDraft` 并更新 `revision` 后递增一次。业务失败不得改变该值；发生溢出时直接 `panic`。`draft_version` 只标识当前编辑会话内的草稿提交，不替代持久化 `revision`。

`name` 必须包含 1 至 128 个 Unicode 标量值，不得包含 Unicode 控制字符，且首尾不得为空白字符；系统不得隐式裁剪或规范化名称。SchemeId 和 StageId 的词法有效性由对应标识类型的构造契约定义。

### 1.2 DraftMutation

`ModifyDraft` 使用封闭的强类型修改模型：

```text
DraftMutation
├── SetName(name)
├── InsertStage
│   ├── before_stage_id: Optional<StageId>
│   └── stage: StageConfig
├── RemoveStage(stage_id)
├── MoveStage
│   ├── stage_id
│   └── before_stage_id: Optional<StageId>
├── SetStageEnabled
│   ├── stage_id
│   └── enabled
├── ReplaceStageDefinition
│   ├── stage_id
│   ├── operator_id
│   └── parameters
├── ReplaceStageParameters
│   ├── stage_id
│   └── parameters
└── SetDecisionRule(decision_rule)
```

`before_stage_id = None` 表示追加到阶段列表末尾。插入阶段的 StageId 由命令调用方提供；App Controller 必须校验其有效性和在当前草稿中的唯一性。移动、启用状态修改、算子替换和参数替换均不得改变目标 StageId。算子类型和参数可以通过 `ReplaceStageDefinition` 原子地一起替换；参数单独修改使用 `ReplaceStageParameters`，v1 不提供任意字符串字段路径、通用 JSON Patch、mutation 数组或整表 `ReplaceAllStages`。

一次 `ModifyDraft` 只能携带一个 DraftMutation 变体。App Controller 必须先基于当前草稿形成候选值并完成该变体规定的字段级校验，再全有或全无地提交 Draft Config 和新的 `draft_version`。失败时必须丢弃候选值，不得改变草稿、`draft_version` 或草稿快照。

### 1.3 字段级校验

字段级校验保证 mutation 可以明确定位目标、新值自身合法且修改后的草稿仍可完整表示；它不保证整份草稿能够通过完整配置校验或构建 Inspection Plan。

| Mutation | 必须执行的字段级校验 | 延迟到完整配置校验的事项 |
| --- | --- | --- |
| `SetName` | 名称满足第 1.1 节约束 | 无跨字段事项 |
| `InsertStage` | 插入锚点存在；StageId 有效且唯一；OperatorId 已注册；参数符合该算子的参数模式 | 阶段引用、执行顺序和判定规则引用 |
| `RemoveStage` | 目标阶段存在 | 其他阶段或判定规则是否仍引用该阶段 |
| `MoveStage` | 目标和锚点存在，且锚点不是目标自身 | 移动后的阶段引用顺序 |
| `SetStageEnabled` | 目标阶段存在 | 启用状态变化造成的跨阶段引用有效性 |
| `ReplaceStageDefinition` | 目标存在；新 OperatorId 已注册；参数符合新算子的参数模式 | 后续阶段和判定规则的输出引用兼容性 |
| `ReplaceStageParameters` | 目标存在；参数符合当前算子的参数模式 | 参数中跨阶段引用的存在性、顺序和类型 |
| `SetDecisionRule` | 规则变体、表达式结构、字面量和不依赖阶段类型环境即可判定的类型关系合法 | 被引用阶段的存在性、启用状态、判定字段存在性及完整表达式类型 |

字段级类型校验必须拒绝不需要解析 StageOutputRef 即可确定的类型错误，例如以 `Int64` 字面量作为 `Not` 的操作数。只要类型判断依赖 StageOutputRef 的实际字段类型，就延迟到完整配置校验；字段级校验不得猜测引用类型。

因此，字段修改成功后草稿可以暂时包含悬空引用、对禁用阶段的引用、前向引用或输出类型不匹配。`ValidateDraft`、`SaveDraft` 和 `StartTestInspection` 必须通过完整配置校验发现这些问题。禁用阶段在字段级修改中仍执行与启用阶段相同的 StageId、OperatorId 和参数自身校验。

字段级校验失败统一返回 `ConfigInvalid(location, code, diagnostic)`。`location` 必须是结构化位置，例如 `name`、`stages[stage_id=<id>]`、`stages[stage_id=<id>].parameters.threshold` 或 `decision_rule`；GUI 不得解析 `diagnostic` 决定程序行为。稳定错误码至少包括：

```text
name.empty
name.too_long
name.invalid_character
stage.not_found
stage.anchor_not_found
stage.invalid_id
stage.duplicate_id
stage.self_anchor
operator.unknown
parameters.invalid
decision_rule.invalid_structure
decision_rule.invalid_expression
decision_rule.expression_too_deep
decision_rule.expression_too_large
decision_rule.invalid_literal
decision_rule.invalid_arity
decision_rule.invalid_operand_type
```

具体算子的参数错误码必须位于 `operator.<operator_id>.parameter.<code>` 命名空间。完整配置校验的跨字段错误码至少包括 `reference.stage_not_found`、`reference.stage_disabled`、`reference.forward_reference`、`reference.output_type_mismatch`、`decision_rule.reference_stage_not_found`、`decision_rule.reference_stage_disabled`、`decision_rule.reference_field_not_found`、`decision_rule.reference_type_mismatch` 和 `decision_rule.root_type_mismatch`。错误码是稳定分类，诊断文本只用于展示和诊断。Expression 错误的 `location` 必须定位到对应 AST 节点；GUI 不得依赖节点位置的展示文本推断错误类别。

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
- 启用阶段对不存在阶段、禁用阶段或执行顺序中后续阶段输出的引用；
- DecisionRule 对不存在阶段、禁用阶段或未声明判定字段的引用；
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

- `Expression(expression)` 是符合[判定表达式语法与类型规约](./DecisionExpression.md)的类型化声明式表达式；
- `AlwaysPass` 是始终产生 `Pass` 的规则；
- `AlwaysFail` 是始终产生 `Fail` 的规则。

v1 Expression 只能读取字面量和启用阶段输出契约显式声明的判定字段，不得直接读取 Frame、图像像素、InspectionMetadata、当前时间、随机数、AppState、GUI 状态、配置文件、派生产物缓存，或者测量、缺陷和可视化对象的未声明内部字段。算子需要让某项结果参与判定时，必须在输出契约中将其声明为稳定类型的判定字段。

完整配置校验必须根据全部启用阶段的判定字段声明建立引用类型环境，并按表达式语法规约检查每个引用、操作数和根节点。每个 StageOutputRef 必须满足：

1. StageId 存在且对应阶段已启用；
2. 对应算子的输出契约声明了该 DecisionFieldId；
3. 引用取得的 ExpressionType 满足所在表达式节点的类型要求。

DecisionRule 在所有启用阶段完成后求值，因此可以引用配置中任意位置的启用阶段，不适用阶段间引用的前向引用限制。所有引用都必须静态校验，包括因 `And` 或 `Or` 短路而可能未在某次执行中读取的引用。

配置校验不得执行算子、读取实际 StageOutput 或读取实际 Frame。依赖实际图像内容的业务结果属于检查执行，不属于配置有效性。

## 3. 算子注册表

程序维护固定的算子注册表。注册表在应用初始化完成后必须不可变，每种算子必须提供符合[算子描述符规约](./OperatorDescriptor.md)的完整描述符：

```text
OperatorDescriptor
├── operator_id: OperatorId
├── parameter_contract
├── input_contract
├── output_contract
├── build_contract
├── execution_contract
└── cancellation_contract
```

输出契约必须声明封闭的 StageOutput 名义类型，并显式列出可供 DecisionRule 读取的顶层判定字段。DecisionFieldId 必须匹配 `[a-z][a-z0-9_]{0,63}`，在同一个 OutputContract 中唯一且稳定；其 ExpressionType 必须与被映射 StageOutput 字段完全一致。没有判定字段时使用空数组。

公共约束：

- OperatorId 在注册表中唯一；
- 查询注册表是确定性的，不产生外部业务副作用；
- 参数解析不得进行未声明的隐式类型转换；
- 输入和输出契约必须足以在构建期检查阶段引用和 DecisionRule 的判定字段引用；
- 构建成功的 Executable Stage 不得依赖注册表后续变化；
- 重复 OperatorId、无效描述符或注册表初始化失败属于组件初始化失败，直接 `panic`，不作为 `ConfigInvalid`；
- 未在注册表中找到配置引用的 OperatorId 属于 `ConfigInvalid`。

每个具体算子必须另行声明参数模式、可读取输入、完整 StageOutput、DecisionField、正常业务结果、稳定参数及执行错误码、取消检查方式、最坏取消响应时间和资源上界。尚未给出有界取消保证的算子不得声称支持有界优雅取消。

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

`ConfigSaveFailed` 只表示保存事务中的序列化、临时文件写入或原子替换失败。保存成功保证同一运行环境中替换后的文件对后续读取可见，不承诺掉电或操作系统崩溃后的持久性，不要求额外执行文件或目录同步。方案已经构建并开始执行后，算子或判定求值失败产生 `InspectionError`，并由 Inspection Actor 在适用条件下发布 `InspectionFailed`。

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

多个算子需要相同通用中间产物时，例如使用相同转换参数的灰度图，不应重复计算。Inspection Core 为单次检查提供任务级 Provider 和派生产物缓存；完整描述符和类型规则见[算子描述符规约](./OperatorDescriptor.md#8-任务级派生产物)。

```text
ArtifactKey<T>
├── artifact_kind
└── all_result_affecting_parameters
```

派生产物采用首次请求时惰性计算，不在 Plan 执行前预计算全部需求。第一个请求方触发 Provider 调用该 ArtifactKind 唯一注册的生产者；成功结果发布为不可变共享产物，后续相同键请求直接取得共享引用。

缓存契约：

- 缓存只属于当前一次 Inspection Core 调用，不跨检查任务或 Frame 共享；
- ArtifactKey 必须包含所有影响计算结果的参数；
- 同一 ArtifactKind 只能有一个稳定生产语义，改变语义必须更换 ArtifactKind；
- 同一键在一次检查中至多成功计算一次；
- 成功发布的派生产物不可变，多个算子可以共享读取；
- 计算失败或观察到取消时，不得发布部分产物或失败缓存项；
- 算子只能请求描述符已声明并在构建期绑定的类型化键，不得直接删除、覆盖、修改缓存项或自行发布共享产物；
- 派生产物不是阶段输出，不得被 DecisionRule 或其他阶段通过 StageId 引用；
- 首次生产失败归入当前请求阶段的 OperatorExecutionFailed；
- Core 调用完成、失败或取消后释放整个缓存及其中间资源。

v1 的线性执行不要求并发初始化。未来允许并发请求时，也必须保证同一键只发布一个确定结果。

## 8. 判定规则执行

DecisionRule 在所有可执行阶段成功后求值：

- `Expression` 只读取字面量和已静态解析的累计阶段输出判定字段；
- `AlwaysPass` 产生 `Pass`；
- `AlwaysFail` 产生 `Fail`；
- Expression 根节点求值为 `true` 时产生 `Pass`，为 `false` 时产生 `Fail`；
- 判定求值不得修改累计输出或派生产物缓存；
- 判定求值失败产生 `InspectionError`，不得伪装为业务 `Fail`；
- 判定前和构造 Completed 输出前必须执行[执行、并发与取消规约](./ExecutionAndCancellation.md)规定的取消检查。

Expression 按 AST 递归求值。`Compare` 先求值左操作数，再求值右操作数；`And` 和 `Or` 按操作数配置顺序从左到右求值，`And` 遇到 `false` 后短路，`Or` 遇到 `true` 后短路。求值顺序不得由实现、编辑器或优化过程改变。

`Bool` 和 `Int64` 使用对应值的精确比较；`Float64` 只比较有限值，并使用 IEEE 754 的数值比较关系，其中正零和负零相等；`String` 按 Unicode 标量值序列精确、区分大小写地比较，不执行裁剪、大小写折叠或 Unicode 规范化。

Expression 求值必须是确定性的且无外部业务副作用。相同表达式和相同累计阶段输出必须产生相同结果。Scheme Manager 可以将 Expression 构建为内部可执行表示，但该表示必须保持原 AST 的可检查结构、类型、引用、求值顺序和结果语义。

通过完整校验并成功构建后，所有 StageOutputRef 均已绑定到具体启用阶段和判定字段。运行期缺少已绑定阶段输出或判定字段，或者实际字段类型不符合 OutputContract，表示阶段输出或 Plan 内部不变量被破坏，直接 `panic`，不得转换为 `Fail` 或 `ConfigInvalid`。v1 表达式节点本身均为全函数；`DecisionEvaluationFailed` 保留用于判定执行无法正常完成的其他已声明错误，不得用于掩盖内部不变量破坏。

## 9. 阶段输出与可视化公共契约

本章不规定具体算子的 StageOutput 字段，只规定公共约束：

- StageOutput 必须符合注册表中该算子的输出契约；
- StageOutput 在提交到累计上下文后不可变；
- 输出中的测量、缺陷和可视化数据必须能够关联到来源 StageId；
- 后续阶段只能按声明的类型读取更早阶段输出；
- StageOutput 必须为 OutputContract 中每个判定字段提供一个类型完全一致的不可变值；
- DecisionRule 不得读取 OutputContract 未声明为判定字段的 StageOutput 内容；
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
5. DecisionRule 始终存在，并且只能是 Expression、AlwaysPass 或 AlwaysFail；Expression 必须符合独立语法规约并且根节点类型为 Bool。
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
16. DecisionRule 只能读取启用阶段显式声明的判定字段；运行期判定字段缺失或类型不符属于内部不变量破坏。
