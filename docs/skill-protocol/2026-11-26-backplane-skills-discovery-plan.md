# Backplane、Synapsis 与 sigma 的 Skills 发现与加载开发计划

**目标**　在 Backplane 的「Skills → 配置」选出会话默认可见的技能。Synapsis 和 sigma 连接同一来源后，启动时取得这些技能的摘要，按任务搜索其余技能，选中后读取精确版本的正文和随包文件。用户可以关闭主目录的全局技能来源。

**阶段**　2026-11-26 制定，2026-11-27 完成本地候选实现及三端联调。开发起点为 Backplane `1e2a8cc6`、Synapsis `f41dcdba`、sigma `483451f`。本文路径均相对于所在任务对应的仓库根目录。

## 可观察行为

| Backplane 中的技能 | 新会话取得的默认目录 | 关键词搜索 | 读取 |
|---|---|---|---|
| 已启用、已发布、勾选「总是返回」 | 返回摘要 | 匹配时返回 | 选中后按 revision 和 digest 读取 |
| 已启用、已发布、未勾选 | 省略 | 匹配时返回 | 遵循同一套来源、Agent 分配和调用策略 |
| 已禁用、未发布或当前版本不可用 | 省略 | 省略 | 拒绝为新发现结果加载 |

- 「总是返回」是 Backplane 上按稳定 skill ID 保存的展示选择。勾选不会授予客户端权限；取消勾选不会撤销已有的显式分配。搜索不会自动分配技能或修改常驻列表。
- 建议新旧技能默认均未勾选。空选择产生空的默认目录，搜索仍可用。既有客户端继续使用原有全量目录；切换新模式后，空集合也有明确含义。
- 发现阶段只传描述信息。客户端以来源 ID、skill ID、revision、digest 标识结果；同名技能分别展示。文档声明仅限手动调用时，保留显式选择，模型自动目录遵守该声明。
- 开关只管用户主目录的全局 skills。仓库 `<workdir>/.agents/skills`、显式分配和私有 workshop 沿用各自策略。远程异常或空结果不能重新打开本地扫描。

## 1. 先做一次跨仓库协议验证

- [x] 在隔离的开发数据中通过已有归档上传入口发布一个合法 skill，含 `SKILL.md` 和 `references/checklist.md`。准备一个只出现在正文中的词，例如 `quartzneedle`，并记录 skill ID、revision、digest 和引用文件的预期内容。
- [x] 用 Synapsis 与 sigma 当前锁定的 SDK 和各自的 Backplane 连接指向同一公共 HTTP origin；开发默认端口为 4220。凭据通过现有 credential supplier 提供，要求 `skill::read`。分别请求 catalog、resolve、artifact，记录两端拿到的精确引用和验证结果。
- [x] 再走两端产品入口：Synapsis 的来源同步、Agent 分配和读取；sigma 的远程目录、显式调用和资源读取。分别记录 SDK 与产品层证据。重点复现 Synapsis 将字符串 `"ready"` 与原子 `:ready` 比较，以及返回正文后清理已解包目录的现象。
- [x] 保存这组 fixture 作为后续回归基线。之前只读调查的本机样本为 211 个已启用的 GitHub skills，全部 pending、零归档、零 current revision。用小样本先验证接口，存量数据待发布链路验证后再处理。

现有入口在 Backplane 的 `apps/backplane_api/test/backplane/api/skill_protocol_http_integration_test.exs`、Synapsis 的 `apps/synapsis_mcp/test/synapsis/backplane/consumer_integration_test.exs` 和 sigma 的 `apps/sigma_session/test/sigma_session/skills_remote_source_test.exs`。

## 2. Backplane 让已有来源产生可消费的版本

- [x] GitHub 同步先把所选 branch 解析到一个 commit，按该 commit 获取每个选中 skill 的完整根目录。保留原始 SKILL.md 和相对资源，在现有 bundle 边界内校验、打包、发布。仅修改引用文件也要产生新 revision；相同内容重试应保持同一 revision。
- [x] 将数据库自建 skill 的创建、编辑接到现有 publication 逻辑，按其实际保存的元数据和正文生成单文档包。归档上传继续走已有完整包路径。创建或切换 current revision 时，保证 blob、清单和可搜索内容对应同一版本，失败不能留下可发现的半成品。
- [x] 从既有来源重新同步存量 GitHub 记录，按原 ID 对齐，保留启用状态及常驻选择；自建记录可从数据库内容补发。先提供预览和逐项结果，再执行指定来源。不能恢复原目录、slug 冲突或文档无效时给出诊断，避免用只有正文的包冒充完整目录。既有 archive backfill 只处理已有归档，不能用于恢复上述 211 项的资源。
- [x] 回归覆盖完整目录、仅资源变化、重复同步、禁用后再同步、失败后重试，以及已有归档照常下载。验收以真实 resolve/artifact 和文件内容为准。

主要文件在 `apps/backplane_skills/lib/backplane/skills/` 下的 `sources/github.ex`、`skill_sources.ex`、`sources/database.ex`、`publication.ex` 和 `ingest.ex`。

## 3. Backplane 配置菜单、发现协议与 SDK

- [x] 在 `skills` 表增加布尔字段 `always_return`，默认 false；迁移归属 `apps/backplane_system/priv/repo/migrations/`。以稳定 ID 更新字段，让同步写入来源内容时保留管理员选择。
- [x] 在 Skills 导航添加「配置」，建议路由 `/skills/config`。提供可搜索、分页的技能列表，展示启用状态、发布状态和「总是返回」。保存只更新用户实际改动的 ID，避免跨页筛选或两位管理员编辑不同技能时丢失选择。复用 Admin 路由、共享导航和 DESIGN.md 的交互规范。浏览器验收跨页勾选、保存重开、空选择及窄屏操作。
- [x] 扩展 `GET /skill-protocol/v1/catalog?view=always`，按稳定 ID 分页。保留无 view 时现有全量响应和既有过滤语义。增加 `GET /skill-protocol/v1/search?q=quartzneedle&limit=10`，同一读取权限、同一可见发布范围，支持分页；搜索总是包含匹配的常驻项。
- [x] 搜索名称、描述、标签和正文，按相关性并用 ID 打破并列。复用 PostgreSQL 全文检索，但确保命中内容和返回 revision 一致。现有 search_vector 未含标签，需显式覆盖标签；现有 catalog 的 q 仅过滤名称。补测名称精确命中、正文独有词、标签独有词、重复名称、并列跨页、禁用项及未发布编辑内容的隔离。
- [x] 更新 `backplane_skill_protocol` 的 Client、Source.Backplane、Wire、JSON schema 及 `docs/skill-protocol/contract-v1.md`。新增 client 的常驻目录和 search 操作，复用既有超时、取消、字节上限与凭据机制。返回足够的调用资格元数据，让两端识别仅手动调用的技能，无需下载归档。
- [x] 兼容性测试覆盖两个方向。旧客户端请求无 view 的 catalog，严格解码器仍能读取同一结构。新客户端请求常驻目录时要求响应明确确认应用了 view（建议仅在 opt-in 响应中加 `view: "always"`）；旧服务器可能忽略未知参数并返回全量，此时新客户端提示来源需要升级。cursor 绑定操作、view、查询、字段和授权上下文，禁止把全量或搜索 cursor 用于常驻目录。
- [x] 用真实客户端与 HTTP 服务验证响应、401/403、无效 cursor、第二页和无匹配结果。确认两次发现请求都没有发起 artifact 下载；补测选择某个结果后只准备对应的精确版本。

服务端入口为 `apps/backplane_skills/lib/backplane/skills/{publication,protocol_v1_router,search}.ex`；SDK 入口为 `apps/backplane_skill_protocol/lib/backplane/skill_protocol/{client,wire,descriptor,source/backplane}.ex`。管理端在 `apps/backplane_admin/lib/backplane/admin/{router,components/layouts}.ex` 和同目录的 `live/`。

## 4. Synapsis 接入常驻目录、搜索和资源读取

- [x] 复用现有 Backplane 连接、provider 凭据与 `/settings/skills`。保留现有完整清单同步和按 Agent 分配能力。常驻目录用独立的会话发现操作读取；不能把常驻列表或一页搜索结果交给完整清单同步的删除/失效逻辑。
- [x] 修正 `"ready"` 类型判断，将单页限制与全目录遍历预算分开。有明确预算上限时，达到上限报告部分结果并保留未见记录。用至少 101 条已发布描述符覆盖第二页。
- [x] 在启用了该来源的原生 Agent 会话中接入常驻描述符，按来源和调用资格组装 prompt 与 reader。保留现有 Agent 分配作为读取约束。扩展原生 `synapsis::skills_search` 支持显式搜索该 Backplane 来源；结果区分当前可读和需要分配，用户可走既有分配入口。只在读取时按精确引用获取正文或 manifest 中列出的相对资源，操作结束后清理。
- [ ] 验证原生 Agent 仅使用受信任的显式本地根和 workshop。对指向全局目录的显式配置说明其与自动扫描的边界。Synapsis 转接 sigma 的会话由实际执行端应用来源策略，并测试新建与恢复。外部 Codex 子进程自行发现技能，须单独用实际版本核实可控制的启动/恢复参数；本计划的原生支持不能当作外部 Codex 验收证据。

入口为 `apps/synapsis_mcp/lib/synapsis/backplane/{client,sync,skill_loader}.ex`、`apps/synapsis_core/lib/synapsis/{skill_catalog,skill_reader}.ex`、`apps/synapsis_agent/lib/synapsis/agent/tools/skills.ex`、`apps/synapsis_web/lib/synapsis_web/live/skill_live/index.ex`。

## 5. sigma 跳过全局扫描，并向模型提供搜索与读取

- [x] 在 `/settings/skills` 增加「加载 ~/.agents/skills」，缺省 true。集中在发现全局目录前判断。关闭后，设置页、项目页、Web/协议会话、slash 补全、提示词与原生工具都不触发该目录遍历；仓库目录继续可用，原有逐项禁用选择可在重新开启后恢复。
- [x] 复用既有 skillSources、凭据、来源开关和显式离线配置。为采用 Backplane 常驻/搜索的来源提供显式设置，兼容既有仅手动调用的来源。加载常驻摘要时遍历其分页，保持本地目录读取不触发远程网络。Web 和协议会话使用一致的有效目录。
- [x] 在 `skills::list/read` 旁增加 `skills::search`。设置页与运行时共用远程搜索操作，结果携带精确引用。对允许模型使用的远程技能沿用现有 RemoteSource 准备与资源读取，取代统一标记 manual_only 的行为；文档本身的调用限制仍优先。UI 上的手动调用及现有精确离线缓存继续按原规则运行。
- [x] 用临时全局目录和仓库目录写入不同标记技能，验证开关关闭后目录发现函数未访问全局路径；再新增全局文件，确认它仍未出现。覆盖同名来源、仅手动技能、远程未授权、来源停用和恢复会话。在线失败不能切换到已关闭的本地目录。

入口为 `apps/sigma_session/lib/sigma_session/{skills,config_manager}.ex`、`apps/sigma_session/lib/sigma_session/skills/{catalog,remote_adapter,remote_source}.ex`、`apps/sigma_agent/lib/sigma_agent/backplane/{native_tools,skill_resources}.ex`、`apps/sigma_web/lib/sigma_web/{live/settings_live,protocol_session_options}.ex`。

## 6. 集成、测试与完成条件

步骤 1 最先执行。步骤 2 和 3 共用 Publication，由服务端统一集成；SDK 数据结构定下后，Synapsis 和 sigma 两项可并行。跨仓库开发时先用同一候选 SDK 在隔离环境联调；交付采用已发布的兼容 Hex 版本并分别核对 lockfile。实施本计划不隐含发布、部署或批量改写现有开发库的授权。

在各自仓库的开发环境先运行下列已有测试，再加入各任务新增的针对性用例。预期为相关套件全部通过。

| 仓库 | 聚焦命令 |
|---|---|
| Backplane | `mix test apps/backplane_api/test/backplane/api/skill_protocol_http_integration_test.exs apps/backplane_api/test/backplane/api/skill_protocol_router_test.exs apps/backplane_skills/test/backplane/skills/publication_test.exs apps/backplane_skills/test/backplane/skills/ingest_test.exs apps/backplane_skill_protocol/test/backplane/skill_protocol/client_test.exs` |
| Synapsis | `mix test apps/synapsis_mcp/test/synapsis/backplane/client_test.exs apps/synapsis_mcp/test/synapsis/backplane/sync_test.exs apps/synapsis_mcp/test/synapsis/backplane/skill_loader_test.exs apps/synapsis_core/test/synapsis/skill_reader_test.exs apps/synapsis_mcp/test/synapsis/backplane/consumer_integration_test.exs` |
| sigma | `mix test apps/sigma_session/test/sigma_session/skills_remote_adapter_test.exs apps/sigma_session/test/sigma_session/skills_remote_source_test.exs apps/sigma_agent/test/sigma_agent/backplane_skill_resources_test.exs apps/sigma_web/test/sigma_web/protocol_session_options_test.exs apps/sigma_web/test/sigma_web/live/settings_live_test.exs` |

最终使用同一 Backplane 开发实例、两个真实客户端和各自的原生会话验收：

- [x] A、B、C 均已发布，只勾选 A，禁用 C。刷新后两端的 Backplane 默认目录均只出现 A。取消全部勾选，默认目录为空，B 仍能搜索。
- [x] 用只存在 B 正文的词命中 B，搜索阶段 artifact 请求为零。模型能读取获准使用的 B 及其引用文件，两端核对到相同 revision、digest 与文件内容。未获分配的 Synapsis Agent 能发现 B，并清楚显示其读取条件。
- [x] 只更新 B 的引用文件，刷新后两端获得新 revision；仍持有旧引用的会话读取精确旧版本或收到明确的版本不可用，不能读到混合内容。禁用 B 后，在线的新发现与新读取按服务端策略拒绝。
- [x] 本机全局目录、仓库目录和 Backplane 都放入可区分的技能。关闭全局来源、重启并恢复会话后，sigma 只保留允许的来源。分别记录 Synapsis 原生和 Synapsis 转接 sigma 的实际结果。
- [x] 验收记录分别给出 Backplane 发布/搜索、SDK、Synapsis 原生和 sigma Web/协议会话的版本、观察结果及未验证边界。覆盖来源断开、权限不足与空结果，界面能区分这三种状态。

## 2026-11-27 本地验收记录

| 范围 | 实测结果 |
|---|---|
| Backplane 发布 | 在隔离数据库按实际配置取 `obra/superpowers` 的 `brainstorming`，commit `22f0b463e7a5e579904dd6211a520321035526f7`。完整包有 8 个文件，artifact 重新计算的 SHA-256 与 resolve 一致。这次隔离验收仅发布样本。共享开发库存量的恢复结果见下文。 |
| 管理 UI | Chromium 在 1200px 宽度跨两页勾选、保存；390px 宽度重开后两项选择均保留，LiveView 已连接。 |
| 首次发现与权限 | 同一真实 HTTP 服务，仅 A 常驻，B 通过正文关键词命中，artifact 请求为零。Synapsis 未分配时显示分配条件，分配后能读；sigma 能从原生搜索结果读正文和附件。缺少令牌和作用域不足分别有 HTTP 测试。 |
| 更新与禁用 | 24919 隔离服务仅修改 B 的引用文件。两端从相同 v1（digest 前缀 92f2b60d）读到 v2（2d79589e）；v1 精确引用仍取得 v1 或原会话快照明确失效。禁用 B 并取消勾选 A 后，两端新默认目录和关键词搜索均为空，已有在线读取被拒绝。 |
| 执行端策略 | Synapsis 实际连接 sigma 的 app-server，验证新建、断线恢复，以及替换 sigma BEAM 后恢复同一会话。实际 Agent context 均有 A 和仓库技能，无 B 和用户全局目录标记。使用 MockProvider，未发起模型回合。 |
| 聚焦测试 | Backplane 96 项。Synapsis 当前 lock 167 项、候选 SDK 172 项，另有 sigma adapter 7 项。sigma 当前 lock 87 项、候选 SDK/runtime 89 项。以上均零失败。 |

**交付边界**　三个 main 工作树均为未提交的候选修改。Backplane 测试库已执行迁移，开发共享服务和生产环境未部署。客户端当前 Hex 锁保留，旧依赖明确报告不支持新能力。发布兼容的 Skill Protocol 和 Agent Runtime、更新两端 lock、迁移目标数据库并重复部署验收仍待执行。[发布跟踪 #193](https://github.com/gsmlg-opt/backplane/issues/193)

**其他未验证项**　Synapsis 原生 Agent 与转接 sigma 均已验证。外部 Codex 0.171.0 的协议 schema 已核对，其独立进程启动和恢复时能否关闭全局目录仍未证实。Backplane 严格 Credo 扫描报告 4 条本次变更文件以外的发现，位于 Agent Runtime 的已有测试。尚未运行全仓测试或 Dialyzer。

## 原生会话创建技能

2026-11-27 扩展了候选协议。Synapsis 的 `synapsis::skills_create` 和 sigma 的 `skills::create` 都使用已配置的来源和凭据，提交唯一 slug、显示名称、描述和 Markdown 正文。Backplane 使用 `skill::write` 授权，在同一事务中生成数据库技能并发布单文档包，返回精确版本。新技能可搜索，常驻选择仍归管理员。已有 slug 返回冲突，创建请求遇到不确定结果时不会自动重发。

在同一个隔离的 Backplane HTTP 实例中，两个原生工具分别创建了技能，双方都用正文关键词找到了对方的版本。Synapsis 在分配前拒绝读取，显式分配后读取成功。sigma 使用创建响应的 package 读取了正文。Backplane 聚焦测试验证了匿名、只读和只写凭据的边界，以及冲突、无效文档回滚和精确版本读取。启用此能力还需发布候选 Skill Protocol 和 Agent Runtime 并更新消费者依赖；共享开发库和现有凭据配置均未因这次联调而改写。

## 共享开发库的 211 项存量恢复

2026-11-27 在 `10.100.10.28:4220` 的 `backplane_dev` 完成。11 个来源只保存了分支名 `main`。按当前分支预览时，有 16 个原目录缺失，另一个 slug 对应两个路径。恢复使用各记录上次同步时间附近的上游提交，并用原 ID、所属仓库、库内正文哈希及描述核对身份。共使用 18 个历史提交。归档保留全部文件，发布沿用 `Publication.publish_github/2`，并为每项记录具体 commit 和源文件路径。原有 211 项启用状态及 211 项常驻选择均保留。

发布后通过公共 HTTP 接口遍历普通及常驻目录，均按 100、100、11 条返回。逐项按精确 revision 请求 resolve 和 artifact，211 个归档的 SHA-256 与清单一致，解包后的 2,183 个文件也与源提交逐文件一致。协议全文搜索 `review` 返回 81 项，首项为 `github/review`。同一主机 4580 端口的 Sigma 设置页通过已配置来源打开目录，首屏显示 20 项，搜索 `review` 显示 4 个名称匹配结果，包括 `Backplane:github/review`。
