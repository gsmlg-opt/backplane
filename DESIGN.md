# Backplane UI 实现规范

本文件约束 Backplane 管理界面的新增与修改，供开发者、代码代理和评审者共同遵守。目标是让配置入口、列表操作、表单和状态反馈保持一致。页面以清晰、紧凑、易操作的管理工具为主，不采用营销页式装饰。

已有页面尚未完全符合本规范；它们不是新增实现的例外依据。修改页面时在任务范围内对齐，未经授权不开展全站重构。本规范不改变领域状态机、权限或 API 契约；明确的任务要求优先，持续适用的新决定应同步更新此文件。

## 1. 技术与组件

- 使用 Phoenix LiveView、HEEX、Tailwind CSS 4 和 DuskMoon。业务 UI 属于 `apps/backplane_admin`，业务验证与持久化仍由所属领域 context 完成。
- 首选 `phoenix_duskmoon` 的 `dm_*` 组件；样式使用 `@duskmoon-dev/core/plugin`。按需使用 DuskMoon Elements，避免注册未使用的全部组件。
- 禁止引入 DaisyUI、其他 CSS 组件库或 Phoenix 默认 `core_components.ex`。不为单个页面增加新的 UI 框架、字体依赖或独立设计系统。
- 组件参数、插槽和 hook 以当前安装版本为准。先检查已有实现及依赖源码，不能根据旧示例猜测接口。
- JS hook 只负责浏览器交互，如原生 dialog 的打开、关闭和焦点；配置状态、验证及授权由服务端负责。复用现有 hook，避免重复实现。
- 确认的 DuskMoon 缺陷按 [AGENTS.md](AGENTS.md) 的上游问题流程处理；阻塞问题不得用本地替代组件绕过。

## 2. 信息架构与导航

顶层导航表达已有业务域，具体功能放在对应侧边菜单。导航定义集中在 `Backplane.Admin.Layouts`，页面不得各自维护一套菜单。

| 业务域 | 放置内容 |
| --- | --- |
| Dashboard | 健康、统计、用量及刷新结果 |
| Llama | Provider、模型路由、Decisions、Images、Embeddings、TTS、ASR、Realtime、MiniMax Audio |
| MCP | 托管服务、上游、Agent MCP、协议检查 |
| Memory | 记录、事件、会话及 Memory 配置 |
| Skills | 技能浏览、来源、草稿及上传 |
| Plugins | 插件目录、来源、版本及分发 |
| Auth | OAuth、RBAC 和认证审计 |
| System | 系统配置、凭据、客户端、Host Agent、监控配置和日志 |

- OpenAI 等 Provider 的 API 能力均放在 **Llama** 下，禁止增加 **API Proxy** 顶级菜单。当前 OpenAI 能力页使用 `/llama/openai/:kind`。
- MiniMax 专属音频配置明确命名为 **MiniMax Audio**，与 OpenAI TTS/ASR/Realtime 分开；音频模型不得混入聊天模型菜单或目录。
- 配置页负责配置，Dashboard 负责运行数据。例如 System 下 API Usage 管理账号，Dashboard 下 API Usage 显示用量和刷新。
- 同一业务域使用一致的路由前缀、侧栏高亮和详情页归属。已有对外地址改动需要显式兼容跳转与验证。
- 复用共享桌面侧栏及移动导航；保留折叠、会话偏好、活动项与滚动行为。页面不得增加重复侧栏标题或另存一套折叠状态。

## 3. 页面结构与视觉

- 页面依次呈现：标题与简短说明、主要操作、筛选（如有）、列表或主体内容。每页一个 `h1`，标题应描述业务对象。
- 列表页主要操作为 **Add**，放在标题区；当前活动界面只有一个主要操作。弹窗打开后，保存是弹窗内的主要操作。
- 使用共享布局的 `max-w-7xl` 内容边界、响应式内边距和 `min-w-0`；内容分组通常采用 `space-y-6`，组内使用 `gap-2` / `gap-4`。避免重复嵌套容器和无意义卡片。
- 复用已有字体。页面标题通常为 `text-3xl font-bold`；说明使用 `text-sm text-on-surface-variant`；元数据使用 `text-xs`；模型 ID、路径和协议字段用等宽字体。
- 使用 DuskMoon 语义 token：页面 `bg-surface text-on-surface`，卡片使用 surface container，说明使用 `text-on-surface-variant`。背景和前景必须配对。
- 主操作用 `primary`，普通操作用 `outline` / `ghost`，破坏性操作用 `error`。`success`、`warning`、`error`、`info` 只表达状态。
- 新增页面不得硬编码颜色或使用 Tailwind 固定调色板。沿用共享布局和 Appearance 的主题设置；已有集中式品牌变量及兼容规则不应复制到页面。
- 同时支持 `sunshine` 和 `moonlight`；不在页面内固定主题。保留键盘焦点样式，并尊重 `prefers-reduced-motion`。

## 4. 列表与表格 Actions

- 结构化配置优先使用 `dm_table`，提供清晰列名、可读状态和独立的 **Actions** 列；可使用 `hover`、`zebra` 增强扫描体验。
- **表格 Actions 全部使用 icon button**，不使用成排的 Edit / Enable / Delete 文字按钮。页面级 Add、弹窗 Save / Cancel 保留文字。
- 按钮使用 `dm_btn`，图标使用 `dm_mdi` / `dm_bsi`。同表按钮尺寸和形状一致，通常为紧凑圆形按钮；不能只让一个无标签 SVG 响应点击。
- 每个按钮必须有可访问名称和 tooltip。`aria-label` 包含动作及对象，例如 `Edit openai route`；tooltip 简短，例如 `Edit`；可附 `sr-only` 文本。tooltip 同时支持悬停与键盘聚焦。
- `dm_tooltip` 返回的 trigger 属性必须通过 `:let` 获取并传给实际按钮，不能只包一层组件而丢失属性。
- 操作顺序为编辑、启停、其他业务操作、删除。常用图标：编辑 `pencil`、禁用 `pause`、启用 `play`、删除 `delete`。
- 启停按钮表达**将执行的动作**：已启用显示 Disable，已禁用显示 Enable；当前状态在 Status 列以文字 badge 呈现，不能仅依赖颜色。
- 删除使用破坏性样式并要求确认。确认内容明确对象与影响；取消不得触发写入。
- 行操作保留稳定且唯一的 DOM ID。异步操作需要可见的进行中状态，并防止重复提交；请求失败不得伪装为成功。
- 空列表说明尚无配置并引导 Add。无搜索结果与尚无配置应分别提示；存在分页或筛选时保持其状态可理解。

图标按钮示例（可访问名称按业务对象调整）：

```heex
<.dm_tooltip :let={tooltip_attrs} content="Edit" position="bottom">
  <.dm_btn
    {tooltip_attrs}
    id={"edit-service-#{service.id}"}
    type="button"
    size="xs"
    shape="circle"
    variant="outline"
    aria-label={"Edit #{service.provider.name} route"}
    phx-click={JS.push("edit", value: %{id: service.id}) |> JS.push_focus()}
  >
    <.dm_mdi name="pencil" class="h-4 w-4" />
    <span class="sr-only">Edit</span>
  </.dm_btn>
</.dm_tooltip>
```

## 5. Add / Edit 弹窗表单

- 配置列表统一由 **Add → modal form** 创建，编辑图标打开同一类表单。禁止在列表上方常驻完整新增表单。专用工作流或复杂详情编辑需要独立说明其交互设计。
- 使用 `dm_modal` 和原生 dialog 行为；标题区分 Add / Edit，并明确对象。禁止自行堆叠 fixed 遮罩模拟 modal。
- 打开后聚焦首个合理输入项；Tab 在弹窗内导航；关闭后恢复触发按钮焦点。支持 Cancel、关闭按钮和 Escape。
- Cancel、关闭和 Escape 均丢弃未保存值并清空错误；再次 Add 必须打开干净表单，不能残留上次编辑对象。
- 保存成功后关闭弹窗、刷新列表并显示成功反馈；验证失败保留输入及弹窗，显示可修正的错误。不得在失败时清空表单或关闭弹窗。
- LiveView 控制表单是否存在和编辑对象；dialog 的浏览器状态通过组件/hook 协调。不得在 DOM patch 时意外关闭仍有效的表单。
- 每个字段有明确 label；提示解释格式、单位、必要限制和可选性。placeholder 不能代替 label。采用 `dm_input`、`dm_select`、`dm_textarea` 等已有组件。
- 表单明确使用 `phx-submit`；非提交按钮设置 `type="button"`。提交中锁定保存操作并显示进度文案，防止连续提交。
- 表单只采集该配置必需的信息。连接地址和凭据由 Provider 管理时，能力表单选择 Provider，不重复保存端点或密钥。

## 6. 默认启用与状态管理

- **有 enabled/active 状态的新配置默认启用。新增表单不展示启用/禁用字段、checkbox、switch 或隐藏状态字段。**
- 创建默认值必须在领域 schema/context 与数据库默认值中保持一致，不能只依赖前端预填。表单处理器只接收允许字段，不能让额外提交的 enabled 值绕过规则。
- 保存后通过列表启停图标配置状态；普通 Edit 表单也不放置启用开关，编辑其他字段必须保留现有状态。
- 调整默认值只影响后续新增，不批量改变历史配置的启用/禁用状态。
- 区分配置启用状态和实际可用性：例如 route 已启用，但 Provider 禁用或凭据不可用，应显示具体原因，不能把两者合并成一个成功状态。
- 此约定适用于配置的启用状态；连接结果、任务执行状态、OAuth 授权状态等仍由实际业务流程产生，不能凭默认值制造“已连接”或“已授权”。

## 7. 反馈、文案与数据边界

- UI 沿用当前英文术语；同一对象在菜单、标题、按钮和提示中保持同名。使用简短动作词与具体错误，避免暴露无关实现细节。
- 区分加载中、空、成功、失败和数据过期；异步刷新不阻塞整页。错误不能用空列表、虚构零值或旧成功提示掩盖。
- 在对应区域呈现状态；表单错误在弹窗内，操作结果用共享 flash/alert。保留用户能继续修正或重试的路径。
- 打开配置页、Add/Edit 弹窗或普通保存不得隐式执行付费 API 探测；连接测试、刷新或其他外部操作使用明确的独立动作。
- 配置页显示凭据名称或引用，不回显明文密钥。日志、审计和错误消息不得包含秘密或原始敏感请求；一次性凭据签发等专用流程遵循其已有契约。

## 8. 响应式与可访问性

- 至少验证桌面和约 390px 宽的移动视口。页面整体不得因长 URL、模型 ID 或表格而横向溢出；长文本按需要换行。
- 宽表格在自身 `overflow-x-auto` 容器内滚动，保留可理解的列头和操作列；不能通过隐藏关键操作解决移动布局。
- 表单字段窄屏单列；弹窗受视口高度约束，正文可滚动，Save / Cancel 始终可达。
- 原生按钮、链接、表单 label、标题层级和 `aria-current` 必须保留正确语义。所有操作能通过键盘使用，图标按钮不能依赖 hover 才能理解。
- tooltip、菜单、确认框和弹窗不得被表格滚动容器裁剪；浏览器验证需要实际打开、聚焦及关闭，不能仅检查 HTML 中存在节点。

## 9. 实现参考与验收

参考当前安装版本与以下代码的相应职责，不盲目复制整页：

| 位置 | 参考内容 |
| --- | --- |
| `apps/backplane_admin/lib/backplane/admin/components/layouts.ex` | 导航定义、分组与活动项 |
| `apps/backplane_admin/lib/backplane/admin/components/layouts/` | 共享页面壳与响应式导航 |
| `apps/backplane_admin/lib/backplane/admin/live/openai_proxy_live.ex` | Add/Edit 弹窗、默认启用、独立启停及图标 Actions |
| `apps/backplane_admin/assets/js/hooks/openai_service_modal.js` | 原生 dialog 与 LiveView 生命周期协调 |
| `apps/backplane_admin/assets/css/app.css` | 主题、共享样式与已记录的兼容处理 |
| `apps/backplane_admin/test/backplane/admin/live/openai_proxy_live_test.exs` | 创建、编辑、启停、取消、验证及状态隔离回归 |

涉及行为变更时，按影响范围验证：

- 导航归属与当前项正确；无重复入口或意外顶级菜单。
- Add/Edit 打开正确表单，取消无写入，成功关闭，验证失败保留输入。
- 新增默认启用；编辑保留启停状态；列表图标执行正确动作且具有可访问名称。
- 删除有确认，保存/异步操作避免重复提交；列表及错误反馈与实际结果一致。
- 桌面、移动、两种主题及键盘操作可用；实际资源和 hook 加载成功，LiveView 已连接。
- 运行相关 LiveView/领域回归、修改文件格式检查及适当的编译/资源检查。DOM 测试不能证明 dialog 焦点、Escape、tooltip 或移动滚动正常；这些需要浏览器验证。

文档变更只做文档检查。交付时说明实际验证内容及未验证项；不得把已有页面或未运行的检查描述为全站达标。
