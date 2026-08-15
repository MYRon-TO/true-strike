# 规范 Frame 规约

本文定义 v1 Frame 的图像类型、内存布局、构造约束和采集边界转换。Frame 的所有权与发布生命周期见[资源生命周期规约](./Resources.md)，组件职责见[系统架构](../Architecture.md)。

## 1. 类型模型

v1 只发布一种规范图像类型，不在 Frame 中保存运行期 `FrameFormatId`：

```text
Frame
├── frame_id: FrameId
├── captured_at
├── image: Rgb8Image
└── camera_metadata

Rgb8Image
├── width: NonZeroU32
├── height: NonZeroU32
└── pixels: ImmutableRgb8Pixels
```

Frame 和 Rgb8Image 构造完成后不可变。类型本身必须保证图像是合法 Rgb8 数据；调用方不得把任意字节缓冲区未经验证地标记为 Rgb8Image。

## 2. Rgb8Image 布局

规范布局为：

```text
通道顺序    R、G、B
通道类型    无符号 8 位整数
像素排列    交错排列
坐标原点    左上角
X 轴方向    向右
Y 轴方向    向下
行排列      行优先
行填充      不允许
行跨度      width × 3 字节
Alpha       无
```

坐标 `(x, y)` 的通道位于：

```text
base = (y × width + x) × 3
R = pixels[base]
G = pixels[base + 1]
B = pixels[base + 2]
```

有效坐标满足：

```text
0 <= x < width
0 <= y < height
```

## 3. 尺寸与构造

应用级固定部署配置必须给出：

```text
MAX_FRAME_WIDTH
MAX_FRAME_HEIGHT
```

Rgb8Image 必须满足：

```text
0 < width <= MAX_FRAME_WIDTH
0 < height <= MAX_FRAME_HEIGHT
pixels.length == width × height × 3
MAX_FRAME_WIDTH × MAX_FRAME_HEIGHT <= Int64::MAX
255 × MAX_FRAME_WIDTH × MAX_FRAME_HEIGHT <= UInt64::MAX
```

上述乘法按数学整数解释。所有实际尺寸、偏移和长度计算必须执行整数溢出检查。构造器必须在取得类型化 Rgb8Image 前完成验证，例如：

```text
Rgb8Image::try_from_packed_bytes(width, height, bytes)
```

构造失败发生在 Camera Actor 的采集和复制边界，按既有摄像头致命错误处理；不得发布部分 Frame。已经构造的 Rgb8Image 若出现长度、尺寸或布局不一致，表示内部不变量被破坏，直接 `panic`。

实现可以使用连续不可变字节缓冲区，不要求为每个像素分配独立对象。实现细节必须保持上述逻辑类型和布局。

## 4. 采集边界转换

Camera Actor 必须在 Camera SDK 允许复用或释放原始缓冲区前完成：

1. 取得一幅完整采集图像及其元数据；
2. 将 SDK 像素格式转换为规范 Rgb8Image；
3. 将完整图像复制到应用拥有的内存；
4. 构造不可变 Frame；
5. 发布 Frame 的不可变共享引用。

SDK 原始格式可以是 Bayer、BGR、带行填充格式或其他设备格式，但这些格式不得越过 Camera Actor 的 Frame 构造边界。GUI、Inspection Core 和算子只接收规范 Rgb8Image，不重复执行 Bayer 解码、通道重排、位深转换或行填充处理。

v1 不支持在已发布 Frame 中混合多种图像格式。若设备无法产生可转换为规范 Rgb8Image 的完整图像，采集失败并按摄像头致命错误处理。

## 5. 颜色数值语义

Rgb8Image 规定通道样本值和布局，但不声称图像经过设备色彩标定。对通道执行普通归一化时使用：

```text
r = R / 255
g = G / 255
b = B / 255
```

除非具体算子另有明确声明，系统不得隐式执行：

- Gamma 线性化；
- ICC 或其他颜色配置文件转换；
- 白平衡校正；
- 曝光补偿；
- 颜色标定；
- 去噪、锐化或其他图像增强。

影响检测结果的转换必须成为明确的采集约定、具体算子参数或带完整 ArtifactKey 的派生产物，不能依赖图像库默认值。

## 6. 访问与所有权

- Frame 通过不可变共享引用跨组件传递；
- 算子只能借用当前调用显式提供的 Frame；
- 算子和派生产物生产者不得修改 Rgb8Image；
- 切片或视图不得在调用结束后保留对执行上下文的借用；
- 派生图像不是 Frame 的可变附属字段，必须进入当前检查的任务级派生产物缓存；
- Camera Actor 停止或发布后续 Frame 不影响已固定 Frame 的逻辑内容。

## 7. v1 不变量

1. 每个已发布 Frame 恰好包含一个合法、不可变的 Rgb8Image。
2. Frame 不使用运行期格式标识与裸字节组合表示图像类型。
3. Camera SDK 像素格式不得越过 Camera Actor 的构造边界。
4. 图像尺寸受应用固定上限约束，所有长度和偏移计算检查溢出。
5. 相同 Rgb8 样本的数值解释不依赖图像库、平台通道顺序或隐式颜色转换。
