# Responses lifecycle and stream recovery

Backplane can route later requests for the same native Responses object to the
provider and credential context that created it. The feature is an explicit
per-provider-API opt-in, disabled by default. It does not automatically reconnect
a client, run a new generation, or make an OpenAI-compatible service implement
OpenAI's background APIs.

Ordinary `POST /v1/responses` behavior stays transparent. Backplane does not inject
`background`, `stream`, or `store`, and does not convert native Responses requests
to another protocol. Model routing and existing model-name normalization still
apply. A disabled API can transparently forward a caller's `background: true`, but
Backplane does not create a recovery index for that response. A later lifecycle
request for that untracked ID returns an explicit `response_not_found` error.

## Enable only a verified provider

After applying the database migration, use the trusted management context to
configure the specific OpenAI API surface, for example in an operator console:

```elixir
alias Backplane.LLM.ProviderApi

api = ProviderApi.get("<provider-api-uuid>")
{:ok, api} = ProviderApi.update(api, %{
  responses_lifecycle: true,
  responses_route_ttl_seconds: 86_400
})
```

`responses_lifecycle` is an operator attestation that this provider and API target
support OpenAI's native create, retrieve, background stream replay, cancel and
delete contracts. Test the actual provider/model/account before enabling it.
The API must declare `:openai_responses` as a native protocol and use an API-key
credential. Codex OAuth and other OAuth credential types are excluded. A
provider's name, preset or OpenAI-compatible URL does not enable the feature.
Unsupported or invalid capability configuration is rejected, rather than
translated or silently downgraded. In this enabled mode, callers cannot supply
`OpenAI-Project` or `OpenAI-Organization` headers: these return 422
`response_scope_header_unsupported` on creation and later lifecycle requests.
An operator can set those identifiers in `provider.default_headers`; they then
remain part of the fingerprinted routing context. The ordinary disabled proxy
continues to forward caller-supplied scope headers.

The default route lifetime is 86,400 seconds; accepted configuration is 60 to
2,592,000 seconds. This controls Backplane's routing window, not the provider's
response retention or SSE replay window. All native Responses creations on an
enabled API require an authenticated client identity and a durable index admission,
even when the caller has not requested background execution. Local open-access
mode cannot establish recovery ownership and is rejected for this opt-in path.

`Backplane.AiProtocol.Codec.OpenAIResponses.decode_response/4` remains a
terminal conversion codec: its complete-response decoder accepts `completed` and
`incomplete`, rather than background polling objects in `queued` or `in_progress`.
The native public proxy and recovery mapper do not call that decoder. They retain
active states and native failed/cancelled objects as provider data, so an internal
conversion limitation does not reject ordinary lifecycle traffic.

The provider-scoped Codex whitelist remains `GET models`, `POST responses` and
`POST responses/compact`. No retrieve/cancel/delete or replay capability has been
established for that upstream. The new lifecycle routes are ordinary `/v1` routes;
they do not expand the Codex whitelist. No live provider was qualified by the
repository's deterministic mock tests.

## HTTP contract

Use the same Backplane client or OAuth identity that created the response. Both
authentication and `llm::invoke` scope are required for lifecycle operations,
including GET and DELETE. Provider rate limits and LLM access auditing apply.

| Request | Behavior |
| --- | --- |
| `POST /v1/responses` | Create; on an enabled API, persist admission before submission and bind the first returned ID before exposing it |
| `GET /v1/responses/{id}` | Retrieve through the original provider API and credential context, without model selection |
| `GET /v1/responses/{id}?stream=true&starting_after=N` | Forward a stream-replay request; `starting_after` is exclusive |
| `POST /v1/responses/{id}/cancel` | Forward cancellation to the original provider |
| `DELETE /v1/responses/{id}` | Forward deletion and mark a successful deletion in the local index |

Queries are forwarded in their original form, including supported `include[]`,
`stream`, `starting_after` and future provider parameters. Upstream status codes,
error bodies, relevant response headers and SSE event bytes are preserved. The
provider validates its query parameters, cancellation eligibility and replay
cursor. Other lifecycle subresources, such as `input_items`, are not implemented
or advertised by this feature.

A native SSE `error` event before the first response ID is also forwarded with its
original bytes and HTTP status. It does not create a recoverable ID; the pending
attempt remains uncertain and generation is never automatically resubmitted.

For an enabled API, Backplane requests identity content encoding so it can bind
IDs without altering event bytes. Unsupported upstream encoding, malformed
successful response objects, oversized pre-ID prefixes/frames, or persistence
failures stop the recoverable path with a diagnostic error. The ordinary disabled
proxy path retains its existing behavior. The recovery mapper bounds SSE frames
and the prefix before an ID to 1 MiB; JSON responses use the existing 50 MB response
limit. It never retains a full SSE output for later replay.

Example creation, retrieval, replay, cancellation and deletion:

```bash
curl "$BACKPLANE_URL/v1/responses" \
  -H "Authorization: Bearer $BACKPLANE_CLIENT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"verified-provider/model","input":"Explain this result","background":true,"stream":true,"store":false}'

curl "$BACKPLANE_URL/v1/responses/$RESPONSE_ID" \
  -H "Authorization: Bearer $BACKPLANE_CLIENT_TOKEN"

curl --no-buffer "$BACKPLANE_URL/v1/responses/$RESPONSE_ID?stream=true&starting_after=42" \
  -H "Authorization: Bearer $BACKPLANE_CLIENT_TOKEN"

curl -X POST "$BACKPLANE_URL/v1/responses/$RESPONSE_ID/cancel" \
  -H "Authorization: Bearer $BACKPLANE_CLIENT_TOKEN"

curl -X DELETE "$BACKPLANE_URL/v1/responses/$RESPONSE_ID" \
  -H "Authorization: Bearer $BACKPLANE_CLIENT_TOKEN"
```

OpenAI permits background requests with `store: false`; it still temporarily stores
response data for asynchronous execution and polling. Backplane does not force
`store: true`, and does not make a blanket claim about a provider/account's ZDR
eligibility. Review the actual provider's data controls. Starting another stream
requires a response originally created with both `background: true` and
`stream: true`; merely storing a synchronous response does not establish replay.

## Durable routing and failure boundaries

`llm_response_routes`, owned by `backplane_llama` with its migration in
`backplane_system`, records an attempt UUID, a hash of the authenticated principal,
response ID, provider/API IDs, a safe API target snapshot, credential ID/name,
a context fingerprint, timestamps,
last observed state and expiry. Principal identity includes the client and, for
OAuth, its subject and available partition metadata. Two callers cannot access
each other's ID; an unknown ID and an ID owned by another caller both return 404.
An ID collision for one principal never replaces its existing provider mapping.
The same provider API cannot bind one upstream ID to two different principals;
this also prevents a duplicate upstream ID from granting another caller access.

The index stores no prompt, output, event cursor, plaintext key, header snapshot or
full response. The API target snapshot strips URL user information, query and
fragment; the complete configured URL participates only in its digest. The fingerprint covers the API target, provider configuration and
encrypted credential context. Changing a provider target, relevant configuration,
credential reference, credential value or metadata fails closed with
`response_route_changed`; a follow-up never silently chooses another provider or
account. Credential rotation is deliberately conservative: an old response needs
operator reconciliation rather than automatic adoption of a new key. Disabling,
removing or deleting the original provider/API similarly stops forwarding.

Opt-in requests build authentication from the exact verified database credential
snapshot rather than a credential-name cache lookup. A lagging cache cannot
silently substitute another key. The route is revalidated before dispatch.

The mapping is read from PostgreSQL on follow-up requests and survives gateway
restarts without relying on logging or process memory. Expired routes return 410.
Expiry currently prevents access; it does not automatically delete the metadata
rows. Operators must define metadata retention and cleanup for their deployment,
including conflict/tombstone requirements. Local expiry does not cancel or delete
the response at the provider. The provider can expire an object or its replay
history sooner than the local route. Object retention does not imply that its
entire event stream remains replayable.

| Condition | Result / client action |
| --- | --- |
| Database unavailable before admission | 503 `responses_index_unavailable`; no upstream creation is sent |
| ID cannot be durably bound | No recoverable ID is exposed; JSON returns an error with `x-should-retry: false`, or an already-open SSE stream emits an error and stops |
| Submission disconnects/times out before an ID arrives | `response_outcome_uncertain`, `x-should-retry: false` and an attempt UUID in `x-backplane-response-attempt`; no automatic POST retry |
| Missing, untracked, deleted or differently owned ID | 404 `response_not_found`; do not create a replacement automatically |
| Expired local route | 410 `response_expired`; reconcile provider state through an authorized operator if needed |
| Changed provider/API/credential context | 409 `response_route_changed`; operator reconciliation required |
| Unsupported opt-in capability | 422 `responses_lifecycle_unsupported`; correct the provider configuration |
| Caller-supplied OpenAI project/organization headers | 422 `response_scope_header_unsupported`; use operator-configured provider scope |
| Provider rejects cursor, response ID or operation | Preserve its status/error; stop retrying permanent failures |
| Replay transport interruption | Retry GET with bounded backoff and the last applied cursor; query full status if necessary |

An upstream may accept a create before a timeout or before local binding fails.
The attempt record is then evidence of uncertainty, not permission to replay the
POST. Neither the gateway nor a client should resubmit generation merely because
it has no ID. The attempt UUID is diagnostic metadata, not a response ID and not
an idempotency guarantee. The local `x-should-retry: false` hint discourages retries
in supporting SDKs; clients must still disable automatic creation retries, because
not every client honors it and a disconnect can occur before response headers.
Backplane preserves an upstream HTTP error's retry headers rather than replacing
them with this local hint. Backplane leaves Relayixir's ordinary disconnect contract
intact: the downstream disconnect closes the upstream connection. A true background
response continues at a provider that supports that behavior; Backplane does not
keep all upstream connections alive to simulate it.

Admission starts as `submitting`. Immediately before the one upstream send, the
attempt is durably marked `uncertain`; binding the ID replaces it with the observed
response state. Caller or gateway death before an ID arrives therefore leaves an
explicitly uncertain record even when a finalizer cannot run. This conservative
state does not prove that the provider accepted or charged for the operation.

## Client checkpoints and recovery

The LLM proxy does not own an application display or a durable Responses stream
consumer. Backplane's agent runtime has separate provider adapters and tool
execution contracts; it is not a client that creates and resumes background
responses through these public routes. `Backplane.Services.WebXSearch` is another
internal Responses caller: it makes synchronous JSON requests directly to its
configured search provider with `store: false`, without background streaming or
replay. It remains synchronous; its upstream has not been qualified for this
feature. No server-side change can restore a remote application's unpersisted
output or cursor.

A client integrating this API should:

1. Create once with explicit `background: true, stream: true` on a verified API.
   Disable automatic SDK retries for the creation POST unless a separately verified
   upstream idempotency mechanism is in use.
2. Persist `response.id` from `response.created`, scoped to the authenticated account.
   Persist the last **successfully applied durable event** `sequence_number` together
   with the corresponding output/state in one local transaction.
3. Ignore SSE comments and transport `keepalive` events for cursor advancement,
   even if a keepalive carries a connection-local sequence counter. Preserve unknown
   provider events as appropriate for the application's event model.
4. After a network interruption, issue GET for the same response ID with
   `stream=true&starting_after=<last-applied-number>`. Deduplicate event sequences
   before applying output. Serialize consumers for one response or coordinate them
   through an atomic local checkpoint.
5. Use bounded exponential backoff with jitter for transient network/5xx failures.
   Stop for ownership errors, an expired cursor/route, unsupported replay or a
   permanently missing response. Never fall back to another creation POST.
6. Treat `queued` and `in_progress` as active. Stop generation recovery at
   `completed`, `failed`, `cancelled` or `incomplete`; those are response outcomes,
   not reconnectable network errors. If a stream ends without a terminal event,
   retrieve the full response to reconcile its state and current output. Handle
   unavailable replay explicitly instead of retrying forever.

The checkpoint core can look like this pseudocode; the application supplies its
own durable transaction and SSE parser:

```javascript
async function applyStoredEvent(event, checkpointStore) {
  if (event.type === "keepalive" || !event.type.startsWith("response.")) return;
  if (!Number.isSafeInteger(event.sequence_number)) return;

  await checkpointStore.transaction(async (tx) => {
    const state = await tx.load();
    const id = event.response?.id ?? state.responseId;
    if (!id) throw new Error("No response ID; do not retry generation automatically");
    if (state.responseId && state.responseId !== id) throw new Error("Response changed");
    if (event.sequence_number <= state.lastAppliedSequence) return;

    // Apply the event and advance the cursor atomically. A crash cannot persist
    // the cursor while losing the output, or persist output without dedup state.
    await tx.applyEvent(event);
    await tx.save({ responseId: id, lastAppliedSequence: event.sequence_number });
  });
}

// After an interrupted stream, read the checkpoint and resume the same object:
// GET /v1/responses/{responseId}?stream=true&starting_after={lastAppliedSequence}
// Use a bounded retry budget; check the full response if no terminal event arrives.
```

`previous_response_id` creates the next conversational response. It is not a stream
cursor and must never be used to recover the interrupted response. Replaying tool
call events likewise does not make external tools execute exactly once. This
proxy forwards tool events; it does not execute them. A client/agent that executes
tools needs a separate durable execution ledger, stable invocation IDs and an
idempotency policy for each external side effect. Advancing an SSE cursor alone
cannot establish that guarantee.

## Evidence and references

The deterministic endpoint tests use listening loopback gateway and mock-upstream
servers, fragmented events, a real downstream socket disconnect and a second GET.
They check original routing, query/error bytes, applied cursor/dedup behavior,
ownership/scopes, configuration changes, persistence failure and uncertain
submission. They are not live OpenAI or Codex integration evidence. Existing
ordinary proxy disconnect tests continue to require exactly one upstream POST.

Official API references, checked 2026-11-04:

- [Background mode](https://developers.openai.com/api/docs/guides/background)
- [Retrieve a response](https://developers.openai.com/api/reference/resources/responses/methods/retrieve)
- [Cancel a response](https://developers.openai.com/api/reference/resources/responses/methods/cancel)
- [Delete a response](https://developers.openai.com/api/reference/resources/responses/methods/delete)
