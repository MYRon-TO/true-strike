# 视觉检测系统初步架构设计

## 1. 设计目标

- 摄像头采集不受 GUI、检查和持久化逻辑影响。
- 系统只维护一个权威的最新帧入口。
- GUI 预览最新帧，允许跳帧。
- 检查使用触发时获取的最新完整帧。
- 同一时间只执行一次检查。
- 检查方案由配置文件定义，采用线性流程。
- 检查方案不关联工件种类。
- 检查核心使用明确的输入和输出，不执行外部副作用。
- 初版只支持单摄像头。

## 2. 应用状态

应用包含三个互斥状态：

```text
Home
EditMode
ProductionMode
```

编辑模式与生产模式的数据和行为相互隔离，不同时存在。

### 2.1 主页

主页不加载任何检查方案配置。

主页负责：

- 进入编辑模式；
- 进入生产模式；
- 选择目标配置文件；
- 显示摄像头状态。

### 2.2 编辑模式

进入编辑模式时：

1. 选择一份配置文件；
2. 读取并解析配置；
3. 在内存中创建可编辑草稿。

编辑模式允许：

- 修改配置草稿；
- 校验草稿；
- 编译临时检查方案；
- 使用最新帧执行测试检查；
- 将有效草稿写回原配置文件。

编辑模式不允许执行生产检查。测试检查不改变生产模式使用的方案。

返回主页时，释放草稿和临时检查方案。已保存内容保留在配置文件中。

### 2.3 生产模式

进入生产模式时：

1. 选择一份配置文件；
2. 读取并校验配置；
3. 编译为不可变检查方案；
4. 将该方案设为当前生产方案。

生产模式只读取被选中的配置文件，不加载其他配置。运行期间不自动重新读取配置文件。

返回主页时，释放已加载的配置和检查方案。再次进入生产模式时重新读取配置文件。

## 3. 总体结构

```text
Camera Actor
    │
    │ 发布不可变帧
    ▼
Latest Frame Store
    ├────────────────────────────→ GUI 预览
    │
    └────────────────────────────→ Inspection Actor
                                         │
                                         │ 固定帧与检查方案
                                         ▼
                                  Inspection Core
                                         │
                                         ▼
                                  Inspection Actor
                                         │
                                         ▼
                                        GUI

配置文件
    │
    ▼
Scheme Manager
    ├── 编辑模式：Draft Config → 临时 Inspection Plan
    └── 生产模式：Config → 生产 Inspection Plan
```

Actor 管理状态和副作用，最新值存储负责帧分发，检查核心负责图像处理。

## 4. 帧模型

```text
Frame
├── frame_id
├── captured_at
├── image_data
└── camera_metadata
```

帧遵循以下规则：

1. 摄像头完成采集后，将 SDK 图像数据复制到应用拥有的内存。
2. 复制完成后构造不可变帧。
3. 帧发布后不得修改或复用其图像内存。
4. 消费者通过共享引用持有帧。
5. 最新帧被替换后，已被消费者持有的旧帧继续有效。
6. 旧帧在所有持有者释放后销毁。

## 5. Camera Actor

Camera Actor 是摄像头及其 SDK 的唯一访问者。

职责：

- 初始化和关闭摄像头；
- 在独立执行环境中执行阻塞采集；
- 复制每次采集的图像数据；
- 构造不可变帧；
- 分配唯一的 `frame_id`；
- 更新 Latest Frame Store；
- 发布摄像头状态和错误。

约束：

- 不等待 GUI；
- 不等待检查完成；
- 不执行检查逻辑；
- 不执行配置读写；
- 不执行持久化；
- 不建立待处理帧队列。

## 6. Latest Frame Store

Latest Frame Store 是当前最新帧的唯一可信入口。

特性：

- Camera Actor 是唯一写入者；
- GUI 和 Inspection Actor 可以读取；
- 只保存一个最新帧共享引用；
- 新帧原子替换旧引用；
- 读取返回当时最新帧的独立共享引用；
- 替换不修改已发布的帧。

## 7. 检查方案

一份配置文件定义一份检查方案。系统不记录工件与检查方案的对应关系，也不识别当前工件种类。

### 7.1 配置模型

配置至少包含：

```text
InspectionSchemeConfig
├── scheme_id
├── revision
├── name
├── stages[]
└── decision_rule
```

每个阶段包含：

```text
StageConfig
├── operator_id
├── enabled
└── parameters
```

初版按照 `stages` 顺序执行，不支持分支和依赖图。

### 7.2 检查算子

程序提供固定的检查算子集合。配置通过 `operator_id` 选择算子并提供参数。

配置不得包含：

- 可执行代码；
- 任意函数地址；
- 未注册的算子；
- 未声明的外部副作用。

### 7.3 方案构建

```text
InspectionSchemeConfig
    → 校验
    → 解析算子和参数
    → 按顺序构建
    → Immutable Inspection Plan
```

构建失败时不得生成可执行方案。

## 8. Scheme Manager

Scheme Manager 管理配置文件、编辑草稿和检查方案。

职责：

- 读取选中的配置文件；
- 解析和校验配置；
- 调用方案构建逻辑；
- 管理编辑草稿；
- 保存有效草稿；
- 管理当前模式下的检查方案；
- 返回配置错误和构建错误。

### 8.1 编辑草稿

编辑草稿与配置文件分离：

```text
Config File
    → Draft Config
    → GUI 修改
```

修改草稿不直接修改配置文件。

保存时：

1. 校验草稿；
2. 确认草稿可以构建检查方案；
3. 写入临时文件；
4. 原子替换原配置文件。

任一步骤失败时，原配置文件保持不变。

### 8.2 编辑测试

编辑模式可以将当前草稿编译为临时检查方案，并执行一次测试检查。

测试规则：

- 使用当前内存草稿，不要求先保存；
- 使用触发时的最新帧；
- 临时方案仅在编辑模式中有效；
- 测试结果必须标记为测试结果；
- 测试结果不得作为生产检查结果持久化；
- 测试完成后可以继续编辑草稿。

## 9. GUI

GUI 使用 iced 实现，负责：

- 管理主页、编辑模式和生产模式的界面；
- 显示摄像头状态；
- 预览最新帧；
- 选择配置文件；
- 编辑配置草稿；
- 发起测试检查或生产检查；
- 显示检查状态、结果和错误。

预览规则：

- GUI 按自身刷新节奏读取最新帧；
- GUI 可以跳过中间帧；
- GUI 不维护待显示帧队列；
- `frame_id` 未变化时可以跳过重复转换；
- GUI 不直接访问摄像头。

## 10. Inspection Actor

Inspection Actor 串行管理测试检查和生产检查。

### 10.1 状态

```text
Idle

Running
├── inspection_id
├── inspection_kind
├── frame_id
├── scheme_id
├── scheme_revision
├── pinned_frame
└── pinned_plan
```

`inspection_kind` 取值：

```text
Test
Production
```

### 10.2 触发检查

收到检查请求后：

1. 若状态为 `Running`，立即返回 `Busy`；
2. 校验当前应用状态与检查类型是否一致；
3. 获取当前模式下的检查方案共享引用；
4. 从 Latest Frame Store 获取最新帧共享引用；
5. 若没有方案，返回 `NoPlan`；
6. 若没有帧，返回 `NoFrame`；
7. 生成 `inspection_id`；
8. 固定帧和检查方案；
9. 切换为 `Running`；
10. 调用 Inspection Core。

后续发布的新帧和配置修改不影响当前检查。

### 10.3 完成检查

Inspection Core 返回后：

1. 校验 `inspection_id`；
2. 生成对应类型的完成事件；
3. 将结果发送给 GUI；
4. 释放固定帧和检查方案；
5. 切换回 `Idle`。

## 11. Inspection Core

概念接口：

```text
inspect(frame, inspection_plan) -> inspection_result
```

约束：

- 输入帧和检查方案显式传入；
- 按检查方案中的线性顺序执行算子；
- 不读取摄像头；
- 不读取 Latest Frame Store；
- 不读取配置文件；
- 不操作 GUI；
- 不写入数据库；
- 不修改全局业务状态；
- 只返回检查结果或检查错误。

检查结果至少包含：

```text
InspectionResult
├── inspection_id
├── inspection_kind
├── frame_id
├── scheme_id
├── scheme_revision
├── decision
├── measurements
├── defects
└── optional_visualization
```

GUI 展示检查标记时，必须使用结果关联的检查帧。

## 12. 主要流程

### 12.1 采集与预览

```text
Camera SDK
    → Camera Actor 阻塞采集
    → 复制图像数据
    → 构造不可变 Frame
    → 替换 Latest Frame Store
    → GUI 读取并显示最新帧
```

### 12.2 生产检查

```text
主页选择配置文件
    → 加载并编译
    → 进入生产模式
    → GUI 发起生产检查
    → 固定最新帧和生产方案
    → Inspection Core
    → GUI 显示生产结果
```

### 12.3 编辑测试

```text
主页选择配置文件
    → 加载为编辑草稿
    → GUI 修改草稿
    → 校验并编译临时方案
    → 固定最新帧和临时方案
    → Inspection Core
    → GUI 显示测试结果
```

## 13. 错误处理

初版至少区分：

- `Busy`：已有检查正在执行；
- `NoFrame`：尚未成功采集帧；
- `NoPlan`：当前没有可用检查方案；
- `InvalidMode`：检查类型与当前应用状态不一致；
- `ConfigLoadFailed`：配置读取或解析失败；
- `ConfigInvalid`：配置校验失败；
- `PlanBuildFailed`：检查方案构建失败；
- `ConfigSaveFailed`：配置保存失败；
- `CameraUnavailable`：摄像头不可用；
- `CameraFault`：采集发生错误；
- `InspectionFailed`：检查执行失败。

摄像头发生故障后：

- GUI 可以保留最后一帧；
- GUI 必须显示故障状态；
- 系统拒绝新的检查请求。

## 14. 并发约束

1. 摄像头只能由 Camera Actor 访问。
2. Camera Actor 不等待帧消费者。
3. Latest Frame Store 只有一个写入者。
4. 已发布的帧始终不可变。
5. GUI 不积压预览帧。
6. 主页、编辑模式和生产模式互斥。
7. 每个模式只加载用户选中的配置文件。
8. 编辑草稿不修改生产方案。
9. 检查请求由 Inspection Actor 串行处理。
10. 同一时间最多运行一次测试检查或生产检查。
11. 检查期间固定帧和检查方案。
12. 检查核心不执行外部副作用。

## 15. 持久化扩展

生产检查完成后发布事件：

```text
ProductionInspectionCompleted
├── inspection_id
├── frame_id
├── scheme_id
├── scheme_revision
└── result
```

未来增加数据库时，由 Persistence Actor 消费生产检查完成事件：

```text
Inspection Actor
    ├──→ GUI
    └──→ Persistence Actor → Database
```

测试检查结果不发送给 Persistence Actor。持久化不得阻塞摄像头采集。初版不实现 Persistence Actor 和数据库抽象。
