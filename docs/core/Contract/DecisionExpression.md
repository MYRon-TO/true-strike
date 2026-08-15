# 判定表达式语法与类型规约

本文定义 v1 `DecisionRule.Expression` 的封闭抽象语法、值类型、操作符、静态类型规则和结构限制。表达式可读取的业务输入、阶段输出引用有效性、配置校验边界、方案构建和运行期求值由[配置、方案与算子规约](./SchemeAndOperators.md)定义。本文不规定配置文件的具体序列化表示。

## 1. 设计边界

Expression 是结构化声明式数据，不是文本脚本。解析器、校验器、编辑器和方案构建器必须使用同一封闭语法模型，不得各自解释未纳入本规约的字符串语法。

v1 Expression：

- 只包含本文列出的节点、值类型和操作符；
- 不包含可执行代码、函数调用、变量赋值或用户自定义操作符；
- 不执行算术、聚合、字符串转换或隐式类型转换；
- 根节点的静态类型必须是 `Bool`。

## 2. 值类型与字面量

```text
ExpressionType
├── Bool
├── Int64
├── Float64
└── String

ExpressionValue
├── Bool(value: bool)
├── Int64(value: i64)
├── Float64(value: f64)
└── String(value: string)
```

值约束：

- `Float64` 只允许有限值，禁止 `NaN`、正无穷和负无穷；
- `String` 最多包含 256 个 Unicode 标量值；空字符串合法；
- 系统不得在表达式中隐式转换 `Int64`、`Float64`、`Bool` 或 `String`；
- `Int64` 和 `Float64` 是不同类型。

字面量节点的类型就是其 ExpressionValue 变体对应的 ExpressionType。

## 3. 抽象语法

```text
Expression
├── Literal(value: ExpressionValue)
├── StageOutputRef
│   ├── stage_id: StageId
│   └── field_id: DecisionFieldId
├── Not(operand: Expression)
├── And(operands: Expression[])
├── Or(operands: Expression[])
└── Compare
    ├── operator: ComparisonOperator
    ├── left: Expression
    └── right: Expression

ComparisonOperator
├── Eq
├── Ne
├── Lt
├── Le
├── Gt
└── Ge
```

`StageOutputRef` 是语法中的唯一引用节点。StageId、DecisionFieldId 及引用目标的业务有效性由配置、方案与算子规约定义。

## 4. 结构约束

一棵有效的 Expression AST 必须满足：

- `Literal` 恰好包含一个合法 ExpressionValue；
- `StageOutputRef` 恰好包含一个 StageId 和一个 DecisionFieldId；
- `Not` 恰好包含一个操作数；
- `And` 和 `Or` 分别包含 2 至 64 个操作数；
- `Compare` 恰好包含一个 ComparisonOperator、一个左操作数和一个右操作数；
- AST 最大深度为 64，根节点深度为 1；
- AST 节点总数不超过 1024；
- AST 不得包含未知节点、未知操作符、空节点或循环引用。

节点数量按 AST 中实际出现的节点计数；实现不得用对象共享改变配置模型中的计数结果。违反本章任一约束的表达式为结构无效。

## 5. 静态类型规则

类型判断写作：

```text
Γ ⊢ expression : T
```

`Γ` 是由 Scheme Manager 根据有效算子输出声明建立的引用类型环境；若 `Γ(stage_id, field_id) = T`，则对应 StageOutputRef 的类型为 `T`。`Γ` 的建立和引用错误分类由配置、方案与算子规约定义。

### 5.1 字面量和引用

```text
Γ ⊢ Literal(Bool(...))    : Bool
Γ ⊢ Literal(Int64(...))   : Int64
Γ ⊢ Literal(Float64(...)) : Float64
Γ ⊢ Literal(String(...))  : String

Γ(stage_id, field_id) = T
----------------------------------------
Γ ⊢ StageOutputRef(stage_id, field_id) : T
```

### 5.2 逻辑操作符

```text
Γ ⊢ operand : Bool
-----------------------
Γ ⊢ Not(operand) : Bool
```

`And` 和 `Or` 的每个操作数都必须为 `Bool`：

```text
对每个 i，Γ ⊢ operands[i] : Bool
---------------------------------
Γ ⊢ And(operands) : Bool
Γ ⊢ Or(operands)  : Bool
```

### 5.3 相等比较

`Eq` 和 `Ne` 支持 `Bool`、`Int64`、`Float64` 和 `String`。左右操作数类型必须完全相同，结果为 `Bool`：

```text
Γ ⊢ left : T    Γ ⊢ right : T
T ∈ {Bool, Int64, Float64, String}
-----------------------------------
Γ ⊢ Compare(Eq | Ne, left, right) : Bool
```

`Float64` 相等比较使用值的精确相等关系，不提供容差比较；正零和负零相等。需要容差时必须显式组合范围比较，v1 不提供隐式容差。

### 5.4 顺序比较

`Lt`、`Le`、`Gt` 和 `Ge` 只支持同类型数值：

```text
Γ ⊢ left : T    Γ ⊢ right : T
T ∈ {Int64, Float64}
------------------------------------------
Γ ⊢ Compare(Lt | Le | Gt | Ge, left, right) : Bool
```

v1 不定义 Bool 或 String 的顺序关系。

### 5.5 根节点

只有满足以下判断的表达式才能构成 `DecisionRule.Expression`：

```text
Γ ⊢ expression : Bool
-------------------------------
Expression(expression) 类型有效
```

任何操作数类型不匹配、引用无法在 `Γ` 中取得类型或根节点不是 `Bool` 的表达式均为类型无效。

## 6. v1 语法不变量

1. Expression 是封闭的结构化 AST，不是文本 DSL。
2. Expression 只有 `Bool`、`Int64`、`Float64` 和 `String` 四种值类型。
3. Expression 不执行隐式类型转换。
4. 逻辑操作数和根节点必须为 `Bool`。
5. 相等比较要求左右类型完全相同；顺序比较只接受同类型数值。
6. StageOutputRef 是唯一引用形式。
7. 所有表达式都必须满足固定的深度、节点数和操作数数量上限。
