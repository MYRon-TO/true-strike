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
- `ModeSessionId` 随检查申请、检查元数据和异步检查事件传递；
- `inspection_id` 由 Inspection Actor 接受检查申请时生成；
- `frame_id` 由 Camera Actor 生成，且在应用运行期间唯一。

## 3. 用例与命令规约

### 3.1 启动应用

- **触发方**：应用运行环境。
- **前置状态**：应用尚未运行。
- **输入**：待定义。
- **处理过程**：初始化应用组件，Camera Actor 初始化摄像头并开始采集。
- **成功结果**：应用进入 Home，摄像头持续采集。
- **失败结果**：摄像头初始化失败时直接 `panic`；其他启动失败语义待定义。
- **异步后续**：Camera Actor 持续发布最新帧。
- **资源变化**：待定义。

### 3.2 进入编辑模式

- **触发方**：GUI。
- **前置状态**：Home。
- **输入**：用户选择的配置文件路径。
- **处理过程**：
  1. Scheme Manager 读取并解析配置文件；
  2. App Controller 创建内存草稿；
  3. App Controller 生成新的 `ModeSessionId`；
  4. 前述操作成功后提交状态转换。
- **成功结果**：进入 EditMode，并持有配置路径和 Draft Config。
- **失败结果**：返回 `ConfigLoadFailed`，保留 Home。
- **异步后续**：无。
- **资源变化**：EditMode 取得草稿和配置路径的所有权。

### 3.3 进入生产模式

- **触发方**：GUI。
- **前置状态**：Home。
- **输入**：用户选择的配置文件路径。
- **处理过程**：
  1. Scheme Manager 读取并解析配置文件；
  2. 校验配置；
  3. 构建不可变 Inspection Plan；
  4. App Controller 生成新的 `ModeSessionId`；
  5. 前述操作成功后提交状态转换。
- **成功结果**：进入 ProductionMode，并持有配置、配置路径和有效方案。
- **失败结果**：根据失败阶段返回 `ConfigLoadFailed`、`ConfigInvalid` 或 `PlanBuildFailed`，并保留 Home。
- **异步后续**：无。
- **资源变化**：ProductionMode 取得配置和生产方案的所有权。

ProductionMode 运行期间不自动重新读取配置文件。

### 3.4 返回主页

- **触发方**：GUI。
- **前置状态**：EditMode 或 ProductionMode。
- **输入**：无。
- **处理过程**：
  1. App Controller 先将状态切换为 Home；
  2. 释放原模式持有的配置、方案和展示对象；
  3. 如果检查正在运行，则在后台请求取消。
- **成功结果**：立即完成向 Home 的转换，不等待取消结束。
- **失败结果**：待定义。
- **异步后续**：可能继续执行检查取消流程。
- **资源变化**：模式资源被释放；任务已固定的资源继续由 Inspection Actor 持有，直至任务终止。

### 3.5 修改配置草稿

- **触发方**：GUI。
- **前置状态**：EditMode。
- **输入**：草稿修改操作，具体类型待定义。
- **处理过程**：App Controller 将修改应用到当前 Draft Config。
- **成功结果**：内存草稿更新。
- **失败结果**：修改校验层级及错误语义待定义。
- **异步后续**：无。
- **资源变化**：不修改配置文件，不创建或修改生产方案。

### 3.6 校验配置草稿

- **触发方**：GUI。
- **前置状态**：EditMode。
- **输入**：当前 Draft Config。
- **处理过程**：待定义。
- **成功结果**：待定义。
- **失败结果**：`ConfigInvalid` 的结构待定义。
- **异步后续**：无。
- **资源变化**：不得修改草稿和配置文件。

### 3.7 保存配置草稿

- **触发方**：GUI。
- **前置状态**：EditMode。
- **输入**：当前 Draft Config 和原配置文件路径。
- **处理过程**：
  1. 校验草稿；
  2. 确认草稿可以构建方案；
  3. 计算递增后的 `revision`；
  4. 将新配置写入临时文件；
  5. 原子替换原配置文件；
  6. 提交新的 `revision`；
  7. 将内存草稿同步为新 `revision`。
- **成功结果**：文件和内存草稿具有相同的新 `revision`，应用继续处于 EditMode。
- **失败结果**：根据失败阶段返回 `ConfigInvalid`、`PlanBuildFailed` 或 `ConfigSaveFailed`。
- **异步后续**：无。
- **资源变化**：失败时原文件、原 `revision` 和内存草稿的 `revision` 均保持不变。

### 3.8 发起测试检查

- **触发方**：GUI。
- **前置状态**：EditMode。
- **输入**：无；使用当前 Draft Config。
- **处理过程**：
  1. App Controller 固定当前 `ModeSessionId` 和 Latest Frame Store 中的最新 Frame；
  2. 从当前草稿校验并构建临时 Inspection Plan；
  3. 按通用检查申请规约向 Inspection Actor 提交申请。
- **成功结果**：Inspection Actor 接受申请并开始检查。
- **失败结果**：可能返回 `NoFrame`、`ConfigInvalid`、`PlanBuildFailed` 或 `Busy`。
- **异步后续**：产生检查完成、检查失败或检查超时事件；取消事件语义见第 7 节。
- **资源变化**：临时方案只属于本次命令和对应任务，不进入 EditMode 持久状态。

### 3.9 发起生产检查

- **触发方**：GUI。
- **前置状态**：ProductionMode。
- **输入**：无；使用当前生产方案。
- **处理过程**：
  1. App Controller 固定当前 `ModeSessionId` 和 Latest Frame Store 中的最新 Frame；
  2. 取得当前不可变生产方案；
  3. 按通用检查申请规约向 Inspection Actor 提交申请。
- **成功结果**：Inspection Actor 接受申请并开始检查。
- **失败结果**：可能返回 `NoFrame` 或 `Busy`。
- **异步后续**：产生检查完成、检查失败或检查超时事件；取消事件语义见第 7 节。
- **资源变化**：任务获得 Frame 和 Inspection Plan 的独立共享引用。

### 3.10 模式不匹配的检查命令

- EditMode 只接受测试检查；
- ProductionMode 只接受生产检查；
- Home 不接受检查；
- 检查类型与当前状态不匹配时返回 `InvalidMode`；
- `InvalidMode` 不产生检查申请，不改变状态和资源。

### 3.11 优雅关机

- **触发方**：应用运行环境或 GUI。
- **前置状态**：任意应用状态。
- **输入**：无。
- **处理过程**：请求取消正在运行的检查，并等待取消结束；随后停止 Camera Actor 并关闭摄像头。
- **成功结果**：待定义。
- **失败结果**：待定义。
- **异步后续**：无。
- **资源变化**：全部应用资源的释放顺序待定义。

取消完成的通知与等待协议待定义。

## 4. 状态机规约

### 4.1 AppState 状态机

状态：

```text
Home
EditMode(mode_session_id, config_path, draft_config, optional_presentation)
ProductionMode(mode_session_id, config_path, loaded_config, production_plan, optional_presentation)
```

已定义转换：

| 当前状态 | 输入 | 下一状态 | 条件 |
| --- | --- | --- | --- |
| Home | 进入编辑模式 | EditMode | 配置读取和解析成功 |
| Home | 进入生产模式 | ProductionMode | 配置读取、校验和方案构建成功 |
| EditMode | 返回主页 | Home | 无 |
| ProductionMode | 返回主页 | Home | 无 |
| 任意状态 | 关机 | 终止 | 等待协议待定义 |

需要补充：

- 模式进入命令执行期间是否需要显式过渡状态；
- Home 文件选择结果是否属于 AppState；
- 命令执行中的重复输入如何处理；
- GUI 可观察状态与 AppState 的映射。

### 4.2 Inspection Actor 状态机

状态：

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
├── cancellation_reason
└── cancellation_deadline
```

已定义转换：

| 当前状态 | 输入 | 下一状态 | 对外结果 |
| --- | --- | --- | --- |
| Idle | 合法检查申请 | Running | 接受申请 |
| Running | 检查申请 | Running | `Busy` |
| Cancelling | 检查申请 | Cancelling | `Busy` |
| Running | 匹配的 `Completed` | Idle | 检查完成事件 |
| Running | 匹配的 `Failed` | Idle | 检查失败事件 |
| Running | 取消请求或执行超时 | Cancelling | 触发协作式取消 |
| Cancelling | Worker 已停止 | Idle | 依取消原因处理事件 |
| Cancelling | 取消宽限期耗尽 | 终止 | `panic` |

需要补充：

- Idle 收到取消请求的结果；
- 重复取消的处理；
- Worker 提交任务失败时的状态回滚；
- Actor 关闭流程。

### 4.3 Camera Actor 生命周期

```text
未启动 → 采集中 → 已停止
```

需要补充：

- 启动和停止的确认语义；
- 应用关机时与其他组件的停止顺序；
- 摄像头状态如何投影给 GUI。

## 5. 消息规约

### 5.1 App Controller 命令

需要定义统一的应用命令集合及各命令返回类型，至少包括：

- 进入编辑模式；
- 进入生产模式；
- 返回主页；
- 修改草稿；
- 校验草稿；
- 保存草稿；
- 发起测试检查；
- 发起生产检查；
- 优雅关机。

命令的具体类型、字段和同步响应形式待定义。

### 5.2 检查申请

App Controller 向 Inspection Actor 提交的检查申请至少包含：

- 固定的 `ModeSessionId`；
- 检查类型；
- 固定的 Frame；
- 不可变 Inspection Plan。

Inspection Actor 串行处理申请：

- 收到申请时处于 `Running` 或 `Cancelling`，立即返回 `Busy`；
- 收到申请时处于 `Idle`，生成 `inspection_id` 和 InspectionMetadata，创建取消信号和截止时间，转入 `Running`，并向 Worker 提交任务。

申请一旦被接受，应用模式、草稿、配置文件和 Latest Frame Store 的后续变化均不影响任务输入。

需要补充：

- 申请被接受的响应类型；
- Worker 提交失败的响应；
- 请求与响应的关联方式。

### 5.3 Worker 任务

Inspection Actor 向 Inspection Worker 提交的任务至少包含：

- InspectionMetadata；
- 固定的 Frame；
- 固定的 Inspection Plan；
- 取消信号。

任务提交和接收的确认语义待定义。

### 5.4 Worker 输出

Worker 输出分为：

- `Completed(InspectionCoreOutput)`；
- `Failed(InspectionError)`；
- `Cancelled`。

每个输出必须能够与当前任务的 `inspection_id` 关联。具体消息类型待定义。

### 5.5 Inspection Actor 事件

Inspection Actor 向 App Controller 发送的事件至少包括：

- 检查完成；
- 检查失败；
- 检查超时；
- 取消完成，是否作为统一事件待定义。

所有可能更新模式展示状态的事件必须携带 `ModeSessionId`。事件载荷及统一事件类型待定义。

### 5.6 异步事件过滤

App Controller 仅在事件的 `ModeSessionId` 与当前 EditMode 或 ProductionMode 匹配时，允许事件更新当前模式的展示状态。

以下事件必须丢弃：

- App Controller 当前处于 Home；
- 当前模式的 `ModeSessionId` 与事件不一致。

丢弃事件不影响 Inspection Actor 自身的状态转换和资源释放。

## 6. 资源生命周期规约

### 6.1 Frame

Camera Actor 从 SDK 获得图像后：

1. 将图像数据复制到应用拥有的内存；
2. 生成 `frame_id` 并构造不可变 Frame；
3. 通过共享引用发布到 Latest Frame Store；
4. 新引用替换 Store 中的旧引用。

约束：

- 发布后的图像内存不得修改或复用；
- Latest Frame Store 只保存一个最新帧引用；
- 每次读取返回读取时最新 Frame 的独立共享引用；
- 尚未发布帧时，读取结果表示无帧；
- 替换最新帧不修改旧帧，也不等待消费者；
- Frame 在全部共享引用释放后销毁。

### 6.2 检查帧

App Controller 处理合法检查触发命令时，从 Latest Frame Store 读取最新 Frame，并将其固定为本次检查输入。

- 没有可用帧时返回 `NoFrame`，不提交检查申请；
- Inspection Actor 不再次读取 Latest Frame Store；
- 后续发布的新帧不影响该检查；
- 申请失败时释放本次命令临时持有的 Frame；
- 申请成功后，Inspection Actor 持有 Frame，直至任务终止；
- 检查完成或失败事件持有供展示使用的独立共享引用。

### 6.3 Draft Config

- Draft Config 由 EditMode 持有；
- 修改草稿只改变内存状态；
- 草稿变化不创建或修改生产方案；
- 返回 Home 时释放草稿；
- 保存成功后只同步其 `revision` 和已保存内容，具体同步模型待定义。

### 6.4 Inspection Plan

- Inspection Plan 从有效配置构建，且构建后不可变；
- 生产方案由 ProductionMode 持有；
- 测试方案只属于单次测试检查；
- 方案不得使用空值表示缺少方案，但阶段列表可以为空；
- 禁用阶段不得执行，其在构建后方案中的表示方式待定义；
- 申请成功后，Inspection Actor 持有任务方案，直至任务终止。

### 6.5 InspectionPresentation

GUI 只保留当前模式最近一次 InspectionPresentation。展示对象至少包含关联帧以及以下内容之一：

- 成功的 InspectionResult；
- 失败的 InspectionError 及对应元数据。

展示规则：

- 成功且存在可视化数据时，在关联帧上显示标记；
- 成功但没有可视化数据时，显示关联帧和文字结果；
- 失败时显示关联帧和错误；
- 新展示替换旧展示时释放旧帧引用；
- 离开当前模式时释放展示对象。

GUI 展示状态投影及其与 AppState 的边界待定义。

## 7. 执行、并发与取消规约

### 7.1 Inspection Core 执行

Inspection Worker 将固定的 Frame、Inspection Plan 和取消信号显式传入 Inspection Core。

Inspection Core：

- 按方案的线性顺序执行算子；
- 在阶段之间检查取消信号；
- 长时间运行的算子定期检查取消信号；
- 收到取消信号后尽快返回 `Cancelled`；
- 不读取外部业务状态；
- 不执行持久化或其他外部业务副作用。

### 7.2 正常完成

Inspection Actor 在 `Running` 状态处理匹配当前 `inspection_id` 的 `Completed` 时：

1. 使用 InspectionMetadata 和核心输出组装 InspectionResult；
2. 使用结果和固定帧组装 InspectionPresentation；
3. 向 App Controller 发送携带 `ModeSessionId` 的完成事件；
4. 释放 Actor 持有的帧和方案；
5. 切换为 `Idle`。

### 7.3 执行失败

Inspection Actor 在 `Running` 状态处理匹配当前 `inspection_id` 的 `Failed` 时：

1. 使用 InspectionMetadata、检查错误和固定帧组装失败展示对象；
2. 向 App Controller 发送携带 `ModeSessionId` 的失败事件；
3. 释放 Actor 持有的帧和方案；
4. 切换为 `Idle`。

失败展示对象持有关联检查帧，并按与成功结果相同的会话隔离规则更新最近一次展示对象。

### 7.4 取消来源

取消可由以下原因触发：

- 检查超时；
- 返回 Home；
- 应用优雅关机。

检查执行超时和取消宽限期使用应用级固定值。

### 7.5 进入 Cancelling

Inspection Actor 在 `Running` 状态处理取消时：

1. 切换为 `Cancelling`；
2. 保留原任务上下文、帧和方案；
3. 设置取消信号；
4. 记录取消原因和取消截止时间；
5. 拒绝后续检查申请。

`Cancelling` 持续到 Worker 确认停止。系统不强制终止 Worker 线程。

### 7.6 取消结果

因检查超时进入 `Cancelling` 后：

- Worker 在宽限期内停止时丢弃其输出；
- Inspection Actor 发送携带 `ModeSessionId` 的 `InspectionTimedOut` 事件；
- 超时检查不生成正常 InspectionResult；
- Actor 释放固定帧和方案，并切换为 `Idle`；
- Worker 未在宽限期内停止时直接 `panic`。

返回 Home 或关机触发的取消不生成正常检查结果。其取消完成通知和等待语义待定义。

### 7.7 完成与取消的竞争

Inspection Actor 以串行事件处理顺序裁决完成与取消：

- 先处理完成或失败事件时，任务按对应结果结束；
- 先处理取消事件并进入 `Cancelling` 时，之后到达的完成或失败输出一律丢弃；
- 过期或 `inspection_id` 不匹配的 Worker 事件不得改变当前状态。

### 7.8 其他竞争场景

需要补充：

- 返回 Home 与新检查申请的竞争；
- 关机与检查完成的竞争；
- 检查申请与检查超时计时起点的关系；
- 配置保存与测试检查触发的顺序；
- GUI 重复提交同一命令的处理。

## 8. 配置、方案与算子规约

### 8.1 配置有效性

一份配置只有同时满足以下条件才可构建方案：

- 结构和字段有效；
- `operator_id` 均对应已注册算子；
- 算子参数可以解析并通过各自校验；
- 判定规则有效；
- 配置不包含可执行代码、任意函数地址或未注册算子。

构建失败不得产生可执行方案。

### 8.2 方案构建

方案构建遵循配置顺序，解析已启用的算子及其参数，生成不可变 Inspection Plan。

需要补充：

- 配置校验与方案构建的错误边界；
- 参数解析后的类型表示；
- 禁用阶段的构建语义；
- 算子注册表的查询契约。

### 8.3 算子输入输出

待定义：

- 算子的输入类型；
- 阶段之间的数据传递模型；
- 阶段输出和累积结果；
- 算子失败语义；
- 取消检查频率和责任边界。

### 8.4 判定规则

待定义：

- 判定规则可读取的数据；
- 判定执行时点；
- 空阶段方案的判定语义；
- 判定规则失败的错误语义。

### 8.5 可视化数据

待定义：

- 可视化数据的坐标系和关联帧；
- 多阶段可视化数据的合并语义；
- 无可视化数据的表示；
- GUI 可依赖的最小展示契约。

## 9. 错误与结果语义

### 9.1 业务错误

- `Busy`：Inspection Actor 收到申请时已有检查正在运行或取消中；
- `NoFrame`：App Controller 固定检查帧时没有可用帧；
- `InvalidMode`：检查类型与 App Controller 当前状态不匹配；
- `ConfigLoadFailed`：配置读取或解析失败；
- `ConfigInvalid`：配置未通过校验；
- `PlanBuildFailed`：配置无法构建可执行方案；
- `ConfigSaveFailed`：配置未能按保存事务提交；
- `InspectionFailed`：Inspection Core 执行失败，并生成关联帧的失败展示；
- `InspectionTimedOut`：检查超时，且 Worker 已在取消宽限期内停止。

需要为每项错误补充：

- 产生组件；
- 携带上下文；
- 是否可展示；
- 是否改变状态；
- 是否允许重试。

### 9.2 致命错误

以下错误不属于可恢复业务错误，直接 `panic`：

- 摄像头初始化失败；
- 摄像头采集失败；
- Worker 未在取消宽限期内停止。

其他内部不变量被破坏时的处理待定义。

### 9.3 检查结果

需要补充：

- InspectionResult 的完整字段；
- InspectionError 的分类与上下文；
- 成功、失败、取消和超时之间的类型关系；
- 对 GUI 暴露的结果投影。

## 10. 系统级不变量

当前已确定的不变量：

1. App Controller 是 AppState 的唯一所有者。
2. 模式相关命令由 App Controller 串行处理。
3. 每次进入 EditMode 或 ProductionMode 都生成新的 `ModeSessionId`。
4. 过期模式会话的异步事件不得修改当前展示状态。
5. Camera Actor 是摄像头的唯一访问者。
6. Camera Actor 是 Latest Frame Store 的唯一写入者。
7. Camera Actor 不等待帧消费者。
8. 已发布 Frame 始终不可变。
9. GUI 不积压预览帧。
10. Inspection Actor 不读取或持有 AppState。
11. Inspection Actor 串行处理检查申请和任务事件。
12. `Running` 和 `Cancelling` 均拒绝新检查申请。
13. 同一时间最多执行一个检查任务。
14. 检查期间固定 Frame 和 Inspection Plan。
15. Inspection Core 只在 Inspection Worker 中执行。
16. Inspection Core 及其算子不执行外部业务副作用。
17. 检查完成与取消的竞争由 Inspection Actor 的事件处理顺序裁决。
18. 每个被接受的检查最终必须释放 Actor 持有的 Frame 和 Inspection Plan，或因致命错误终止进程。
19. InspectionPresentation 持有关联检查帧。
20. 生产方案和测试任务方案都不为空，但允许阶段列表为空。

后续每增加一个命令、状态或消息，都应检查其是否保持以上不变量。

## 11. 完整性检查清单

### 11.1 用例覆盖

- [ ] 每个 Scope 功能都有对应命令或明确的后台行为；
- [ ] 每个命令都定义前置状态、成功和失败结果；
- [ ] 每个异步用例都定义终止路径；
- [ ] 每个退出路径都定义资源释放。

### 11.2 状态机覆盖

- [ ] 每个命令在所有 AppState 下都有确定结果；
- [ ] Inspection Actor 的每种输入在所有状态下都有确定结果；
- [ ] 所有过渡状态都有成功、失败、取消和超时出口；
- [ ] 过期及重复消息不会破坏当前状态。

### 11.3 消息覆盖

- [ ] 每条消息都有发送方、接收方和载荷；
- [ ] 每个请求都有接受、拒绝或丢弃条件；
- [ ] 每个异步响应都有身份关联字段；
- [ ] 每条消息的资源所有权变化明确。

### 11.4 错误与资源覆盖

- [ ] 每个副作用都定义失败语义；
- [ ] 每个错误都定义状态是否变化；
- [ ] 每个共享资源都定义创建、持有、转移和释放；
- [ ] 每个已接受任务都存在确定的资源终止路径。

## 12. 待讨论事项

1. GUI 可持有的展示状态投影及其与 AppState 的边界；
2. Home 文件选择结果的状态归属；
3. 取消完成通知和优雅关机等待协议；
4. 算子输入输出和阶段间数据传递模型；
5. 判定规则及空阶段方案语义；
6. 多阶段可视化数据的合并语义；
7. 状态机章节中列出的未定义输入与竞争场景；
8. 消息和错误的具体类型结构。
