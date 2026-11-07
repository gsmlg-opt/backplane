# Standalone Responses WebSocket client

This reference client is intentionally a separate Mix project, outside the
Backplane umbrella. It uses published `http_web_socket == 1.0.0-rc.5` and the
extracted `backplane_ai_protocol` package containing the new message codec.
It can be consumed as a path dependency by another application with a compatible
HTTP dependency graph. It is not wired into the Backplane gateway.

```sh
# Build/extract the local protocol package first; its README documents its boundary.
export AI_PROTOCOL_PACKAGE_PATH=/absolute/path/to/extracted/backplane_ai_protocol
mix deps.get
mix test
```

The only transport dependency is the released HTTP family; there is no alternative
HTTP client, private-state access, Git pin or vendored runtime. Backplane uses the compatible RC5/Gaoxy/DuskMoon release set. The reference
client remains an independent project for other applications.

```elixir
alias Backplane.ResponsesWebSocket.Client

# The host resolves credentials; never hardcode or print real tokens.
{:ok, client, handshake} = Client.open(endpoint, [{"authorization", "Bearer " <> token}])
try do
  :ok = Client.create(client, %{"model" => model, "input" => "Hello"})
  {:ok, event} = Client.next_event(client, 5_000)
  # Continue reading until the corresponding response is terminal.
  # Route native events by stream/response identity when using multiple turns.
after
  Client.close(client)
end
```

`open/3` has finite connect/open/write/close limits and ACK-based inbound delivery.
It accepts explicit request headers and optional `connect_address`, message/frame/
read/queue bounds, request-local `ssl` trust options, and the protocol codec's `limits`/`max_encoded_bytes` options.
Default transport message size equals the codec byte cap (2 MiB). Requests have
no automatic reconnect/retry/replay. Local send success does not mean the provider
accepted/completed a response. `:submission_unknown` requires host reconciliation,
never blind resubmission. Receive timeout leaves the session open. Failed decoding
or transport failure closes it and returns the actual cleanup-barrier result.
The creating process owns the socket and all methods except `completion/1`;
owner death releases transport resources. `close/1` waits for local cleanup only.

The HTTP dependency exposes handshake status and ONLY `retry-after` and
`x-codex-websocket-max-unfragmented-message-bytes`, with `truncated?` when selected
values are duplicate/oversized. The client rejects truncated handshake metadata
and invalid peer size limits, and rejects an outgoing message exceeding the
advertised peer limit before sending. It does not fragment or replay that request.
This is not a transparent response-header API.
No credential refresh, model routing, response scheduling, Codex-specific OAuth,
interrupt/steer or public REST cancellation is implemented here. Provider `error`
events remain raw data; avoid logging sensitive event payloads.

Verification: raw TCP loopback tests cover request auth/session headers, successful
and rejected handshakes, bounded metadata, native messages, owner restrictions,
owner-death cleanup, receive timeout, oversized frames, and disconnect without
reconnect/replay. TLS 1.3 loopback tests additionally verify a caller-selected CA,
native messages, and rejection of a wrong hostname before HTTP credentials.
The committed certificate/key are public test fixtures only, valid until November
2036. OTP SSL is a test-only peer dependency; the client still uses ex_ssl.
The earlier OTP 28 TLS-1.2-only peer failure is explained: its ServerHello omits
Extended Master Secret (extension 23), and ex_ssl deliberately rejects that peer
with `:extended_master_secret_required`. The published ex_ssl README documents
this boundary. An independent verified-CA TLS 1.2 handshake and HTTP exchange with
OpenSSL 3.5.7 succeeded using ECDHE-RSA/AES-128-GCM. This qualifies that transport
subset, not native WebSocket messages over TLS 1.2 or arbitrary TLS 1.2 peers.
No real provider has been tested. See `docs/responses-websocket.md` for the gateway
contract, including its required handshake-time `model` query.
