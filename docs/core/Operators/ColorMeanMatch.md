# ROI 颜色均值匹配算子规约

本文定义 v1 具体算子 `color_mean_match`。通用描述符结构见[算子描述符规约](../Contract/OperatorDescriptor.md)，Frame 图像语义见[规范 Frame 规约](../Contract/FrameFormat.md)，配置和阶段执行公共规则见[配置、方案与算子规约](../Contract/SchemeAndOperators.md)。

## 1. 功能与身份

```text
operator_id = color_mean_match
stage_output_type = color_mean_match.output.v1
```

算子对规范 Rgb8Image 中的归一化矩形 ROI 执行：

1. 将 ROI 确定性地映射为像素区域；
2. 计算 R、G、B 通道算术均值；
3. 将 RGB 均值转换为 HSV；
4. 按 H、S、V 独立容差与目标颜色比较；
5. 输出测量值和匹配结果。

颜色不匹配是正常业务结果，不是执行错误。

## 2. OperatorDescriptor

```text
OperatorDescriptor
├── operator_id: color_mean_match
├── parameter_contract: ColorMeanMatchParameters
├── input_contract
│   ├── frame_access: Required
│   ├── prior_outputs: []
│   └── derived_artifacts: []
├── output_contract: color_mean_match.output.v1
├── build_contract: ColorMeanMatchExecutable
├── execution_contract: deterministic, total on valid input
└── cancellation_contract: Cooperative
```

该算子直接读取当前 Frame，不读取前序 StageOutput，也不请求派生产物。

## 3. 参数契约

```text
ColorMeanMatchParameters
├── roi
│   ├── x: Float64
│   ├── y: Float64
│   ├── width: Float64
│   └── height: Float64
├── target
│   ├── h_deg: Float64
│   ├── s: Float64
│   └── v: Float64
└── tolerance
    ├── h_deg: Float64
    ├── s: Float64
    └── v: Float64
```

所有字段必填，不接受未声明字段，所有 Float64 必须为有限值。

### 3.1 ROI

ROI 使用相对于 Frame 宽高的归一化坐标：

```text
0 <= roi.x < 1
0 <= roi.y < 1
0 < roi.width <= 1
0 < roi.height <= 1
roi.x + roi.width <= 1
roi.y + roi.height <= 1
roi.x + roi.width > roi.x
roi.y + roi.height > roi.y
```

最后两项按实际 Float64 运算验证，防止正宽度或高度因表示精度而在加法后消失。系统不得裁剪、修正或归一化无效 ROI。

### 3.2 目标 HSV

```text
0 <= target.h_deg < 360
0 <= target.s <= 1
0 <= target.v <= 1
```

H 的单位为度，S 和 V 为无单位归一化数值。

### 3.3 容差

```text
0 <= tolerance.h_deg <= 180
0 <= tolerance.s <= 1
0 <= tolerance.v <= 1
```

比较边界为包含边界。

### 3.4 参数错误码

| 稳定错误码 | 参数位置 | 条件 |
| --- | --- | --- |
| `operator.color_mean_match.parameter.missing_field` | 缺失字段 | 任一必填字段缺失 |
| `operator.color_mean_match.parameter.unknown_field` | 未声明字段 | Object 中出现未声明字段 |
| `operator.color_mean_match.parameter.invalid_type` | 对应字段或 `parameters` | 值不符合声明的 ParameterSchema 类型 |
| `operator.color_mean_match.parameter.non_finite` | 对应数值字段 | 值为 NaN 或无穷 |
| `operator.color_mean_match.parameter.roi_origin_out_of_range` | `roi.x` 或 `roi.y` | 原点不满足范围 |
| `operator.color_mean_match.parameter.roi_size_out_of_range` | `roi.width` 或 `roi.height` | 尺寸不满足范围 |
| `operator.color_mean_match.parameter.roi_out_of_bounds` | `roi` | 右边界或下边界超过 1 |
| `operator.color_mean_match.parameter.roi_unrepresentable` | `roi` | 正尺寸在 Float64 加法后消失 |
| `operator.color_mean_match.parameter.target_h_out_of_range` | `target.h_deg` | 不在 `[0, 360)` |
| `operator.color_mean_match.parameter.target_sv_out_of_range` | `target.s` 或 `target.v` | 不在 `[0, 1]` |
| `operator.color_mean_match.parameter.tolerance_h_out_of_range` | `tolerance.h_deg` | 不在 `[0, 180]` |
| `operator.color_mean_match.parameter.tolerance_sv_out_of_range` | `tolerance.s` 或 `tolerance.v` | 不在 `[0, 1]` |

参数结构、类型、数值和关系校验均必须使用本表中的具体错误码，不得降级为笼统的 `parameters.invalid`。Object 字段和关系规则按本文声明顺序校验，遇到首个错误停止。

## 4. ROI 栅格化

对 Frame 尺寸 `W × H` 计算：

```text
left   = floor(roi.x × W)
top    = floor(roi.y × H)
right  = ceil((roi.x + roi.width) × W)
bottom = ceil((roi.y + roi.height) × H)
```

结果使用半开像素区域：

```text
[left, right) × [top, bottom)
```

有效参数和规范 Frame 必须得到：

```text
0 <= left < right <= W
0 <= top < bottom <= H
```

计算必须使用 Float64，且不得改用四舍五入、像素中心包含关系或图像库的隐式 ROI 规则。上述规则使任一有效 ROI 至少包含一个像素。

## 5. RGB 均值

按 y 递增、同一行内 x 递增的顺序遍历 ROI。对 N 个像素分别执行无符号整数累加：

```text
sum_r = Σ R
sum_g = Σ G
sum_b = Σ B
pixel_count = N
```

累加器使用能够容纳 `255 × MAX_FRAME_WIDTH × MAX_FRAME_HEIGHT` 的无符号整数类型。部署配置必须证明该值不会溢出；实现仍必须对尺寸和乘法执行溢出检查。

归一化均值为：

```text
mean_r = Float64(sum_r) / (Float64(N) × 255)
mean_g = Float64(sum_g) / (Float64(N) × 255)
mean_b = Float64(sum_b) / (Float64(N) × 255)
```

算子不得先将各像素转换为 HSV 后求均值，也不得执行 Gamma 线性化、白平衡、颜色标定或图像增强。

## 6. RGB 到 HSV

定义：

```text
c_max = max(mean_r, mean_g, mean_b)
c_min = min(mean_r, mean_g, mean_b)
delta = c_max - c_min

mean_v = c_max

mean_s =
    0                 if c_max == 0
    delta / c_max     otherwise
```

Hue 按以下顺序分支：

```text
mean_h_deg =
    0
        if delta == 0

    60 × mod6((mean_g - mean_b) / delta)
        if c_max == mean_r

    60 × (((mean_b - mean_r) / delta) + 2)
        if c_max == mean_g

    60 × (((mean_r - mean_g) / delta) + 4)
        otherwise
```

其中 `mod6(x)` 返回 `[0, 6)` 内与 x 模 6 同余的值。最终结果必须满足：

```text
0 <= mean_h_deg < 360
0 <= mean_s <= 1
0 <= mean_v <= 1
```

当 `delta == 0` 时没有可区分色相，v1 固定输出 `mean_h_deg = 0`，不引入空值或未定义值。若多个通道同时等于 `c_max` 且 `delta != 0`，按 R、G、B 的上述分支顺序选择；实现不得依赖图像库分支规则。

## 7. 容差比较

```text
raw_h_delta = abs(mean_h_deg - target.h_deg)
delta_h_deg = min(raw_h_delta, 360 - raw_h_delta)
delta_s = abs(mean_s - target.s)
delta_v = abs(mean_v - target.v)
```

匹配结果为：

```text
matched =
    delta_h_deg <= tolerance.h_deg
    AND delta_s <= tolerance.s
    AND delta_v <= tolerance.v
```

Hue 使用圆周最短距离。低饱和度颜色仍执行相同 Hue 比较；v1 不隐式忽略 Hue。需要忽略 Hue 时，配置可以显式设置 `tolerance.h_deg = 180`。

## 8. 输出契约

```text
ColorMeanMatchOutput
├── matched: Bool
├── mean_r: Float64
├── mean_g: Float64
├── mean_b: Float64
├── mean_h_deg: Float64
├── mean_s: Float64
├── mean_v: Float64
├── delta_h_deg: Float64
├── delta_s: Float64
├── delta_v: Float64
└── pixel_count: Int64
```

所有字段必填且不可变。范围为：

```text
mean_r, mean_g, mean_b ∈ [0, 1]
mean_h_deg ∈ [0, 360)
mean_s, mean_v ∈ [0, 1]
delta_h_deg ∈ [0, 180]
delta_s, delta_v ∈ [0, 1]
pixel_count > 0
```

### 8.1 DecisionField

| field_id | output_field_id | ExpressionType |
| --- | --- | --- |
| `matched` | `matched` | Bool |
| `mean_h_deg` | `mean_h_deg` | Float64 |
| `mean_s` | `mean_s` | Float64 |
| `mean_v` | `mean_v` | Float64 |
| `delta_h_deg` | `delta_h_deg` | Float64 |
| `delta_s` | `delta_s` | Float64 |
| `delta_v` | `delta_v` | Float64 |

`mean_r`、`mean_g`、`mean_b` 和 `pixel_count` 是 StageOutput 字段，但 v1 不向 DecisionRule 公开。

典型 DecisionRule 直接使用：

```text
StageOutputRef(stage_id = <stage>, field_id = "matched")
```

该引用已经是 Bool，不需要再与 Bool 字面量比较。

### 8.2 测量、缺陷和可视化

算子按下列稳定顺序贡献测量：

```text
mean_r, mean_g, mean_b,
mean_h_deg, mean_s, mean_v,
delta_h_deg, delta_s, delta_v,
pixel_count
```

每项测量关联当前 StageId；H 使用度，S、V 和 RGB 均值无单位，pixel_count 使用像素。v1 本算子不产生 Defect，也不产生可视化图元，分别使用空数组和明确的无可视化表示。`matched = false` 仍正常提交全部测量。

## 9. 构建契约

Scheme Manager 在完整配置校验后将参数解析为不可变 `ColorMeanMatchParameters`，并构建不依赖注册表后续变化的 `ColorMeanMatchExecutable`。本算子没有前序输出绑定和 ArtifactKey。

有效参数无法构建执行对象属于内部契约破坏，直接 `panic`。构建不得读取 Frame 或实际像素。

## 10. 执行结果与错误

对规范 Frame 和有效类型化参数，本算法是全函数：

- 一致时返回 `Completed(output)` 且 `matched = true`；
- 不一致时返回 `Completed(output)` 且 `matched = false`；
- 观察到取消时返回 `Cancelled`；
- v1 不声明可恢复的 `operator.color_mean_match.execution.*` 错误码。

以下情况是内部不变量破坏，直接 `panic`：

- 输入不是合法 Rgb8Image；
- 有效参数栅格化后得到空区域或越界区域；
- 算术溢出；
- 输出出现 NaN、无穷或越界值；
- StageOutput 缺少字段或字段类型不符。

## 11. 取消契约

```text
observation_mode = Cooperative
```

算子在以下位置观察由 Actor 设置并经 Worker、Core 传入的 CancellationSignal：

1. 读取第一个 ROI 像素前；
2. 每处理完一行 ROI 后；
3. RGB 均值完成后、HSV 转换前；
4. 构造 StageOutput 前。

观察到取消后立即释放未提交临时资源并返回 `Cancelled`，不得提交 StageOutput。算子不得设置或复位信号、决定取消原因或管理截止时间。

最大检查点间工作量为处理不超过 `MAX_FRAME_WIDTH` 个 Rgb8 像素及固定数量的整数和浮点操作。注册描述符必须携带针对受支持部署环境资格验证得到的具体 `max_cancel_latency`，并满足算子描述符规约规定的取消宽限期关系。

## 12. 确定性与资源

相同 Frame、类型化参数和取消观察序列必须产生相同结果。实现必须：

- 保持本文规定的遍历、累加、转换和比较顺序；
- 使用整数通道累加和 Float64 转换；
- 禁止改变结果的 fast-math、浮点重排、近似比较或不稳定并行归并；
- 不读取时间、随机数、图像库默认颜色配置或外部状态；
- 不执行外部业务副作用。

除最终 StageOutput 和结果测量外，算子只需要固定数量的标量临时存储，不分配与 ROI 面积成比例的临时图像。调用返回后不得保留 Frame 或执行上下文的借用。
