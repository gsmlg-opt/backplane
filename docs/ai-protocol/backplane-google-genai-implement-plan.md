# Backplane Google GenAI 原生支持：Implementation Plan

- 日期：2026-09-20
- 状态：Proposed；用于实施，不是功能已完成声明。
- 当前实施与验收记录：[M1 status — 2026-09-23](google-genai-m1-status.md)。本计划保留原始验收标准；用户已明确延后 E2E。
- 仓库：`gsmlg-opt/backplane`
- 审查基线：`main@6b42c06b970880ee57652902f6d11d2f5000d818`
- 推荐提交位置：`docs/ai-protocol/google-genai-implement-plan.md`
- 验证边界：已静态检查下述源码和 Google 官方文档；没有运行仓库编译、测试或真实 Google 请求。实施者开始工作时必须重新记录 HEAD，核对基线之后的变化。

## 1. 结论与实施目标

当前不是完全没有 Google 代码，而是 **已有部分 Google codec，没有完整的 Google 原生代理链路**。不要把本任务简化为添加一个 SDK 依赖或修改 provider 名称。

Google GenAI SDK 是客户端；Backplane 应实现它所调用的、明确版本化的 HTTP 协议。官方提供原生 REST/SSE，也提供 OpenAI 兼容入口。这两种入口应独立配置，不应强制把原生请求绕经 OpenAI 格式。[G1][G2]

本计划按三个主要里程碑推进：

| 里程碑 | 交付范围 | 完成后可以宣称 |
|---|---|---|
| M1：原生代理 | Gemini Developer API 的 GenerateContent、流式生成、模型目录、countTokens；API key；管理界面、日志和 SDK 契约测试 | 支持已验证的 Google GenerateContent 原生 API 子集 |
| M2：共享协议与翻译 | 加固已有 Google codec；逐条开放经过测试的跨协议路径 | 支持明确列出的 Google 与 OpenAI/Anthropic 翻译组合 |
| M3：扩展原生接口 | 独立实现 Google Interactions；Cloud 后端作为后续独立工作包 | 按各自发布的操作清单声明支持范围 |

截至本次核对，Google 已将 Interactions 列为推荐接口。它与 GenerateContent 是不同的协议契约，不能通过同一个 `:google` 分支随意混用。[G1] M1 先解决仓库当前已有 codec 对应的生成链路；不能把 M1 的完成描述为“支持整个 GenAI SDK”。

Antigravity OAuth/订阅接入不是官方 Gemini Developer API 的别名。本计划明确分离它，但不把一个未经独立验证的 Antigravity 后端算作已实现。

## 2. 当前代码基线与缺口

以下路径均相对于仓库根目录，内容对应上述固定 SHA。

| 已检查位置 | 当前事实 | 实施影响 |
|---|---|---|
| `apps/backplane_ai_protocol/lib/backplane/ai_protocol/codec.ex` | 有 `:google` selector；公共契约主要是请求编码、响应/错误解码和流解码 | 不等于已有网关所需的双向 codec |
| 同目录 `codec/google.ex` | 已有 contents、tools、images、usage 和 SSE 处理；生成结果包含内部 `model`、`stream` 字段；拒绝 signed non-thought content | 必须复用并加固，但不能让它限制原生透传能力 |
| 同目录 `translation.ex` | 已有严格的 `Translation.plan/4`，对未知能力和降级有检查 | 可复用预检；不能误认为翻译执行链路已经完成 |
| `apps/backplane_llama/lib/backplane/llm/provider_api.ex` | `api_surface` 只有 OpenAI/Anthropic；native protocols 只有三种现有协议 | 补 Google family、wire protocol、校验和相关持久化兼容性 |
| 同目录 `protocol_route.ex` | 只识别现有 `/v1/...` 路径；协议不匹配直接拒绝 | 新增原生 Google 路由；翻译必须另行显式启用 |
| 同目录 `router.ex` | 从 JSON 顶层 model 取模型；走同 family resolver，再选择 native 路由 | GenerateContent 的模型位于 URL，不能照搬现有正文提取逻辑 |
| 同目录 `credential_plug.ex` | 只接受 OpenAI/Anthropic surface；无 Google 原生认证分支 | 在既有 Credentials 基础上新增适配，不另建 secret store |
| 同目录 `provider_preset.ex` | `google-ai-studio` 使用 `/v1beta/openai`，同时默认绑定 `google-antigravity`、`google_oauth`；预设结构只有 openai/anthropic 槽位 | 纠正认证与端点耦合；迁移必须显式，不能悄悄重定向旧账户 |
| 同目录 `model_discovery.ex` | 有 Google Antigravity 静态模型列表分支 | 官方目录发现不得复用该分支冒充远端可用性 |
| 同目录 `model_resolver.ex` | 按 surface 过滤；模型字符串按 provider/model 拆分 | 规范化 Google resource name；翻译阶段需要调整候选选择顺序 |
| 同目录 `usage_accumulator.ex` | 协议分支没有 Google JSON/SSE observer | 新增有界旁路统计，不能借此重建原生响应 |
| 同目录 `proxy_request.ex` | 已有 tokens、cached、reasoning、metadata、operation 等字段 | 优先复用日志模型，说明字段语义和缺失状态 |

另外，`apps/backplane_api/lib/backplane/api/router.ex` 本身不是当前 LLM 代理路由。实施前必须追踪实际 HTTP listener/dispatcher 的挂载路径，不能只在一个未被访问到的 Router 中加 `/v1beta`。

## 3. 不可破坏的架构边界

### 3.1 原生透传优先

同 wire protocol：认证与授权 → 模型/后端解析 → 替换上游认证与必要的路由目标 → 原始请求/响应转发；日志只做有界旁路观察。

异 wire protocol：解析源协议 → `Translation.plan` → 规范化表示 → 目标协议编码 → 反向响应/流/错误编码。

原生路径不调用语义翻译。不能为了统计 usage，把原始 JSON 解码后重新序列化，也不能把 SSE 转成统一事件后再拼回去。正文透明指实体正文内容与事件字节不被改写，不要求保留 HTTP 分块边界、hop-by-hop headers 等传输细节。

旁路解析失败、未知字段、观察队列超限，只影响统计完整度；认证失败、权限不足和宿主明确的安全策略仍必须拒绝。不能借“透传”绕过授权。

### 3.2 区分后端、API family、wire protocol 与 operation

建议沿用现有模型，增加以下明确身份；不要新增一个含义不清的 `genai` 万能协议。

| 维度 | 建议值/含义 |
|---|---|
| Provider preset/profile | `google-gemini-developer`；未来另有 Cloud profile；Antigravity 保持独立 |
| API family | `:google` |
| Wire protocol | `:google_generate_content`；以后另有 `:google_interactions` |
| Operation | generate、stream_generate、count_tokens、models_list、models_get |
| Endpoint 配置 | 受信任的 base URL、明确 API version、credential binding |

`Codec.Google` 继续作为 GenerateContent 实现；保留旧 `:google` selector 的兼容映射，避免无必要地破坏共享包消费者。模型发现/countTokens 是独立操作，不伪装成聊天生成。

### 3.3 职责归属

`backplane_ai_protocol`：纯数据、codec、usage observer、能力与翻译预检；不依赖 Backplane Repo、Phoenix、管理界面或 Google SDK 进程。

`backplane_llama`：provider 配置、凭据引用、路由、HTTP 转发、模型发现、日志集成、限流。继续复用 Relayixir/现有 HTTP 基础设施。

`backplane_admin` 与现有管理 API：创建/修改 provider、展示认证与能力、模型重载、兼容性提示。

`backplane_ai_protocol_testkit`：独立 fixtures、模拟上游、故障注入和协议契约测试；不得反向成为生产包依赖。

不要为了 Google 集成新增 Python/Node sidecar，不把 SDK 的自动工具执行循环搬入网关，不新增与本任务无关的 service/MCP 编排系统。

## 4. 工作包 W0：锁定契约与回归基线

**任务**

1. 记录实施 SHA；读取仓库 AGENTS.md 和测试约定。清点 Google selector 消费者、现有共享 runtime 的 provider dispatch、HTTP 入口挂载、授权资源映射、所有 surface/protocol enum、模型列表序列化和相关迁移。
2. 固定目标 REST API version。M1 默认只开放经过验证的 `v1beta`；其他版本单独列入 allowlist 和测试，不套用现有重复 `/v1` 清理规则。
3. 固定官方 Python `google-genai`、TypeScript `@google/genai`、Go GenAI SDK 的实际测试版本；记录可覆盖的子集，而非要求三个 SDK 所有功能同时交付。
4. 用本地 recording server 验证自定义 base URL、版本前缀、模型 resource name、API key/header 注入、SSE 请求与响应行为。优先让 TypeScript 或 Go 完成一个最小端到端契约，再扩展其他 SDK；不编造未经运行的 SDK 配置示例。
5. 保存现有 OpenAI Chat/Responses、Anthropic、Codex 原生路径回归测试。真实付费生成不得作为默认 CI 或后台健康检查。

**验收**：提交 API/SDK 支持矩阵、现有调用链与待改动清单；测试明确区分 passed、failed、skipped。没有真实凭据的 live smoke 必须标记 skipped，不能写“Google 已验证通过”。

## 5. 工作包 W1：Provider、预设与持久化

**主要修改位置**：`provider_api.ex`、`provider_preset.ex`、provider 创建逻辑、`ProviderModelSurface`、`AutoModelRoute`/相关 schema、管理 API 与实际数据库迁移位置。

**任务**

1. 增加 `:google` family 与 `:google_generate_content` protocol；补 defaults、验证、序列化、筛选和缓存失效逻辑。逐个检查数据库列类型/约束：Ecto enum 改动不自动证明 SQL 约束兼容。
2. 新增 `google-gemini-developer` 预设：官方原生 endpoint、API key credential。版本归属与 base URL 合成只选一种统一约定，禁止重复产生 `/v1beta/v1beta`。
3. 预设配置不能再默认只有 openai/anthropic 两个槽位。可做小范围标准化为 surfaces 配置，同时保持旧预设读取兼容；不要借机重写全部 provider 管理。
4. 如保留 Google OpenAI-compatible 预设，单独命名，使用对应凭据模式；native protocols 只声明实际验证的协议。不得沿用“所有 OpenAI-compatible 都支持 Responses”的宽泛默认。
5. 对旧 `google-ai-studio` 配置提供迁移诊断：显示现有 endpoint、认证类型、影响和待选择目标。保留旧数据/credential reference，标记 legacy；禁止自动把 Antigravity token 当作 Gemini API key，禁止根据 token 外观猜测类型。
6. provider、surface、model 的禁用和权限撤销必须立即影响新请求。新增字段或配置不改变既有 OpenAI/Anthropic/Codex 路径。

**验收**：能创建、保存、重载原生 Google provider；旧配置不被静默重定向；Google 与 compatibility/legacy 配置在 UI 中明确区分；从旧数据库升级和回滚方案有测试。

## 6. 工作包 W2：原生入口、认证与转发

### 6.1 对外操作

M1 提供下列入口；路径中的 `<model-or-alias>` 表示模型/Backplane alias，不是要求把它写入正文。[G3]

| 方法 | 路径 | 行为 |
|---|---|---|
| POST | `/v1beta/models/<model-or-alias>:generateContent` | 原生 JSON 生成 |
| POST | `/v1beta/models/<model-or-alias>:streamGenerateContent?alt=sse` | 原生 SSE |
| POST | `/v1beta/models/<model-or-alias>:countTokens` | 独立计数操作 |
| GET | `/v1beta/models` | Google 形状的授权后模型目录 |
| GET | `/v1beta/models/<model-or-alias>` | 对应模型描述 |

如果 SDK 使用部署前缀，入口适配必须以契约测试为准。未支持的方法返回明确的 Google 形状错误，不能错误命中 OpenAI fallback。M1 的 streaming transport 只承诺 `alt=sse`；其他格式明确拒绝，不能声称已兼容所有流表示。

### 6.2 请求目标解析

新增一个纯的 Google request-target 解析/构建模块，名称可采用 `Backplane.LLM.Google.RequestTarget`；这是建议的新模块名，不是已有实现。

模型从 URL 读取，不复用“正文必须存在 model”的验证。分别保存 requested alias、resolved upstream model 和原始 provider resource name。精确处理 `models/` 前缀，避免现有 resolver 把 `models` 误当 provider 名。

优先使用 URL-safe 的单段 alias；任何 provider/model 扩展语法必须显式定义、测试 SDK 编码行为。操作后缀采用 allowlist；拒绝路径穿越、编码后的分隔符绕过、重复解码和调用者控制上游 host/project。对正文出现的路由字段冲突明确拒绝，不能悄悄覆盖。

生成请求的 alias 替换仅作用于路径；不得往原生正文添加 `model` 或 `stream`。`countTokens` 的嵌套请求若含 model 引用，必须与已解析上游目标一致；需要重写时将它定义为该独立操作的显式规则并测试，不能悄悄扩散到生成请求正文。

### 6.3 双层认证

客户端使用 Backplane 凭据；Google 上游 API key 只由受信任的 credential binding 注入。原生上游的 API key header 按官方契约处理。[G1]

优先复用现有 Bearer 认证。为官方 SDK 提供经过测试、仅限 Google 路由的 `x-goog-api-key` → Backplane 凭据入口适配，再进入相同的授权链；不是接受任意 Google key 的 BYOK 通道。必须在现有 ResourceAuthPlug 之前完成适配，并绑定正确的资源 audience/scope。

M1 默认不接受 query `key` 作为 Backplane 登录方式。收到该参数明确拒绝，并确保最外层 HTTP/access/proxy 日志同样脱敏，不把拒绝请求的 URL secret 记录下来。只有另行需求与完整安全测试后才能开放。

剥离客户端 Authorization、x-api-key、x-goog-api-key 及其他凭据残留；重复或冲突的凭据 fail closed。最后注入可信上游认证，default_headers 不得覆盖。上游重定向不得携带 secret 到未经批准的目的地。只允许管理员配置 endpoint，复用现有出站地址安全检查。

### 6.4 原生执行

复用现有 Relayixir 原始转发路径，并增加 Google 的路径与 query 构建。保留业务正文、响应 status、相关 end-to-end headers 和 SSE 内容；不保证保留 hop-by-hop 传输头。

原生 GenerateContent 的多 candidate、native tools、签名或新字段不能因为统一 IR 暂不认识而被拒绝。仍执行明确的资源、凭据、大小、权限及已配置功能策略检查。

禁止在正常流末尾追加/伪造 OpenAI `[DONE]`，禁止把 `finishReason` 当作停止读取的理由。取消关闭本地上下游资源；不能宣称上游未执行或未计费。生成请求超时/断线后不自动重放，输出开始后不切 provider。

本地错误使用 Google 对应形状并保留正确 HTTP status；上游原生错误尽可能透明转发。已开始发送的流遇到传输错误按明确契约终止，不补一段虚假的成功响应。

**验收**：请求从真实 listener 进入后，普通/流式生成能到达模拟 Google 上游；捕获到的实体正文与输入逐字节相同；路径模型正确；上游只收到其绑定凭据；客户端断开时本地资源被回收。

## 7. 工作包 W3：旁路观察、模型目录与界面

### 7.1 有界 observer

仿照现有 `OpenAIResponsesObserver`/`UsageAccumulator` 集成模式，新增纯 `GoogleGenerateContentObserver`，将 JSON 与 SSE 模式显式接入 `UsageAccumulator`。不要将完整 `Codec.Google.decode_response` 当成原生转发的验证器。

记录 usage、provider request ID、原始 finish reason、blocked/partial/transport failure、首字节/首内容/完成时间；保留原生 usage 子字段与来源。Google 的 prompt、cached、candidate、thoughts 和 total 计数有不同含义，不能把 cache 再加进 prompt，不能把 reasoning 重复加入 total。[G3]

发布前决定跨 provider 的 `output_tokens` 定义，并在 metadata 记录包含关系；缺失保持 unknown/null，不填零。usage snapshot 更新不重复累计，tail usage 必须被读取；多 candidate 原生可透传，统计有歧义则标明不完整。

观察器需有帧大小、队列、累计正文、解析时间预算。超限/解析失败写 observation_status，不打断成功的 native forwarding；不得为得到完整日志把整条流无限缓存。默认不记录密钥、完整正文和 opaque 签名；正文日志只在明确启用的策略下存储并受保留期限制。

### 7.2 模型目录

实现 Google 目录解析和完整分页；不能用 OpenAI 的 `data[].id` 解析器，也不能返回 Antigravity 静态列表。[G4]

保存原始 resource name、显示名、输入/输出限制、supported methods 与 provenance；未发现的高级能力为 unknown，不能从“模型名像 Gemini”推出支持 tools/Responses/所有模态。

缓存隔离至少覆盖 provider API、credential binding/generation 和 API version；未来 Cloud 加 project/location。所有分页成功后才更新删除/失效状态；分页失败保留 stale 信息但不恢复已撤销权限。迟到发现结果不能覆盖更新的配置代次。

Google `/models` 响应按 Google 形状生成，并过滤到调用者有权限且确实可路由的模型。Backplane 聚合目录是有意的目录适配，不属于生成响应原样透传承诺。每个返回 name 必须能直接用于后续生成；aliases 对应的描述与能力必须来自实际选中的上游。

### 7.3 管理体验

现有 provider 页面增加 Google 原生 surface、认证类型、API version、目录刷新状态和协议能力；模型页显示 native/translation 区别；日志页显示 protocol、operation 和 usage 完整性。

“测试连接”默认做明确的非生成探测，不后台触发付费对话。独立的生成 smoke 由用户主动执行。旧 Google AI Studio/Antigravity 混合配置显示具体迁移提示，不能只换显示名称。

**验收**：分页目录可被至少一个已固定版本的官方 SDK 使用；模型列表中的每个 name 可解析；native 流解析失败不破坏转发；管理页面能创建并验证完整 Google provider。W0–W3 通过后才发布 M1。

## 8. 工作包 W4：加固共享 Google codec

本工作包服务于共享客户端/runtime 和后续翻译，不是原生 M1 的前置阻塞。

1. 清点 `Codec.Google.encode_request` 的消费者，明确返回的是 REST body 还是内部 envelope。迁移时把 model/operation/stream 放入传输目标描述，确保真实出站生成正文符合契约；保留必要的兼容 wrapper，不能直接删字段破坏已有消费者。
2. settings/output constraints 改为显式语义映射，禁止仅 stringify 后合并。未知或不可等价映射的选项返回字段级诊断；thinking 的 budget/level 不固定映射成跨厂商同义档位。
3. 工具调用保存顺序、native ID、名称和结构化参数；工具结果保持结构化对象及关联 ID，不强行字符串化。多次调用相同工具名仍必须准确关联。
4. `thoughtSignature` 在 GenerateContent 中属于 Part 级不透明状态。[G3] 复用既有 ProviderState/Affinity，绑定原始 part、位置、模型、profile/endpoint、credential scope/version。不能把签名单独抽成新 thought 文本，不能把 functionCall 上的签名移到其他 part，不能伪造、推断或静默丢弃。
5. 正文内容结束、provider 协议完成、传输 EOF 与本地请求终态分开；最后 usage 可晚于内容结束。未知 finish reason 不自动当成功。
6. 明确 canonical 模式支持的 candidates/modalities 子集。超出子集严格拒绝；不得让这个限制反向影响 native 路由。
7. 增加同来源 signed tool-call 多轮回放测试，以及跨模型、跨账户、跨 provider 的 affinity 拒绝测试。共享 runtime 若已有 Google 分支，验证工具结果回传闭环；若没有，另列消费者集成任务，不把 codec 单测当作 agent 已可用。

**验收**：Google codec 的结果与独立官方 wire fixtures 相符；至少一个共享包消费者能完成无损的工具调用→结果→继续生成；共享生产包不引入 Ecto/Phoenix/SDK 运行时依赖。

## 9. 工作包 W5：显式、逐对开放跨协议翻译

当前路由拒绝异协议是安全行为，不能删掉拒绝条件就认为已支持翻译。

先补齐 source request decode、destination request encode、upstream response/error decode、client response/error encode、双向 streaming encode/decode 的契约。复用 `Translation.plan/4` 和现有 canonical 类型；OpenAI Chat、OpenAI Responses 必须按不同 wire protocol 处理。

路由也要调整：当前 resolver 先按入口 surface 过滤，会在 codec 之前排除 Google provider。新增“基于明确翻译能力的候选选择”，冻结一次 attempt 的目标、权限、凭据与能力快照；不能把任意 family 都放行。

建议开放顺序：

| 入口 → 上游 | 初始策略 |
|---|---|
| Google GenerateContent → Google GenerateContent | 始终优先 native，不经 IR |
| OpenAI Chat → Google GenerateContent | 首个翻译组合；单候选文本、明确支持的图片和客户端工具 |
| Anthropic Messages → Google GenerateContent | 独立完成 request/response/SSE/error 矩阵后启用 |
| OpenAI Responses → Google GenerateContent | 独立组合；不能伪装 previous_response_id、server-side state 等不存在的能力 |
| Google GenerateContent → OpenAI/Anthropic | 单独的反向组合；不能认为正向通过就自动可用 |

原生 opaque 状态、provider-side tools、安全/隐私配置及不可等价的语义默认不跨 provider。合法的同 Google 状态回传需要明确、经验证的 client extension；客户端不能保留它时直接报告该工具回合不支持，不能静默删签名。

不兼容应尽可能在访问上游之前返回字段级错误。只有显式授权且有可执行规则的降级才允许；工具/schema/system 语义不得默认丢弃。流已开始后才发现不可表示内容，按目标协议失败/中断，不能报成功，也不能改写已提交的 HTTP status。

**验收**：每条已开启路径都有独立 golden、任意分片流、错误和多轮工具测试；未开启路径仍确定性拒绝且不产生上游请求。发布说明列出方向和子集，不写“任意协议互转”。

## 10. 工作包 W6：Interactions 与其他 Google 后端

### Interactions：下一个独立里程碑

增加 `:google_interactions`，以当前官方 Interactions 契约固定 endpoint、事件名和生命周期。[G1][G5] 优先实现 native passthrough，不通过 GenerateContent 转换。

先交付明确的 create 非流式/流式操作；涉及 history/reference、查询、删除、取消或后台任务时，逐项验证并建立 tenant→provider/account 的资源绑定。interaction ID 不能跨账户路由，不能把 Google server-side state 当作 Backplane 普通文本历史。

为它单独实现 observer、usage 和终态处理；不要复用 GenerateContent 的字段名或 SSE 结束假设。尤其不能全局规定“Google 流没有 DONE”——不同 Google 协议有不同事件格式。[G5]

### Cloud 后端：独立 profile 和认证工作包

后续再接 Google Cloud/Vertex endpoint：project、location、endpoint 与凭据模式显式配置；认证按所选官方模式实现，不复用 Antigravity token，也不假设所有 Google endpoint 认证相同。[G6]

如实现 ADC/service-account/OAuth，使用现有凭据机制与单 owner 刷新，配置代次防止退出/撤销后旧刷新结果恢复凭据；生产环境不静默读取开发者本机凭据。不把项目、地区和 credential scope 放入客户端可覆盖的自由 headers。

### 不属于 M1/M2 的能力

Live WebSocket、Files 上传/下载与 resumable upload、cachedContents 管理、Batch、embeddings、多媒体长任务、Antigravity 专用服务均需独立操作、资源归属和测试契约。

已有权限且与选定上游绑定的 `fileData`/`cachedContent` 引用可按原生生成请求透传；这不代表网关提供了创建、上传或管理这些资源的 API。默认不跟随任意 URL 代客户端下载内容。

## 11. 必须覆盖的验收矩阵

| 编号 | 场景 | 通过条件 |
|---|---|---|
| T01 | 旧数据库升级、新增 Google provider | 迁移成功；旧 provider 配置和凭据引用不变 |
| T02 | 真实入口路由 | `/v1beta` 到达 LLM gateway，而不是 404/落入 OpenAI fallback |
| T03 | 模型路径与 alias | 无正文 model 也能生成；`models/`、后缀、编码不误解析 |
| T04 | 原生正文保真 | 未知字段、tools、签名、多模态部分及空白不被重建 |
| T05 | 原生响应保真 | 多 candidate、复杂 parts、未来字段均可原样返回 |
| T06 | SDK 契约 | 固定版本 SDK 通过配置访问代理；版本/path/auth 行为实测 |
| T07 | 认证隔离 | 上游只有绑定的 Google 凭据；客户端凭据不泄漏 |
| T08 | 恶意配置/请求 | 双凭据、query key、header override、路径绕过被拒绝或按策略处理；日志脱敏 |
| T09 | SSE 任意分片 | 拆 UTF-8/JSON、多帧同包、CRLF、EOF 边界不丢事件 |
| T10 | 结束与 usage | finish 后 tail usage 保留；重复 snapshot 不重复记账；不伪造 DONE/成功 |
| T11 | Blocked 和错误 | 原生 safety response、429、认证失败、5xx 保持正确语义 |
| T12 | 观察器故障 | 超限/异常只标记统计不完整，不打断原生成功请求 |
| T13 | 慢客户端与取消 | 转发/观察缓冲有界；本地资源回收；生成不自动重放 |
| T14 | 模型分页与撤销竞态 | 中途失败不错误移除；迟到结果不复活禁用 provider/model |
| T15 | 目录形状 | Google SDK 能解析，返回 name 均可路由，受授权过滤 |
| T16 | 工具多轮 | 同名多调用、结构化结果、签名 part 关联均正确 |
| T17 | 签名 affinity | 跨不兼容账户/模型/provider 拒绝，不丢弃、不伪造 |
| T18 | 翻译预检 | 不支持字段出站前失败；未开路径真实上游调用次数为零 |
| T19 | countTokens | 不混作生成计费；嵌套 model/alias 一致性、Google 形状正确 |
| T20 | 既有路径回归 | OpenAI Chat/Responses、Anthropic、Codex 同协议转发不退化 |
| T21 | 独立包 | 从真实打包产物创建独立消费者通过；没有宿主依赖泄漏 |
| T22 | 发布证据 | 本地 fixtures、SDK contract、live smoke 分开报告；无凭据明确 skipped |

Fixtures 必须包含独立来源的请求/响应样本或官方 SDK 对模拟服务器的实际输出；不能只用自编 encoder 生成数据再让自编 decoder 验证。所有 fixtures 删除 secrets 与个人正文。

## 12. PR 拆分、依赖与发布

| PR | 内容 | 依赖/发布门槛 |
|---|---|---|
| PR-A | W0 契约基线 + W1 provider/预设/迁移 | 不开启生产 Google 流量 |
| PR-B | W2 原生路由、认证、透明转发 | 依赖 A；fixture/安全测试通过后灰度 |
| PR-C | W3 目录、observer、UI、SDK 集成 | 依赖 B；T01–T15/T19/T20/T22 完成发布 M1 |
| PR-D | W4 共享 Google codec 加固 | 可与 C 部分并行；必须通过消费者兼容测试 |
| PR-E 系列 | W5 每个方向的翻译 | 依赖 D；每条路径独立功能开关与测试发布 |
| PR-F | W6 Interactions native | 独立协议、资源绑定和 observer；不复用未验证的假设 |

Cloud/Antigravity/Files/Live 等后续工作另开 PR 与验收清单，不混入 PR-B 的原生生成修复。

发布使用 provider/surface 级开关；翻译另有开关。先模拟上游，再显式 opt-in 的真实账号 smoke，最后小范围 native 流量。回滚关闭新增 surface/translation，不自动降级到另一种协议或另一个账户。日志不得保存回滚后仍可使用的认证材料。

## 13. 给实施者的执行约束

先让“原生 SDK → Backplane → Google 原生 endpoint”可用，再增加翻译。不要从删除 `unsupported_translation` 检查开始。

提交结果必须包含：实际改动路径、migration 行为、原生/翻译支持矩阵、SDK 版本、运行过的测试命令与结果、未执行的真实验证及其原因。明确哪些任务只是设计、哪些已交付。除经验证的最小需求外，不进行全项目 provider 重构或无关 agent runtime 重构。

## 14. 来源

### 固定源码基线

仓库基线 URL：`https://github.com/gsmlg-opt/backplane/tree/6b42c06b970880ee57652902f6d11d2f5000d818`

第 2 节列出的所有文件均在该基线实际读取；另检查了 `apps/backplane_llama/lib/backplane/llm/route_loader.ex` 的现有 Relayixir upstream 配置。

既有设计参考：Agent Note `67dda4ce-869c-4746-811a-016f23b5ebc4`，revision 1，标题《Backplane AI Protocol — 统一 API、双向翻译、Auth/Models 与 TestKit 设计（Proposed）》。其“原生透传、严格翻译、provider state affinity、宿主负责凭据与执行”的边界延续至本计划；不把旧 proposed 文档当作最新实现证据。

### Google 官方参考（2026-09-20 核对）

- [G1] Gemini API reference：`https://ai.google.dev/api`
- [G2] OpenAI compatibility：`https://ai.google.dev/gemini-api/docs/openai`
- [G3] GenerateContent、streamGenerateContent、Part、FunctionCall/Response、UsageMetadata：`https://ai.google.dev/api/generate-content`
- [G4] Models / 分页与模型元信息：`https://ai.google.dev/api/models`
- [G5] Thinking / 当前 Interactions 事件示例：`https://ai.google.dev/gemini-api/docs/thinking`
- [G6] Google Cloud inference：`https://docs.cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference`（当前会重定向到 Google 新的官方文档路径）
- [G7] 官方 Python GenAI SDK 文档：`https://googleapis.github.io/python-genai/`

官方 SDK 的接口、默认版本和自定义 endpoint 行为会演进；实施时以锁定版本实测结果为准，不能用本计划代替 wire contract 测试。
