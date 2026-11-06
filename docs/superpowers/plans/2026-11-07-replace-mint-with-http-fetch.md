# Replace Mint & Mint.WebSocket with HTTP.Fetch & HTTP.WebSocket Implementation Plan

> **For agentic workers:** Execute tasks sequentially with focused verification per step.

**Goal:** Completely remove `:mint` and `:mint_web_socket` dependencies across the `backplane` umbrella repository, replacing all usage with `:http_fetch` (`HTTP.fetch`, `HTTP.Promise`, `HTTP.Stream`) and `:http_web_socket` (`HTTP.WebSocket`).

**Tech Stack:** Elixir 1.18+ / OTP 28, `http_fetch` ~> 0.21.19, `http_web_socket` ~> 0.21.19, Gaoxy HTTP, Plug.

---

## Task 1: `apps/relayixir` Migration

**Files:**
- `apps/relayixir/lib/relayixir/proxy/websocket/frame.ex`
- `apps/relayixir/test/relayixir/proxy/websocket/frame_test.exs`
- `apps/relayixir/test/relayixir/proxy/websocket/integration_test.exs`
- `apps/relayixir/test/relayixir/proxy/websocket/header_filtering_test.exs`
- `apps/relayixir/mix.exs`
- `apps/relayixir/README.md`

- [ ] In `apps/relayixir/lib/relayixir/proxy/websocket/frame.ex`, remove `from_mint/1` and `to_mint/1`.
- [ ] In `apps/relayixir/test/relayixir/proxy/websocket/frame_test.exs`, remove test cases for `from_mint/1` and `to_mint/1`.
- [ ] In `apps/relayixir/test/relayixir/proxy/websocket/integration_test.exs`:
  - Replace downstream Mint test client with `HTTP.WebSocket.new("http://127.0.0.1:#{proxy_port}/ws")`.
  - Assert message events via `{HTTP.WebSocket, socket, %HTTP.WebSocket.Event.Open{}}`, `%HTTP.WebSocket.Event.Message{}`, `%HTTP.WebSocket.Event.Close{}`.
  - Send frames using `HTTP.WebSocket.send/2` (text & binary array_buffer) and `HTTP.WebSocket.close/3`.
  - Replace non-WebSocket GET request test with `HTTP.fetch/2`.
- [ ] In `apps/relayixir/test/relayixir/proxy/websocket/header_filtering_test.exs`:
  - Replace Mint client with `HTTP.WebSocket.new/2` passing `protocols: [...]`.
  - Assert negotiated subprotocol using `HTTP.WebSocket.protocol(socket)`.
- [ ] In `apps/relayixir/mix.exs`:
  - Remove `{:mint, "~> 1.6", only: :test}` and `{:mint_web_socket, "~> 1.0", only: :test}`.
- [ ] In `apps/relayixir/README.md`, update text referencing Mint.
- [ ] Verify: `mix test apps/relayixir/test/` passes.

---

## Task 2: `apps/backplane_llama` Audio HTTP Transport Migration

**Files:**
- `apps/backplane_llama/lib/backplane/audio/http.ex`
- `apps/backplane_llama/test/backplane/audio/downstream_test.exs`

- [ ] In `apps/backplane_llama/lib/backplane/audio/http.ex`:
  - Re-implement `post/8` using `HTTP.fetch`.
  - Handle body streaming:
    - Binary: `body: body`.
    - `{:enumerable, size, enumerable}`: Create `HTTP.Stream` via `HTTP.Stream.from_enumerable` and set `body: stream, duplex: "half"`.
    - `{:file, prefix, path, suffix}`: Create concatenated stream and pipe to `HTTP.Stream.from_enumerable`.
  - Consume streaming responses incrementally:
    - If `response.body` is a PID, stream chunks with `{:read_chunk, self(), :ack}`.
    - Check byte bounds against `max_bytes`.
    - Deliver chunks via `deliver_data`.
  - Map status codes, error codes, and timeouts matching the existing `Backplane.Audio.Error` specification.
- [ ] In `apps/backplane_llama/test/backplane/audio/downstream_test.exs`:
  - Replace Mint HTTP/1 and HTTP/2 test client calls with `HTTP.fetch` (with `http_version: :h2c` and `HTTP.AbortController` where cancellation is tested) or `:gen_tcp`.
- [ ] Verify: `mix test apps/backplane_llama/test/backplane/audio/` passes.

---

## Task 3: `apps/backplane_api` Audio Loopback Test Migration

**Files:**
- `apps/backplane_api/test/backplane/api/audio_loopback_endpoint_test.exs`

- [ ] Replace `Mint.HTTP` and `Mint.HTTP2` client helpers with `HTTP.fetch` (`http_version: :http1` and `http_version: :h2c`).
- [ ] For HTTP/2 cancellation tests, use `HTTP.AbortController.abort/1`.
- [ ] Verify: `mix test apps/backplane_api/test/backplane/api/audio_loopback_endpoint_test.exs` passes.

---

## Task 4: `apps/backplane_mcp` Transport Test Migration

**Files:**
- `apps/backplane_mcp/test/backplane/transport/sse_http_test.exs`

- [ ] Replace `Mint.HTTP1` and `Mint.HTTP2` calls with `HTTP.fetch`:
  - Connect with `http_version: :http1` and `http_version: :h2c`.
  - Read response chunks from `response.body` (stream PID) to assert SSE events (`event: message\n`, `: connected\n\n`).
- [ ] Verify: `mix test apps/backplane_mcp/test/backplane/transport/sse_http_test.exs` passes.

---

## Task 5: Dependency Cleanup & Lockfile Unlocking

**Files:**
- `mix.exs`
- `mix.lock`

- [ ] In root `mix.exs`, add `{:http_fetch, "~> 0.21.19", override: true}` alongside `http_web_socket`.
- [ ] Run `mix deps.unlock mint mint_web_socket finch`.
- [ ] Run `mix deps.get`.
- [ ] Assert `mint`, `mint_web_socket`, and `finch` are not in `mix.lock`.
- [ ] Run check verifying Finch and Mint are not in dependencies or started applications.

---

## Task 6: Full Verification & Code Quality

- [ ] Run `mix compile --warnings-as-errors`.
- [ ] Run `mix format --check-formatted`.
- [ ] Run `mix credo --strict`.
- [ ] Run `mix dialyzer`.
- [ ] Run full test suite: `mix test`.
