# Issue 24 Auto-Discovery Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Streamable HTTP clients using `protocol_version: :auto` fall back to the canonical legacy initialization flow when `server/discover` returns valid JSON-RPC `-32601 Method not found`, while keeping pinned clients and all other errors unchanged.

**Architecture:** Keep era-selection policy inside `Backplane.McpProtocol.Client.Negotiation`. Normalize the HTTP 200 and decoded HTTP 400 representations through the existing recognized-error helper, then add one unpinned-only `method_not_found` clause that starts `initialize` with `Protocol.fallback_version()`.

**Tech Stack:** Elixir 1.18, OTP, ExUnit, Bypass, Plug, `Backplane.McpProtocol.Client`, Streamable HTTP, GitNexus.

---

## File Map

- `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/negotiation.ex`
  owns negotiation policy and receives the two Streamable HTTP error representations.
- `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/negotiation_test.exs`
  pins the error-classification state machine without involving a live transport.
- `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http_test.exs`
  proves the real `discover -> initialize -> initialized -> tools/list` wire flow for HTTP 200 and HTTP 400 error envelopes.
- `apps/backplane_mcp_protocol/README.md`
  documents `method_not_found` as narrow legacy evidence for auto clients.
- `apps/backplane_mcp_protocol/CHANGELOG.md`
  records the regression fix under Unreleased.

### Task 1: Add the Complete RED Matrix and Fix Negotiation

**Files:**

- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/negotiation_test.exs:4-9,573-667`
- Modify: `apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http_test.exs:4-7,87-170,785-816`
- Modify: `apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/negotiation.ex:172-194`

- [ ] **Step 1: Add unit tests for direct and wrapped method-not-found errors**

Add the `Protocol` alias:

```elixir
alias Backplane.McpProtocol.Protocol
```

Replace the current terminal recognized-error test and add the direct-response case:

```elixir
test "HTTP auto falls back on a direct discovery method-not-found error" do
  state = state(:auto, StreamableHTTP)
  request = request(discover_operation(@modern_version))
  error = Error.protocol(:method_not_found)

  assert {:send, operation, fallback} = Negotiation.handle_error(state, request, error)
  assert operation.method == "initialize"
  assert operation.params["protocolVersion"] == Protocol.fallback_version()
  assert fallback.era == :legacy
  assert fallback.negotiation_status == :initializing
  assert fallback.negotiated_version == nil
end

test "HTTP auto falls back on a recognized HTTP 400 method-not-found error" do
  state = state(:auto, StreamableHTTP)
  request = request(discover_operation(@modern_version))

  body =
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "discover",
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    })

  error =
    Error.transport(:send_failure, %{
      original_reason: {:http_error, 400, body}
    })

  assert {:send, operation, fallback} = Negotiation.handle_error(state, request, error)
  assert operation.method == "initialize"
  assert operation.params["protocolVersion"] == Protocol.fallback_version()
  assert fallback.era == :legacy
  assert fallback.negotiation_status == :initializing
end
```

Add pinned negative coverage for both representations:

```elixir
for envelope <- [:direct, :http_400] do
  test "pinned HTTP modern negotiation does not fall back on #{envelope} method not found" do
    state = state(@modern_version, StreamableHTTP)
    request = request(discover_operation(@modern_version))

    error =
      case unquote(envelope) do
        :direct ->
          Error.protocol(:method_not_found)

        :http_400 ->
          body =
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => "discover",
              "error" => %{"code" => -32_601, "message" => "Method not found"}
            })

          Error.transport(:send_failure, %{
            original_reason: {:http_error, 400, body}
          })
      end

    assert {:error, %Error{reason: :method_not_found}, failed} =
             Negotiation.handle_error(state, request, error)

    assert failed.protocol_preference == @modern_version
    assert failed.era == :modern
    assert failed.negotiation_status == :failed
  end
end
```

Add the corresponding narrow-scope guard for a different JSON-RPC error:

```elixir
for envelope <- [:direct, :http_400] do
  test "HTTP auto keeps #{envelope} invalid params terminal" do
    state = state(:auto, StreamableHTTP)
    request = request(discover_operation(@modern_version))

    error =
      case unquote(envelope) do
        :direct ->
          Error.protocol(:invalid_params)

        :http_400 ->
          body =
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => "discover",
              "error" => %{"code" => -32_602, "message" => "Invalid params"}
            })

          Error.transport(:send_failure, %{
            original_reason: {:http_error, 400, body}
          })
      end

    assert {:error, %Error{reason: :invalid_params}, failed} =
             Negotiation.handle_error(state, request, error)

    assert failed.era == :modern
    assert failed.negotiation_status == :failed
  end
end
```

Keep the existing JSON-RPC-looking HTTP 404, `-32022`, non-400/404 status,
malformed-response, network, and timeout assertions unchanged.

- [ ] **Step 2: Add real Streamable HTTP fallback tests before changing production code**

Add the protocol and response aliases:

```elixir
alias Backplane.McpProtocol.Protocol
alias Backplane.McpProtocol.MCP.Response
```

Replace the current terminal HTTP 400 integration test with table-driven HTTP
200 and HTTP 400 fallback tests:

```elixir
for status <- [200, 400] do
  test "auto falls back after HTTP #{status} JSON-RPC method not found", %{bypass: bypass} do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = JSON.decode!(body)
      send(test_pid, {:negotiation_request, request["method"]})

      case request["method"] do
        "server/discover" ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            unquote(status),
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "error" => %{"code" => -32_601, "message" => "Method not found"}
            })
          )

        "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            200,
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{
                "protocolVersion" => Protocol.fallback_version(),
                "capabilities" => %{"tools" => %{}},
                "serverInfo" => %{"name" => "LegacyHTTP", "version" => "1.0.0"}
              }
            })
          )

        "notifications/initialized" ->
          Plug.Conn.resp(conn, 202, "")

        "tools/list" ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            200,
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{
                "tools" => [
                  %{
                    "name" => "echo",
                    "description" => "Echo",
                    "inputSchema" => %{"type" => "object"}
                  }
                ]
              }
            })
          )
      end
    end)

    suffix = String.to_atom("method_not_found_#{unquote(status)}")
    {client, transport} = start_http_negotiation_client(bypass, suffix)

    assert :ok = Client.await_ready(client, timeout: 2_000)

    assert {:ok, %Response{result: %{"tools" => [%{"name" => "echo"}]}}} =
             Client.list_tools(client)

    assert_receive {:negotiation_request, "server/discover"}
    assert_receive {:negotiation_request, "initialize"}
    assert_receive {:negotiation_request, "notifications/initialized"}
    assert_receive {:negotiation_request, "tools/list"}

    assert %{
             negotiation_status: :ready,
             era: :legacy,
             negotiated_version: version
           } = Client.get_protocol_info(client)

    assert version == Protocol.fallback_version()
    assert Process.alive?(client)
    assert Process.alive?(transport)
  end
end
```

Change the helper to accept an optional preference without breaking existing
callers:

```elixir
defp start_http_negotiation_client(bypass, suffix, protocol_version \\ :auto) do
  client_name = Module.concat(__MODULE__, "#{suffix}Client")
  transport_name = Module.concat(__MODULE__, "#{suffix}Transport")
  server_url = "http://localhost:#{bypass.port}"

  _supervisor =
    start_supervised!(%{
      id: {Client, suffix},
      start:
        {Client, :start_link,
         [
           [
             name: client_name,
             transport_name: transport_name,
             transport:
               {:streamable_http,
                [
                  base_url: server_url,
                  mcp_path: "/mcp",
                  transport_opts: @test_http_opts
                ]},
             client_info: %{"name" => "HTTPNegotiation", "version" => "1.0.0"},
             capabilities: %{},
             protocol_version: protocol_version,
             timeout: 1_000
           ]
         ]},
      restart: :temporary
    })

  {Process.whereis(client_name), Process.whereis(transport_name)}
end
```

Add one pinned-modern Bypass test:

```elixir
test "pinned modern does not fall back after HTTP 400 method not found", %{bypass: bypass} do
  test_pid = self()

  Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = JSON.decode!(body)
    send(test_pid, {:negotiation_request, request["method"]})

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(
      400,
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{"code" => -32_601, "message" => "Method not found"}
      })
    )
  end)

  {client, transport} =
    start_http_negotiation_client(
      bypass,
      :pinned_method_not_found,
      @modern_version
    )

  assert {:error, %Error{reason: :method_not_found}} =
           Client.await_ready(client, timeout: 2_000)

  assert_receive {:negotiation_request, "server/discover"}
  refute_receive {:negotiation_request, "initialize"}, 50

  assert %{negotiation_status: :failed, era: :modern} =
           Client.get_protocol_info(client)

  assert Process.alive?(client)
  assert Process.alive?(transport)
end
```

- [ ] **Step 3: Run the focused files and verify RED**

Run from the issue worktree root:

```bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && \
  MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  mix test \
    test/backplane/mcp_protocol/client/negotiation_test.exs \
    test/backplane/mcp_protocol/transport/streamable_http_test.exs \
    --seed 0'
```

Expected: the new auto HTTP 200 and HTTP 400 fallback assertions fail because
negotiation returns `method_not_found`; pinned and unrelated negative tests
remain green.

- [ ] **Step 4: Implement the minimal negotiation policy**

Add a direct Streamable HTTP `method_not_found` clause beside the existing
unsupported-version clause:

```elixir
defp handle_http_discovery_error(state, request, %Error{reason: :method_not_found} = error) do
  handle_recognized_modern_error(state, request, error)
end
```

Add an unpinned-only clause before the recognized-error catch-all:

```elixir
defp handle_recognized_modern_error(
       %State{protocol_pinned?: false} = state,
       _request,
       %Error{reason: :method_not_found}
     ) do
  initialize(state, Protocol.fallback_version())
end
```

Do not change the generic catch-all, HTTP response classifier, stdio legacy
error list, error decoder, or fallback version.

- [ ] **Step 5: Run the focused files and verify GREEN**

Run:

```bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && \
  MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  mix test \
    test/backplane/mcp_protocol/client/negotiation_test.exs \
    test/backplane/mcp_protocol/transport/streamable_http_test.exs \
    --seed 0'
```

Expected: all negotiation and Streamable HTTP tests pass. The HTTP 200 and
HTTP 400 cases complete legacy `initialize`, `notifications/initialized`, and
`tools/list`; pinned clients remain terminal.

- [ ] **Step 6: Run adjacent dual-era client regressions**

Run:

```bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && \
  MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  mix test \
    test/backplane/mcp_protocol/client/dual_era_integration_test.exs \
    test/backplane/mcp_protocol/client/state_test.exs \
    test/backplane/mcp_protocol/protocol_test.exs \
    --seed 0'
```

Expected: all adjacent dual-era, state, and fallback-version tests pass.

- [ ] **Step 7: Run GitNexus change detection and commit the fix**

Run `gitnexus_detect_changes({scope: "all", repo: "backplane"})`. GitNexus
may report no indexed Elixir symbols; if so, record the UNKNOWN result and use
the focused test evidence plus direct diff review.

Then run:

```bash
git diff --check
git add -- \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/negotiation.ex \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/negotiation_test.exs \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http_test.exs
git commit -m "fix(mcp): fall back when discovery is unsupported"
```

Expected: one focused code-and-regression commit with no unrelated files.

### Task 2: Document the Behavior and Run Final Verification

**Files:**

- Modify: `apps/backplane_mcp_protocol/README.md:103-108`
- Modify: `apps/backplane_mcp_protocol/CHANGELOG.md:3-11`

- [ ] **Step 1: Clarify the README auto-negotiation contract**

Replace the current auto-selection paragraph with:

```markdown
`:auto` is the default. It probes with modern `server/discover`, negotiates
`2026-07-28` when available, and falls back to legacy initialization only when
the transport provides protocol-defined evidence of a legacy peer. For
Streamable HTTP, a valid JSON-RPC `-32601 Method not found` response to
`server/discover` is legacy evidence whether it arrives with HTTP 200 or HTTP
400. Explicit version pins never downgrade. Pin a version string when
cross-era fallback is not wanted:
```

- [ ] **Step 2: Add the Unreleased changelog entry**

Add beneath `## Unreleased`:

```markdown
- Fixes Streamable HTTP `:auto` negotiation so a valid `server/discover`
  `-32601 Method not found` response falls back to the canonical legacy
  initialization flow while explicit version pins remain strict.
```

- [ ] **Step 3: Run changed-file formatting and whitespace checks**

Run:

```bash
devenv shell -- mix format --check-formatted \
  apps/backplane_mcp_protocol/lib/backplane/mcp_protocol/client/negotiation.ex \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/client/negotiation_test.exs \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/transport/streamable_http_test.exs
git diff --check
```

Expected: formatter and whitespace checks exit 0.

- [ ] **Step 4: Run the complete package suite**

Run:

```bash
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && \
  MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  mix test --seed 0'
```

Expected: all package unit, integration, and doctests pass. If an out-of-scope
test fails, list it and stop per `AGENTS.md`; do not modify unrelated code.

- [ ] **Step 5: Review the complete scope and commit documentation**

Run:

```bash
git status --short
git diff --stat HEAD~1
git diff --check
```

Expected: only the five approved production/test/documentation files differ
from the design commit.

Run `gitnexus_detect_changes({scope: "all", repo: "backplane"})`, then commit:

```bash
git add -- \
  apps/backplane_mcp_protocol/README.md \
  apps/backplane_mcp_protocol/CHANGELOG.md
git commit -m "docs(mcp): document auto legacy fallback"
```

Expected: documentation is committed separately from the behavioral fix.

- [ ] **Step 6: Final post-commit verification**

Run:

```bash
git status --short
git log -3 --oneline
devenv shell -- bash -lc 'cd apps/backplane_mcp_protocol && \
  MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps \
  mix test \
    test/backplane/mcp_protocol/client/negotiation_test.exs \
    test/backplane/mcp_protocol/transport/streamable_http_test.exs \
    --seed 0'
```

Expected: clean worktree, design/fix/docs commits present, and focused tests
pass after the final commit.
