# 算子描述符规约

本文定义 v1 算子注册表中 `OperatorDescriptor` 的完整结构、参数和输入输出类型、构建与执行错误、取消契约，以及任务级派生产物的声明和复用方式。配置、方案构建和阶段组合的公共规则见[配置、方案与算子规约](./SchemeAndOperators.md)，规范 Frame 见[规范 Frame 规约](./FrameFormat.md)，Inspection Core 的取消边界见[执行、并发与取消规约](./ExecutionAndCancellation.md)。

## 1. 设计边界

每种可注册算子必须具有一个完整且可自校验的描述符：

```text
OperatorDescriptor
├── operator_id: OperatorId
├── parameter_contract: ParameterContract
├── input_contract: InputContract
├── output_contract: OutputContract
├── build_contract: BuildContract
├── execution_contract: ExecutionContract
└── cancellation_contract: CancellationContract
```

描述符是程序内固定规约，不是配置数据。注册表初始化必须校验描述符内部一致性；重复 OperatorId、无效类型引用、重复字段、错误码冲突或互相矛盾的契约均属于组件初始化失败，直接 `panic`。注册表发布后不可变。

## 2. 参数契约

```text
ParameterContract
├── schema: ParameterSchema
├── validation_rules: ParameterValidationRule[]
└── error_codes: ParameterErrorDescriptor[]
```

### 2.1 封闭参数模式

```text
ParameterSchema
├── Bool
├── Int64(minimum?, maximum?)
├── Float64(minimum: FloatBound?, maximum: FloatBound?)
├── String(min_length, max_length)
├── Enum(variants: String[])
├── Object(fields: ParameterField[])
├── Array(item_schema, min_items, max_items)
└── StageOutputReference(expected_output_type, expected_field_type)

FloatBound
├── value: Float64
└── inclusive: bool

ParameterField
├── field_id
├── required: bool
└── schema: ParameterSchema
```

参数模式必须满足：

- Object 不接受未声明字段；
- 不执行隐式类型转换；
- Float64 只接受有限值；
- 必填字段不得由实现隐式补默认值；
- v1 不定义通用 `null`，非必填字段以字段缺失表示未提供；
- Enum 只接受描述符列出的稳定值；
- 数组顺序具有业务意义，元素数量必须有有限上界；
- StageOutputReference 必须声明预期输出类型和字段类型。

Object 字段按描述符声明顺序校验；Array 元素按索引顺序校验；`validation_rules` 按描述符顺序校验。任一层遇到首个错误即停止，确保同一无效参数产生确定的首个错误。

`validation_rules` 表达无法仅靠单字段边界描述的关系约束。规则必须是确定性的纯校验，不得读取 Frame、运行期状态或外部环境。

### 2.2 参数错误

参数错误码必须位于：

```text
operator.<operator_id>.parameter.<code>
```

每个错误描述符必须给出稳定错误码和适用的参数位置。`ConfigInvalid.location` 必须定位到具体字段；`diagnostic` 只用于诊断和展示。完整配置校验不得用一条笼统的 `parameters.invalid` 掩盖具体算子已经声明的稳定错误。

## 3. 输入契约

```text
InputContract
├── frame_access: None | Required
├── prior_outputs: PriorOutputInputDescriptor[]
└── derived_artifacts: DerivedArtifactRequirement[]
```

v1 的 Frame 只含规范 `Rgb8Image`，因此不使用运行期 `FrameFormatId`。`frame_access = Required` 表示算子可以借用当前任务的不可变 Frame；`None` 表示不得读取 Frame。

### 3.1 前序阶段输出

```text
PriorOutputInputDescriptor
├── input_id
├── expected_stage_output_type
├── binding_parameter_path
└── required: bool
```

每个前序输出输入必须通过参数中的 StageOutputReference 显式绑定。Scheme Manager 必须在构建期验证目标阶段存在、已启用、位于当前阶段之前且输出类型匹配。算子执行时只能取得已经绑定的输入，不得按任意 StageId 查询累计上下文。

### 3.2 派生产物需求

```text
DerivedArtifactRequirement
├── artifact_kind: ArtifactKind
├── parameter_bindings
└── expected_type: ArtifactType
```

需求声明算子可以请求的派生产物种类、所有影响结果的参数如何从类型化算子参数绑定，以及预期的静态输出类型。构建后的 Executable Stage 必须持有具体的类型化 ArtifactKey；算子不得构造或请求未在描述符中声明的键。

## 4. 输出契约

```text
OutputContract
├── stage_output_type: StageOutputTypeId
├── stage_output_schema: StageOutputSchema
├── decision_fields: DecisionFieldDescriptor[]
├── measurements: MeasurementDescriptor[]
├── defects: DefectDescriptor[]
└── visualization: VisualizationDescriptor[]
```

### 4.1 StageOutput

```text
StageOutputSchema
└── fields: StageOutputFieldDescriptor[]

StageOutputFieldDescriptor
├── field_id
├── value_schema
├── required: bool
└── semantic
```

StageOutput 是封闭、不可变的名义类型。字段名称、类型、单位和语义必须稳定；成功执行时必须产生全部必填字段。StageOutput 提交到累计上下文后不得修改。

### 4.2 判定字段

```text
DecisionFieldDescriptor
├── field_id: DecisionFieldId
├── output_field_id
└── value_type: ExpressionType
```

判定字段只能映射到 StageOutput 的公开顶层字段。`field_id` 必须匹配 `[a-z][a-z0-9_]{0,63}`，在同一输出契约中唯一；`value_type` 只能是 Bool、Int64、Float64 或 String，并且必须与被映射字段完全一致。未列入 `decision_fields` 的 StageOutput 字段不得被 DecisionRule 读取。

### 4.3 测量、缺陷和可视化

具体算子必须分别声明可能产生的测量、缺陷和可视化类型，以及单位、坐标系、缺省表示和稳定顺序。没有此类输出时使用空描述符数组。正常业务不匹配可以产生缺陷或标记，但不得因此返回执行错误。

## 5. 构建契约

```text
BuildContract
├── typed_parameter_type
├── executable_operator_type
├── build_inputs
└── postconditions
```

构建流程为：

```text
validated parameters
    → typed parameters
    → bound prior outputs and artifact keys
    → immutable executable operator
```

构建只能读取已经验证的类型化参数、静态绑定、不可变描述符和应用级固定执行配置，不得读取 Frame、摄像头、GUI、配置文件、AppState、当前时间、随机数或可变全局业务状态。

完整配置校验成功后，构建必须成功。此后仍发生参数解析、引用绑定或执行对象构造失败，表示校验器、描述符和构建器之间的内部契约被破坏，直接 `panic`。

## 6. 执行契约

```text
ExecutionContract
├── normal_outcomes
├── error_codes: ExecutionErrorDescriptor[]
├── determinism_contract
└── resource_contract
```

算子同步调用的概念结果为：

```text
OperatorOutcome
├── Completed(StageOutput)
├── Failed(OperatorExecutionError)
└── Cancelled
```

- `Completed` 包括匹配、不匹配、未检测到目标、无缺陷或无可视化等正常业务结果；
- `Failed` 只表示算法无法对有效的显式输入履行输出契约；
- `Cancelled` 表示算子观察到取消并协作返回，不是执行错误；
- `Failed` 或 `Cancelled` 均不得提交部分 StageOutput、测量、缺陷或可视化。

执行错误码必须位于：

```text
operator.<operator_id>.execution.<code>
```

Inspection Core 使用当前 StageId 和 OperatorId 将错误包装为 `OperatorExecutionFailed`。错误诊断文本不得作为程序分支依据。实际输出违反 OutputContract 属于内部不变量破坏，直接 `panic`，不得转换为执行错误。

确定性契约必须声明数值运算顺序、是否允许并行归并或近似计算，以及所有影响结果的输入。v1 算子不得读取时间、随机数或未声明状态；相同显式输入必须产生相同正常结果。

资源契约必须给出临时内存上界或其关于受限输入尺寸的计算方式。算子不得在调用返回后保留对输入、Provider 或执行上下文的借用。

## 7. 取消契约

```text
CancellationContract
├── observation_mode: BoundedByWholeInvocation | Cooperative
├── checkpoints
├── max_work_between_checkpoints
├── max_cancel_latency
└── cleanup_contract
```

取消由 Inspection Actor 发起和裁决，Worker 传递观察端，Inspection Core 在阶段边界观察。算子不得设置或复位 CancellationSignal、决定取消原因、管理截止时间或发送组件消息。

`BoundedByWholeInvocation` 适用于整个同步调用已有严格时间上界的算子；`Cooperative` 算子必须在声明的内部安全检查点观察同一个 CancellationSignal。观察到取消后，算子必须释放未提交临时资源并返回 `Cancelled`。

注册的描述符必须携带针对受支持部署环境和最大输入规模确定的 `max_cancel_latency`。它与 Inspection Core 边界处理余量之和必须小于应用取消宽限期；否则注册表初始化失败。仅声明算法复杂度或检查频率不能替代时间上界。

## 8. 任务级派生产物

### 8.1 描述符与类型

通用派生产物由固定注册表中的唯一生产者定义：

```text
DerivedArtifactDescriptor
├── artifact_kind: ArtifactKind
├── parameter_schema
├── output_type: ArtifactType
├── producer_contract
├── execution_errors
└── cancellation_contract
```

同一 ArtifactKind 在注册表中只能有一个稳定生产语义。改变结果语义时必须使用新的 ArtifactKind；不得让两个算子以同一个键提供不同计算实现。

Provider 对算子暴露类型化请求：

```text
ArtifactKey<T>
├── artifact_kind
└── all_result_affecting_parameters

DerivedArtifactOutcome<T>
├── Completed(ImmutableShared<T>)
├── Failed(DerivedArtifactError)
└── Cancelled
```

稳定 ArtifactKind 用于描述符检查和错误诊断，类型参数 `T` 保证请求方不能把灰度图读取为其他产物类型。ArtifactKind 与输出类型不匹配属于注册表或 Plan 内部不变量破坏。

派生产物错误码必须位于 `artifact.<artifact_kind>.execution.<code>` 命名空间。需要该产物的算子必须在自己的 ExecutionContract 中声明对应的稳定包装错误码或确定映射；不得把未声明的 Artifact 错误直接泄漏为算子错误码。

### 8.2 惰性计算和缓存

派生产物固定采用首次请求时惰性计算，不在 Plan 执行前预计算全部需求：

```text
first get(key)
    → cache miss
    → Provider invokes registered producer
    → success: publish immutable artifact and return shared reference
later get(same key)
    → cache hit
    → return another shared reference
```

Provider 负责查找、计算协调、成功发布和生命周期管理。算子只能请求构建期已经声明并绑定的键，不得直接读取、插入、删除或覆盖缓存项，也不得自行发布共享产物。

缓存必须满足：

- 只属于当前一次 Inspection Core 调用，不跨检查任务或 Frame 共享；
- ArtifactKey 包含所有影响结果的参数；Frame 不进入键，因为一个 Provider 只对应一个固定 Frame；
- 同一键在一次检查中至多成功计算一次；
- 成功产物不可变，多个阶段可以共享读取；
- 计算失败或取消时不发布部分产物，也不缓存失败项；
- 首次请求中的生产失败归入当前请求阶段的 OperatorExecutionFailed，使用请求算子已声明的稳定包装错误码，并在诊断上下文中保留派生产物种类和原因码；
- Core 完成、失败或取消后释放缓存及其共享引用。

v1 按阶段线性执行，不要求并发初始化。未来允许并发请求时，仍必须保证同一键只发布一个确定结果。

## 9. 描述符初始化不变量

注册表初始化至少验证：

1. OperatorId、StageOutputTypeId、ArtifactKind 和字段标识合法且在各自作用域唯一；
2. 参数、输出和错误描述符均为封闭且有限的结构；
3. DecisionField 映射的字段存在且类型完全一致；
4. 前序输出和派生产物需求具有可解析的静态类型；
5. 构建、执行和取消契约完整；
6. `max_cancel_latency` 满足应用固定取消宽限期；
7. 描述符没有依赖注册表发布后的可变状态。
