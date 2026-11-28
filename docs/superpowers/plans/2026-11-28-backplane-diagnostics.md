# Backplane Diagnostics Implementation Plan

**目标**：完成 Diagnostics 首版，让应用异常与行为异常经 Host Agent 持久交付，在 Backplane 形成可审阅的报告、修复任务和运行验证记录。

**架构**：独立 client package 负责应用侧采集与脱敏。Host Agent 负责来源认证、本地持久缓存与旁证。中央 diagnostics app 在 PostgreSQL 中保存事件、投影、报告和修复证据，通过 Admin 和只读 MCP 提供查询。

**实现基础**：Elixir/OTP、Phoenix Channel 和 LiveView、Gaoxy/Plug、Host Agent 的 `ex_turso`、Ecto/PostgreSQL、现有 LLM proxy 和 Agent Runtime。

## 交付顺序与基线

以 [Backplane Diagnostics 设计](../../diagnostics/backplane-diagnostics-design.md) 的 R1–R8、M0–M4 和 A01–A41 为准。以下路径中尚不存在的文件为计划新增的文件。任务中的命令从对应仓库根目录运行，测试文件由对应任务创建。每个阶段都要有可重复的测试和实际证据，全部阶段通过后再判定首版完成。

| 仓库 | 本次核对的 HEAD | 当前接入点 |
| --- | --- | --- |
| Backplane | `9334ba6a8c02c5483b001a85d076b967495ffcea` | `HostAgentChannel`、Host HTTP/Channel、Runtime 错误及 LLM/MCP 入口 |
| Sigma | `f747b9387c4dab90504c80b1c085f172c62ada06` | `apps/sigma_protocol/lib/sigma_protocol/metrics.ex`、`apps/sigma_agent/lib/sigma_agent/runtime.ex`、`apps/sigma_agent/lib/sigma_agent/backplane/provider_lifecycle.ex` |
| Synapsis | `a90555cf2564da400c11a993cfdc3c399f4b2bcc` | `apps/synapsis_agent/lib/synapsis/agent/run_events.ex`、`apps/synapsis_agent/lib/synapsis/agent/events/emitter.ex` |
| Samgita | `df4d76958b3eac7db600af3dcedce9898ec712e7` | `apps/samgita/lib/samgita/domain/native_runtime_event.ex`、`apps/samgita/lib/samgita/codex_runtime/driver.ex` |

中央接收先于 Host 上传，Host 与 client 测试通过后先做 Sigma 单来源试点，再接入 Synapsis、Samgita 和 Backplane。M1 的中央接收与 Host spool 可以分别用测试替身验证，完成后须再验证两跳真实连接。M3 依赖真实或受控的 M2 事实，M4 依赖 M3 的问题归组。当前 Sigma 有两处 skill resource 文件的本地改动，产品接入须先复核工作区并保留已有改动。各仓库的写入、提交、发布和部署按各自授权执行。

M0–M4 的 13 项任务已在本地候选版本完成。实际模型、两跳传输、旧版 Channel、平台旁证和性能边界见 [验收记录](../../diagnostics/acceptance.md)。仓库已有的非本次改动检查问题也记录在该处。

## M0 契约和复用验证

### T01 固定事件、身份与确认协议

- [x] 创建 `apps/backplane_diagnostics_client/mix.exs` 及 `lib/backplane/diagnostics_client/{envelope,canonical,receipt}.ex`（相对该 app），将 schema、语义说明与 fixture 放在 `docs/diagnostics/protocol/v1/`。固定本地 `diagnostics.v1` 和远端 `host_diagnostics.v1`，列出事件类型、错误分类、最大层数、字段大小、未知字段和版本处理以及所有 receipt 结果。计量小数可用十进制字符串，时间用有界的标准时间表示，持续时间用整数微秒。
- [x] 固定 `sha256` 摘要与 canonicalization 版本。规范说明递归对象键排序、数组顺序、整数和字符串编码以及输入键的唯一性。协议 fixture 应给出规范化字节和摘要的预期值，同一套字节在 client、Host 与中央测试中使用。业务主键、来源 `(source_id, producer_epoch, source_sequence, event_id)`、执行关联各自保留。Host 的 `ingress_digest` 绑定 client 输入，`forward_digest` 绑定首次接纳后冻结的上传视图，服务端存储视图可进一步脱敏。
- [x] 固定请求 `protocol`、`batch_id`、`events` 与回复 `batch_id`、`receipts` 的形状。单项包含 `event_id`、对应跳的 `digest`、`status`，并按需附加受限 `reason` 与重试提示。定义认证失败和超大批次的整批错误，普通内容错误返回逐项结果。先按整批校验和索引回复，再应用结果。比如同一 ID 同时出现 `stored` 和 `identity_conflict` 时保留该事件，另一条唯一且摘要匹配的 `stored` 仍可确认。封存和历史导入分别定义独立的受控操作。
- [x] 在 `apps/backplane_diagnostics_client/test/contract_test.exs` 固定字段边界、规范字节、摘要、序列冲突和混合 receipt 用例。用 `mix test apps/backplane_diagnostics_client/test/contract_test.exs` 验证支持的 fixture 及预期拒绝码，包含乱序成员、未知、缺失、重复、矛盾与摘要不匹配的回复。

### T02 固定脱敏政策和部署约束

- [x] 在 client app 增加 `lib/backplane/diagnostics_client/redaction.ex` 与 `test/redaction_test.exs`。先从明确允许的结构提取，再限长和过滤消息、结构化参数、栈与 breadcrumbs。用合成密钥测试键的大小写与分隔符变体、Bearer、Cookie、嵌套值、异常消息、连接串与敏感正文，断言禁止字段和密钥标记从规范字节消失。对无法安全公开的异常文本保留错误类、允许的栈帧及脱敏或截断标记。
- [x] 在 M0 验证记录中逐项核对 `Backplane.Observability.{Context,Event,Redaction,Buffer,RuntimeSink}`、`TraceStore`、`Memory.CaptureUploader` 和 LLM writer 的复用条件。测试外部字符串不创建 atom，现有 trace cast 和 LLM 日志 enqueue 不发持久 ACK。独立 client 只能使用可单独消费的依赖，打包构建参照 `scripts/verify_agent_runtime_package.sh` 的外部 consumer 做法。
- [x] 用锁定的 `ex_turso` 3.1.18 在临时数据库中测事务提交、重开、进程中断、文件与 WAL 增长。用连接 owner 的接口读活跃状态，记录所用同步配置及其已验证保证。用实际 Host Channel 检验编码后的批次上限。将实测结果记录到 `docs/diagnostics/acceptance.md`，据此冻结试点容量。Agent Note `9c0aa381-f43e-41de-a0c9-3cbd3c5d9572` 的锁结论来自历史 3.1.1，测试当前版本。
- [x] 运行 `mix test apps/backplane_diagnostics_client/test`，审阅 schema、fixture、脱敏清单和失败状态表。M0 通过后固定 fixture 版本并作为 M1 两跳验收输入。

## M1 两跳可靠交付

### T03 中央持久接收与权限

- [x] 创建 `apps/backplane_diagnostics` 及其 `lib/backplane/diagnostics/{sources,events,outbox}.ex`。在 `apps/backplane_system/priv/repo/migrations/` 新增来源、事件、去重凭证、封存标记和投影 outbox 迁移。由数据库唯一约束保护 `(source_id, event_id)` 和 `(source_id, producer_epoch, source_sequence)`。验证 Host/来源归属和上传摘要后，每个合法事件与其待投影记录同事务提交，退回事务的项返回可重试拒绝。同身份同摘要返回持久 `duplicate`，不同摘要或同序列不同 ID 返回对应冲突。
- [x] 在 `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex` 增加能力声明和 `diagnostics_sync`。使用 socket 中已认证的 host/token 标识，每一批重新检查 `Backplane.Skills.AgentManage` 的 token assignment，以及当前 `host_agent.diagnostics.write` 授权。结合来源登记验证每项，忽略数据包自报的 host 权限。对旧 Host 的 join、`trace_sync`、`memory_events` 保持原有行为。将中央域与 Repo 加入 Backplane release 所需依赖，Host release 只包含 client 侧协议依赖。
- [x] 在 `apps/backplane_diagnostics/test/events_test.exs` 验证提交前断点与响应丢失、身份和序列冲突、单项非法、并发重复、封存及服务端保留清理后的去重。在 `apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs` 验证已连接 token 被撤销后下一批拒绝、凭据无 scope、来源属另一台 host 及原有消息兼容。运行 `mix test apps/backplane_diagnostics/test/events_test.exs apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs`，断言一次成功事件只对应一条 outbox 记录。

### T04 Host 本地入站、持久存储和补传

- [x] 在 `apps/backplane_host_agent/lib/backplane/host_agent/` 新增 `http_router.ex` 与 `diagnostics/{ingress,sources,spool,uploader,health}.ex`，接入现有 `http_server.ex`、`application.ex`、`config.ex`、`channel.ex`、`reporter.ex` 和 `config/host_agent_runtime.exs`。用复合 router 挂载 `POST /diagnostics/v1/events`、`GET /diagnostics/v1/status`，其它路径按原请求交给 `MemoryRouter`。来源 token 按注册绑定 `source_id` 及允许的应用、仓库和服务元数据，状态使用独立管理授权或来源内统计。试点使用 loopback HTTP 加来源凭据，容器显式配置可达地址。
- [x] spool 使用独立库，由 owner 串行执行事务。认证和校验后先查原 ingress 摘要及处置，随后对新事件脱敏并冻结 forward 字节。在同一准入操作检查总量、来源、优先预留和正文/WAL 预算，再提交 payload、双摘要、身份、尝试和交付状态。以设计默认值起步并校准，普通正文最多占总量 75%，`expired`/`dead_letter` 正文同时受 7 天和总配额 10% 限制。最长待传到期写显式缺口；正文回收后仍能用凭证响应重传。磁盘写失败和配额拒绝不给 `local_durable`。
- [x] uploader 验证能力、按条数和编码字节分批、退避并加入 jitter，完整解析 receipt 后由 owner 持久提交确认。匹配的远端持久成功才释放当前待传记录，其他终结处置遵循独立保留规则。认证失效暂停，旧网关显示 `unsupported capability`，非法项与冲突分别隔离，重试修正内容使用新身份并引用原事件。独立健康接口及低频 heartbeat 提供队列深度、容量、最老年龄、最近确认、丢弃、拒绝、解析失败和死信。总开关与单来源开关分别控制新采集，已有队列按配置继续交付或保留暂停。对中央侧 outbox 和 Reporter 提供同样可独立查询的健康摘要。
- [x] 在 `apps/backplane_host_agent/test/backplane/host_agent/diagnostics/` 创建 `ingress_test.exs`、`spool_test.exs`、`uploader_test.exs`。运行 `mix test apps/backplane_host_agent/test/backplane/host_agent/diagnostics apps/backplane_host_agent/test/backplane/host_agent/memory_router_test.exs`。覆盖无凭据、伪造来源、磁盘写失败、进程重启、正文清理后重复事件、认证撤销后的待传保留、并发配额及旧路由。

### T05 Client Reporter 与实际两跳验证

- [x] 在 client app 增加 `lib/backplane/diagnostics_client/{reporter,context,local_transport}.ex`。在昂贵操作和发送前做严格的共享条数/字节准入，绑定每应用实例的有界 breadcrumbs 与健康计数。应用捕获线程只返回接纳结果，worker 处理 HTTP、重试和释放。重试持有稳定的规范化事件；进程重启或主动轮换后，新事件使用新 epoch。两个接收端保存封存标记，在旧队列已完结、失联待传窗口与缺口已结算后才封存。重放走独立路径。
- [x] 增加 `apps/backplane_diagnostics_client/test/reporter_test.exs` 和 `apps/backplane_api/test/backplane/api/diagnostics_delivery_test.exs`，用独立 Host 进程跑集成场景。故障注入在本地提交后、远端提交后分别丢一次 ACK，重启 Host，带同一身份重试；断言 spool、中央事件和 outbox 各只有一个有效项。另跑延迟、批次乱序、应用/Host/中央分别离线、脱敏升级、矛盾 receipt 和混合版本。运行 `mix test apps/backplane_diagnostics_client/test/reporter_test.exs apps/backplane_api/test/backplane/api/diagnostics_delivery_test.exs`。
- [x] 创建外部 client consumer 测试并做独立 Host release 构建检查，记录包含的 app 和依赖。M1 的停止门槛是两跳提交、恢复、撤销、队列上限和旧协议均有实测证据。运行吞吐与资源基线，保留后续 M4 同工作负载复测的参数。

## M2 自动捕获、旁证和产品试点

### T06 应用捕获与关联

- [x] 增加 `apps/backplane_diagnostics_client/lib/backplane/diagnostics_client/integrations/{logger,phoenix,task}.ex` 及 `test/integrations_test.exs`。从选定 Logger/OTP 事件和锁定 Phoenix 的异常事件取原因、可用栈和请求关联；识别取消和正常 shutdown。用公共捕获边界的 `occurrence_hint` 或明确的因果标识关联同次故障。普通日志保留栈 `unavailable`。显式在 Task、job、GenServer 与子 Agent 间传递上下文，复用进程恢复原上下文。
- [x] 在 `apps/backplane_agent_runtime/lib/backplane/agent_runtime/error.ex` 的转换调用处接入可选观察边界，在 `Error.to_map/1` 省略 cause 之前采集；保持公共 DTO 和异常/退出语义。Backplane 在 `apps/backplane_llama/lib/backplane/llm/proxy_plug.ex`、`apps/backplane_mcp/lib/backplane/transport/mcp_handler.ex` 和拥有者的后台任务边界导出 allowlisted 失败与请求关联。Kernel 继续执行纯计算。
- [x] 用隔离 fixture 启动两个并行 run，注入 Task 崩溃、Phoenix 异常、handled error、普通日志和 Reporter 不可用，检查原业务结果、栈可用性和关联。运行 `mix test apps/backplane_diagnostics_client/test/integrations_test.exs`，并在各 owning app 的定向测试中断言原调用和监督行为。

### T07 目标服务旁证与 Host 健康

- [x] 新增 `apps/backplane_host_agent/lib/backplane/host_agent/diagnostics/collectors/` 下的 `process.ex`、`service.ex`、`resource.ex`、`log.ex`、`crash_artifact.ex`。使用预登记目标和受限适配器。进程用宿主 boot、PID 与启动时间关联，日志轮转要有持久游标。支持 Linux/systemd、macOS/launchd 的受控服务证据与容器目标能力声明，权限不足和不支持项返回 `unavailable`。故障前保留低成本周期摘要，触发时按预算采一次目标快照。崩溃材料默认只保存摘要和受控引用。
- [x] 在 `apps/backplane_host_agent/test/backplane/host_agent/diagnostics/collectors_test.exs` 模拟 PID 重用、日志轮转、不可用采集器、磁盘与服务退出；在 Linux 与 macOS 各用一个登记的受控服务验证退出/重启，记录能力差异。单次心跳缺失记录 `disconnected` 或证据缺口。用独立健康计数记录 Host 自身 collector、spool 和 uploader 故障，验证采集失败与诊断分析故障不会递归。

### T08 接入和扩大试点

- [x] 在 Sigma `apps/sigma_agent/lib/sigma_agent/backplane/diagnostics.ex` 映射已存在的 Metrics facts、run/turn lifecycle、Provider/Tool/Runtime 和存储/MCP 错误。保留 request、turn、retry lineage、revision 和 `unknown` usage。在 `apps/sigma_agent/test/sigma_agent/backplane/diagnostics_test.exs` 注入崩溃、handled error、429 后恢复、取消与子 Agent，并在单来源试点验证真实 Host 交付。
- [x] Sigma 通过后，在 Synapsis `apps/synapsis_agent/lib/synapsis/agent/diagnostics.ex` 和 Samgita `apps/samgita/lib/samgita/diagnostics.ex` 分别加入 adapter。Synapsis 在 `RunEvents`/`Events.Emitter` 确认关键事实后导出，保持原生终态和因果。Samgita 在 Driver/NativeRuntimeEvent 边界保留 runtime、instance、generation、sequence 和外部调用关联。从对应仓库根目录运行 `mix test apps/synapsis_agent/test/synapsis/agent/diagnostics_test.exs` 和 `mix test apps/samgita/test/samgita/diagnostics_test.exs`，断言掉线或拒绝下仍保持原生状态、终态与持久性。正文和原生加密负载维持原有数据边界。
- [x] 使用同一份协议 fixture 验证四个产品与 Host 自身来源。活动 Run 的低频摘要只传允许的阶段、deadline、最近确认进度与等待类型，来源无法提供时显示缺口。记录各来源支持的入口、不可用字段、故障注入结果及部署构建标识。M2 通过条件是自动异常、已处理错误和已登记服务的外部旁证都能观察，App 返回值与原生业务状态保持。

## M3 问题、分析、报告与查询

### T09 幂等投影和检测

- [x] 在中央 app 新增 `lib/backplane/diagnostics/{projector,runs,occurrences,issues,detectors}.ex` 及共享 Repo 迁移。投影事务先竞争 `(projector, version, source_id, event_id)` 处理键，再建立 Run/Occurrence/Issue 关系。发生次数仅在 issue-occurrence 关系首次插入时更新；事件数、故障数、Run 数分别查询。显式 occurrence_hint 或有范围的原生 ID 支持合并，近似文本和时间只提示候选。Issue 指纹固定版本、组件、边界、错误类和规范帧，人工拆分/合并保留审计。运行摘要按来源 revision，保留晚到证据、冲突、采样、时钟偏差和缺口。
- [x] 实现八类版本化检测规则。以输出契约为首版无异常检查器，输入须包含契约版本、预期、实际只读摘要和已确认终态，所需事实不足返回 `insufficient_evidence`。重启风暴、疑似停滞、重试无进展、交接、环境关联及版本回归以设计 §8 的证据阈值输出；正常取消或等待、重试恢复和数据缺口各自独立。通过受信的 request、trace、attempt 或 invocation 关联 LLM/MCP 记录。旧 trace 使用协议、host 和 seq 的只读适配，重复观察归同一执行时用关联记录而不增加执行数或叠加用量。
- [x] 运行 `mix test apps/backplane_diagnostics/test/projector_test.exs apps/backplane_diagnostics/test/detectors_test.exs`。模拟事务中断、两个并发 worker、整库重放、旧 revision、同一/不同 attempts、成功恢复、缺数据和明确契约失败，逐项断言中央状态和三种计数。

### T10 确定性报告、受控分析与证据保留

- [x] 在中央 app 增加 `lib/backplane/diagnostics/{evidence,analyses,reports,repair_tasks,retention}.ex` 及共享迁移。确定性报告由问题创建和重要变化触发，显著恶化、复发或验证状态变化使用幂等键产生内部通知候选。证据包冻结问题和运行标识、脱敏栈与宿主摘要、对照和缺口、受控内部引用及精确 SHA 的有界代码片段。无法取到该版本显示 `source_unavailable` 或 `version_mismatch`。正文过期后保留支持去重、归组和验证的字段，显示 `evidence_expired`。保留周期、模型和阈值使用 `diagnostics.*` Settings，附件默认关闭。
- [x] 对高严重度异常和确认的契约违反自动安排分析，以 `(issue_id, evidence_set_digest, policy_version)` 去重。先作原子预算预留，再经 LLM proxy 运行有并发、Token、费用、次数、冷却及超时限制的只读任务。日志、源码和工具输出只作为数据；模型工具只能按当前证据包的内部 ID 获取已验证资料。带 `origin=diagnostics` 的自监控失败独立计量。校验结构、证据引用、实际读取的 SHA 和位置后生成 Analysis 与 RepairTask，记录限制、出处、复现/回归条件与模型用量。无模型、预算耗尽、超时及无效输出均产生可见状态，确定性报告继续。
- [x] 运行 `mix test apps/backplane_diagnostics/test/analyses_test.exs apps/backplane_diagnostics/test/retention_test.exs`，覆盖重复风暴、并发预算、超时、伪造引用、日志指令、过期证据与当前/封存 epoch 重传。用受控模型生成一份有效结果与一份无效结果，检查无效结果为 `analysis_invalid`；已配置模型的试点验收留存脱敏结果和用量，不保存模型私有推理。

### T11 Admin、只读 MCP 和运维操作

- [x] 在 `apps/backplane_admin/lib/backplane/admin/router.ex` 和 `apps/backplane_admin/lib/backplane/admin/live/diagnostics/` 接入问题列表及详情、Run 详情、采集健康、分析设置和修复观察。中央上下文提供分页有界查询及独立的分析重跑、归组调整、状态变更、死信管理。操作与配置变化写审计记录。运行 LiveView 定向测试及本地 Chrome 检查，记录渲染、操作反馈、窄屏、键盘和过期/缺失证据状态。[Backplane UI Implementation Guidelines](../../../DESIGN.md)
- [x] 在 `apps/backplane_mcp/lib/backplane/services/diagnostics.ex` 注册 `diagnostics::{search_issues,get_issue,get_run,get_evidence,get_report}`，接入 `apps/backplane/lib/backplane/application.ex` 的服务协调。核对 `Backplane.Registry.Namespace` 的 prefix 冲突处理。在发现和调用两处验证明确授权的 `diagnostics::read`，对匿名开放入口、无 scope、跨消费面及 Host 代转各做回归，确保 wildcard 或常规工具可见性无法隐式扩大证据权限。管理权限与只读权限分别检查，Admin 使用项目现有可信运维部署边界。确保工具限制证据大小、只返回有效内部引用或明确过期状态，并支持适用 MCP 版本。
- [x] 运行 `mix test apps/backplane_admin/test/backplane/admin/live/diagnostics_test.exs apps/backplane_mcp/test/backplane/services/diagnostics_test.exs`，再跑 public/named/Host 调用面的授权定向用例。M3 通过条件是受控事件自动产生问题、报告和有效修复任务，可按身份读到来源、证据质量和分析结果；重复事件只增加适用统计。

## M4 修复验证与完整首版验收

### T12 修复与观察状态机

- [x] 在 `apps/backplane_diagnostics/lib/backplane/diagnostics/resolutions.ex` 和共享迁移中分别存储问题、回归测试、修复实现、实际部署和运行观察状态。保存仓库/commit/PR、验证记录、部署范围和可信来源。使用明确构建集合或经验证的 Git ancestry 判断修复适用性。软件、环境、上游和 AI 质量问题分别使用设计 §10 的关闭证据，均记录工作量分母、采集健康和覆盖门槛。
- [x] 在 `apps/backplane_diagnostics/test/resolutions_test.exs` 使用一个脱敏故障 fixture 执行复现、修复验证、部署身份证据、健康覆盖、复发和迟到回放。校验仅测试通过仍未部署，零流量或采集有缺口仍 `insufficient_coverage`。健康证据达标后允许观察和关闭。修复版复发重开并排分析，旧版本迟到只补历史。运行 `mix test apps/backplane_diagnostics/test/resolutions_test.exs` 并从 Admin 修复观察页复验。

### T13 运行手册、发布兼容和证据收尾

- [x] 在 `docs/diagnostics/` 提供 client 安装与最小用法、Host 来源注册/环境配置、spool 恢复和 dead-letter 操作、中央设置、Admin/MCP 权限以及耐久性边界。演练旧/新 Backplane 和 Host 的四种组合，先中央后 Host 再应用。回滚演练停新采集或分析并保留待传事件与历史证据，验证原 LLM/MCP/Memory 在演练中继续运行。
- [x] 在 `docs/diagnostics/acceptance.md` 逐条记录 A01–A41 的命令、环境、代码与构建 ID、数据状态和证据位置。使用本地 provider/tool stub 及受控服务做故障注入。对真模型、Linux/macOS collector、重启与真实连线分别留证，据实区分测试、试点和实际部署观察。注入合成密钥并检查 Reporter 备份（如启用）、spool、数据库、报告、日志、MCP 结果及可选附件边界。
- [x] 用相同工作负载比较采集开关前后应用延迟，覆盖正常流量、触顶并发和离线后排空。记录 Reporter 热路径延迟分布、峰值常驻内存、spool/WAL 峰值和排空用时、PostgreSQL 事务与分页查询延迟。先记录负载、环境和阈值，再判结果，分别验证各预算。配额拒绝和丢失统计应能在线读取。
- [x] 从拥有 app 运行目标测试，随后运行 `mix format --check-formatted`、`mix compile --warnings-as-errors` 及仓库规定的相关 Credo、Dialyzer 和 CI 工作流检查。检查集成 diff、干净 consumer 和 Host release 的可用性。保留所有有效验收记录，按交付版本说明已实现行为、验证范围和平台限制。

## 验收索引

| 设计场景 | 验证任务及证据 |
| --- | --- |
| A01、A02、A03、A04 | T06/T08/T09：自动栈与 handled error，业务行为保持，多观察同故障和跨 attempt 次数 |
| A05、A06、A07 | T07/T08/T09：重试后成功、取消/等待、VM 外部退出旁证 |
| A08、A09、A10、A11、A12 | T01/T03/T04/T05：两跳丢 ACK，冲突、逐项拒绝和完整 receipt 校验；T09 复核 Issue 不重计 |
| A13、A14、A15、A16 | T03/T04/T05/T09：epoch、迟到、事务中断、重放与投影计数 |
| A17、A18、A19、A20、A21 | T02–T05/T10/T11/T13：分层离线，磁盘、容量、撤销、首次落盘及证据输出脱敏 |
| A22、A23、A24、A25、A26 | T07/T09/T10：契约、失联、重复汇报、分析限额和证据工具边界 |
| A27、A28、A29、A30 | T12：测试与部署区分、健康观察、修复版复发与旧版迟到 |
| A31、A32、A33、A34、A35、A36 | T04–T11/T13：协议矩阵、平台能力、正文留存与去重、跨运行关联、独立健康、有效/无效分析和实际模型 |
| A37、A38、A39、A40、A41 | T01/T03–T05/T09：脱敏策略升级、矛盾 ACK、并发配额、重启后凭证、并发投影 |

| 设计需求 | 实施任务 |
| --- | --- |
| R1、R2 | T05–T08 |
| R3 | T03–T05、T07 |
| R4、R5 | T06、T08、T09 |
| R6 | T10、T11 |
| R7 | T11、T12 |
| R8 | T02、T04–T07、T10、T13 |
