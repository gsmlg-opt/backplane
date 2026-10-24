# Host Memory 过滤完整性与精确读取

状态：用户已批准并实施，本地范围验证通过；1.10.34 尚未发布。日期：2026-10-24（Asia/Shanghai）。
基线：`main@9c67cc183c6c37374d2eb2a41264709df8eef78e`。
范围：internal requests #83、#84。下一可用 patch 目标为 **1.10.34**；
此前的 1.10.33 候选 tag 已存在，但其发布失败。

## 问题与成功标准

#83：canonical 查询参数进入 fallback 后，committed mirror 丢失 project、type、tag、
agent、facets 和分页等约束；private/shared provisional overlay 也未保持 project。
同一授权 partition 内多个项目包含相同文字时，项目限定的查询可能成功返回其他项目内容。

#84：Host Agent 没有读取单个 canonical `bpm_memories` record 的公开方法。
现有 `Memories.get/2` 只检查 partition 和 deleted_at，缺少公开读取所需的到期、
lifecycle、project/source 约束，不能直接暴露。

成功标准：每个返回记录都符合该次请求的授权和过滤条件；无法表达的约束明确报错。
新增按真实 canonical ID 读取的接口，HTTP 与 MCP 使用相同实现；
读取独立重新检查权限和可见性，不因之前 search 成功而跳过。

## 方案比较

| 方案 | 行为与代价 |
| --- | --- |
| **推荐：保留现有 fallback，按能力校验；精确读取先提供 online-only** | 使用现有 partition、Access 和 Store 边界；能正确表达的过滤条件在选择候选前执行，其余明确拒绝；不需要 mirror schema migration。 |
| 完整扩展 mirror 的过滤、分页和精确读取 | 需要补充 generator、creation time、facets 和稳定分页语义，并处理 provisional ID 与 canonical ID；超出本轮最小修复。 |
| 所有读取改为 canonical-only | 容易界定一致性，但会移除现有 recall/list 的离线能力，不符合本轮修复范围。 |

## 所有权和授权边界

- `MemoryToolContract` 负责公开 schema、permission、发现和 routing metadata。
- Host Agent 沿用 `MemoryService -> MemoryFacade -> MemoryProxy` 和 authenticated host channel。
- Server `Memory.Service` 从已认证 private default 或明确授权的 `memory_access_id` 派生 partition。
- 所有权是 `(memory_space_id, scope, namespace)`；记录的 host/client 是来源信息。
  shared 读取可以读取同一授权 partition 中由其他 host 创建的记录。
- shared access 沿用 request ticket、generation、authority version、撤销 fence 和最终响应重验。
  不把新读取接入旧 mutator 的 generator-host/client 限制。
- 新接口拒绝调用者提供的原始 partition、namespace、scope、host/client、authority version。
  既有方法的 scope 绑定及鉴权错误优先级保持现有契约。
- 不创建新的存储或授权系统，不修改无关 Memory UI、Host Agent worker、devenv 和依赖改动。

## #83：过滤校验和 fallback

### 参数与在线行为

在用户参数与可信 partition 参数合并之前，按 recall/list 各自 schema 校验名称和类型。
未知过滤字段、错误类型和非法分页不能因为 transport error 而成为成功的 fallback。
正常 core HTTP 路由的 agent_id 在 context 中，不注入 read args；它不是显式 agent filter。

canonical 的权限、协议、参数和过滤错误直接返回，只有既有 allowlist 中的 transport error
才允许 fallback。legacy canonical recall 也不得静默忽略其不能表达的 project 等约束，
应明确拒绝；不新增 legacy 检索实现。

### 能力矩阵

| 请求条件 | fallback 行为 |
| --- | --- |
| recall 的 query、limit、project | 保留现有 bounded substring recall；project 使用 canonical 的 NFC、空白折叠、trim 和 1024 字节规则，精确匹配 `metadata.project`。空 project 按既有 recall 规则等同未指定。 |
| list 的 type、tag、普通 q、limit | mirror 和 provisional 均在候选选择前执行；limit 按各方法公开默认值统一，保持现有上限。 |
| list 的 agent_id | provisional-only 路径可使用真实 generator 字段；需要 committed mirror 时返回 `unsupported_filter`，不以 metadata.agent_id 代替缺失字段。 |
| recall 的显式 agent_id/tag、非空 facets/temporal/entity hints、显式 token_budget/channel_weights/include_working | fallback 返回 `unsupported_filter`；不冒充 canonical V2 的过滤、ranking 或 budget 行为。未显式设置 include_working 时，排除 working 记录。 |
| list 的 project、facets、source/session 等未公开字段；recall 的 type/q/offset | 在请求校验阶段明确拒绝，不发明新的过滤语义。 |
| list 非零 offset | 在线 canonical 分页保持现有行为；committed mirror 参与时明确返回 `unsupported_filter`；既有 private provisional-only 路径保留正确的过滤后分页。 |
| list q 含 `%`、`_` 或反斜线 | fallback 明确返回 `unsupported_filter`，避免把 canonical ILIKE 通配语义当作 literal substring。canonical 既有 q 行为不扩展。 |

错误应携带稳定的 `unsupported_filter` 分类和不含内容的字段名；schema/type 错误为
`invalid_arguments`。空 facets/entity hints 不产生过滤约束，可按空集合处理。

### 在线 overlay

canonical 成功不免除 pending/acknowledged upserts 的过滤义务。project 和默认的 working
排除规则在在线 overlay 同样执行；type/tag/q 等可表达谓词也必须在候选选择前应用。

当请求携带本地无法忠实表达的 facets、temporal、entity、ranking、budget 等约束，
而 partition 中存在通过其他已知谓词、原本会加入结果的 upsert 时，整个请求明确返回
`unsupported_filter`。不以空 overlay 或静默遗漏掩盖无法保证的过滤。
该存在性判断在 cap 前执行，不能只检查截取后的前 100 条。
若没有这样的 upsert，可返回已由 canonical 完整执行约束的结果，继续应用同 partition 的
pending forget；不自行重新 ranking 或扩充 canonical budget。

### 候选选择与合并

project/type/tag 谓词必须进入 mirror/private/shared/acknowledged overlay 的选择过程，
在 limit、offset 和 overlay cap 之前执行；不能先截取 100 条再过滤。
mirror 沿用 revision、完整 partition、lifecycle 和 expiry 检查。
缺失或非字符串的 stored project 不能满足非空 project filter。

所有公开结果集合，包括 results/hits/items/upserts 和 provisional sideband，遵守相同谓词。
同 partition 的 pending forget 仍可抑制相应 canonical ID；不能因为删除操作不含 project
而绕过删除覆盖。在线 list 的 canonical 分页与 provisional_results 保持分列。
不声称 mirror 的 canonical-ID 排序等于 canonical 的创建时间排序。
不为 shared 路径新增 provisional-only fallback：其仍要求既有 committed mirror 与有效 lease。

## #84：memory::get

### 输入和可发现性

新增 `memory::get`，permission 为 `memory.read`，仍属于 canonical overlap 路由。
为它单独声明 `authority=canonical`、`consistency=canonical`、`availability=online`，
不继承其他 overlap 方法的 offline metadata。

输入对象 `additionalProperties: false`：

- `id`：必填，canonical `bpm_memories` UUID。
- `memory_access_id`：可选的已授权 access UUID；省略则选择 designated private default。
- `project`：可选非空 UTF-8，采用上述规范化后最多 1024 字节，精确匹配。
- `source`：可选对象，只允许 `repository_id`、`checkout_root`、`cwd`，至少指定一项。
  每项为非空 UTF-8 字符串、最多 4096 字节；未知或无法规范化的约束明确报错。

source 复用 `MemoryRepository` 的来源规范化和去凭证规则；repository_id 采用规范仓库标识，
路径字段精确匹配已存来源，不从本地路径猜测仓库。全部 source 条件必须由同一条
`metadata.repository_sources` association 同时满足，不能跨两条来源拼接匹配。
没有来源证据的记录不满足指定的 source 条件。

它仅读取 canonical `bpm_memories` record，包括满足可见性条件的各 memory_type；
不会猜测 lesson/crystal/summary/observation、
trace 或 device slot 的表。Recall 返回的其他 kind 不能假定可由本接口读取。

### 独立读取、结果和界限

在 Memory domain 新增专用 public point-read query，保留内部 `Memories.get/2` 的既有用途。
每次查询同时要求准确 partition、未删除、未过期、lifecycle 不为
superseded/archived/tombstoned，并应用本次 project/source 约束。
记录不存在、不符合可见性或 project/source 不匹配都返回 `not_found`，不泄露其他 partition 的存在性。
shared grant/read capability、connection generation 和 authority version 在释放响应前再次校验。

返回 `{record, mode, authority, consistency, stale, history_available}`：

- record 包含真实 id/canonical_id、kind=memory、完整 content、memory_type、tags、
  lifecycle_state、expires_at、inserted_at、updated_at、project，以及真实来源 provenance。
- provenance 包含记录自身的 source_host_id/source_client_id、agent_id/session_id 和
  规范 repository_sources；未知值保持 null/空集合，不写入请求者身份。
- mode=online、authority=canonical、consistency=canonical、stale=false、history_available=true。
- 完整编码后的 host reply envelope 必须符合既有 524,288 字节限制。
  在 `Access.finish_request` 之前将超限转换为 `payload_too_large`，避免现有越界分支
  将它当作 authority_changed 并 fence access；direct/API 成功 envelope 使用相同上限。
  不截断原始内容，不扩展为不受限的 provenance 图遍历。

精确读取只走 canonical point query。transport outage 返回 `canonical_unavailable`；
不扫描 list 页、不读 recall trace、不读取 mirror/provisional，也不把本地缺失当 canonical not_found。
旧 server 返回可识别的结构化 unknown-method/tool 错误时，映射为 `unsupported_operation`，
不自动改走通用 HubProxy；不把一般协议错误猜测成方法不受支持。

### HTTP 与 MCP

Host direct `POST /memory/:agent_id/call/get` 与 `memory::get` MCP 调用使用同一 facade 实现。
Gateway 的公开 Memory HTTP 精确读取路由也调用同一 domain Service，不能保留较弱的裸 get 路径。
对于新增 get：not_found -> 404，unauthorized -> 403，canonical_unavailable -> 503，
unsupported_filter/invalid_arguments -> 400，payload_too_large -> 413，unsupported_operation -> 501。
MCP 保持既有 error envelope，携带相同稳定分类；成功 record 内容保持一致。
其他方法的 HTTP status 不随此项新接口整体重写。

## 验证与提交边界

先增加能复现过滤丢失和精确读取越界的 scoped regression，再实施最小修复：

1. Shared schema/permission/discovery：get online metadata 和 host/server schema parity。
2. 两个 project 的相同 query；较早/较新的无关记录超过 100 条时，匹配项仍在 cap 前被选中。
3. private/shared 的 canonical、mirror、pending 和 acknowledged overlay；删除覆盖、过期及生命周期。
4. 不支持的 facets/agent/temporal/ranking/pagination/通配过滤明确失败；权威失败不触发 fallback。
5. get 的完整内容、真实 provenance、project/source 的同 association 匹配及未知过滤错误。
6. 精确 partition 隔离；跨 origin host 的合法 shared read；撤销、旧版本和旧 connection 的拒绝。
7. search 成功后再删除、到期或撤销权限，后续 get 重新验证；其他 Recall kind 不被误读。
8. offline get 无 mirror/overlay/list/HubProxy 调用；oversize 明确失败；HTTP/MCP 行为一致。

测试限定到 contract、Memory domain、Host Agent facade/proxy/router、Access 和相关 API/channel 测试。
仅在实际有变更时运行适当的编译、format、Credo、Dialyzer 和 CI contract 检查。
实现已提交至远端 main。按用户指示，发布候选从远端 main@0166c5e2 的隔离 worktree 准备，
只推送本轮依赖及版本更新；本地 main 的五个无关提交保持原样。

## 发布前提

DuskMoon native 下载阻塞 `duskmoon-dev/duskmoon-bundler#5` 已修复，10.0.4 的正式发布、
公开 artifacts 和四组 published-native 消费测试已通过；Backplane 已更新八个既有依赖包。
按仓库 Blocker Policy，确认上游修复并更新依赖后才恢复发布；不增加本地绕过。
新的发布必须对新源码重新验证，完成正式 qualification、所有构建和 installed smoke，
并确认 GitHub assets/checksums、五个 Hex/HexDocs 包、GHCR 以及 main/tag 来源。
本设计和本地测试都不代表已发布、Synapsis 已接入或生产已部署。

## 实施与验证

实现保持上述 contract、Service、Access 和 Store 边界，没有 schema migration。
默认 private 的精确读取在最终鉴权时比较实际查询的完整 ownership tuple，
防止读取期间切换 default 后，用新 partition 的权限释放旧 partition 内容。
pending/acknowledged forget 的标识选择独立于 100 条 upsert 内容上限；
删除覆盖不能因 upsert 填满候选而消失。provisional-only 响应超出既有大小上限时明确失败。
Host proxy 在发送 get 前检查选定 channel 与完整 connection generation，响应前再次校验；
forget 标识以 prepend/reverse 线性累积，512 条真实删除记录的回归确认顺序及抑制行为。

本地范围验证覆盖 contract、Memory、Host Agent、API/channel，共 464 项测试通过；
修改文件的格式、warnings-as-errors 编译、scoped strict Credo 和 14 个修改模块的
Dialyzer 检查通过（沿用仓库既有 ignore 规则）。权限切换和删除覆盖问题均有先失败后通过的回归。
设计一致性与代码质量复审均通过。首次最终测试中两个既有 API 测试超过 100ms 消息等待；
未修改代码的单独复跑及相同 seed 的完整复跑均通过。

远端 main@0166c5e2 已通过全部五个 CI job 和20个 application Test job。
上游10.0.4 正式发布 run40063695995 已成功，47个 native archive 和九个 Hex 包均可用。
安装矩阵 run40066226848 的公开 artifacts 及四组 published-native job 通过；另有
registry、ARM musl fixture 因第三方 lazy_html 下载及缺少 make 的源码回退失败，upgrade 未执行。
因此不宣称整个上游安装矩阵通过。本轮使用实际消费的 DuskMoon native 验证及 Backplane
自身的完整 qualification、构建和 installed smoke 作为发布证据，不新增下载绕过或跳过检查。

隔离1.10.34 候选在10.0.4 依赖下通过 warnings-as-errors 编译、修改 manifest 格式、
542项范围回归，以及 CI contract8/0、release config26/0、Hex dependency5/0。
frozen npm 安装和公开端、管理端的 Tailwind/JavaScript 构建均通过；
四个最低版本约束和八个 lock entry 之外的依赖保持不变。

候选049c5909 的六个远端工作流均通过。首次正式发布 run40068713984 在 qualification
之前因第三方 MDExNative0.2.12 下载的 GitHub 重定向头超过 OTP10240字节上限而失败；
没有发布 tag、归档、Hex 包或镜像。锁定版本已正式支持 `artifact_source: :cloudflare`，
本轮在 compile-time config 中选择这一官方分发源。四个 Linux GNU/macOS x64/arm64
归档无重定向且 SHA256 与包内公布值一致；隔离冷启动复现 GitHub 失败，并验证 Cloudflare
下载、warnings-as-errors 编译及 Markdown native 调用成功。版本、目标和完整性校验不变，
不新增 downloader 或源码回退。该配置候选仍须新源码 CI 和完整正式发布验证。

源码9504a2bf 的新源码 CI、20项应用矩阵及双平台 Audio 均通过。正式发布40070601038
通过 qualification、六个平台构建、打包后迁移幂等及 HTTP 资源检查，发布25个 GitHub 资产。
运行随后因 runtime 在 umbrella 内打包时排除两个内部协议依赖而失败，Docker 未执行。
同一源码导出到独立目录后 Hex build 和文档生成通过，101个包内文件逐字节一致，两个协议
依赖在 Hex metadata 中正确声明。其余四个 Hex 包及版本化文档已存在；MCP 的 job 虽被取消，
包和文档实际上已发布。因此仅修复发布编排，通过既有 qualified recovery 补发 runtime，
再构建相同9504a2bf 的镜像。tag 和产品源码保持不变；新 main 的编排修复不替换已验证源码。
验证记录必须保留原流程失败，并分别确认限定恢复流程、镜像及发布页，不能把恢复写成原流程成功。

## 可复查源码

- `apps/backplane_memory_contract/lib/backplane/memory_tool_contract.ex`
- `apps/backplane_memory_contract/lib/backplane/memory_repository.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/memory_facade.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/memory/mirror/store.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/memory.ex`
- `apps/backplane_host_agent/lib/backplane/host_agent/memory/access.ex`
- `apps/backplane_memory/lib/backplane/memory/service.ex`
- `apps/backplane_memory/lib/backplane/memory/memories.ex`
- `apps/backplane_memory/lib/backplane/memory/partition_identity.ex`
- `apps/backplane_memory/lib/backplane/memory/recall/query_plan.ex`
- `apps/backplane_memory/lib/backplane/memory/recall/channels.ex`
