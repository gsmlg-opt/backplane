# Agent Plugins 验证记录

日期：2026-10-23。对应 [实现评审](agent-plugins.md) 与批准设计 Agent Note
`22fadaea-6cfe-461f-8721-3c6b446bccb2`。
验证对象为 `codex/agent-plugins` 的未提交 worktree，基于
`e8317e799b8c7bceb8831b6300a95bddd368d919`。

## 本地测试环境

使用项目 devenv 的 Elixir/OTP、Python 3 和现有 PostgreSQL 17 + pgvector 测试数据库。
所有 Mix 命令串行运行。此机器从原项目的已缓存 devenv 进入 worktree：

```sh
devenv shell --no-tui -- sh -c '
  cd /home/gao/Workspace/gsmlg-opt/backplane/.trees/plugins
  export PGHOST=/run/user/1000/devenv-0404c3b/postgres
  export MIX_ENV=test
  mix compile --warnings-as-errors
'
```

其他机器应使用自己的 PostgreSQL 测试 socket/host。迁移在 `backplane_test` 执行，
数据库测试由 Ecto Sandbox 回滚；没有向开发/生产数据库写入演示插件。
这里的 `--no-start` 避免启动整个 gateway；数据库/API/UI 测试显式启动自己的应用。
本机复制的 `_build` 中还有已退出依赖图的 `bypass.app`，不能用整个 umbrella 的启动结果
代替这些测试结果。测试不修改该无关构建缓存问题。

## 范围内自动验证

以下命令均从 worktree 根目录的 devenv shell 执行，使用 `MIX_ENV=test`。

| 范围 | 通过数量 |
| --- | ---: |
| Plugin Protocol | 29 |
| MCP origin/status 与既有 transports 回归 | 66 |
| Registry / Git / Codex | 24 |
| Runtime plugin sessions | 6 |
| Host Agent plugin installations | 4 |
| Plugin API | 4 |
| Admin 插件页面与导航 | 14 |
| 功能范围合计 | 147 |
| 工作流契约（单独） | 8 |

协议包：

```sh
mix test --no-start apps/backplane_plugin_protocol/test
```

覆盖可选/非 SemVer 版本、manifest 与组件局部失败、扩展保留、完整 skill 资源、
路径边界、安全归档、大小限制、digest、执行位和注入传输的 Client。
目录 Loader 与 portable Archive 使用各自的链接处理边界。

Runtime 与 Host 安装：

```sh
mix test --no-start \
  apps/backplane_agent_runtime/test/backplane/agent_runtime/plugin_session_test.exs \
  apps/backplane_host_agent/test/backplane/host_agent/agent_plugins_test.exs
```

覆盖真实 Python stdio MCP、tools/list 分页、每个 server 的失败清理、畸形工具目录、
run 授权、占位符与每 server 凭证、status 脱敏、release 锁定、安装完整性、升级与回滚、
数据目录保留、symlink cache 拒绝和 Codex 本地导出。

Registry、公共 API、管理 UI 与导航：

```sh
mix run --no-start --eval '
  Logger.configure(level: :warning)
  {:ok, _} = Application.ensure_all_started(:backplane_api)
  {:ok, _} = Application.ensure_all_started(:backplane_admin)
  Mix.Task.run("test", [
    "--no-start",
    "apps/backplane_plugins/test",
    "apps/backplane_api/test/backplane/api/plugin_registry_test.exs",
    "apps/backplane_admin/test/backplane/admin/live/plugins_live_test.exs",
    "apps/backplane_admin/test/backplane/admin/layouts_test.exs"
  ])
'
```

覆盖完整制品发布、相同声明版本的不同 release、固定 Git commit、第三方 marketplace
独立来源 commit、部分失败与旧 release 保留、完整 skill revision 组合、channels/回退、
desired/actual、API scopes/消费端隔离、ETag/304、内容篡改、原生 Codex 命名和重复名边界。
Git 发布测试使用临时 bare repository，检查仅移除本导出拥有的旧插件并保留其他内容。
新协议与 Registry 应用已加入现有 CI 测试矩阵。

工作流契约检查：`mix run --no-start test/ci_workflow_test.exs`。

MCP owning-module 回归从其应用目录执行：

```sh
cd apps/backplane_mcp_protocol
mix test \
  test/backplane/mcp_protocol/http_origin_test.exs \
  test/backplane/mcp_protocol/transport/status_test.exs \
  test/backplane/mcp_protocol/transport/stdio_test.exs \
  test/backplane/mcp_protocol/transport/sse_test.exs \
  test/backplane/mcp_protocol/transport/streamable_http_test.exs \
  test/backplane/mcp_protocol/transport/streamable_http/stream_test.exs
```

覆盖 opt-in 同 origin 策略、相对 redirect、跨 origin 拒绝、legacy SSE endpoint event、
stdio 原有行为，以及 transport/请求状态的凭证脱敏。原有未启用该策略的调用方行为保留。
跟踪问题为 [#77](https://github.com/gsmlg-opt/backplane/issues/77) 与
[#78](https://github.com/gsmlg-opt/backplane/issues/78)。

另已检查改动文件的格式、范围内 strict Credo 和 `git diff --check`。
MCP 应用使用自己的 `.formatter.exs`（包含 Styler），其余改动使用所属配置。
协议包 `mix hex.build` 验证了打包内容；没有发布 Hex 包。
另将生成 tar 中的 `contents.tar.gz` 解到 umbrella 外的临时目录，使用
`HEX_OFFLINE=1 MIX_ENV=test mix deps.get`、`mix compile --warnings-as-errors` 和 `mix run`
加载完整样例，确认 skill/MCP 发现、Archive round-trip 均成功，且没有 Repo/Phoenix 模块。
实际独立依赖仅 `yaml_elixir` 和 `yamerl`；临时包与构建目录在验证后清理。

## 真实 Codex 0.163.0 验收

使用 `/home/gao/.local/bin/codex`，在 bubblewrap 隔离的临时配置与缓存内执行。
只读挂载工作区，在隔离 namespace 中把临时 Codex 目录绑定到默认配置位置；
真实用户配置、插件安装与缓存没有被修改。没有发送模型请求。

测试包为 `apps/backplane_agent_runtime/examples/plugin`，同时含有 `plugin.json`、
`mcp.json`、skill、脚本和 marker 资源。通过真实 Registry 导出两个已发布 release，
两者声明版本均为 `1.0.0`，只改变 marker。Fixture 发布在数据库 sandbox 事务内回滚。

原生 CLI 流程：

```sh
codex plugin marketplace add /path/to/export-v1 --json
codex plugin add backplane-example@backplane-test --json
# 更新 marketplace 的来源目录内容为 export-v2。
codex plugin add backplane-example@backplane-test --json
```

每次验收启动新的原生 `codex app-server --stdio`，调用以下真实接口：

| 调用 | 检查 |
| --- | --- |
| `initialize` / `initialized` | 启用 experimental API |
| `thread/start` | 创建新的 ephemeral 会话 |
| `skills/list` | 找到启用的 `backplane-example:plugin-hello`，具有 pluginId |
| `mcpServerStatus/list` | 插件 echo MCP 连接和工具可见 |
| `mcpServer/tool/call` | 调用 `echo`，参数 `{"text":"native-codex-proof"}` |

实际返回：

| 安装来源 | 新会话 MCP 返回 |
| --- | --- |
| 本地 marketplace，V1 | `BACKPLANE_PLUGIN_V1: native-codex-proof` |
| 本地 marketplace，重新 add 后 V2 | `BACKPLANE_PLUGIN_V2: native-codex-proof` |
| Git marketplace，V2 | `BACKPLANE_PLUGIN_V2: native-codex-proof` |

Git 通道使用平台精确导出的 V2 文件创建临时 Git/bare repository，通过 loopback
HTTP 提供 Git 服务，再由原生 `marketplace add http://127.0.0.1:<port>/export.git`
克隆并安装。没有真实远端 GitHub/Gitea 凭证或推送。

确认的兼容边界：Codex 要求 marketplace entry.name 等于所选 release 的 manifest.name。
跨发布者重名需要明确选择导出范围；manifest 不改写。只更新本地来源不会自动替换安装副本；
同版本重新 add 后副本更新，新会话使用 V2。旧会话热更新未验收。
安全裁剪后的 release 映射、skill 发现和实际响应保存在
[Codex 原生证据](agent-plugins-evidence/codex-native.json)。

## 浏览器验收

使用独立测试端口 `http://127.0.0.1:4421`、共享 sandbox 事务和本 worktree 编译的资产，
以测试 fixture 展示两个 release、来源和不同的 desired/actual 状态。没有重启原开发服务。
检查目录、组合默认 JSON、来源、发布/兼容性、分发、渠道回退与 LiveView 连接；
桌面宽度 1440px、窄屏 390px 检查水平溢出，并检查浏览器 console。
最终两个尺寸均 LiveView connected，页面无水平溢出，console 没有 error/warning。
窄屏表格在 295px 容器内滚动，保持 768px 的可读表宽。
实际服务资产为 `app-51508baf.css` / `app-cedd3e63.js`。
测试预览在取证后关闭，sandbox fixture 回滚。

- [发布页桌面截图](agent-plugins-evidence/releases-desktop.png)
- [发布页窄屏截图](agent-plugins-evidence/releases-mobile.png)
- [分发页截图](agent-plugins-evidence/distribution-desktop.png)
- [浏览器检查数据](agent-plugins-evidence/browser.json)

## 未覆盖的交付阶段

未运行全仓库测试、全仓库 Dialyzer 或远端 CI；范围内本地结果不能代替这些检查。
未执行真实远端 GitHub/Gitea 写入、自动来源生产巡检、Hex 发布、release 或部署。
Sigma/Synapsis 产品集成和现有 Host WebSocket 自动同步入口属于后续接入。
共享宿主测试和原生 Codex 示例验收不能称为三端已部署验证。
