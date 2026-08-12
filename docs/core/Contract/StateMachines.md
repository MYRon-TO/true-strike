# 状态机规约

本文定义应用生命周期、应用模式、Inspection Actor 和 Camera Actor 的状态转换。整体规约索引见 [行为规约](../Contract.md)。

## 1. ApplicationLifecycle

应用生命周期独立于 `AppState`：

```text
Starting → Running → ShuttingDown → Terminated
```

- `Starting`：初始化组件，尚不处理 GUI 命令；
- `Running`：`AppState` 有效，正常处理应用命令；
- `ShuttingDown`：关机流程已开始，不再接受新的应用命令；
- `Terminated`：组件已关闭，应用资源已释放。

转换规则：

| 当前状态 | 输入 | 下一状态 | 条件 |
| --- | --- | --- | --- |
| Starting | 初始化完成 | Running | Home 已提交，Camera Actor 已开始采集 |
| Starting | 初始化失败 | 终止进程 | `panic` |
| Running | 优雅关机 | ShuttingDown | 无 |
| ShuttingDown | 全部关闭步骤完成 | Terminated | 无 |
| ShuttingDown | 组件关闭失败或取消宽限期耗尽 | 终止进程 | `panic` |

`ShuttingDown` 不属于 GUI 业务模式，不加入 `AppState`。进入该状态后不可返回 `Running`。

## 2. AppState

`AppState` 仅在 ApplicationLifecycle 为 `Running` 时有效：

```text
Home
EditMode(mode_session_id, config_path, draft_config, optional_presentation)
ProductionMode(mode_session_id, config_path, loaded_config, production_plan, optional_presentation)
```

已定义转换：

| 当前状态 | 输入 | 下一状态 | 条件 |
| --- | --- | --- | --- |
| Home | 进入编辑模式 | EditMode | 配置读取、解析和校验成功 |
| Home | 进入生产模式 | ProductionMode | 配置读取、校验和方案构建成功 |
| EditMode | 返回主页 | Home | 无 |
| ProductionMode | 返回主页 | Home | 无 |

模式进入采用状态外准备和单点提交，不增加显式过渡状态。准备期间 App Controller 保持原状态并继续占有串行处理权，后续命令等待。

ApplicationLifecycle 进入 `ShuttingDown` 后，不再发生 `AppState` 模式转换。当前 `AppState` 只在关机流程中等待释放，不需要先转换为 Home。

需要补充：

- Home 文件选择结果是否属于 AppState；
- GUI 可观察状态与 AppState 的映射。

## 3. Inspection Actor

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
| Cancelling | Worker 已停止 | Idle | 发布内部取消完成通知 |
| Cancelling | 取消宽限期耗尽 | 终止进程 | `panic` |
| Idle | 取消请求 | Idle | 立即确认无需取消 |

关机取消规则：

- 因关机进入 `Cancelling` 后，不生成正常检查结果或失败展示；
- Worker 停止后，Actor 释放任务资源、转入 `Idle`，并确认取消完成；
- 关机流程以该确认或 Idle 状态确认作为继续关闭 Worker 和 Actor 的条件；
- 重复取消不得延长最初的取消宽限期。

Worker 任务提交失败属于内部基础设施失效，直接 `panic`，不执行状态回滚。

需要补充：

- 返回 Home 与关机取消请求重叠时的取消原因优先级；
- Actor 的具体关闭消息与确认类型。

## 4. Camera Actor

```text
未启动 → 采集中 → 已停止
```

- 应用启动成功前，Camera Actor 必须进入采集中；
- 优雅关机进入 `ShuttingDown` 后，先请求 Camera Actor 停止采集并关闭摄像头；
- Camera Actor 确认已停止后，关机流程才能继续；
- 初始化、采集或关闭失败在 v1 中直接 `panic`。

摄像头运行状态如何投影给 GUI 待定义。
