# Responses WebSocket capability (transport blocked)

## Pre-commit review (2026-11-06)

Remote main was rechecked at `bc200d0110fc6ce075152485599dc92f272577d5`.
The full 211-test protocol suite and 10-test standalone TCP/TLS client suite
passed again, along with client warnings-as-errors compilation and changed-file
formatting. Two integration tests now reload the persisted API between true/false
updates so they genuinely exercise disabling the declaration. Those integration
tests still have not run: umbrella compilation again failed downloading the
existing mdex_native NIF (this resumed container reported proxy connection refused;
the earlier attempt reported HTTP 403). Root dependencies/lockfile are unchanged.
The user explicitly authorized committing this partial implementation and pushing
to main. Gateway forwarding remains 501 and is not presented as complete.

## Current checkpoint: published rc.3 and standalone client (2026-11-06)

Working changes were reconciled with current Backplane main by fast-forwarding
`work` from `902b5cc4` through `d0503317` to
`bc200d0110fc6ce075152485599dc92f272577d5`. Incoming agent-runtime changes and
MCP test fixes touched no task files; all pre-existing changes were retained.
No new branch/worktree, task commit, push or release was made.

`http_web_socket 1.0.0-rc.3` is now published (2026-11-06T04:23:18Z), not retired,
and its actual tarball contains #152's fix. Publication is no longer the blocker.
The latest upstream packages still exclude this HTTP family:

| Published dependency | Relevant requirement |
| --- | --- |
| gaoxy_http 0.14.1 | http_core ~> 0.21 and >= 0.21.17 |
| duskmoon_npm 10.1.1 | http_fetch ~> 0.20.0 or ~> 0.21.0 |
| duskmoon_quickbeam 10.1.1 | http_fetch/http_event_source/http_web_socket ~> 0.20.0 or ~> 0.21.0 |
| phoenix_socket_client 0.8.9 | http_web_socket ~> 0.21.14 |

rc.3 requires exact rc.3 http_core/http_runtime. The constraints do not intersect,
and rc.3 removes the OTP TLS backend used by current Relayixir. A coordinated
compatible release/backport or supported ecosystem upgrade is required before
integrating it in the umbrella. No incompatible production overrides, dependency
changes or private-state workaround were applied. The compatibility request is now
registered as [http_fetch #155](https://github.com/gsmlg-dev/http_fetch/issues/155),
with the `internal request` label and Feature/blocker classification in its body.
The GitHub connector succeeded after the earlier CLI `Forbidden` response.
The connector did not expose a structured issue-type field. See the
[compatibility request](upstream/responses-websocket-compatible-release.md).
Latest release constraints were rechecked on 2026-11-06 at approximately 10:32 UTC;
even DuskMoon 10.1.1 excludes rc.3. Upstream publication remains necessary.

Unaffected work: [the standalone reference client](../examples/responses_websocket_client/README.md)
now provides `Backplane.ResponsesWebSocket.Client.open/3`, `create/2`,
`next_event/2`, `completion/1` and `close/1`. It is an independent Mix project
outside the umbrella, intended for client applications whose dependency graph
supports rc.3. It uses the released API and the existing pure protocol package;
it is not a gateway bypass or a replacement transport library.

Ten real TCP/TLS loopback tests passed against the exact published rc.3 artifacts:
request authentication/session headers, successful/rejected handshakes,
duplicate/oversized metadata rejection, native create/events, peer-advertised
outbound size enforcement, receive timeout, owner checks,
owner-death cleanup receipt, declared oversized frame rejection and disconnect
after submission without reconnect/replay. Four compatibility checks against
published release requirements confirmed the exclusions above. Registry requests
inside the container timed out, so the isolated verification harness compiled
unaltered official tarball contents for the matching rc.3 family, plus compatible
cached telemetry/Jason and the extracted protocol package. Path source selections
were limited to that disposable harness; the production lockfile is unchanged.
TLS 1.3 loopback verifies a test CA, native create/event exchange, cleanup and
rejection of a trusted certificate with the wrong host before HTTP credentials.
OTP SSL is only the test server; the client uses the released ex_ssl transport.
An exploratory TLS-1.2-only server failed the handshake; TLS 1.2 compatibility
is unresolved and is not claimed. No real provider, OAuth refresh or gateway
forwarding was tested. Client compilation with warnings as errors and formatting
were checked separately. The pure codec's earlier 211-test suite and package
consumer checks remain unchanged; the full umbrella suite remains unverified.

The loopback also verifies the public metadata boundary: only Retry-After and
Codex's message-size limit are returned. Other response headers are absent, even
when the server sends them. This reference client makes no broader transparency
claim. A future gateway integration must explicitly define which upstream/session
headers it promises to mirror rather than treating issue closure as full parity.

The earlier checkpoints below document the investigation history; this section
supersedes their publication and branch-state statements.

## Latest upstream checkpoint: 2026-11-06 03:23 UTC

[#152](https://github.com/gsmlg-dev/http_fetch/issues/152) is now closed as completed
(closed 2026-11-06T03:06:35Z). Source commit
[`27e5fe6`](https://github.com/gsmlg-dev/http_fetch/commit/27e5fe617d31b0eaa8dd4e36487c89e1b0258ab2)
adds handshake metadata to Open/Error events, literal dial controls and separate
frame/read bounds. Its changelog places the fix in `1.0.0-rc.3`.

Publication is still pending: the Hex package index reports latest
`1.0.0-rc.2`; both the [rc.3 release endpoint](https://hex.pm/api/packages/http_web_socket/releases/1.0.0-rc.3)
and [rc.3 tarball](https://repo.hex.pm/tarballs/http_web_socket-1.0.0-rc.3.tar)
returned HTTP 404 at the checkpoint. Thus no supported published artifact could
be adopted or loopback-tested for this fix. No Git pin, vendoring or dependency
workaround was introduced. The following older checkpoints are historical.

The source fix exposes status plus a deliberately fixed response-header allowlist:
`retry-after` and `x-codex-websocket-max-unfragmented-message-bytes` only. Values
must occur once and fit 1024 bytes each; duplicate/oversized selected values are
omitted and mark metadata truncated. Other response headers are not exposed.
This addresses #152's specific metadata contract, but does not establish the
broader gateway session/routing-header forwarding contract. On publication,
verify the exact required header set and supported extension point before
claiming transparent forwarding; do not read private socket state to fill gaps.
No duplicate issue or new upstream mutation was made in this checkpoint.

## Implemented scope

`llm_provider_apis.responses_websocket` is a non-null boolean, default false.
It declares an upstream capability independently of Responses HTTP/SSE and
`responses_lifecycle`. Enabling it requires the OpenAI surface with the native
`openai_responses` protocol; it does not imply a cancel or steering event.
Both provider creation and editing persist the setting and show its current
limitation. The trusted provider management API serializes the declaration.
It is deliberately not advertised as a usable transport in `/v1/models`.

`GET /v1/responses` passes through normal resource authentication and requires
`llm::invoke`, including for OAuth and DB client tokens. It currently returns
HTTP 501 with code `responses_websocket_unavailable`, before any downstream
upgrade or upstream connection, regardless of the stored declaration. Existing
POST Responses and response-ID lifecycle paths are unchanged. This is configuration
foundation, **not completed Responses WebSocket forwarding**.

## Blocking dependency and registration

Examined main `902b5cc4cdcbcc6ed5f5e2c4cb36f3b3fee0fc7f` and its locked
`http_web_socket 0.21.19` Hex source (upstream `gsmlg-dev/http_fetch`).
`HTTP.WebSocket.Event.Open` has only `target` and `type`; `protocol/1` exposes
the selected subprotocol, but no public API returns handshake response headers.
The HTTP/1 connection implementation receives headers and retains only the
validated negotiation result. `status/1` contains connection/queue state, not
handshake metadata. Therefore upstream session/routing response headers cannot
be forwarded transparently with this API.

The current Relayixir WebSocket plug also discards authentication and session
request headers (keeps only subprotocol headers), and upgrades downstream before
connecting upstream. Wiring it into the LLM router would not satisfy the contract.
No replacement transport, private-state inspection, or handshake workaround was
added: AGENTS.md prohibits local workarounds for upstream blockers.

The existing upstream blocker is
[gsmlg-dev/http_fetch#152](https://github.com/gsmlg-dev/http_fetch/issues/152),
“Expose WebSocket dial controls and bounded handshake metadata for transport
migrations.” Read through the GitHub connector on 2026-11-05: open, label
`internal request`, severity blocker in its body, no comments. Item 2 explicitly
requests successful and rejected upgrade metadata, including Retry-After and
Codex's `x-codex-websocket-max-unfragmented-message-bytes`. This covers the missing
public handshake metadata capability; no duplicate issue is needed. Its future
implementation still must be checked for Backplane's required allowed session
headers and safe pre-upgrade forwarding, not merely an issue-closed status.
The reserved route now references this issue with `TODO(upstream)`.

The earlier `gh issue create` attempt returned GitHub `Forbidden` and obtained no
issue number. The [draft](upstream/responses-websocket-handshake-issue.md) is
retained only as historical Backplane-specific requirements, explicitly superseded
by #152; do not submit it as another issue. The connector read succeeded on this
follow-up, so issue registration is no longer an outstanding task. No issue was
created, edited or commented on during the follow-up. Agent Note recall was
performed earlier; its shared skill was unavailable, so no shared note was written.

### Published-version check (2026-11-05)

The [Hex package index](https://hex.pm/api/packages/http_web_socket) lists
`0.21.19` as the latest non-prerelease and `1.0.0-rc.2` as the latest publication
(published 2026-11-05T01:15:51Z). Inspected the actual
[rc.2 package](https://repo.hex.pm/tarballs/http_web_socket-1.0.0-rc.2.tar), not
only release labels:

- `Event.Open` still has only `target`/`type`, unchanged from 0.21.19.
- `protocol/1`, `extensions/1` and `status/1` still do not return response headers.
- `Connection.http1_open/2` still reduces the handshake to negotiated protocol
  and buffered data; `Handshake.validate_status/1` returns only
  `{:unexpected_status, status}` on rejection.
- The public module documentation now explicitly rejects legacy OTP `:ssl` TLS
  selections, whereas Relayixir's existing client passes `tls_backend: :ssl`.
- rc.2 requires exactly matching `http_core` and `http_runtime` rc.2 packages.
  It does not fit the repository's `~> 0.21.19` constraints.

Therefore no inspected published fix resolves #152; no dependency upgrade or
runtime forwarding was attempted. `mix.lock` and dependency declarations remain
unchanged. A future upgrade needs both the metadata feature and a deliberate
HTTP-family/TLS compatibility migration, followed by the transport tests below.

## Remaining transport design and acceptance gates

- Authenticate before upgrade. Resolve a native Responses route using the selected
  model and only APIs with the declaration enabled. Model may arrive in the first
  `response.create` frame instead of the query; this requires an explicit contract
  for routing before handshake response metadata can be mirrored. Do not silently
  pick an upstream or claim transparent handshakes in a lazy-connect design.
- Pin provider API, resolved model, credential identity and principal to the
  connection. Resolve aliases explicitly. Reject a later request needing another
  upstream/credential rather than moving `previous_response_id` state. Check
  model authorization, rate limits and request policy on every creation event,
  not merely on the upgrade. Preserve unknown protocol fields/events; apply only
  documented routing changes. Decide how HTTP-only transformations are rejected.
- Replace the downstream gateway bearer with provider-specific credentials,
  including refreshed Codex OAuth/account headers when applicable. Preserve
  allowed session/beta/routing headers and provider defaults with explicit
  precedence; remove hop-by-hop and Connection-nominated headers. Do not echo
  credentials, blindly forward cookies, or forward a downstream WebSocket key.
- Await a validated upstream handshake with bounded timeout. Mirror allowed
  response/session metadata and the selected offered subprotocol, not upstream
  Sec-WebSocket-Accept/key or unsupported extension negotiations. Propagate safe
  rejection metadata before upgrading where possible.
- One supervised session owns the upstream and monitors downstream. Bound queues,
  frame sizes and pending sends, preserve ordered text/binary/control/close
  semantics, and cancel/await cleanup on disconnect, timeout or owner death.
  No reconnection, retry or replay after a possible submission; transport closure
  is not application cancellation acknowledgement.
- Do not infer Codex OAuth REST cancellation or interrupt/steering support from
  this switch. Do not populate the HTTP background route store without a separate
  supported ownership/continuation contract.
- Require real loopback tests for auth/session headers, selected protocol and
  handshake response headers, rejection/timeout, per-event controls, multiple
  requests, alias pinning, backpressure, bidirectional disconnect and uncertain
  submission without replay. These are not verified by the configuration tests.

## Verification in the cloud workspace

- Elixir 1.18.6 / OTP 28 container: five isolated ExUnit checks passed (the
  three repository changeset tests plus two smoke tests). These compiled the
  actual Provider/ProviderApi, related model schemas, ResourceAuthorization and
  migration against locked Ecto/Plug dependencies. A disposable PostgreSQL 17
  database verified the migration on an existing row, default false, true/false
  persistence, NOT NULL enforcement and migration rollback. The smoke schema was
  minimal; this was not the complete Backplane migration/application suite.
- Changed-file `mix format --check-formatted` and `git diff --check` passed.
  Phoenix LiveView's HTML formatter parsed all ten HEEx templates in the two
  modified provider screens. This is syntax validation, not a rendered UI test.
- Added normal-suite coverage for config persistence, new/edit UI round trip,
  management serialization, OAuth/DB-token scope checks, and authenticated
  fail-closed upgrade rejection with either flag value. These integration tests
  have **not run**: umbrella `MIX_ENV=test mix compile` failed downloading the
  existing `mdex_native 0.3.1` NIF from `artifacts.mdelixir.dev` (HTTP 403).
  Trying the Llama app independently also hit existing dependency divergence
  (`websock_adapter` Hex identity/override). No dependency versions were changed.
- No live provider, WebSocket handshake/frame/disconnect forwarding, browser
  screenshot, full HTTP regression suite, Credo, Dialyzer, release or deployment
  verification was performed. HTTP code paths were preserved by inspection only.

Once build access is restored, run the focused config, response_capability,
resource_authorization, router and api_router tests under backplane_llama, the
providers_live tests under backplane_admin, and the existing Responses HTTP/SSE
endpoint suite before considering the configuration foundation ready to merge.

## Reusable client protocol layer

The clarified requirement includes other client applications. The available
implementation now also lives in the independently consumable
`backplane_ai_protocol` package as `Backplane.AiProtocol.OpenAIResponsesWebSocket`:

- `encode_create/2`: native string-keyed parameters to one JSON text message.
- `encode_request/2`: canonical Request through the existing Responses codec,
  removing only its transport-specific HTTP stream field.
- `decode_event/2`: one complete text message to bounded native data, retaining
  unknown fields/types and stream/response IDs for the host to correlate.

This is a pure message codec, not an end-to-end networking client. The existing
`Wire` module is a different Backplane-specific protocol; neither it nor SSE
framing is placed on the native Responses connection. Reusable protocol code
has no gateway, Phoenix, database, HTTP client, credentials or process dependency.
No cancellation/steering operation, reconnect or replay policy is introduced.

Other applications can use these functions with their own existing supported
WebSocket transport. Backplane does not supply a replacement transport to bypass
#152: a built-in adapter and gateway forwarding remain blocked. Hosts must still
own handshake metadata, bounded frame reassembly, connection and response
correlation, per-request policy, errors and cleanup. Protocol byte bounds alone
do not establish transport buffering or cancellation guarantees.

Implementation order after this foundation: resolve #152 in a supported release;
verify HTTP-family/TLS compatibility; add an independently testable transport
adapter with owner cleanup and no implicit retries; compose it with gateway
routing/credentials; then validate third-party clients against the public gateway.

Reusable-layer verification (2026-11-06): the focused new module tests passed
7/7, and the complete owning `backplane_ai_protocol` suite passed 211/211.
Owning-package warnings-as-errors compilation, changed Elixir file formatting
and `git diff --check` passed. `scripts/verify_ai_protocol_package.sh` built and
extracted the package, then compiled and tested all three standalone consumers,
including the new `responses_websocket_consumer`, with no host/database/Phoenix
transitive dependencies. The new consumer also checks that HTTP.WebSocket is
not loaded. Hex registry lookups timed out and used cache successfully; this
verification did not modify the workspace lockfile. These tests establish
portable message-codec consumption, not a working network client or gateway.
