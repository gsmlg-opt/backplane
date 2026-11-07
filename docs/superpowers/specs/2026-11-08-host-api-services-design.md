# Host API services

## Approved scope

Backplane operators configure services on registered hosts in the platform. A
service declares exact endpoint URLs keyed by API protocol, independently of the
implementation (Ollama, SGLang, vLLM, or another server). Supported protocols are
`openai_embeddings`, `openai_chat_completions`, `openai_responses`, and
`anthropic_messages`. Host agents need only their existing platform connection
configuration. Platform calls traverse that authenticated connection, including
ordinary responses, streaming bytes, errors, and cancellation.

The user approved this scope on 2026-11-08. Do not introduce task execution,
backend-specific service types, automatic agent upgrades, branches, or worktrees.

## Ownership and configuration

`backplane_llama` owns `HostService` and its context, alongside the existing LLM
and embedding providers. The shared migration directory in `backplane_system`
owns the database migration. A service belongs to one durable `skill_hosts` ID and
stores its name, enabled flag, and a protocol-to-full-URL endpoint map. Model
definitions remain in the existing model tables. Existing provider forms select
a host service; one provider uses one service for all its declared API surfaces.
Embedding providers can select services declaring the embeddings protocol.

LLM and embedding providers gain a nullable `host_service_id`. Existing direct
providers retain their current requirements and behavior. Only host-linked
providers may omit a vault credential for unauthenticated local endpoints.
Credentials remain vault references; decrypted headers exist only during a call,
never in service inventory, logs, audit records, or status output.

Every configured native API must exist in the selected service endpoint map.
Hosted calls use the exact configured URL. The platform never attempts direct
discovery, health HTTP requests, or direct proxy fallback to a hosted endpoint.
Existing provider model routing, protocol gating, authorization, rate limiting,
model mapping, and access observation remain in place.

## Transport

`backplane_system` owns a small protocol-neutral host/request registry and
request transport. `backplane_api` binds it to the currently authenticated host
channel, checking active credentials, host identity, and connection incarnation.
`backplane_llama` uses this transport from a proxy adapter. This avoids a new
Llama-to-Skills dependency.

Agents opt in by offering `host_api.v1` during join. The channel sends the current
enabled service inventory on join and configuration change, and revalidates service
ownership and revision immediately before dispatch.
Service inventories contain no credentials. Requests name the service and API;
only the inventory resolves the endpoint URL. The agent performs POST requests
without redirects, retries, or inherited proxy routing.

The host executor uses supervised concurrent requests. Responses send headers,
numbered bounded binary chunks encoded for the channel, then an explicit terminal
frame. Chunk acknowledgement follows downstream consumption to bound buffering.
Request bodies, headers, concurrency, response size, and idle waits are bounded.
Large request bodies are explicitly rejected rather than exceeding channel limits.
Streaming retains the provider's bytes and end markers; HTTP completion alone
does not fabricate a provider terminal event.

Disconnection, caller death, cancellation, service removal, and token revocation
retire affected requests. A replacement channel cannot complete an older channel's
request. The system never automatically resubmits an ambiguous inference request.

## Verification

Focused tests cover platform CRUD/validation, host selection, credential-free local
services, supported protocol routing, full exact endpoint paths, authenticated
channel ownership, ordinary JSON, fragmented SSE, responses larger than a channel
frame, downstream cancellation, disconnect/reconnect fencing, service changes,
and existing direct-provider regressions. Run formatting and focused compilation,
then inspect the integrated diff. Runtime/deployment evidence remains separate
from controlled local execution; no real host service or production rollout is
authorized by this change.
