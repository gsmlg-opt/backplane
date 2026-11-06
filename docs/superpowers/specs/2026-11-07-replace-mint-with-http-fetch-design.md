# Design: Replace Mint & Mint.WebSocket with HTTP.Fetch & HTTP.WebSocket

## 1. Context & Motivation

Backplane has adopted `:http_fetch` (`HTTP.fetch`, `HTTP.Promise`, `HTTP.Stream`) and `:http_web_socket` (`HTTP.WebSocket`) as the unified HTTP and WebSocket client foundations across the platform.

Currently, legacy dependencies on `:mint` and `:mint_web_socket` linger in a few places:
1. `apps/relayixir`:
   - `mix.exs` contains `{:mint, "~> 1.6", only: :test}` and `{:mint_web_socket, "~> 1.0", only: :test}`.
   - `Relayixir.Proxy.WebSocket.Frame` has legacy `from_mint/1` and `to_mint/1` converters.
   - `test/relayixir/proxy/websocket/integration_test.exs` and `header_filtering_test.exs` drive test downstream clients using `Mint.HTTP` and `Mint.WebSocket`.
   - Docs reference Mint from early design iterations.
2. `apps/backplane_llama`:
   - `Backplane.Audio.HTTP` uses `Mint.HTTP` for bounded HTTP/1 POST transport with streaming uploads and responses.
   - `test/backplane/audio/downstream_test.exs` tests HTTP/2 and HTTP/1 server transport using `Mint.HTTP` and `Mint.HTTP2`.
3. `apps/backplane_api`:
   - `test/backplane/api/audio_loopback_endpoint_test.exs` uses `Mint.HTTP` and `Mint.HTTP2` for loopback testing.
4. `apps/backplane_mcp`:
   - `test/backplane/transport/sse_http_test.exs` uses `Mint.HTTP` for testing SSE streams across HTTP/1 and HTTP/2.
5. `mix.lock`:
   - Contains locked entries for `mint`, `mint_web_socket`, and orphaned `finch`.

The goal is to cleanly eliminate `:mint` and `:mint_web_socket` from the entire repository, standardizing on `:http_fetch` and `:http_web_socket`.

---

## 2. Component Migration Design

### 2.1 `apps/relayixir`

#### 2.1.1 Frame API Cleanup
- In `Relayixir.Proxy.WebSocket.Frame`:
  - Remove `from_mint/1` and `to_mint/1`. (They are not used in production proxy bridging; `UpstreamClient` already directly matches on `HTTP.WebSocket.Event.Frame` and sends `%Frame{}`).
  - Retain `text/1`, `binary/1`, `ping/1`, `pong/1`, `close/2`, and `to_websock/1`.
  - Update `frame_test.exs` to remove tests for `from_mint` and `to_mint`.

#### 2.1.2 Test Suite Migration
- In `test/relayixir/proxy/websocket/integration_test.exs`:
  - Replace the Mint-based client with `HTTP.WebSocket.new("http://127.0.0.1:#{proxy_port}/ws")`.
  - Assert messages received from `{HTTP.WebSocket, socket, %HTTP.WebSocket.Event.Open{}}`, `%HTTP.WebSocket.Event.Message{}`, `%HTTP.WebSocket.Event.Close{}`.
  - Send frames using `HTTP.WebSocket.send/2` (text/binary) and `HTTP.WebSocket.close/3`.
  - Replace `Mint.HTTP` in the non-WebSocket fallback test with `HTTP.fetch("http://127.0.0.1:#{proxy_port}/ws")`.
- In `test/relayixir/proxy/websocket/header_filtering_test.exs`:
  - Replace Mint client with `HTTP.WebSocket.new("http://127.0.0.1:#{proxy_port}/ws", protocols: [...])`.
  - Verify subprotocol negotiation via `HTTP.WebSocket.protocol(socket)` and message exchanges.

#### 2.1.3 Dependency & Documentation Cleanup
- In `apps/relayixir/mix.exs`:
  - Remove `{:mint, "~> 1.6", only: :test}` and `{:mint_web_socket, "~> 1.0", only: :test}`.
- Update `apps/relayixir/README.md` and docs to remove obsolete references to Mint as a test dependency.

---

### 2.2 `apps/backplane_llama`

#### 2.2.1 `Backplane.Audio.HTTP` Transport
- Replace `Mint.HTTP` passive connection, request streaming, and response event loop with `HTTP.fetch`:
  - **URL / Origin Validation**: Retain existing URI validation and query merging.
  - **Request Configuration**:
    - `method: "POST"`
    - `headers`: Include `"accept-encoding" => "identity"`, `"content-length"`, and provided headers.
    - `timeout`: Bounded by remaining deadline (`remaining = max(deadline - System.monotonic_time(:millisecond), 0)`).
    - `connect_timeout`: `min(timeout, 10_000)`.
  - **Body Streaming**:
    - Binary body: Sent directly via `body: body`.
    - `{:enumerable, size, enumerable}`: Create an `HTTP.Stream` using `HTTP.Stream.from_enumerable(enumerable)` and pass `body: stream, duplex: "half"`.
    - `{:file, prefix, path, suffix}`: Create an enumerable stream:
      ```elixir
      enumerable =
        Stream.concat([
          [IO.iodata_to_binary(prefix)],
          File.stream!(path, [], 32_768),
          [IO.iodata_to_binary(suffix)]
        ])
      {:ok, stream} = HTTP.Stream.from_enumerable(enumerable)
      ```
  - **Response Processing**:
    - Await response promise.
    - If response body is streamed (`is_pid(response.body)`):
      Consume chunks incrementally by sending `{:read_chunk, self(), :ack}` to the stream PID, enforcing `max_bytes` check, and passing data to `receiver.(data, acc)` or `receiver.(data, response, acc)`.
    - If response body is buffered binary:
      Check `byte_size(body) <= max_bytes` and dispatch to `deliver_data`.
    - Return `{:ok, status, headers, acc}` on 2xx status; map non-2xx statuses to `Error.new(status, "Provider rejected audio request", ...)` as previously.
    - Map timeout and connection failures cleanly to `Backplane.Audio.Error` structs matching existing contract.

#### 2.2.2 `test/backplane/audio/downstream_test.exs`
- For HTTP/1 tests: `:gen_tcp` is already used for the majority of raw socket tests.
- For HTTP/2 h2c tests (lines 201-233):
  - Use `HTTP.fetch(url, http_version: :h2c, ...)` with `HTTP.AbortController` for request cancellation / stream reset.
  - Or use raw HTTP/2 frames via `:gen_tcp` / `HTTP.HTTP2` where exact frame-level reset assertion is needed.

---

### 2.3 `apps/backplane_api`

#### 2.3.1 `test/backplane/api/audio_loopback_endpoint_test.exs`
- Replace `Mint.HTTP` connections with `HTTP.fetch` or standard HTTP client calls.
- For concurrent and streaming requests, use `HTTP.fetch` with `HTTP.Promise.await` or `Task.async`.
- For HTTP/2 cancellation tests, use `HTTP.fetch` with `http_version: :h2c` and `HTTP.AbortController`.

---

### 2.4 `apps/backplane_mcp`

#### 2.4.1 `test/backplane/transport/sse_http_test.exs`
- Replace `Mint.HTTP1` and `Mint.HTTP2` calls with:
  - `HTTP.fetch(url, method: "POST", http_version: :http1, ...)`
  - `HTTP.fetch(url, method: "POST", http_version: :h2c, ...)`
  - Read response chunks from `response.body` (stream PID) to assert SSE events (`event: message\n`, `: connected\n\n`).

---

### 2.5 Dependencies & `mix.lock`

- Root `mix.exs`:
  - Add `{:http_fetch, "~> 0.21.19", override: true}` to ensure consistent resolution across the umbrella.
- Run `mix deps.unlock mint mint_web_socket finch`.
- Run `mix deps.get`.
- Verify `mint`, `mint_web_socket`, and `finch` are completely absent from `mix.lock`.

---

## 3. Verification

1. Unit & Integration Tests:
   - `mix test apps/relayixir`
   - `mix test apps/backplane_llama/test/backplane/audio/`
   - `mix test apps/backplane_api/test/backplane/api/audio_loopback_endpoint_test.exs`
   - `mix test apps/backplane_mcp/test/backplane/transport/sse_http_test.exs`
   - `test/mcp_protocol_packages/server/verify.exs` (verifying Finch and Mint are not in dependencies or started)
2. Quality Checks:
   - `mix format --check-formatted`
   - `mix compile --warnings-as-errors`
   - `mix credo --strict`
   - `mix dialyzer`
