# Backplane Diagnostics 设计文档

## 文档信息

| 项目 | 内容 |
| --- | --- |
| 文档版本 | 0.1 |
| 日期 | 2026-11-27（Asia/Shanghai） |
| 项目标签 | project: backplane |
| 目标仓库 | gsmlg-opt/backplane |
| 接入项目 | Sigma、Synapsis、Samgita，以及 Backplane 自身 |
| 建议仓库路径 | docs/diagnostics/backplane-diagnostics-design.md |
| 状态 | 用户已确认功能方向并要求成文；本文为待实施设计 |
| 适用读者 | 项目维护者、架构评审者、负责实现与验收的开发 Agent |

**目标：自动收集 AI 系统中的程序异常与异常行为，通过 Host Agent 保存和补充现场，在 Backplane 中形成可分析、可汇报、可修复、可验证的问题。**

本文包含架构、采集契约、两级可靠交付、问题模型、自动分析、修复验证、实施阶段和验收要求。除“当前代码基线”明确标注的内容外，新增模块、接口、配置和行为均为设计目标，不能视为已经实现、测试、发布或部署。

用户已明确的方向是：覆盖程序异常和 Bug 候选；自动收集并汇报；服务于 AI 系统分析、改善与修复；优先经 Host Agent 收集。本文中的字段、模块命名和初始容量是实现建议。

## 1. 目标与设计原则

### 1.1 必须达成的结果

| 编号 | 要求 |
| --- | --- |
| R1 | 接入一次基础 Reporter 后，支持范围内的 Logger/OTP/Phoenix 异常自动形成结构化报告 |
| R2 | 已被捕获并转换为错误结果的失败，能够在 Provider、Tool、Runtime 等公共边界保留现场 |
| R3 | Host Agent 提供本地接收、宿主旁证、有界持久缓存和断线补传 |
| R4 | 同一次故障的多个观察可关联；同类问题的多次发生可聚合，次数语义明确 |
| R5 | 自动发现有证据支持的运行异常，区分软件缺陷、环境问题、上游问题和预期控制流 |
| R6 | 自动生成问题报告；具备模型配置时，自动生成带证据引用的分析与修复任务 |
| R7 | 关联回归测试、修复提交、实际运行版本和复发情况，形成修复验证记录 |
| R8 | 采集、上传和分析失败不改变 Agent 的业务结果，不无限消耗应用资源 |

### 1.2 架构原则

1. **事实与推断分开。** 原始事件、服务端检测结果、模型分析、修复结论分别存储。
2. **应用保留语义，Host Agent 负责本机收集。** 应用知道 run、attempt、异常栈；Host Agent 知道进程、服务、宿主和持久交付状态。
3. **运行状态仍由产品自己的 Runtime/Store 管理。** Diagnostics 保存观测投影，不能凭遥测缺失改写任务终态或重执行工具。
4. **转换核心保持纯函数。** 事件规范化、错误分类、指纹和投影规则可独立测试；通信、持久化和模型调用位于适配器与 worker。
5. **两级持久确认，至少一次投递。** 本机已保存与服务器已保存是不同承诺；通过幂等实现正确的事件和故障计数。
6. **默认收集最小诊断证据。** 秘密和正文在首次落盘前过滤，全文附件单独控制。
7. **按问题汇报。** 新问题、恶化、复发和实质新证据触发报告更新，重复日志只更新聚合。
8. **质量改进以验证为依据。** 模型建议、测试通过、已部署和运行观察是不同状态。

### 1.3 首版边界

首版必须交付自动异常采集、Host Agent 补传、问题聚合、自动报告、受预算控制的辅助分析，以及修复验证记录。

以下能力可后续增加：完整 OTLP 接收、外部观测平台导出、自动生成并发布 PR、大规模行为评测、跨组织多租户、完整执行录制与重放。首版不需要 Kafka、独立列式数据库或新建通用日志搜索引擎。

按现有单用户方向设计。project、repository、host、agent、session 是出处与检索维度；来源凭据用于防止伪造上报，不另建基于项目标签的数据分区体系。（Agent Note N1，见第 19.2 节）

## 2. 当前代码基线与复用边界

### 2.1 本文检查的版本

| 仓库 | 检查提交 |
| --- | --- |
| gsmlg-opt/backplane | 7f868296b4f55ec45d84d5adb1a32173b372a8fa |
| gsmlg-opt/sigma | e8c93931ab700e9ecdad3a1d7359a67147bd374b |
| gsmlg-opt/Synapsis | 025a477bdc4401fa9fa1659485888286b29540da |
| gsmlg-opt/Samgita | 62e65c40b9ce3a8c11eb959a58d3c4cc04a25567 |

这些是设计所依据的源码快照。实施前应检查目标分支差异；本文没有声称验证生产环境。

### 2.2 已有能力

| 组件 | 已检查的行为 | 本设计中的用途 |
| --- | --- | --- |
| backplane_telemetry | 事件封装、关联上下文、脱敏、缓冲和运行日志；目前依赖 backplane_system | 复用服务端观测基础；不直接作为产品的轻量 SDK |
| HostAgent.TraceStore | 订阅 Host Agent 自身固定的 memory/MCP 事件；追加 JSONL 与序号文件 | 参考关联和本地保存经验，不能当作通用异常收集器 |
| HostAgent.TraceSyncer | host_trace.v1 经 trace_sync 上传；按连续成功序号推进游标 | 旧协议保持兼容；新诊断协议使用逐事件确认 |
| HostAgent.Reporter | 主机、版本、Memory/Capture 状态与队列健康 | 增加独立 diagnostics 状态 |
| HostAgent.HttpServer / MemoryRouter | 现有本地 HTTP 服务和 Memory/Capture 入口；默认 loopback，可配置其他绑定 | 增加明确的本地诊断入口与来源认证，保留旧 API 契约 |
| Memory.CaptureUploader | host_events.v1 → memory_events；已有批次确认、重试与 dead-letter 处理模式 | 参考可靠交付模式；诊断数据使用独立协议、spool 和服务端领域 |
| Backplane.AgentTraces | agent_trace_events 按 host_id 与 agent_seq 去重持久化 | 旧 trace 作为可关联证据，不承担 Issue 模型 |
| AgentRuntime.Error / Event | 类型化错误、事件身份与来源序列；Error.to_map 不包含 cause | 在错误转换前捕获脱敏现场，保留 Runtime 原有公共错误格式 |
| Sigma Metrics | Request/Turn 身份、revision、retry、usage provenance 等 | 映射现有事实，避免重新计算一套不一致的指标 |
| Synapsis RunEvents | 关键运行事实与可降级观测事实分开 | 在关键事实确认后导出观测投影 |
| Samgita NativeRuntimeEvent | runtime/instance/generation/source_sequence/method/state 等 | 保留原生 driver 与运行身份，形成来源适配 |

证据见 [B1]–[B15]。已有 Memory 文档是相关背景，历史分支能力不能直接作为当前 Diagnostics 已实现的证据。（Agent Note N1、N2，见第 19.2 节）

### 2.3 复用前必须处理的边界

- TraceStore 使用异步 cast，写入异常会被捕获后返回原状态；不能将调用返回解释为持久保存成功。其 sanitize 主要做类型序列化，不等于秘密脱敏。[B2]
- 旧 trace_sync 与部分 Memory 消息的授权重验方式不同。新 diagnostics 消息应逐批重验有效凭据和权限，不能仅依赖 join 时通过认证。[B5]
- AgentTraces 对冲突使用 on_conflict: nothing，没有检查相同身份是否携带不同内容。新协议需要身份冲突检测。[B6]
- 现有 Event 的字符串 operation 可转为新 atom；新外部协议必须使用受限字符串或固定枚举，不能将外部输入任意转 atom。[B16]
- RuntimeSink mailbox 和现有 Buffer 的并发准入不能直接作为新高流量入口的容量保证；新链路必须验证严格的有界准入。[B17] [B22]
- 当前 Redaction 的部分键名规范化与凭据名单不一致；复用前需修正并验证。异常消息、栈和日志片段也必须经过统一的内容限制。[B18]
- 现有 LLM writer 是可降级的日志写入路径，数据库失败后不重排该批次。它的 enqueue 结果不能作为诊断远端持久确认。[B19]

这些是设计输入中的源码观察，不代表已在生产复现故障。实施只修复实际复用边界，不借此扩大为整个观测系统重构。

## 3. 总体架构与模块所有权

~~~mermaid
flowchart TD
    A["Sigma / Synapsis / Samgita / Backplane"] --> R["应用内 Reporter"]
    R --> H["Host Agent 诊断接收与持久 spool"]
    O["目标服务日志、退出与资源证据"] --> H
    H --> I["Backplane 认证接收与事件存储"]
    I --> P["运行投影、故障关联、问题归组"]
    L["既有 LLM / MCP 代理记录"] --> P
    P --> D["检测规则与分析任务"]
    D --> U["问题页面、报告、诊断 MCP"]
    U --> F["修复任务与回归验证"]
    F -->|"版本覆盖与复发观察"| P
~~~

### 3.1 模块划分

| 所有者 | 建议组件 | 职责 |
| --- | --- | --- |
| 新独立包 backplane_diagnostics_client | Envelope、Reporter、Integrations、LocalTransport | 应用侧捕获、上下文、脱敏、有界缓冲、本地通信 |
| backplane_host_agent | Diagnostics.Ingress、Sources、Spool、Uploader、Collectors、Health | 本地身份、持久缓存、宿主旁证、上传与健康 |
| 新 umbrella app backplane_diagnostics | Events、Runs、Occurrences、Issues、Detectors、Analyses、Reports、Resolutions | 中央诊断领域与查询 |
| backplane_telemetry | 已有 Context、观测工具与基础健康 | 可复用底层能力；不承载问题生命周期 |
| backplane_api | 本次新增的 Host Channel 消息处理和授权 | 远端接收适配；把领域处理交给 diagnostics |
| backplane_admin | 问题、运行、采集健康、分析与修复页面 | 运维与工程评审界面 |
| backplane_mcp | diagnostics::* 工具适配 | 有界、按需的诊断检索 |
| backplane_system | Repo、迁移、设置和凭据基础 | 新表迁移继续放在共享迁移目录 |
| 各产品仓库 | 产品特有 Reporter adapter | 现有事实与诊断协议映射 |

共享 Runtime 只提供可选观察边界；纯 Kernel 不执行网络、文件或数据库 I/O。SDK 不依赖 Repo、Admin、Skills 或整个 backplane_system。Host Agent 仍可独立打包运行。[B1] [B11]

### 3.2 典型正常流程

1. 应用捕获异常或关键运行事件，提取可用上下文并先脱敏。
2. Reporter 接纳到有界队列，后台 worker 向本机 Host Agent 发送。
3. Host Agent 校验来源、schema 和配额，将不可变事件写入本地 spool。
4. 本地提交成功后返回 local_durable receipt。
5. Host Agent 增加独立的宿主旁证，通过既有认证连接上传诊断批次。
6. Backplane 在同一事务提交事件与待投影任务，再返回 remote_durable receipt。
7. 后台投影幂等更新运行视图、Occurrence 和 Issue。
8. 新问题或重要变化触发报告与分析；模型未就绪时仍生成确定性报告。
9. 修复与验证记录关联到具体问题，后续事件用于判断适用版本中的复发。

## 4. 应用内自动捕获

### 4.1 捕获入口

| 入口 | 捕获内容 | 处理要求 |
| --- | --- | --- |
| Logger / OTP handler | 已记录的结构化错误、适用的 crash/supervisor reports | 读取可用的原因与栈；普通日志缺少栈时标记 unavailable |
| Phoenix exception hooks | 请求异常 kind/reason/stacktrace、request 关联 | 与 Logger 对同一异常的观察关联，避免重复次数 |
| Provider / Tool / Runtime 边界 | rescue 后的错误、错误返回、解析失败、超时、重试耗尽 | 在信息丢失前提取现场，保持原有结果与监督行为 |
| Task / worker monitor | 非预期进程退出、任务未完成 | 区分正常退出、取消、shutdown 与 crash |
| 关键运行事实 adapter | 开始、进度、等待、终态、子任务交接 | 优先导出已确认事实，注明原生 revision 和持久性 |
| 用户反馈 / 契约检查 | 期望、实际、规则版本、失败样本引用 | 形成明确的缺陷候选，不直接宣称根因 |

Elixir Logger 的 crash_reason 可提供原因与栈，但不保证每条日志都有；Phoenix 提供异常 instrumentation。接入时应核对产品锁定版本，使用公开接口。[S1] [S2]

### 4.2 捕获行为约束

- Handler 只做轻量提取和有限投递。HTTP、磁盘、昂贵格式化和模型调用均交给后台 worker。
- 保持返回值、raise/exit、取消和监督树行为；上报失败不能被包装成业务失败。
- 在错误被转换为通用字符串或公共 DTO 前形成脱敏原因与栈摘要。当前 Runtime Error.to_map 会省略 cause，因此该捕获点必须位于转换之前。[B11]
- 捕获器失败使用独立的节流健康计数，不重新进入同一异常捕获链产生循环。
- 对 BEAM Task、GenServer 消息、job 和子 Agent 显式传递诊断上下文，并在复用进程中恢复/清理上下文。进程字典不会跨进程自动传播。[S3]
- 完整 VM 崩溃或强制终止可能来不及上报，不能只依赖 terminate/after。Host Agent 提供外部退出旁证；缺失栈时明确标注。
- 不记录隐藏推理内容；默认不采集完整 prompt、工具参数、工具结果或应用进程状态。

### 4.3 Breadcrumbs 与现场

每个活动 run/attempt 可维护固定容量的结构化 breadcrumbs，记录阶段变化、选定工具、重试、等待、压缩和子任务交接。故障时附带最近的有限记录。

Breadcrumbs 记录类型、时间、引用与结果摘要。涉及参数时保留允许的结构信息或经过批准的摘要，不将原始正文复制到每条异常。高频 token/delta 和逐帧音频不进入常规诊断事件。

栈帧优先保存 module/function/arity、仓库相对路径与行号。源码应通过记录的 Git SHA 获取；路径和行号本身不证明目标部署与该源码完全一致。

## 5. Host Agent 采集设计

### 5.1 本地入口

建议由新的复合 Host HTTP router 挂载本地 POST /diagnostics/v1/events 与 GET /diagnostics/v1/status，继续保留原 Memory/Capture 路由。

首版可复用现有 loopback HTTP server，新增独立的来源凭据认证；Unix socket 作为可选本地 transport。不能把 loopback 当作任意本机程序都拥有上报权限。容器接入应明确 socket 挂载或目标网络地址，不能假设容器的 localhost 就是宿主。

来源注册由 Host Agent 的受控配置或管理入口完成，生成稳定 source_id，并绑定应用名称、允许的仓库/服务身份和本地凭据。数据包自报 host_id 不能覆盖已认证身份。原有 Memory API 的认证与路由不因新增功能被隐式改变。[B4] [B20]

### 5.2 主动旁证采集

| 适配器 | 采集范围 |
| --- | --- |
| Process collector | 已登记进程实例的存活、启动时间、退出与重启记录 |
| Service collector | 明确配置的 systemd、launchd 或容器目标的可用状态与日志 |
| Resource collector | 目标进程及宿主的有限内存、CPU、文件描述符、磁盘和队列摘要 |
| Log collector | 指定文件/日志源的结构化错误，处理轮转并持久保存读取位置 |
| Crash artifact collector | 已存在崩溃报告的摘要与受控引用，不默认上传完整 dump |

使用“宿主启动身份＋进程 PID＋启动时间”识别进程，避免 PID 重用导致串联。无法取得权限或指标时返回 unavailable，不填零，也不扩大采集范围。

故障前保持低成本周期摘要，触发后可追加有界快照。避免每条错误都执行全机扫描或完整 lsof。整台主机失联先标为 disconnected；OOM、磁盘故障等原因必须有退出或系统证据支持。

各平台 collector 分别声明能力。NixOS/Linux 的服务证据与 macOS 的服务证据不能互相冒充；跨平台都应支持 Reporter 事件接收。

### 5.3 独立诊断 spool

建议复用 Host Agent 已使用的存储依赖与 owner-process 模式，建立独立 diagnostics 数据库或明确隔离的存储上下文。按事件持久保存 payload、identity、digest、交付状态、尝试次数与下一次重试时间。

复用现有 CaptureUploader 的可靠交付模式，但不向 Memory spool 塞入诊断事件，不混用协议、ACK 或保留策略。[B7]

活跃 spool 的状态查询通过拥有连接的进程/API 进行，不能假定另开 SQLite 连接或复制活跃文件即可得到一致现场。历史 Agent Note 记录过特定 Turso 版本与分支的锁限制；实现应验证当前依赖，而非直接沿用历史结论。（Agent Note N2，见第 19.2 节）

### 5.4 已接纳数据的责任

- 未获远端确认的诊断事件不受普通日志 TTL 静默删除。
- 配额满时优先限制低优先级新事件，为异常、终态与采集健康预留容量。
- 配置的最长待传年龄到期时，进入明确 expired/dead-letter 状态，产生缺口记录和计数。
- 磁盘满、写入失败、配额拒绝均不能返回 local_durable。
- 已确认事件正文可按保留策略回收，但仍需保存本地去重凭证。待发送、发送中、expired 和 dead-letter 的正文都计入总量；expired/dead-letter 最多保留 7 天且不得占用超出总配额 10% 的空间，达到条件后可清除正文，保留处置、身份与损失摘要。优先级由可信规则判定，来包自报高优先级不能绕过配额。dead-letter 支持查询与受控重处理。
- Host Agent 自身崩溃通过启动标记、服务管理器证据和恢复后的健康报告补充，不能承诺在宿主断电瞬间完成上传。

## 6. 事件、身份与两级交付契约

### 6.1 不混淆三种身份

| 层次 | 字段 | 语义 |
| --- | --- | --- |
| 来源与传输 | source_id、producer_epoch、source_sequence、event_id | 来源身份、序列代际和事件幂等 |
| 业务事实 | native session/run/turn/attempt/tool-call IDs、subject_revision | 保留各产品原生语义，以来源限定身份 |
| 执行关联 | trace_id、span_id、parent_span_id、links、causation_id | 跨服务调用与因果联系，不代替业务主键 |

source_id 在来源注册后稳定；producer_epoch 在进程启动或序列状态重建时更新。重传必须保持 event_id、epoch、sequence 和内容不变。

source_sequence 用于识别来源内部缺口；服务端不要求跨来源全局连续。外部日志的读取游标单独保存，不能把过滤后的日志行号解释为缺失的故障事件。

长期 session 和恢复执行可跨多个 trace。不同项目的 run_id 若含义不同，保存原生值并建立显式关系，不强行覆盖为同一 ID。

### 6.2 事件 Envelope

| 分组 | 内容 |
| --- | --- |
| 协议 | schema_version、event_type、event_id |
| 来源 | source_id、producer_epoch、source_sequence、application、service instance |
| 版本 | repository、git_sha、release、runtime/adapter versions、允许的配置摘要 |
| 时间 | occurred_at、源端单调时钟计算的 duration；接收时间由各接收端另记 |
| 业务关联 | session/run/turn/attempt/tool invocation、parent run、subject_revision |
| 执行关联 | trace/span/parent/links、causation、可选 occurrence_hint |
| 结果 | phase、outcome、error_class、retryable、certainty |
| 证据 | 脱敏异常、栈、有限 breadcrumbs、measurement、evidence reference |
| 数据质量 | redaction_policy_version、采样信息、截断、来源缺口、可用性标记 |

字段与枚举要有正式 schema，拒绝超长、超深、非法类型或未知不兼容版本。外部字符串不得任意转 BEAM atom。

来源事件不可变。Host Agent 补充资源快照、接收时间与上传状态时，写入接收元数据或新的关联证据，不能随每次重传改写原事件。

### 6.3 本地与远端确认

| 状态 | 明确保证 | 允许的动作 |
| --- | --- | --- |
| enqueued | Reporter 已接纳到有界内存队列 | 不能当作持久保存完成 |
| local_durable | Host Agent 已按声明的持久性配置提交 spool | Reporter 可释放该事件的补传副本 |
| remote_durable | Backplane 已提交事件及 durable projection outbox | Host Agent 可回收对应待传记录 |

持久性等级必须有实际存储配置与故障测试支撑；普通文件追加或异步 cast 不自动等于掉电保护。应用捕获回调不等待两跳完成，交付状态由后台发送器维护。

~~~mermaid
sequenceDiagram
    participant A as 应用 Reporter
    participant H as Host Agent
    participant B as Backplane 接收
    participant P as 投影与诊断
    A->>H: 事件批次与稳定身份
    H->>H: 校验、配额准入、spool 提交
    H-->>A: 逐项 local_durable
    H->>B: host_diagnostics.v1 批次
    B->>B: 事件与待投影任务事务提交
    B-->>H: 逐项 remote_durable
    B->>P: 已提交事件引用
    P->>P: 幂等关联、归组与报告
~~~

### 6.4 去重与冲突

两跳均执行：

- 同一 source_id 与 event_id、相同规范化内容摘要：duplicate，按对应持久确认成功处理。
- 同一 event_id、不同内容：identity_conflict，保留原证据，拒绝覆盖。
- 同一 source_id、epoch、sequence 被不同事件占用：source_sequence_conflict。
- 摘要算法与 canonicalization 版本固定；排除接收时间等接收端字段。
- 对同一业务 revision 的矛盾事实保留冲突，不用最后到达覆盖已有事实。

摘要在脱敏后生成。Host 保存 ingress_digest（Reporter 已脱敏输入）与 forward_digest（Host 首次接收后冻结的上传表示），分别绑定本地和远端 receipt。身份校验及认证后，先用原 ingress_digest 检查已接纳事件，再决定是否转换新事件；已接纳事件不会因脱敏策略升级重新计算上传内容。服务端先核对 forward_digest，将接收身份与进一步脱敏后的存储视图分开。策略收紧需要清理旧内容时，保留身份和明确的处置状态，不以同一 event_id 偷换内容。

### 6.5 批次与逐项 receipt

本地协议建议命名 diagnostics.v1；远端通过 Host Channel 新增 diagnostics_sync，协议名 host_diagnostics.v1。加入连接能力声明和最大批次能力协商，不复用 trace_sync 或 memory_events。

| 逐项结果 | 接收含义 | 发送端行为 |
| --- | --- | --- |
| stored | 对应持久提交已完成 | 记录 receipt，释放该项 |
| duplicate | 同身份同内容已存在 | 按成功处理 |
| retryable_rejection | 当前没有持久确认 | 保留，退避与 jitter 重试 |
| permanent_rejection | 内容不符合契约 | 移入有界 dead-letter，保留原因 |
| identity_conflict | 身份被不同内容占用 | 隔离并报告，不自动改 ID 掩盖冲突 |
| unsupported_schema | 不支持该协议版本 | 暂停该版本上报并暴露兼容性问题 |
| receipt 缺失或响应丢失 | 接收状态未知 | 以原身份重传 |

receipt 必须绑定 batch_id、本批 event_id 与对应跳的内容摘要。先解析完整响应、按 event_id 建表并验证成员、摘要和结果唯一性，再统一提交确认状态；不能边读取响应边删除 spool。未知 event_id 不确认，某项的重复或矛盾 receipt 使该项视为状态未知并保留；其他唯一且匹配的成功项仍可确认。

单个坏事件不能阻塞后续合法项。批次过大可拆分；单事件过大需在源端形成明确的截断或拒绝结果。认证失效暂停对应来源，等待配置恢复；不能无限快速重连。

### 6.6 顺序、时钟与回放

- 允许乱序与迟到；按来源序列、业务 revision 和因果关系投影。
- 旧 revision 保留为证据，但不能把新状态回退。推断状态单独存储。
- occurred_at 表示源时间；host_received_at、server_received_at 分别表示接收时间。本机 duration 使用单调时钟。
- 发现时钟偏差或缺口时降低判断置信度，不能用跨机时间差证明严格先后。
- 采样和丢弃必须可见；缺少 completed 不直接等于失败。
- 两跳均持久保留有效去重凭证。Host 已回收正文后，仍凭 source_id/event_id、ingress_digest 和处置状态回答 Reporter 的重复提交；中央凭 forward_digest 去重。不能只保留服务端凭证。
- producer_epoch 是传输代际，另存进程 boot 身份；长时间运行的 Reporter 可每 24 小时轮换到新 epoch，旧队列继续以原身份投递。旧 epoch 不再产生新事件、队列均获确认或明确结束处置后，才由受控流程封存；异常退出的代际在待传窗口结束、缺口结算后封存。轮换不改变已有事件身份。
- 封存状态在两跳持久保存，尚有待处理项目时不能清理去重键。封存后，已有凭证的重复项可返回原处置；凭证已清理的旧 epoch 普通提交返回 epoch_sealed，不能作为新事件接收。历史导入走独立路径，不默认增加当前故障次数。有效 epoch 的事件级凭证不自动过期；封存后才可按保留策略压缩，封存标记的规模由来源注册和轮换频率限制。
- 修正被拒事件的内容时，创建新事件并引用原事件；不得用旧 event_id 提交新 payload。

## 7. 中央存储与投影

### 7.1 领域对象

| 对象 | 含义与关键字段 |
| --- | --- |
| Source | 来源注册、host、application、允许的身份元数据、能力与健康 |
| Event | 不可变源观察；身份、digest、时间、schema、关联和质量 |
| RunProjection | 按来源限定的运行摘要、阶段、原生终态、revision、关联关系 |
| Occurrence | 一次实际故障或异常行为；可关联多条 Event 与宿主旁证 |
| Issue | 同类问题；fingerprint/version、类别、严重程度、影响、次数与状态 |
| Finding | 检测器产生的观察；规则版本、证据、推断状态与不确定性 |
| Analysis | 版本化分析；证据集、事实、假设、限制、模型与分析配置版本 |
| Report / RepairTask | 可审阅报告及可交给开发 Agent 的具体修复材料 |
| Resolution | 修复提交、回归证据、适用版本、部署观察、复发与关闭理由 |
| EvidenceRef | 受控证据引用、大小、摘要、来源、脱敏版本与保留期 |

建议独立建立 diagnostics_sources、diagnostics_events、diagnostics_runs、diagnostics_occurrences、diagnostics_issues、diagnostics_findings、diagnostics_analyses、diagnostics_reports、diagnostics_resolutions 及必要的关联表。

接收事务同时写事件与 projection outbox。迁移归 backplane_system；schema、查询、规则和领域处理归 backplane_diagnostics。

### 7.2 Event、Occurrence、Issue 的区别

- 同一事件重传：一个 Event。
- 同一异常被 Phoenix、Logger 和 worker DOWN 观察：多条 Event，能够确认时归为一个 Occurrence。
- 两次独立 attempt 出现同样异常：两个 Occurrence，归为一个 Issue。
- 只有文本相似或时间接近：可提示候选关系，不能不可逆地当作同一次故障。

应用尽量在公共捕获边界生成 occurrence_hint，后续捕获复用。旁证使用 source instance、epoch、run/attempt、进程身份和时间窗口关联；时间窗口仅是辅助信号。

### 7.3 Issue 指纹

初始指纹使用组件、操作边界、异常类型或稳定错误码、规范化应用栈关键帧。移除随机 ID、时间戳、绝对工作目录与动态错误文案；版本和行号不作为主要稳定特征。

fingerprint_version 必须保存。人工拆分/合并和算法升级保留关系与审计；不能改写不可变源事件。不同配置、provider 或工具类别是否拆分由规则明确决定，避免把所有 timeout 合成一个问题。

### 7.4 投影幂等

每个 projector 以事件身份与 projector_version 记录处理状态。对 (projector, projector_version, source_id, event_id) 建唯一处理约束，用唯一插入或锁竞争确定处理者，不能只靠事务中的先查后写。Issue 指纹、issue-occurrence 关系及具有确定身份的 occurrence 也有相应唯一约束。一个事务中：

1. 判断事件是否已处理。
2. 建立或关联 occurrence。
3. 仅根据 issue-occurrence 唯一关系插入成功的结果，原子增加发生次数。
4. 更新运行、影响维度和派生状态。
5. 标记完成并提交。

投影失败可重试。回放时使用版本化投影或重算聚合，不能把历史事件再次累加。Issue 页面分别显示 Event 数、Occurrence 数和受影响 Run 数，避免含义混用。

## 8. 异常检测与问题分类

### 8.1 分类模型

初始分类包括 software_defect、upstream_failure、environment_failure、configuration_or_compatibility、expected_control_flow、agent_quality、unknown。

预期取消、审批拒绝、正常 shutdown、单次 429 后恢复不自动升级为软件 Bug。失败 attempt 与最终 Run outcome 分别记录；unknown_outcome 保持独立，不归并成成功或普通失败。

检测与分析不能直接改写来源 Runtime 的终态，也不能发起工具补执行。

### 8.2 首版检测规则

| 规则 | 所需证据 | 输出 |
| --- | --- | --- |
| program_exception | 结构化异常、worker exit、来源身份 | 程序异常发生记录 |
| restart_burst | 同一服务多个退出与重启 | 重启异常；原因可未知 |
| suspected_stall | 当前阶段、deadline、最近进度、等待类型与采集健康 | 疑似停滞 |
| retry_without_progress | logical operation、attempt、错误码、进度检查点 | 重试无进展 |
| handoff_anomaly | parent/child、子任务终态、父任务等待事实 | 交接异常候选 |
| contract_violation | 契约版本、期望、实际摘要 | 可解释的契约违反 |
| environment_correlated_failure | EMFILE/内存/磁盘等失败与宿主证据 | 环境关联故障 |
| release_regression | 同类工作负载、release、有效运行数、失败数和覆盖 | 新版本回归候选 |

规则是版本化纯函数，输入有界事实和策略，输出 Finding。阈值按阶段和来源配置，不能用统一“多久没消息”判断所有 Agent。

### 8.3 AI 行为问题

没有异常的 Bug 需要可检验的预期。首版至少接入一个具有明确期望的确定性检查器，并完成故障注入，例如输出契约违反，或有完整证据的子任务交接异常。所需事件有缺口时输出 insufficient_evidence，不将缺失直接判为已确认违反。更广泛的状态不变量、任务验收、离线评测和用户反馈逐步扩展。

例如“工具返回成功但结果没有进入下一轮”需要运行边界事实或明确检查器；仅有用户觉得答案不好时，先记录反馈与关联运行。LLM 评判可以作为一份带版本的评测证据，不直接等同已确认的软件缺陷。

真实失败可沉淀为脱敏 regression fixture 或 eval case。涉及外部副作用的工具调用不能通过诊断回放直接重执行，应使用受控环境与替代依赖。

## 9. 自动分析与汇报

### 9.1 触发策略

满足以下任一条件时，创建或更新分析任务：

- 新 Issue 首次达到配置的分析条件。
- 严重程度或受影响范围显著增加。
- 获得新的异常栈、宿主证据、源码或复现结果。
- 适用的修复版本出现复发。
- 操作者主动要求重新分析。

重复发生只更新统计与代表样本。每个 Issue 同时最多一个分析任务；相同 evidence_set_digest 与 analysis_policy_version 不重复调用模型。证据变化产生新的版本，不能覆盖之前分析的依据。

一期至少对高严重度的新程序异常和明确契约违反自动分析；其他类别按规则和冷却时间处理。模型未配置、预算不足或连接失败时，事件采集、归组和确定性报告继续，UI 显示 waiting_for_model、budget_exhausted 或 retrying。

### 9.2 证据包

分析输入由服务端生成不可变 EvidenceBundle，包含：

| 部分 | 内容 |
| --- | --- |
| 身份 | issue、occurrence、来源、原生 run/turn/attempt、trace |
| 版本 | repository、Git SHA、release、runtime/adapter、允许的配置摘要 |
| 异常 | 规范化类型、错误码、可用栈、最近 breadcrumbs |
| 运行链 | Provider/Tool/MCP/子 Agent 的选定事件、重试与恢复 |
| 宿主 | 进程、服务退出、资源摘要和对应采集时间 |
| 对照 | 同版本正常样本、受影响范围、既有相似问题与修复 |
| 数据质量 | 截断、采样、缺口、掉线、时钟偏差、缺失字段 |
| 代码 | 与 Git SHA 对应的有界源码片段、已有测试与契约引用 |

读取摘要后按 evidence_id 取必要详情。默认不能把完整日志库、整个仓库或所有会话放进分析上下文。

代码无法获取到对应 SHA 时，注明 source_unavailable 或 version_mismatch；不能将最新 main 的代码当作故障时实际部署代码。源码与依赖归属从注册元数据和真实依赖来源解析，不能让日志中的 URL 决定任意访问地址。

### 9.3 分析 Agent

可使用 backplane_agent_runtime 承载有界诊断任务，经现有 LLM proxy 访问配置的模型。首版只读代码与证据，产出结构化 Analysis 和 RepairTask。

分析结果必须包含：

1. 已观察事实，每项引用具体证据。
2. 可能原因，以及支持证据、反证和未知项。
3. 当前有证据支持的影响范围。
4. 建议复现条件与步骤。
5. 建议修复方向和可能归属的仓库/模块。
6. 修复前应暴露问题的回归测试与修复后验收条件。
7. 分析限制与置信等级。

模型可提出证据较强、待验证等解释性等级；已复现和 confirmed_root_cause 等验证状态仅由可信的测试/复现记录或明确人工确认产生，不能由模型自报获得。

Analysis 发布前必须通过结构和证据引用校验。引用只能属于当前 EvidenceBundle，代码位置须对应实际读取的准确版本；越界引用、缺失证据引用或无效结构标为 analysis_invalid，不作为有效修复报告。保存模型标识、分析策略/提示模板版本、证据摘要、用量和结果版本；无需保存模型私有推理内容。

日志、工具输出和源码都是待分析数据。它们不能改变分析器的授权、要求执行命令或扩大读取范围。所有 evidence 和源码工具都使用已解析的内部引用，避免任意路径/URL 读取。

### 9.4 预算与防止递归

分析并发、单任务输入/输出、超时、每 Issue 冷却和全局用量预算均有上限。相同问题在分析期间新增事件可合并进下一次证据版本，不无限创建任务。

诊断分析自身带 origin=diagnostics 标记。其失败仍记录在独立健康分类，但不能自动触发无限自我分析。报告通知和分析调用都有幂等键；模型服务不可用不会积压无限重试队列。

用量统计选择一个实际计费来源。Agent 上报、代理用量和模型返回用于核对，不能无条件相加。unknown usage 保持未知。

### 9.5 报告与修复任务

Backplane 内部自动维护问题报告，突出新问题、恶化、复发、修复观察和数据缺口。

RepairTask 至少包含：

- 目标仓库、故障 Git SHA、建议实施基线与相关依赖版本。
- 问题描述和实际影响，附原始证据引用。
- 已验证根因与待验证假设，明确分开。
- 最小复现线索或需要新增的复现测试。
- 建议修改范围、行为约束与验收标准。
- 不能重放的外部副作用和需替代的依赖。
- 关联 Issue/Occurrence/EvidenceBundle 标识。

内部报告生成属于自动流程。GitHub issue/PR 发布、编码任务执行、合并和部署是独立集成，使用各自配置的权限；首版的完成不依赖这些外部动作。

仅在新问题、显著恶化、复发或验证状态变化时形成通知候选。重复事件归并；外部通知目的地和发送策略单独配置，避免逐条日志通知。

## 10. 修复、验证与持续改进

### 10.1 问题状态与验证状态分开

Issue 生命周期建议为 open → triaged → fixing → observing → resolved；复发进入 reopened。另提供 muted、duplicate 等管理标记，不能通过 muted 隐藏数据丢失。

测试状态、部署状态和运行观察独立保存：

| 维度 | 示例状态 |
| --- | --- |
| 回归测试 | not_added、reproduced、fixed_in_test、failed |
| 修复实现 | proposed、implemented、merged |
| 部署 | unknown、not_observed、observed_on_source |
| 运行观察 | insufficient_coverage、healthy_observation、recurred |

PR 合并或测试通过不自动代表运行环境已经修复。

### 10.2 Resolution 内容

记录仓库、PR/commit、修复原理、回归测试证据、目标 release/runtime/config 范围，以及实际观察到的部署来源。

关闭条件按问题类型声明：

| 问题类型 | 关闭所需证据 |
| --- | --- |
| 软件缺陷 | 回归验证、适用修复构建、健康运行覆盖 |
| 配置/环境问题 | 已实施的配置或环境变更身份、相关检查、健康运行覆盖 |
| 上游服务故障 | 恢复探测与适用请求覆盖；不要求本地代码修复提交 |
| AI 行为质量问题 | 对应任务验收或评测改善、适用模型/策略版本 |

各类型均需足够工作负载覆盖和采集健康。没有流量、上报中断或数据缺口时显示 insufficient_coverage。故障恢复可与根因仍未知同时成立，不为关闭问题伪造已确认根因。

不要把 Git SHA 当作自然可排序的版本号。修复适用性使用明确 release 集合、部署构建身份或可验证的祖先关系。

### 10.3 复发与迟到事件

- 依据事件发生时的版本与运行身份判断复发，不按接收时间判断。
- 修复后收到旧版本迟到事件：补充历史，不能自动重开新版本问题。
- 适用修复版本仍出现同类故障：重开 Issue，生成新的分析证据版本。
- 指纹变化、部分修复或不同环境应保留关联，但不能武断地宣称是同一根因。

### 10.4 长期改进

从真实故障提取脱敏 fixture、契约检查和 eval case。版本升级后持续运行对应回归集，比较适用工作负载下的失败率、重试成本、完成率和延迟。

原始事件、分析迭代、临时推测留在 Diagnostics。确认的根因、架构约束、修复原理和长期操作经验，经过质量判断后写入 Agent Note 的 project: backplane；其他仓库的知识按其明确项目范围处理，不批量制造任务完成笔记。

## 11. 存储、关联与互通

### 11.1 中央存储

首版使用现有 PostgreSQL 与 Ecto。常用检索字段做独立列及有界索引，扩展属性使用受限 map/JSONB。

优先索引：

- source_id/event_id 唯一身份与 digest。
- source_id/producer_epoch/source_sequence。
- occurred_at、server_received_at。
- 来源限定的 run/attempt、trace_id。
- Issue fingerprint_version/fingerprint。
- release、git_sha、error_class、issue status。

大字段不进入常规列表查询；日志消息、run ID、trace ID 和任意工具参数不进入 metrics labels。先通过容量和查询指标决定是否分区或增加专用存储，不预设高复杂度基础设施。

### 11.2 数据保留

保留策略区分：

| 数据 | 初始建议 |
| --- | --- |
| 成功运行的详细事件 | 7 天，允许明确采样 |
| 异常事件与有限现场 | 30 天 |
| Issue、Analysis、Resolution 与运行摘要 | 至少 180 天，可配置 |
| 未上传 spool | 最长待传年龄独立配置；到期记录显式损失 |
| 本地与远端去重凭证 | 覆盖全部有效重试窗口；封存 epoch 后才可压缩，不能随正文直接清除 |
| 可选敏感附件 | 单独更短保留期与读取权限 |

这些是建议默认值，不是已验证容量。正文清理后保留必要的归组、计数与验证关系，并在 UI 标注 evidence_expired；不可继续声称完整现场仍可读取。

### 11.3 与代理记录关联

通过可信的 trace、request、attempt 和 tool invocation 关联已有 LLM/MCP 记录。跨边界传递需有明确契约；仅时间相近不自动关联。

一次逻辑 LLM 操作及其多次请求 attempt 分别可见。业务调用、代理观察和协调层观察可以描述同一工作，不重复计算执行次数和 Token 用量。

### 11.4 OpenTelemetry

新诊断协议是版本化应用协议。W3C Trace Context 用于链路关联；未来通过独立 adapter 映射 OpenTelemetry spans/logs/events 或接收 OTLP。

GenAI semantic conventions 仍在演进，映射应固定版本并记录 schema URL。数据库及 Issue 语义不能直接随 gen_ai 字段变化迁移。[S4]

不将自定义 JSON API 宣称为 OTLP 兼容入口。若后续提供 OTLP，应遵守其独立的错误、部分成功和重试语义，不与本设计逐项 receipt 混用。[S5]

## 12. 身份、权限与证据保护

### 12.1 两层来源校验

本地 Reporter 使用绑定来源的凭据，或具有等价来源绑定能力的 Unix socket 机制。仅限制 socket 文件权限可减少访问范围，但不能自动区分同一用户下的所有程序；有需要时仍使用来源凭据。

远端 diagnostics_sync 使用认证 Channel 的 host 身份，并逐批检查有效凭据与新增 host_agent.diagnostics.write 权限。来源注册需属于该 host；事件体中的 host/source 信息不得扩大权限。

只读诊断 MCP 使用 diagnostics::read；问题管理、重试分析或修改状态使用独立 diagnostics::manage。具体名称作为新增设计，需要在实际权限注册与验证路径中同步实现。

Backplane 当前 Admin 属受信任运维端点，本模块遵循现有部署访问边界；新增公开查询接口不能复用这一信任假设。[B1]

### 12.2 脱敏与限制

- 在应用到 Host 的第一次落盘之前脱敏；Host 与服务端再做 schema 白名单和限制。
- 默认拒绝 Authorization、Cookie、token、完整环境变量、原始 prompt、工具正文和完整进程状态。
- 异常消息本身可能含用户输入或秘密，也要截断和过滤。
- 配置摘要只对允许字段或凭据引用名计算，不能把秘密值的 hash 当作安全替代。
- EvidenceRef 必须指向受控对象；分析器不根据日志内容访问任意本机路径或 URL。
- 全量 crash dump、用户文档和会话正文使用独立附件策略；一期默认关闭。
- 来源、规则、人工归组、状态变更与分析配置变更留有可追踪记录。

### 12.3 收集器自身的健康

必须显示 Reporter/Host/服务端分别的队列深度、容量、最老待传年龄、最近确认时间、丢弃量、拒绝量、dead-letter、解析失败和协议不兼容状态。

健康数据不依赖同一条已经拥堵的普通事件队列才能被读取。保留独立计数和受控状态接口，低频通过 Host heartbeat 同步摘要。

## 13. 初始配置与容量建议

所有数字是试点起点，实施必须按实际消息大小与故障注入结果校准；本文没有性能实测结论。

| 配置 | 建议起点 | 说明 |
| --- | --- | --- |
| 来源采集 | 登记并启用后自动采集 | 未登记来源不接受；不会自动扫描所有应用历史日志 |
| Reporter 内存 | 每应用实例共享 1,000 条且不超过 4 MiB | 条数与字节数双限制 |
| Reporter 故障备份 | 可选，最多 16 MiB | Host 不可用时的受控本地备份；保留丢失统计 |
| 单事件 | 64 KiB | 包含有限 stack/breadcrumbs，超限有明确结果 |
| 批次 | 最多 100 条且不超过 512 KiB | 适配现有 Host Channel frame 上限，实测包含编码开销 |
| Host spool | 每 host 256 MiB，单来源 64 MiB | 普通正文最多使用总量 75%；高优先级可使用预留 25%，仍受总量/来源限制 |
| 最长待传年龄 | 7 天 | 到期进入显式损失处理，不默默清空 |
| 普通 flush | 1 秒或达到批次阈值 | 紧急事件可唤醒发送器，仍受限流 |
| 重试 | 1 秒至 60 秒指数退避并加入 jitter | 优先遵守接收端重试提示 |
| Host 资源摘要 | 15 秒低成本采样 | 故障触发最多追加一个受限快照 |
| Run 活动摘要 | 活动期 15 秒 | 携带 phase、deadline、等待状态；不能单独证明进度 |
| 分析并发 | 全局 2 个，每 Issue 1 个 | 独立后台队列 |
| 分析冷却 | 同 Issue 30 分钟 | 严重升级/新证据可依规则突破 |
| 自动分析次数 | 全局每日 50 次上限 | 可配置，另设 Token/费用预算 |
| 分析单任务 | 5 分钟；输入 16K、输出 4K Token 上限 | 模型支持与证据裁剪需适配 |
| 新报告通知 | 默认内部报告 | 外部渠道按配置启用 |

Reporter 的队列与 breadcrumbs 共享应用实例的总预算，不能为每个业务进程复制完整容量。Host 的总量、来源配额与优先级预留必须在一次原子准入中检查；编码后的事件与批次按实际字节计数，磁盘预算还需考虑索引、WAL 和运行预留空间。

客户端注册和本地连接配置归 Host Agent；模型、预算、检测规则、服务端保留策略归 Backplane Settings，使用 diagnostics.* 键。部署和启动所需本地配置继续遵循 Host Agent 的独立 release 配置方式。

总采集开关与来源开关分开。关闭某来源后停止新采集；已有待传数据应明确选择继续交付或暂停，不能借关闭直接删除。

## 14. 管理页面、API 与 MCP

### 14.1 管理页面

| 页面 | 必须回答的问题 |
| --- | --- |
| 问题列表 | 哪些新问题、恶化和复发值得处理；当前严重程度与影响 |
| 问题详情 | 事实、代表现场、版本分布、分析、修复与验证状态 |
| 运行详情 | 当前阶段、调用关系、重试、等待、终态和数据缺口 |
| 采集健康 | 哪个来源掉线、积压、丢弃、权限或协议有问题 |
| 分析设置 | 使用的模型、预算、触发规则、失败原因 |
| 修复观察 | 哪些修复已部署、覆盖是否足够、是否复发 |

页面遵循仓库 DESIGN.md 和现有 Duskmoon Phoenix 组件规范。技术字段只在能帮助诊断和判断时展示；默认列表突出问题、影响和行动。

### 14.2 接口边界

- 本地 Host API：接收结构化事件、返回本地 receipt、查询采集健康。
- Host Channel：能力声明、diagnostics_sync、诊断健康摘要。
- 中央查询：由 diagnostics context 为 Admin/MCP 提供分页、有界查询。
- 管理命令：明确的分析重跑、归组调整、状态变化和 dead-letter 操作，与只读查询分开。

首版不要求产品同时向 Host 与中央双写。无 Host 的环境将来可增加 transport adapter，但保持同一事件和问题模型。

### 14.3 只读 MCP 工具

| 工具 | 返回 |
| --- | --- |
| diagnostics::search_issues | 有界问题摘要、过滤结果和游标 |
| diagnostics::get_issue | 问题状态、影响、当前报告和证据引用 |
| diagnostics::get_run | 指定运行的阶段、关联调用和缺口 |
| diagnostics::get_evidence | 按内部引用返回限量脱敏证据 |
| diagnostics::get_report | 分析与可交付的修复任务材料 |

默认先检索摘要，再读取证据。返回附带数据质量与版本信息；长报告可用资源引用与分页，不一次把所有原始日志放入 Agent 上下文。

## 15. 产品接入与兼容迁移

### 15.1 产品接入表

| 产品 | 首要接入点 | 必须保留 |
| --- | --- | --- |
| Sigma | Metrics facts、turn lifecycle、provider/tool 边界、存储与 MCP 异常 | request/turn ID、revision、retry lineage、unknown usage |
| Synapsis | RunEvent/RunEvents、Emitter、provider/tool 边界、子 Agent 交接 | 关键事实确认顺序、原生终态、correlation/causation |
| Samgita | native runtime/driver 与 domain event 适配 | runtime/instance/generation/sequence、外部执行关联 |
| Backplane | LLM/MCP 失败边界、后台任务、关键服务异常 | 代理 request/trace、现有错误类别与数据持久性 |
| Host Agent | 自身 collector/uploader/spool 健康及启动退出证据 | 单独的 origin 与防递归规则 |

产品已有事实经过 allowlisted projection 后导出。Synapsis 的 debug 正文、Samgita 原生加密 payload 或其他本地私有内容不能因接入而默认解密/全文上传。

同一执行在协调层和执行层被观察时保留证据关系，不能再次算作独立模型或工具执行。

### 15.2 旧协议兼容

host_trace.v1、host_events.v1 与 host_diagnostics.v1 分别识别和处理。旧 trace 与 Memory 路径保持原有语义，新诊断数据不写入 Memory 原始事件表。

旧 trace 可经只读适配进入统一检索，使用协议名、host_id 和 agent_seq 作为限定身份。原数据缺少 run、stack、版本时显示 unknown。若旧新两条链描述同一故障，关联证据后再计数。

发布顺序：

1. Backplane 提供新协议、持久接收与查询。
2. Host Agent 提供新本地入口、spool 和 uploader，并声明能力。
3. 产品接入 Reporter，先单来源试点，再扩大。

新 Host 连接旧 Backplane 时显示 unsupported capability，有界保留数据；不能假装上传成功或静默降级成丢字段的旧协议。

回滚时停止新采集/分析入口并保留队列与证据，旧 LLM/MCP/Memory 继续运行。数据库采用可兼容的新增迁移，不通过回滚删除待处理现场。

## 16. 实施阶段与交付物

以下 M0–M4 共同组成第一版。只完成采集或仪表盘不能宣称完整 MVP 已交付。

| 阶段 | 工作 | 完成门槛 |
| --- | --- | --- |
| M0：契约与基础 | 固定 schema、来源身份、错误分类、receipt、容量、脱敏；复核实际复用组件 | 协议 fixture 与故障矩阵评审通过 |
| M1：可靠链路 | Client、Host 本地入口/spool/uploader、服务器事件/outbox、采集健康 | 两跳丢 ACK、重启、乱序、配额与权限撤销验证通过 |
| M2：自动捕获 | Logger/OTP/Phoenix、公共执行边界、宿主旁证；先 Sigma 试点，再接另外产品和 Backplane | 自动异常与 handled error 均有现场；业务行为保持 |
| M3：诊断产品 | Occurrence/Issue、运行视图、至少一个无异常契约检查器、自动报告、受预算分析、只读 MCP | 新问题自动形成有效分析和修复任务；重复不触发风暴 |
| M4：修复验证 | Resolution、回归 fixture、部署版本观察、复发与迟到判断 | 复现—修复—验证—复发场景完整通过 |

建议实现时拆成独立 PR，但保持协议兼容和阶段依赖。Backplane、Host Agent 与 client package 的契约先固定；产品适配在契约稳定后可并行。

核心交付物：

- 版本化事件 schema 与兼容性 fixture。
- 可独立消费的 client package 及最小接入说明。
- Host Agent 采集配置、spool、健康与恢复说明。
- Diagnostics 数据模型、规则、分析与报告。
- Admin 页面和只读 MCP。
- 故障注入、协议兼容、修复验证的验收记录。
- 说明已实现行为、未覆盖边界和验证范围的人类可审阅实现文档。

修改范围遵循所属 app 与各仓库 AGENTS.md。依赖缺陷按真实上游归属处理；本设计文档不创建 issue、提交代码、发布或部署。

## 17. 验收矩阵

| 编号 | 场景 | 必须验证的结果 |
| --- | --- | --- |
| A01 | GenServer/Task 非预期崩溃 | 自动捕获可得原因、栈、来源版本与运行关联 |
| A02 | 异常被 rescue 并转为错误结果 | 转换前现场可用；返回与监督行为保持 |
| A03 | 同一异常经 Phoenix、Logger、DOWN 报告 | 多份证据、一个可确认 Occurrence，次数不重复 |
| A04 | 两个独立 attempt 抛同样异常 | 两个 Occurrence、一个 Issue |
| A05 | 429/网络瞬断后恢复成功 | 保留失败 attempt，最终 Run 仍成功 |
| A06 | 正常取消、审批等待、合法长任务 | 不误判程序崩溃或已确认停滞 |
| A07 | 应用 VM 突然退出 | Host 保存退出/重启证据；缺失栈明确标记 |
| A08 | Host 本地提交成功但 ACK 丢失 | Reporter 原身份重传后 duplicate，只有一个记录 |
| A09 | 服务端提交成功但 ACK 丢失 | Host 重传，事件与 Issue 次数均不重复 |
| A10 | 同 event_id 不同内容 | 明确 identity_conflict，不覆盖原证据 |
| A11 | 批次中一条非法事件 | 合法项继续；非法项进入可见 dead-letter |
| A12 | 未知、缺失、重复或矛盾 receipt | 仅匹配成功项可释放，未知项仍可恢复 |
| A13 | 来源重启/序列重建 | 新 epoch 不与旧数据冲突 |
| A14 | 事件乱序、缺口、旧 revision 迟到 | 后续可处理；摘要不回退；缺口可见 |
| A15 | 投影更新计数时崩溃 | 事务重试后计数准确 |
| A16 | 全部历史事件重放 | 不重复创建 Occurrence 或增加次数 |
| A17 | Reporter/Host/Backplane 分别离线 | Agent 继续；缓冲、补传与损失符合边界 |
| A18 | spool 满、磁盘写失败、最长待传到期 | 不虚报持久确认；拒绝和缺口可查询 |
| A19 | 同时大量异常 | 内存和磁盘受限；高优先级保留与丢弃计数符合策略 |
| A20 | 本地伪造来源、远端 host token 撤销 | 拒绝或暂停；撤销后下一批不能继续接受 |
| A21 | 凭据嵌入异常、header、正文或配置 | 首次落盘前过滤，报告/MCP/附件不泄漏 |
| A22 | 明确状态不变量违反 | Finding 有规则版本、期望、实际与证据 |
| A23 | 心跳消失或采集缺口 | 标记失联/证据不足，不擅自认定 OOM 或死锁 |
| A24 | 新问题重复出现数百次 | 合并报告与统计，分析次数受限 |
| A25 | 模型未配置/预算耗尽/分析超时 | 确定性报告继续；分析等待原因可见 |
| A26 | 恶意日志要求执行命令或读文件 | 仅作为证据，分析工具不扩大权限 |
| A27 | 测试通过但修复未部署 | 不显示运行环境已修复 |
| A28 | 修复版本有足够健康运行覆盖 | 可进入 observing/resolved，保存覆盖依据 |
| A29 | 修复版本复发 | Issue 重开，关联新证据和分析 |
| A30 | 修复后收到旧版本迟到事件 | 仅补充历史，不错误重开 |
| A31 | 新旧 Host/Backplane 协议组合 | 旧协议可用；能力不足显式呈现 |
| A32 | Linux/macOS 平台能力不同 | 可用能力如实报告；不支持的指标为 unavailable |
| A33 | Evidence 过期与去重凭证保留 | 展示过期；有效重传仍不重复计算 |
| A34 | 跨 Task/子 Agent/服务的同一次执行 | 关联链正确，其他并行运行不串线 |
| A35 | 诊断系统自身故障 | 独立健康记录，无递归采集/分析风暴 |
| A36 | 新问题自动分析成功及无效输出 | 受控模型返回生成有效 Analysis/RepairTask；引用与代码版本正确；无效结构/引用为 analysis_invalid，试点补一次实际配置模型验收 |
| A37 | ACK 丢失且 Host 脱敏策略升级 | 原事件重传仍得到原处置，不误判内容冲突，不重复上传 |
| A38 | 响应中先 stored 后冲突的同一 event_id | 完整解析后将该项保留，不能提前删除 |
| A39 | 多来源并发逼近配额且 dead-letter 增长 | 普通事件不占预留，总量、来源和正文回收规则都生效 |
| A40 | Host 重启并已清理正文后收到重复事件 | 本地凭证仍识别重复；封存 epoch 不重新接收为新故障 |
| A41 | 两个 projector worker 并发处理同一或相关事件 | 唯一处理约束和关系计数正确，崩溃回滚可重试 |

验收应使用受控本地 provider/tool stub 和故障注入，避免为复现重放生产副作用。测试优先覆盖协议和故障边界，随后进行单来源集成与真实部署试点。

性能验收需记录 Reporter 热路径开销、故障风暴时应用延迟、最大常驻内存、spool 增长与排空时间、数据库写入/查询表现。定义测量方法和工作负载后再设性能门槛，不能凭本文默认值宣称达标。

## 18. 决策、限制与后续演进

### 18.1 本设计采用的选择

| 决策 | 原因 |
| --- | --- |
| Host Agent 为主采集入口 | 集中管理主机身份、外部故障证据、持久缓存与上报 |
| 应用保留轻量 Reporter | 只有应用能完整提供 handled error、异常栈和业务身份 |
| 独立 backplane_diagnostics | 问题与修复生命周期需要清晰的领域所有权 |
| 自有版本化事件协议 | 表达 Issue/Occurrence/业务状态与逐项交付，后续再适配标准 |
| PostgreSQL 与现有 Host 存储基础 | 降低第一版运维成本，先验证完整流程 |
| 确定性规则配合分析 Agent | 规则提供可解释检测，模型帮助形成假设与修复材料 |
| 源事实与观测推断分开 | 防止遥测不完整影响 Runtime 正确性与副作用处理 |
| 首版自动产出内部报告与修复任务 | 尽早提供改善价值，同时独立配置外部执行集成 |

### 18.2 明确的限制

- 自动捕获不保证发现所有 Bug；无异常的语义错误依赖契约、测试、评测或反馈。
- 采集器和宿主同时崩溃、掉电或磁盘损坏时可能丢失尚未持久化数据；缺口必须可见。
- 文件 append、数据库 commit 与掉电持久性之间的保证取决于实际存储配置，需故障测试验证。
- 异常栈和日志不必然足以复现。证据不足时报告下一步验证需求。
- 主机失联不能证明 OOM；无错误不能证明修复成功。
- 仅按时间与文本归并会误合并，关联置信度与人工修正能力必须保留。
- 自动分析有预算和来源限制；无法读取准确源码时不能伪造已验证根因。
- 首版设计不承诺自动修改、合并和部署任意仓库。

### 18.3 实施时需验证的选项

本地 loopback HTTP 可作为首版 transport；Unix socket 按平台与部署需要补充。Host spool 的具体存储设置、模型选择、预算和规则阈值在试点配置中确定，已有默认建议可用于开始实现。

平台 collector 先实现所需能力，不要求全部系统日志能力同时上线。对某平台缺少外部退出证据时，仍提供应用 Reporter 与可靠上报，并显示覆盖差异。

这些选项不阻止先完成协议与基础链路。需要改变本设计核心语义时，更新文档与兼容性 fixture，再调整实现。

## 19. 来源与设计依据

### 19.1 固定代码快照

下列代码链接固定到本次检查提交，支撑“当前已存在”的描述。新增接口、模块、配置与行为是本文设计。

| 编号 | 来源 |
| --- | --- |
| B1 | [Backplane AGENTS.md：所有权、认证、观测和 Agent Note 约定][B1] |
| B2 | [Host Agent TraceStore][B2] |
| B3 | [Host Agent TraceSyncer][B3] |
| B4 | [Host Agent MemoryRouter][B4] |
| B5 | [HostAgentChannel][B5] |
| B6 | [AgentTraces][B6] |
| B7 | [Memory CaptureUploader][B7] |
| B8 | [Host Agent Reporter][B8] |
| B9 | [Observability Context][B9] |
| B10 | [backplane_telemetry 依赖][B10] |
| B11 | [AgentRuntime Error][B11] |
| B12 | [AgentRuntime Event][B12] |
| B13 | [Sigma Metrics][B13] |
| B14 | [Synapsis RunEvents][B14] |
| B15 | [Samgita NativeRuntimeEvent][B15] |
| B16 | [Observability Event][B16] |
| B17 | [Observability Buffer][B17] |
| B18 | [Observability Redaction][B18] |
| B19 | [LLM LogWriter][B19] |
| B20 | [Host Agent HttpServer][B20] |
| B21 | [HostAgentSocket][B21] |
| B22 | [Observability RuntimeSink][B22] |

### 19.2 官方参考与历史上下文

| 编号 | 来源与适用范围 |
| --- | --- |
| S1 | [Elixir Logger metadata][S1]：结构化日志与 crash_reason 的适用范围 |
| S2 | [Phoenix instrumentation][S2]：异常事件；实际接入需核对锁定版本 |
| S3 | [OpenTelemetry Erlang/Elixir instrumentation][S3]：跨进程上下文传递 |
| S4 | [OpenTelemetry GenAI semantic conventions][S4]：演进中的映射标准 |
| S5 | [OTLP specification][S5]：未来互通适配的协议依据 |
| N1 | Agent Note：Backplane Memory 精简重建，ID aa6150e4-284b-4fb8-a32a-ae39e27e3e06。使用其中单用户与出处追踪方向，不将其历史状态当作当前 Diagnostics 实现 |
| N2 | Agent Note：Host Memory live diagnostics must use the Turso owner connection，ID 9c0aa381-f43e-41de-a0c9-3cbd3c5d9572。特定历史版本/分支的存储检查经验，实施时需复核 |

### 19.3 交付与验证状态

本文交付的是设计，不包含功能实现。已完成源码与项目约定核对、协议和工作流设计、独立评审及文档一致性检查。本文列出的 A01–A41 是未来实施验收要求，尚未执行，不构成当前测试通过声明。

[B1]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/AGENTS.md
[B2]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_host_agent/lib/backplane/host_agent/trace_store.ex
[B3]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_host_agent/lib/backplane/host_agent/trace_syncer.ex
[B4]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex
[B5]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex
[B6]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_system/lib/backplane/agent_traces.ex
[B7]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_host_agent/lib/backplane/host_agent/memory/capture_uploader.ex
[B8]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_host_agent/lib/backplane/host_agent/reporter.ex
[B9]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_telemetry/lib/backplane/observability/context.ex
[B10]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_telemetry/mix.exs
[B11]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_agent_runtime/lib/backplane/agent_runtime/error.ex
[B12]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_agent_runtime/lib/backplane/agent_runtime/event.ex
[B13]: https://github.com/gsmlg-opt/sigma/blob/e8c93931ab700e9ecdad3a1d7359a67147bd374b/apps/sigma_protocol/lib/sigma_protocol/metrics.ex
[B14]: https://github.com/gsmlg-opt/Synapsis/blob/025a477bdc4401fa9fa1659485888286b29540da/apps/synapsis_agent/lib/synapsis/agent/run_events.ex
[B15]: https://github.com/gsmlg-opt/Samgita/blob/62e65c40b9ce3a8c11eb959a58d3c4cc04a25567/apps/samgita/lib/samgita/domain/native_runtime_event.ex
[B16]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_telemetry/lib/backplane/observability/event.ex
[B17]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_telemetry/lib/backplane/observability/buffer.ex
[B18]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_telemetry/lib/backplane/observability/redaction.ex
[B19]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_llama/lib/backplane/llm/log_writer.ex
[B20]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_host_agent/lib/backplane/host_agent/http_server.ex
[B21]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_api/lib/backplane/api/channels/host_agent_socket.ex
[B22]: https://github.com/gsmlg-opt/backplane/blob/7f868296b4f55ec45d84d5adb1a32173b372a8fa/apps/backplane_telemetry/lib/backplane/observability/runtime_sink.ex
[S1]: https://logger.hexdocs.pm/Logger.html#module-metadata
[S2]: https://phoenix.hexdocs.pm/Phoenix.Logger.html#module-instrumentation
[S3]: https://opentelemetry.io/docs/languages/erlang/instrumentation/
[S4]: https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/README.md
[S5]: https://opentelemetry.io/docs/specs/otlp/
