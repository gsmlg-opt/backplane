# Backplane 一次性实施任务：将 OpenAI Codex 重构为透明 Responses API 代理

## 1. 任务目标

在 `gsmlg-opt/backplane` 的一个工作分支和一个 PR 中，一次性完成 OpenAI Codex 代理链路修复。

最终结果必须满足：

- Codex 使用 **Responses API** 直接经过 Backplane 访问 ChatGPT Codex backend。
- Backplane 不再把 Chat Completions 转换成 Responses。
- Backplane 不再把 Responses 或 Responses SSE 转换成 Chat Completions。
- Codex 请求体、流事件、错误响应及协议扩展字段应尽可能按字节透明转发。
- 模型发现使用 Codex backend 的真实 `/models` 接口，不再使用硬编码的旧模型清单。
- 新模型即使尚未同步进 Backplane 本地模型表，也不能被透明 Codex 路由提前拦截。
- 修复认证头覆盖、重复 header、路径拼接、OAuth metadata、模型解析和可诊断性问题。
- 保持其他 OpenAI-compatible、Anthropic-compatible、embedding provider 的现有行为不回归。

本任务不能只做分析、局部补丁或临时配置修改。必须同时完成实现、数据库迁移、测试、文档和真实 smoke verification。

---

## 2. 不可变架构决策

### 2.1 Codex 只使用 Responses wire API

OpenAI Codex provider 的协议定义为：

```text
wire_api = responses
```

Codex 主链路只支持：

```text
GET  /models
POST /responses
POST /responses/compact
```

本任务不再为 OpenAI Codex provider 提供 Chat Completions 兼容转换。

当客户端尝试通过 `/v1/chat/completions` 调用 OpenAI Codex OAuth provider 时，Backplane 必须返回明确、稳定的本地错误，例如：

```json
{
  "error": {
    "type": "unsupported_api_surface",
    "code": "codex_requires_responses_api",
    "message": "OpenAI Codex providers support the Responses API only."
  }
}
```

不得偷偷转换，不得向上游发起请求。

### 2.2 使用 provider-scoped 透明路由

增加下列公开路由：

```text
GET  /v1/providers/:provider/models
POST /v1/providers/:provider/responses
POST /v1/providers/:provider/responses/compact
```

其中 `:provider` 使用 Backplane provider 的稳定名称，例如：

```text
openai-codex
```

路径映射必须是精确的：

```text
/v1/providers/openai-codex/models
  -> https://chatgpt.com/backend-api/codex/models

/v1/providers/openai-codex/responses
  -> https://chatgpt.com/backend-api/codex/responses

/v1/providers/openai-codex/responses/compact
  -> https://chatgpt.com/backend-api/codex/responses/compact
```

`/responses/compact` 是 legacy compatibility route，仍必须透明映射。当前 Codex
CLI 的默认远端压缩协议是 remote compaction v2：请求仍发往 `/responses`，携带
`x-codex-beta-features: remote_compaction_v2`，并在 `input` 中加入
`{"type":"compaction_trigger"}`。Backplane 必须同样透明转发该协议，不得在两种
compact 形态之间转换。

查询参数必须原样传递，例如：

```text
?client_version=...
```

该设计让 Codex 可以发送真实 canonical model slug，例如：

```text
gpt-5.6-sol
```

而不需要在 JSON body 中使用：

```text
openai-codex/gpt-5.6-sol
```

因此透明路由不需要读取或改写请求体中的 `model`。

### 2.3 Upstream 是模型可用性的最终事实来源

透明 Codex 路由不得因为本地模型表中没有某个模型而拒绝请求。

本地模型目录只用于：

- 管理 UI；
- 全局 `/v1/models`；
- alias / auto-model；
- 可观测性；
- capability metadata。

透明 Codex 路由只能验证：

- provider 存在；
- provider 已启用且未删除；
- `preset_key == "openai-codex"`；
- OpenAI API surface 已启用；
- credential auth type 为 `openai_oauth`；
- endpoint 在允许列表内；
- provider rate limit 未超限。

模型是否合法、当前账户是否有 rollout 权限，由 Codex upstream 返回真实结果。

### 2.4 透明传输优先于 JSON 兼容

对于 provider-scoped Codex 路由：

- 不使用 `Plug.Parsers`；
- 不 JSON decode/re-encode；
- 不调用 `ModelExtractor`；
- 不调用 `ModelResolver`；
- 不调用 `ModelExtractor.replace_model/2`；
- 不调用 `MoonshotCompat`；
- 不调用任何 Chat/Responses adapter；
- 不改写 unknown request fields；
- 不改写 SSE event；
- 不重建 upstream error。

允许做的事情只有：

- 本地客户端认证和授权；
- provider 选择；
- 路径映射；
- provider rate limiting；
- provider OAuth credential 注入；
- 安全 header 覆盖；
- 非破坏性的 telemetry / usage side observation；
- transport limits。

---

## 3. Codex 客户端目标配置

完成后，Codex 应按以下方式接入：

```toml
model = "gpt-5.6-sol"
model_provider = "backplane-codex"

[model_providers.backplane-codex]
name = "Backplane OpenAI Codex"
base_url = "https://backplane.example/v1/providers/openai-codex"
env_key = "BACKPLANE_API_KEY"
wire_api = "responses"
supports_websockets = false
```

要求：

- `base_url` 不带 `/responses`；
- Codex 自己追加 `/responses` 或 `/models`；
- `BACKPLANE_API_KEY` 是调用 Backplane 的 credential；
- Backplane 在 upstream 请求中将它替换为已保存的 ChatGPT OAuth access token；
- 本次任务明确禁用 Responses WebSocket；HTTP/SSE 是唯一验收链路。

---

## 4. 当前必须删除的错误设计

处理：

```text
apps/backplane_llama/lib/backplane/llm/openai_codex_compat.ex
apps/backplane_llama/lib/backplane/llm/router.ex
```

删除以下行为及所有依赖代码：

```text
chat_completions_to_responses_body
response_body_to_chat_completion
chat_completion_stream_mapper
messages_to_responses_input
tool_call_to_responses_item
tools_to_responses
tool_choice_to_responses
reasoning_to_responses
map_response_stream_chunk
map_response_event
chat_delta
chat_finish
proxy_codex_chat_completion
```

建议结果：

- 删除 `Backplane.LLM.OpenAICodexCompat`；
- 或将其缩减并重命名为纯 provider specification 模块，例如：

```elixir
Backplane.LLM.OpenAICodex
```

该模块只能维护：

- canonical backend base URL；
- provider predicate；
- allowed endpoints；
- path mapping；
- provider-specific header policy。

其中不得再包含 body、message、tool、usage 或 SSE schema conversion。

完成后，下列命令不得命中生产代码：

```bash
rg \
  'chat_completions_to_responses|response_body_to_chat|chat_completion_stream_mapper|proxy_codex_chat_completion' \
  apps
```

---

## 5. 实施范围

### 5.1 增加独立透明代理 Plug

建议新增：

```text
apps/backplane_llama/lib/backplane/llm/openai_codex_proxy_plug.ex
```

职责：

1. 匹配 provider-scoped 路由。
2. 执行与 `/v1` 资源一致的客户端认证和授权。
3. 根据 provider name 读取 provider。
4. 检查 provider 类型、状态、API surface 和 OAuth credential。
5. 将公开路径映射为 upstream-relative path。
6. 构造 Relayixir upstream。
7. 注入 provider OAuth headers。
8. 原样转发请求 body、query string 和响应。
9. 记录 telemetry，但不改变 payload。
10. 将本地配置错误与 upstream 错误清楚地区分。

不要把 direct Codex 分支塞进通用 Router 的 `proxy_request/2`。它应当在 JSON parser 和通用 model resolver 之前被分流。

### 5.2 修改顶层 LLM Proxy dispatch

修改：

```text
apps/backplane_llama/lib/backplane/llm/proxy_plug.ex
```

优先匹配：

```text
/v1/providers/:provider/models
/v1/providers/:provider/responses
/v1/providers/:provider/responses/compact
```

然后才将其他 `/v1/...` 请求交给现有 `Backplane.LLM.Router`。

确保 provider-scoped 请求不会进入通用 `Plug.Parsers` pipeline。

### 5.3 复用认证，不复制认证逻辑

如果 `Backplane.LLM.Router` 中的认证 pipeline 无法直接复用，抽取一个小型公共 Plug，例如：

```text
Backplane.LLM.RequestAuthorizationPlug
```

共同完成：

```text
Backplane.Transport.CORS
Backplane.Auth.ResourceAuthPlug
Backplane.LLM.ResourceAuthorization
```

不得为了新增 direct route 绕过现有 resource scope 和 RBAC。

---

## 6. 请求与响应透明性

### 6.1 Request body

provider-scoped Codex 请求必须保持原始字节：

```text
downstream body SHA-256 == upstream received body SHA-256
```

需要覆盖：

- 普通 JSON；
- unknown future fields；
- tools；
- tool choice；
- reasoning；
- metadata；
- previous response references；
- multimodal input；
- encrypted/opaque state；
- zstd-compressed request body。

如果 Relayixir 当前不支持压缩请求透明传递，应修复 Relayixir，而不是在 Codex Plug 中解压再压缩。

必须保留：

```text
Content-Type
Content-Encoding
Accept
Accept-Encoding
```

只允许重新计算或删除由 HTTP transport 自己负责的：

```text
Content-Length
Transfer-Encoding
Connection
```

### 6.2 SSE

对于：

```text
Content-Type: text/event-stream
```

要求：

- 不解析 event type；
- 不重建 `data:` frame；
- 不合并、拆分或重排事件；
- 不添加 Chat Completions `[DONE]`；
- 不把 Responses event 改为 `chat.completion.chunk`；
- 客户端断开时取消 upstream；
- 保持 backpressure；
- telemetry scanner 只能旁路观察，不能改变 chunk。

### 6.3 Non-stream response

普通 JSON 响应必须保持：

```text
status
body
content-type
request-id headers
rate-limit headers
retry-after
```

不得转换 usage schema、output schema 或 error schema。

### 6.4 Upstream errors

下列 upstream 状态必须原样返回：

```text
400
401
403
404
409
429
500
502
503
504
```

不得把所有失败统一转换为：

```text
Provider credential not configured
```

只有请求尚未发送到 upstream 的本地错误，才返回 Backplane 自己的 JSON error。

---

## 7. Header 策略与 Relayixir 修复

当前 Relayixir 的普通 header forwarding 和 injected headers 必须改为大小写无关的确定性 merge。

### 7.1 Provider-owned headers

下列 header 必须由 Backplane provider credential 覆盖客户端值，且 upstream 中只能出现一次：

```text
Authorization
X-API-Key
ChatGPT-Account-ID
X-OpenAI-FedRAMP
```

即使客户端使用不同大小写，也不能产生重复项。

### 7.2 Client metadata headers

下列 header 应原样保留；Backplane 只能在缺失时添加默认值：

```text
User-Agent
originator
x-client-request-id
session-id
thread-id
x-openai-subagent
openai-beta
x-codex-*
x-responsesapi-*
```

当前 credential metadata 中的：

```text
originator = codex_cli_rs
```

应改为 **put-if-absent**，不能覆盖真实 Codex 客户端已经发送的 originator。

### 7.3 Relayixir API

可以采用任一清晰实现，但必须区分：

```text
replace headers
default headers
pass-through headers
strip headers
```

不要继续只用：

```elixir
forwarded_headers ++ injected_headers
```

新增 case-insensitive header merge 单元测试。

---

## 8. OAuth credential 修复

核对并完善：

```text
apps/backplane_system/lib/backplane/settings/credentials.ex
apps/backplane_llama/lib/backplane/llm/credential_plug.ex
```

要求：

1. upstream 使用有效的 OAuth access token。
2. token 即将过期时按现有 credential lifecycle 刷新。
3. refresh 后保留：
   - account ID；
   - auth type；
   - credential identity；
   - provider-required metadata。
4. 生成：
   - `Authorization: Bearer <access_token>`；
   - `ChatGPT-Account-ID: <account_id>`，当账户存在时。
5. 不记录 token、refresh token、ID token。
6. OAuth refresh 失败返回明确本地错误：
   - `oauth_refresh_failed`；
   - `credential_unavailable`；
   - `credential_metadata_invalid`。
7. 不将 credential 错误误报为 model error。

增加 refresh 前后 account ID 不丢失的回归测试。

---

## 9. 模型发现修复

修改：

```text
apps/backplane_llama/lib/backplane/llm/model_discovery.ex
```

### 9.1 删除静态 Codex active catalog

删除：

```elixir
@default_openai_codex_models
```

以及 `openai-codex` OAuth provider 直接返回静态数组的特殊分支。

不得把以下旧列表继续作为真实发现结果：

```text
gpt-5.5
gpt-5.4
gpt-5.4-mini
gpt-5.3-codex-spark
```

### 9.2 调用真实 Codex models endpoint

使用 provider OAuth credential 请求：

```text
GET https://chatgpt.com/backend-api/codex/models?client_version=<value>
```

`client_version` 必须可配置，例如：

```text
OPENAI_CODEX_CLIENT_VERSION
```

应用配置建议：

```elixir
config :backplane, :openai_codex_client_version, ...
```

不得丢弃 direct client 请求中已有的 `client_version`。

### 9.3 解析 Codex 模型 schema

支持：

```json
{
  "models": [
    {
      "slug": "gpt-5.6-sol"
    }
  ]
}
```

模型主键使用：

```text
slug
```

同时将其余模型对象安全存入 `ProviderModel.metadata`，或规范化存储明确需要的 capability 字段。未知字段必须保留，便于后续兼容。

### 9.4 Last-known-good

模型发现失败时：

- 保留本地 last-known-good catalog；
- 不 prune；
- 不禁用所有旧 surface；
- 不把 `last_discovered_at` 更新成成功；
- 记录可诊断的 failure metadata 或日志。

下列情况都视为失败，不得触发 prune：

```text
network error
timeout
401 / 403
non-2xx
invalid JSON
missing models
empty models when previous catalog is non-empty
models entries without slug
```

只有完整且成功的 discovery 才允许 prune 已不再返回的 `source: discovered` 模型。

手工维护的模型不得被 discovery 删除。

### 9.5 Provider-specific `/models`

`GET /v1/providers/:provider/models` 是给 Codex 客户端使用的透明 endpoint：

- 直接代理 upstream Codex schema；
- 不转换成 OpenAI `{object, data}` schema；
- 原样传递 `client_version`；
- 原样返回 rollout/account-specific model metadata。

管理后台的 discovery 可以解析同一 upstream 响应并持久化，但不能改变 direct endpoint 的响应。

---

## 10. 全局 `/v1/models` 修复

全局 endpoint 仍保持 OpenAI-compatible 形式：

```json
{
  "object": "list",
  "data": []
}
```

但必须修复以下不变量：

1. 只列出可路由模型：
   - provider enabled；
   - provider not deleted；
   - provider API enabled；
   - model enabled；
   - model surface enabled。
2. ID 使用可稳定解析的 provider name：
   ```text
   <provider-name>/<canonical-model>
   ```
3. 每一个返回的 ID 都必须通过相同 API surface 的 `ModelResolver` round-trip。
4. 按 ID 去重并稳定排序。
5. 不把 provider-specific Codex model schema 混进全局 OpenAI list。
6. 可以增加非标准扩展字段：
   ```json
   {
     "provider": "openai-codex",
     "canonical_id": "gpt-5.6-sol"
   }
   ```
7. direct Codex endpoint 不依赖这个全局 list。

增加契约测试：

```text
for every /v1/models entry:
  resolve(surface, entry.id) must succeed
```

---

## 11. 通用 Router 修复

修改：

```text
apps/backplane_llama/lib/backplane/llm/router.ex
```

要求：

- 删除 `proxy_codex_chat_completion/7`；
- 删除 Codex Chat Completions 转换分支；
- `/v1/responses` 的通用 aggregator 保留现有 provider routing 能力；
- provider-scoped Codex route 不进入该 Router；
- 当通用 `/v1/chat/completions` 最终解析到 `openai-codex` provider 时，明确拒绝；
- 不再把 Codex provider 标记成普通 OpenAI Chat Completions surface；
- local resolver error、credential error、upstream error分别处理；
- 不破坏其他 provider 的 Moonshot 或其他兼容逻辑。

---

## 12. 数据迁移与 backfill

增加幂等 migration/backfill，处理现有 OpenAI Codex provider：

1. 将 Codex API surface base URL 规范化为：
   ```text
   https://chatgpt.com/backend-api/codex
   ```
2. 保持用户显式配置的合法自定义 Codex-compatible backend；只自动修复已知旧默认值。
3. 将旧静态/discovered 模型标为 stale/disabled，或在首次真实 discovery 成功后安全 prune。
4. 不删除 `source: manual` 的模型。
5. 不删除 alias 和 auto-model；如果 target 失效，给出可见诊断。
6. backfill 可重复执行，不产生 duplicate models 或 surfaces。
7. migration 不包含 credential 明文。

如果 schema migration 并非必须，使用独立、幂等的 data migration，但必须随 release 执行并有测试。

---

## 13. 可观测性

新增或补全以下 telemetry / structured log：

```text
codex.proxy.request.started
codex.proxy.request.completed
codex.proxy.request.failed
codex.models.discovery.started
codex.models.discovery.completed
codex.models.discovery.failed
codex.oauth.refresh.failed
```

至少记录：

```text
provider_id
provider_name
endpoint
method
status
latency_ms
stream
client_request_id
upstream_request_id
error_class
```

可选记录：

```text
model
```

仅当无需解压/改变 body 且可以安全旁路提取时记录；不能为了记录 model 而破坏透明性。

禁止记录：

```text
Authorization
access token
refresh token
ID token
full request body
tool arguments
user prompt
```

明确区分：

```text
provider_not_found
provider_disabled
api_surface_disabled
unsupported_endpoint
codex_requires_responses_api
credential_unavailable
credential_metadata_invalid
oauth_refresh_failed
upstream_unauthorized
upstream_forbidden
upstream_model_unavailable
upstream_rate_limited
upstream_transport_error
client_disconnected
```

---

## 14. 测试要求

### 14.1 新增 direct proxy integration tests

建议新增：

```text
apps/backplane_llama/test/backplane/llm/openai_codex_proxy_plug_test.exs
```

必须覆盖：

#### 路径

- `/models` 映射到 upstream `/models`；
- `/responses` 映射到 upstream `/responses`；
- `/responses/compact` 映射到 upstream `/responses/compact`；
- query string 原样传递；
- 不出现 `/v1/v1`；
- 不出现 `/codex/codex`；
- 非允许 endpoint 返回本地 404/405，不请求 upstream。

#### Request body

- JSON body byte-for-byte 相同；
- unknown fields 保留；
- tools/reasoning/metadata 保留；
- model slug 不被加前缀或替换；
- compressed bytes 和 `Content-Encoding` 保留；
- direct route 不调用 JSON parser。

#### Headers

- Backplane client token 不发送给 upstream；
- provider OAuth bearer 正确注入；
- account ID 正确注入；
- 客户端伪造的 upstream auth/account ID 被覆盖；
- header merge 大小写无关；
- upstream 中不存在重复 Authorization；
- originator、User-Agent、session-id、thread-id、x-client-request-id 保留；
- provider default originator 只在缺失时添加。

#### Responses

- non-stream body byte-for-byte 相同；
- SSE body/event byte-for-byte 相同；
- SSE 不出现 `chat.completion.chunk`；
- SSE 不额外产生 `[DONE]`；
- upstream error status/body/header 原样返回；
- `retry-after` 和 request ID 保留；
- client disconnect 取消 upstream。

### 14.2 Model discovery tests

更新：

```text
apps/backplane_llama/test/backplane/llm/model_discovery_proxy_test.exs
```

覆盖：

- 解析 `models[].slug`；
- 发送 `client_version`；
- OAuth headers 正确；
- metadata 保留；
- 成功发现后 upsert；
- 失败不 prune；
- 空列表不清空 last-known-good；
- 手工模型不被删除；
- stale discovered model 只在完整成功后 prune。

### 14.3 Router regression tests

更新：

```text
apps/backplane_llama/test/backplane/llm/router_test.exs
```

覆盖：

- Codex Chat Completions 被明确拒绝；
- 不发生 Chat -> Responses upstream request；
- 通用 OpenAI provider 的 Chat Completions 不回归；
- 通用 `/v1/responses` 不回归；
- Anthropic 和 embedding 路由不回归；
- 全局模型 ID 全部 round-trip。

### 14.4 Credential tests

更新：

```text
apps/backplane_llama/test/backplane/llm/credential_plug_openai_codex_test.exs
apps/backplane_system/test/**
```

覆盖：

- bearer；
- account ID；
- refresh；
- refresh 后 metadata 不丢失；
- originator put-if-absent；
- token 不出现在日志。

### 14.5 Relayixir tests

为 header merge、body pass-through、SSE/error pass-through 增加单元和 integration tests。

---

## 15. 文档与 smoke 工具

新增：

```text
docs/llm-proxy-openai-codex.md
```

内容必须包括：

- 架构图；
- direct route；
- Codex `config.toml` 示例；
- OAuth credential 前置条件；
- models discovery；
- Responses/SSE 行为；
- `supports_websockets = false`；
- troubleshooting；
- 本地错误与 upstream 错误区别；
- 不支持 Chat Completions 的说明；
- 安全注意事项。

新增一个不泄漏 credential 的 smoke command 或 script，例如：

```bash
mix backplane.codex.smoke \
  --provider openai-codex \
  --model gpt-5.6-sol
```

它至少验证：

1. provider 配置；
2. `/models`；
3. 普通 `/responses` 请求及其原生 SSE 完成事件；
4. 额外的流式 `/responses` 请求；
5. 输出 status、request ID 和事件计数；
6. 不打印 token 或完整 prompt；
7. 当前 Codex 使用的 remote-compaction-v2 `/responses` 流程，并验证
   `compaction` output item。

当前 ChatGPT Codex backend 要求 Responses 请求使用 `stream: true`。成功的真实
upstream smoke 因此验证原生 SSE；non-stream response byte fidelity 和 legacy
`/responses/compact` 映射由本地 integration tests 验证。不得为了得到一个成功的
“非流式” smoke 而转换协议。

真实 upstream smoke test 使用环境变量显式启用，不得默认进入 CI。

---

## 16. 验收标准

任务只有在以下全部满足后才能完成：

### 功能

- Codex CLI 通过 Backplane 使用 `gpt-5.6-sol` 完成一次真实请求。
- 流式 Responses 正常。
- tool-calling Responses 正常。
- `/models` 返回当前账户真实可用模型。
- 新 upstream model 不需要先写入本地 catalog 就能通过 direct route 请求。
- legacy `/responses/compact` 保持透明映射，当前 remote-compaction-v2
  `/responses` 流程可真实工作。
- Chat Completions 不再被转换到 Codex。
- 其他 provider 不回归。

### 协议

- direct request body byte-for-byte 保真。
- SSE byte-for-byte 保真。
- upstream error byte-for-byte/语义保真。
- query string 保真。
- auth header 唯一且正确。
- 不存在 provider prefix JSON rewrite。
- 不存在 Chat/Responses response conversion。

### 数据

- 旧硬编码 Codex model catalog 已移除。
- `slug` discovery 已实现。
- discovery failure 不破坏 last-known-good。
- data migration 幂等。
- 手工模型不被错误删除。

### 代码

下列命令无生产代码匹配：

```bash
rg \
  'chat_completions_to_responses|response_body_to_chat|chat_completion_stream_mapper|proxy_codex_chat_completion' \
  apps
```

没有：

- TODO；
- stub；
- dead conversion code；
- duplicated Codex base URL definitions；
- secret logging；
-仅通过修改测试绕过真实问题。

### CI

必须运行并通过：

```bash
mix deps.get
mix ecto.migrate
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
```

如仓库已有更严格的 app-specific 或 release checks，也必须通过。

---

## 17. 实施约束

- 这是一个任务、一个工作分支、一个最终 PR，不拆成多个后续任务。
- 可以在一个 PR 内分成逻辑清晰的 commits。
- 不要停在“给出设计”或“发现问题”阶段。
- 不采用简单更新静态 GPT 模型数组的临时修复。
- 不引入另一个 HTTP proxy library；优先修复和复用 Relayixir。
- 不为 direct route复制整套认证系统。
- 不把 Codex provider 当作通用 OpenAI Chat Completions provider。
- 不依赖客户端发送 `provider/model` 形式的 body model。
- 不实现 Responses WebSocket；显式文档化并配置 `supports_websockets = false`。
- 不修改与本任务无关的 MCP、memory、skills 或 agent plugin 模块。
- 发现现有测试与真实协议冲突时，删除错误测试并替换为新的协议契约测试。
- 完成报告必须列出：
  - 删除的转换代码；
  - 新 direct routes；
  - migration；
  -测试结果；
  - 真实 smoke test 结果；
  - 尚存的明确限制。

---

## 18. 预期最终架构

```text
Codex CLI
  model = gpt-5.6-sol
  wire_api = responses
        |
        | POST /v1/providers/openai-codex/responses
        | Authorization: Bearer <backplane-token>
        | raw Responses body
        v
Backplane OpenAICodexProxyPlug
  - authenticate Backplane client
  - select openai-codex provider
  - validate provider/surface
  - rate limit
  - replace provider-owned auth headers
  - preserve request bytes and metadata headers
        |
        | POST /responses
        | Authorization: Bearer <chatgpt-oauth-token>
        | ChatGPT-Account-ID: ...
        | unchanged request body
        v
https://chatgpt.com/backend-api/codex
        |
        | unchanged status / headers / JSON / SSE
        v
Codex CLI
```

全局聚合链路继续独立存在：

```text
/v1/chat/completions
/v1/responses
/v1/messages
/v1/embeddings
/v1/models
```

但 OpenAI Codex 的可靠主入口是 provider-scoped transparent Responses route，不再经过通用模型翻译和协议兼容层。
