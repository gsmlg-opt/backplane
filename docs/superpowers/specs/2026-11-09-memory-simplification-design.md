# Backplane Memory 精简重建 — 设计

- 日期：2026-11-09
- 状态：待用户确认；Plan 2（host 离线记忆：本地存储、outbox、pull）已实现
- 范围：`apps/backplane_memory`、`apps/backplane_host_agent` 的 memory/capture 部分、`apps/backplane_api` 的 host-agent memory 通道、`apps/backplane_system` 中 memory 相关表与 settings、`apps/backplane_admin` 的 Memory 页面、`integrations/memory/*`、CI 中 memory 相关步骤。
- 标注约定：**[用户决定]** 来自用户明确表态；**[设计者决定]** 是我（设计者）的选择，用户可推翻；**[留给实施者]** 由实施者自行判断。

## 1. 意图与原因

Backplane Memory 只为一个人服务。用户同时使用多个 agent（多台机器上的 OpenClaw、Hermes，以及 Claude Code、Codex、Cursor、Sigma、Synapsis），希望它们共享一份记忆，让 agent 在用户提到某个服务、仓库、机器时能直接定位，而不是重新到处 ssh、`ls`、`find`。

典型诉求（用户原话归纳）：

- 处理过哪些服务器，在上面做了什么操作、怎么做的；
- 哪些机器上有哪些 git 仓库；
- 最近做过哪些工作；
- 有些事是别的 agent 做的——各 agent 有各自专长，要知道每条记忆**从哪来**（哪台 host、哪个 agent、哪次会话）。

当前系统从 [rohitg00/agentmemory](https://github.com/rohitg00/agentmemory) 移植，现状（2026-11-08/09 调查）：

- 采集链路可用：host agent spool → channel → `bpm_events` → 会话/观察投影。
- **没有真正的提炼**：会话总结只是拼接观察；事实提炼要求逐字整句、单个候选不合格即整会话作废、长会话直接拒绝；从未配置 `memory.llm_model`，因此从没运行过。真实库里的记忆全部是 Hermes 直接写入。
- **召回被分区隔离**：每个 host 一个私有 memory space，召回按精确分区过滤，跨 host 的记忆互相不可见；普通 OAuth/`bp2_` 客户端没有任何途径获得 `memory_partition_id`，经网关调用 `memory::*` 一律 `unauthorized`。
- 大量照搬自 agentmemory 的周边功能（lessons、crystals、graph、slots、leases、signals、actions、team share、replay 等，约 2 万行）与核心诉求无关。agentmemory 原版本身的提炼也是默认关闭、`consolidate` 从不自动触发。

**[用户决定]** 分区/所有权模型是过度设计，应删除；host/agent/session 只作为**来源追踪（provenance）**，不作为权限边界。

## 2. 目标

1. 所有 agent 共享**一份全局记忆**；每条记忆带完整出处。
2. 会话/任务结束后**自动提炼**出可召回的记忆，三类：
   - **环境事实**（fact）：某 repo 在哪台 host 的哪个路径、某服务跑在哪台机器等。会变，新事实覆盖同一主体的旧事实。
   - **操作经验**（procedure）：在哪台机器上怎么做某操作、注意事项。追加，可被标记过时。
   - **工作日志**（worklog）：什么时候、在哪、用哪个 agent 做了什么。用于"最近做了什么"。
3. 用户可以明确说"记住这个"（直接写入），也可以说"这个过时了/忘掉"（标记失效）。
4. **召回由 agent 判断需要时主动调用工具**完成 **[用户决定]**；不做每轮自动注入。
5. 提炼来源有三条：
   - (a) **工作 agent 自己写**：类似 Hermes，会话/任务结束一段时间后 agent 自己写记忆；客户端支持就做，不支持就跳过（尽力而为）**[用户决定]**；
   - (b) **Memory 系统自己的 LLM 提炼**：使用用户已购买的模型 API，配置到 memory 的 LLM model **[用户决定]**；
   - (c) **host 侧采集**：host agent 扩展采集器，从所在主机收集环境数据，交给 memory agent 提炼 **[用户决定]**。
6. 后台提炼由运行在 `backplane_agent_runtime` 上的 **memory 维护 agent** 完成 **[用户决定]**（这正是 agent_runtime 设计中"Backplane 托管配置/内容 agent"消费场景）。
7. 补齐插件：Codex、Cursor、Claude Code、Sigma、Synapsis，并保留 Hermes、OpenClaw **[用户决定]**。

## 3. 非目标

- 多用户、多租户、团队共享、权限分区。
- 每轮对话自动注入记忆上下文。
- 保留或迁移现有记忆数据——**生产环境还没有记忆，所有现存数据都可清空** **[用户决定]**。
- agentmemory 的协作类功能（actions/leases/signals/routines/sentinels/mesh 等）。

## 4. 反目标（技术上能跑也算失败的情况）

- 召回返回其他 host 写的记忆时被过滤掉，或要求客户端绑定分区/空间才能读。
- 记忆没有出处，或出处只能靠猜。
- 提炼失败**静默**发生（只打 debug 日志、记一个 skipped 状态）。缺模型、缺凭证、LLM 调用失败都必须在 admin 页面和 warning 日志中可见。
- 旧的同主体事实与新事实并存且都作为有效结果返回。
- "过时/忘掉"后该记忆仍出现在默认召回结果里。
- 主机采集每次都上报相同快照、导致重复提炼。

## 5. 约束

- Elixir umbrella，遵循 AGENTS.md 的应用归属：schema/context 在 `backplane_memory`，迁移在 `apps/backplane_system/priv/repo/migrations`，host 侧在 `backplane_host_agent`，admin UI 用 `phoenix_duskmoon`。
- 公共 API 认证仍走 `Backplane.Auth.ResourceAuthPlug` 的普通 scope 校验（如 `memory::*`、`memory.read`/`memory.write` 类）；**不再有** memory 专属的分区授权层。admin 端仍是受信任运维面。
- 依赖 `gsmlg-opt` 等组织下的仓库（Sigma、Synapsis、agent_runtime 的外部消费者）缺功能时，按 AGENTS.md 的 upstream issue 规则处理。
- 不提交、不推送，除非用户明确要求。

## 6. 已决定的做法

### 6.1 删除范围 **[用户决定，按设计者建议]**

删除（代码、表、MCP 工具、Styx worker/cron、admin 页面、测试、CI 步骤一并删除）：

- 分区/所有权层：memory spaces、entitlements、legacy aliases、backfill issues、access audits/commands、revocations、`Partition`、`PartitionIdentity`、`Authorization`、`memory_partition_id` 相关逻辑、`scope`/`namespace` 作为所有权的用法；host 侧 `Access`、`MemoryProxy.authorize_private` 等授权协商。
- Edge sync（partition revisions、changes、snapshots、触发器、retention）、host-edge 加密。
- 周边功能：lessons、crystals、graph、slots、leases、signals、actions、team share（shared commands）、replay、imports、generated skills、facets、profiles、activity、eval/qualify/seed_bench 等 mix 任务。
- 现有的提炼实现：`SummaryWorker`（拼接式）、`WindowSummaryWorker`、`EpisodicWorker`/`FactExtraction`、`ProceduralWorker`、`RelationClassifierWorker` 及相应 prompts。

数据：清空。新迁移直接 drop 旧 memory 表并建新表；不写回填或兼容逻辑。

### 6.2 保留 **[设计者决定]**

- 采集协议：`POST /capture/v1/hooks/:integration/:hook` → host agent durable spool → channel `memory_events` → 网关 ingest → 事件表；以及会话投影（会话开始/结束、按会话聚合事件）。实施时去掉其中的分区校验，其余行为保持。
- 会话关闭判定：SessionEnd 显式关闭，或空闲超时关闭（现有 fallback sweep 机制）。
- host agent 的离线能力 **[用户决定：必须保留，很重要]**，见 6.11。

### 6.3 数据模型（语义已定，字段名由实施者定）

一张记忆主表，每条记忆具备：

- `kind`：`fact` | `procedure` | `worklog` | `note`（`note` 用于用户显式"记住"且无法归类时）**[设计者决定]**；
- **主体（subjects）**：一组 `{type, key}`，type 至少包括 `host`、`repo`、`service`、`path`、`project`。用于定位与覆盖判断；
- `fact` 额外有**属性（property）**，"同一主体 + 同一属性"的新事实覆盖旧事实；
- 内容正文、可选标题/标签；
- **状态**：有效 / 被覆盖（指向新记忆） / 已失效（用户标记过时或遗忘，附原因与时间）。失效不物理删除 **[设计者决定]**；
- **出处**：host、agent、integration（客户端类型）、会话、来源事件 id 列表，以及**写入者**：`agent`（工作 agent 自写）/ `memory_agent`（后台提炼）/ `user`（显式记住）/ `host_collector`（主机采集提炼）；
- 全文检索列与向量列（embedding 可选，未配置模型时仅全文检索）；
- 时间戳（含"事实观测时间"，用于"最近"类查询）。

**出处来源** **[设计者决定]**：单用户系统，信任调用方自报的出处。
- 经 host agent 写入：host agent 盖上 host_id、agent_id；
- 经网关直接写入：网关记录认证得到的 client 身份，host/agent/session 由调用方参数提供（可选）；
- `memory::remember` 接受可选 `session_id`，插件应当传入，用于把该会话标记为"已由 agent 提炼"；
- 缺失的出处字段保持为空（如实记录），不推测。

事件与会话表保留现有出处字段（host_id、agent_id、integration、session_id、project 等），删除分区列。

### 6.4 提炼

两条（加上主机采集共三条）来源产出**同一种"记忆候选"格式**，进入**同一个合并步骤**：

- **合并规则**：
  - `fact`：同主体 + 同属性已有有效记忆 → 新的覆盖旧的（旧的标为被覆盖，指向新的）；内容等价 → 只刷新观测时间和出处。
  - `procedure`：与已有有效 procedure 语义近似（同主体且内容相似）→ 更新/合并为一条，否则新增。
  - `worklog`：只追加。
  - 合并判断由 memory agent 借助工具完成，而不是 Jaccard 之类的词重叠规则 **[设计者决定]**。
- **(a) 工作 agent 自写** **[用户决定：方式 B]**：只靠常驻指令（插件附带的 skill/说明文件，告诉 agent "工作完成后若有值得记住的内容，调用 `memory::remember`"），agent 自行判断——大多数会话可能不需要记忆。不使用阻塞 Stop hook，不强制多一轮。Hermes、OpenClaw 这类插件自身支持会话结束后延迟触发的，沿用其原有方式。写入者记为 `agent`；带 `session_id` 时该会话标记为"已由 agent 提炼"。
- **(b) memory agent 后台提炼**：会话关闭后（空闲延迟一段时间，避免与 (a) 重复），对**未被 agent 自写覆盖**的会话运行 memory agent；对已被 agent 自写的会话，只做合并/去重检查 **[设计者决定]**。长会话分块处理后汇总（借鉴 agentmemory 的分块总结）。
- **(c) 主机采集**：见 6.6。
- **失败可见**：提炼状态按会话记录（待处理/进行中/完成/失败+原因），admin 可见，可手动重试；缺 `memory.llm_model` 时以 warning 报告并在 admin 显著提示。

### 6.5 Memory 维护 agent

- 运行在 `backplane_agent_runtime` 上，作为 Backplane 进程内托管的 agent（无 git、无 shell、无工作区）。
- LLM：使用 memory 设置中配置的模型（`memory.llm_model`），经 Backplane 自己的 LLM proxy 路由到用户已购买的 provider。
- 工具（最小集）：读取某会话的事件/观察、按主体或关键词搜索已有记忆、写入记忆候选、覆盖、标记失效。工具只作用于 memory 领域。
- 由会话关闭事件驱动；同一时刻处理多少会话由实施者设上限。
- **[设计者决定]** provider 适配器调用 Backplane LLM proxy 的 OpenAI chat-completions 协议（优先进程内调用）；`memory.llm_model` 须解析到支持 tool calling 的模型，不支持时在 admin 报错。runtime 使用 ephemeral store；提炼状态的持久化放在 memory 领域自己的表中。

### 6.6 主机采集

- host agent 新增采集器，定时运行，**只在内容变化时上报**（内容指纹比对）。
- 默认采集范围 **[设计者决定，用户可改]**：
  - git 仓库：路径、remote、当前分支、最近提交；
  - 服务：docker 容器、systemd（Linux）/ launchd（macOS）服务；
  - 主机信息：hostname、系统、IP、监听端口。
- 扫描根目录与开关在 host agent 配置文件中设置。
- 快照作为一种事件（integration = host collector）进入现有采集链路。**[设计者决定]** 快照到事实的映射是**确定性的**（快照差异 → 新增/更新/失效 `fact`，写入者 `host_collector`），不需要 LLM；memory agent 只在需要时做补充（如把仓库与已有操作经验关联）。
- 失效规则 **[设计者决定]**：快照中消失的条目只使**写入者为 `host_collector`** 的对应事实失效；`agent`/`user` 写的事实不被自动失效。只有当某个扫描根目录/采集器**本次完整成功**时，才把其中消失的条目视为"已删除"；采集器关闭、根目录移除、扫描部分失败都不触发失效。

### 6.7 召回与写入工具

MCP 工具保持 `memory::` 命名空间，最小集 **[设计者决定，名称可调]**：

- `memory::search`：关键词/自然语言查询，可按 host、agent、kind、主体、时间范围过滤；默认只返回有效记忆；结果包含出处；带 token 预算（借鉴 agentmemory）。
- `memory::get`：按 id 取完整内容与出处链（含被覆盖历史）。
- `memory::recent`：最近的工作日志（可按 host/agent 过滤）。
- `memory::remember`：显式写入（写入者 `user` 或 `agent`）。
- `memory::forget`：标记过时/遗忘，需提供原因。

召回检索：全文检索 + 向量（若配置 embedding 模型）的融合排序（agentmemory 的 RRF 方式）；**全局，不按来源过滤，除非调用者显式传过滤条件**。

暴露面：

- 网关 `/mcp`：`services.memory.enabled` 默认 `true` 并在 `/mcp/managed` 提供开关；普通客户端凭 scope 即可调用。
- host agent `/memory/:agent_id/mcp`：同一组工具，在线时转发到网关；离线行为见 6.11。

### 6.8 插件

- **统一 hook 客户端**：一份共享实现（读 stdin JSON → POST 到本机 host agent 采集端点 → 失败不影响 agent），随 host agent release 打包。
- **Claude Code、Codex、Cursor**：各生成一份官方插件包/配置（采集 hooks + MCP 指向 host agent `/memory/:agent_id/mcp` + 6.4(a) 的常驻指令）。Cursor 需要新增 host 侧事件适配（`conversation_id`、`workspace_roots`、camelCase 事件名）。
- **Hermes、OpenClaw**：保留现有插件，删除其中依赖分区/授权协商的部分，召回改用新工具。
- **Sigma、Synapsis**：它们是用户自己的仓库（`gsmlg-opt/sigma`、`gsmlg-opt/Synapsis`），在各自仓库实现 memory 后端接入 host agent；本仓库负责提供协议与 host 侧适配。所需的对方仓库改动按 upstream issue 规则开 `internal request` issue **[设计者决定]**。
- `PluginInstaller` 与 admin 插件目录扩展到上述所有客户端。

### 6.9 Scope **[设计者决定]**

- 保留 `memory.read`（search/get/recent）与 `memory.write`（remember/forget）。
- 删除 `memory.coordinate`、`memory.replay`；`memory.admin` 仅在仍有对应工具时保留，否则删除。现有 client 记录中的这些 scope 在迁移中清理（数据可清空）。

### 6.10 配置与可见性

- `memory.llm_model`、`memory.embed_model`、`memory.proxy_credential` 在 `/memory/config` 设置；未设置时 admin 明显提示"提炼未启用"。
- LLM/embedding 调用不再硬编码 `localhost:4220`；须在生产（默认 4100）与开发环境都能正确到达 LLM proxy（具体方式留给实施者，优先进程内调用）。
- Claude Code hooks 不再依赖开发目录的 `mix memory.connect`。

### 6.11 host agent 离线能力 **[用户决定]**

网关不可达时，host agent 仍须：

1. **保存记忆**：`memory::remember` / `memory::forget` 在本机持久化（outbox），立即返回成功（标明"待同步"），网关恢复后按顺序上传；上传幂等（重复上传不产生重复记忆）。
2. **召回本机已保存的记忆**：`memory::search` / `get` / `recent` 在本机存储上检索（全文检索即可），结果标明"离线、仅本机"。
3. 采集事件照常写入 spool，恢复后上传（现有行为）。

本机存储的内容 **[设计者决定]**：
- 经本机写入的记忆（含待同步与已同步的），同步后保留；
- 在线时由本机采集事件提炼出、且出处 host 为本机的记忆，由网关回推/本机拉取后保存（以出处 host 为界，一个简单的"自某时间以来的变更"增量拉取，含覆盖/失效状态）；
- 不镜像其他 host 的记忆。

旧的 edge sync、分区修订、加密镜像全部删除，以上述简单增量替代。本机存储的引擎沿用 host agent 现有选择，但须规避已知的 `gsmlg-dev/ex_turso#9`（同进程 reopen 卡死）问题——实施时检查该 issue 状态，未修复则按 upstream 规则处理。

## 7. 留给实施者

- 具体表结构、字段名、索引、迁移拆分。
- memory agent 的 prompt、工具 schema、分块大小、并发上限、空闲延迟时长。
- 合并时"语义近似"的判断方式（embedding 相似度、LLM 判断或组合）。
- host 采集的扫描间隔、扫描根目录默认值、指纹算法。
- 统一 hook 客户端的实现语言与打包方式。
- 阶段拆分与 PR 顺序。建议顺序：① 删除 + 新 schema + 采集继续可用 → ② 工具（search/get/recent/remember/forget）与网关/host 暴露 → ③ memory agent 提炼 → ④ host 采集 → ⑤ 插件。
- 与已删除功能相关的 admin 页面如何精简（保留：记忆浏览/搜索、会话及提炼状态、配置）。

## 8. 验收

1. 两台不同 host 上的 agent：A 写入的记忆，B 通过 `memory::search` 能检索到，并看到 A 的出处。
2. 一次真实 Claude Code 或 OpenClaw 会话结束后，在配置了 `memory.llm_model` 的情况下，自动出现 fact/procedure/worklog 记忆，均能指回来源事件。
3. 同一 repo 路径变更后再次提炼，旧事实被覆盖，默认召回只返回新的。
4. 断开网关后，在某 host 上 `remember` 成功并能 `search` 到；恢复连接后该记忆出现在网关，且只有一份；离线期间仍能召回该 host 此前的记忆。
5. `memory::forget` 后该记忆不再出现在默认召回中，`memory::get` 仍能看到失效原因。
6. 未配置模型时，admin 与日志明确显示提炼未运行及原因。
7. 主机采集：新增一个 git 仓库后，下一次采集产生对应 fact；无变化时不重复上报。
8. Claude Code、Codex、Cursor、Hermes、OpenClaw 各自完成一次"采集 → 提炼 → 召回"真实验证；Sigma/Synapsis 以 upstream issue 跟踪。
9. 范围内的 CI：编译无警告、格式、Credo、Dialyzer、相关测试通过；已删除功能的测试与 CI 步骤一并移除。
