# 视觉检测系统架构

## 1. 总体结构

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
                                  Inspection Worker
                                         │
                                         ▼
                                  Inspection Core
                                         │
                                         ▼
                                  Inspection Actor
                                         │
                                         │ 结果与检查帧
                                         ▼
                                        GUI

配置文件
    │
    ▼
Scheme Manager
    ├── 编辑模式：Draft Config → 临时 Inspection Plan
    ├── 生产模式：Config → 生产 Inspection Plan
    │
    └────────────────────────────→ Inspection Actor
```

架构采用以下分工：

- Actor 管理状态和副作用；
- 最新值存储分发帧；
- Inspection Worker 隔离检查计算；
- Inspection Core 执行图像处理；
- GUI 发送命令并展示状态和结果。

## 2. 应用状态

```text
AppState
├── Home
├── EditMode
└── ProductionMode
```

三个状态互斥。

### 2.1 Home

Home 不持有检查配置或检查方案。用户在 Home 选择配置文件，并进入 EditMode 或 ProductionMode。

### 2.2 EditMode

```text
EditMode
├── config_path
├── draft_config
├── optional_test_plan
└── optional_presentation
```

进入时读取配置并创建草稿。返回 Home 时释放草稿、临时方案和展示结果。

### 2.3 ProductionMode

```text
ProductionMode
├── config_path
├── loaded_config
├── production_plan
└── optional_presentation
```

进入时读取、校验并编译配置。返回 Home 时释放配置、方案和展示结果。

## 3. 帧模型

```text
Frame
├── frame_id
├── captured_at
├── image_data
└── camera_metadata
```

帧生命周期规则：

1. Camera Actor 从 SDK 取得图像；
2. 将图像数据复制到应用拥有的内存；
3. 构造不可变 Frame；
4. 通过共享引用发布 Frame；
5. 最新帧替换不修改旧帧；
6. Frame 在所有共享引用释放后销毁。

发布后的图像内存不得修改或复用。

## 4. Camera Actor

Camera Actor 是摄像头及其 SDK 的唯一访问者。

职责：

- 初始化和关闭摄像头；
- 在独立执行环境中执行阻塞采集；
- 复制采集图像；
- 构造不可变 Frame；
- 分配唯一 `frame_id`；
- 更新 Latest Frame Store；
- 暴露运行状态。

约束：

- 不等待 GUI；
- 不等待检查任务；
- 不执行检查逻辑；
- 不读写配置；
- 不建立待处理帧队列。

生命周期：

```text
应用启动 → 初始化并开始采集
应用运行 → 跨应用状态持续采集
应用退出 → 停止采集并关闭摄像头
```

摄像头初始化或采集失败时直接 `panic`。

## 5. Latest Frame Store

Latest Frame Store 是当前最新帧的唯一可信入口。

特性：

- Camera Actor 是唯一写入者；
- GUI 和 Inspection Actor 可以读取；
- 只保存一个最新帧共享引用；
- 新帧原子替换旧引用；
- 读取返回当时最新帧的独立共享引用；
- 替换操作不等待消费者。

GUI 读取用于预览。Inspection Actor 读取用于固定检查输入。

## 6. 检查方案

### 6.1 配置模型

```text
InspectionSchemeConfig
├── scheme_id
├── revision
├── name
├── stages[]
└── decision_rule

StageConfig
├── operator_id
├── enabled
└── parameters
```

`stages` 按配置顺序执行。

程序维护固定的检查算子注册表。`operator_id` 必须对应已注册算子。

配置不得包含：

- 可执行代码；
- 任意函数地址；
- 未注册算子；
- 产生外部业务副作用的算子。

### 6.2 方案构建

```text
InspectionSchemeConfig
    → 校验
    → 解析算子和参数
    → 按顺序构建
    → Immutable Inspection Plan
```

构建失败不得生成可执行方案。

## 7. Scheme Manager

Scheme Manager 管理配置文件、编辑草稿和检查方案。

职责：

- 读取选中的配置文件；
- 解析和校验配置；
- 构建不可变检查方案；
- 管理编辑草稿；
- 保存有效草稿；
- 提供当前模式的检查方案；
- 返回配置和构建错误。

### 7.1 编辑草稿

```text
Config File → Draft Config → GUI 修改
```

修改草稿不直接修改文件。

保存流程：

1. 校验草稿；
2. 确认草稿可以构建方案；
3. 计算递增后的 `revision`；
4. 写入临时文件；
5. 原子替换原配置文件；
6. 提交新 `revision`。

任一步骤失败时，原文件和原 `revision` 保持不变。

### 7.2 编辑测试

每次测试请求执行：

1. 读取当前内存草稿；
2. 重新校验草稿；
3. 编译临时 Inspection Plan；
4. 使用最新帧执行测试检查。

临时方案只在当前 EditMode 中有效，不修改生产方案。

## 8. GUI

GUI 使用 iced 实现。

职责：

- 管理三个应用状态的界面；
- 显示摄像头状态；
- 选择配置文件；
- 预览最新帧；
- 编辑配置草稿；
- 发起测试检查或生产检查；
- 显示检查状态、结果和错误。

GUI 只发送检查命令，不执行 Inspection Core。

### 8.1 预览

- GUI 按自身刷新节奏读取最新帧；
- GUI 允许跳帧；
- GUI 不维护待显示帧队列；
- `frame_id` 未变化时可以跳过重复转换。

### 8.2 结果展示

GUI 只保留最近一次 `InspectionPresentation`：

```text
InspectionPresentation
├── result
└── frame: Shared<Frame>
```

展示规则：

- 有可视化数据时，在关联帧上显示标记；
- 无可视化数据时，显示关联帧和文字结果；
- 新结果替换旧结果时，释放旧帧引用；
- 离开当前模式时，释放展示对象。

## 9. Inspection Actor

Inspection Actor 串行管理测试检查和生产检查。

### 9.1 数据模型

```text
InspectionMetadata
├── inspection_id
├── inspection_kind
├── frame_id
├── scheme_id
└── scheme_revision
```

`inspection_kind` 为 `Test` 或 `Production`。

### 9.2 状态

```text
Idle

Running
├── metadata
├── started_at
├── deadline
├── cancellation
├── pinned_frame
└── pinned_plan

Cancelling
├── running_context
└── cancellation_deadline
```

`Cancelling` 保留原检查的元数据、帧和方案，直至 Worker 确认停止。

### 9.3 触发检查

1. 状态不是 `Idle` 时返回 `Busy`；
2. 检查应用状态与检查类型，不匹配时返回 `InvalidMode`；
3. 测试检查重新校验草稿，失败时返回 `ConfigInvalid`；
4. 测试检查编译临时方案，失败时返回 `PlanBuildFailed`；
5. 生产检查获取当前生产方案；
6. 从 Latest Frame Store 获取最新帧；
7. 没有方案时返回 `NoPlan`；
8. 没有帧时返回 `NoFrame`；
9. 生成 InspectionMetadata；
10. 固定帧和检查方案；
11. 创建取消信号并记录超时时限；
12. 切换为 `Running`；
13. 将任务提交给 Inspection Worker。

后续帧和配置变化不影响当前检查。

### 9.4 正常完成

Inspection Worker 在超时前返回后：

1. 校验 `inspection_id` 和当前状态；
2. 使用 InspectionMetadata 和核心输出组装 InspectionResult；
3. 使用结果和固定帧共享引用组装 InspectionPresentation；
4. 将 InspectionPresentation 发送给 GUI；
5. 释放 Actor 持有的帧和方案引用；
6. 切换回 `Idle`。

GUI 事件持有独立帧引用。Actor 释放自身引用不影响结果展示。

### 9.5 超时与取消

超时后：

1. 切换为 `Cancelling`；
2. 向 Inspection Worker 发出取消信号；
3. 拒绝新的检查请求；
4. 等待 Worker 停止；
5. Worker 在取消宽限期内停止后，丢弃其输出；
6. 将 `InspectionTimedOut` 发送给 GUI；
7. 释放固定帧和方案；
8. 切换回 `Idle`。

超时检查不生成正常 InspectionResult。Worker 未在取消宽限期内停止时直接 `panic`。

## 10. Inspection Worker

Inspection Worker 在独立工作线程中同步执行 Inspection Core。

职责：

- 接收 Inspection Actor 提交的任务；
- 向 Inspection Core 传递帧、方案和取消信号；
- 返回核心输出、检查错误或 `Cancelled`。

约束：

- 同一时间只执行一个任务；
- 不管理应用状态；
- 不读取 Latest Frame Store；
- 不操作 GUI；
- 不读写配置；
- 不强制终止工作线程。

GUI 的异步任务只负责发送命令和接收消息，不承载检查计算。

## 11. Inspection Core

概念接口：

```text
inspect(frame, inspection_plan, cancellation) -> inspection_core_outcome
```

执行约束：

- 按 Inspection Plan 的线性顺序执行算子；
- 所有输入显式传入；
- 不读取摄像头、Latest Frame Store 或配置文件；
- 不操作 GUI；
- 不执行持久化；
- 不修改全局业务状态；
- 算子不执行外部业务副作用；
- 阶段之间检查取消信号；
- 长时间运行的算子定期检查取消信号；
- 收到取消信号后尽快返回 `Cancelled`。

返回类型：

```text
InspectionCoreOutcome
├── Completed(InspectionCoreOutput)
├── Cancelled
└── Failed(InspectionError)

InspectionCoreOutput
├── decision
├── measurements
├── defects
└── optional_visualization
```

Inspection Actor 组装最终结果：

```text
InspectionResult
├── metadata: InspectionMetadata
└── core_output
```

## 12. 主要流程

### 12.1 采集与预览

```text
Camera SDK
    → Camera Actor 阻塞采集
    → 复制图像数据
    → 构造不可变 Frame
    → 替换 Latest Frame Store
    → GUI 读取最新帧
```

### 12.2 生产检查

```text
Home 选择配置文件
    → 加载并编译
    → 进入 ProductionMode
    → GUI 发起生产检查
    → Inspection Actor 固定帧和方案
    → Inspection Worker
    → Inspection Core
    → Inspection Actor 组装结果
    → GUI 展示结果
```

### 12.3 编辑测试

```text
Home 选择配置文件
    → 加载为 Draft Config
    → GUI 修改草稿
    → 重新校验并编译临时方案
    → Inspection Actor 固定帧和方案
    → Inspection Worker
    → Inspection Core
    → Inspection Actor 组装结果
    → GUI 展示测试结果
```

### 12.4 超时取消

```text
Inspection Actor 检测到超时
    → Cancelling
    → 通知 Inspection Worker
    → Worker 停止
        ├── 宽限期内停止 → 丢弃输出 → GUI 接收 InspectionTimedOut → Idle
        └── 宽限期内未停止 → panic
```

## 13. 错误

- `Busy`：已有检查正在运行或取消中；
- `NoFrame`：没有可用帧；
- `NoPlan`：没有可用检查方案；
- `InvalidMode`：检查类型与应用状态不匹配；
- `ConfigLoadFailed`：配置读取或解析失败；
- `ConfigInvalid`：配置校验失败；
- `PlanBuildFailed`：方案构建失败；
- `ConfigSaveFailed`：配置保存失败；
- `InspectionFailed`：检查执行失败；
- `InspectionTimedOut`：检查超时且 Worker 已停止。

## 14. 架构约束

1. Camera Actor 是摄像头的唯一访问者。
2. Camera Actor 不等待帧消费者。
3. Latest Frame Store 只有一个写入者。
4. 已发布的 Frame 始终不可变。
5. GUI 不积压预览帧。
6. Home、EditMode 和 ProductionMode 互斥。
7. 每个模式只加载用户选中的配置文件。
8. Draft Config 不修改生产方案。
9. Inspection Actor 串行处理检查请求。
10. Inspection Core 只在 Inspection Worker 中执行。
11. `Running` 和 `Cancelling` 均拒绝新检查。
12. 同一时间最多运行一个检查任务。
13. 检查期间固定帧和检查方案。
14. InspectionPresentation 持有检查帧共享引用。
15. 取消通过显式取消信号协作完成。
16. Inspection Core 及其算子不执行外部业务副作用。
