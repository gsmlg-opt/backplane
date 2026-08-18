defmodule Backplane.Transport.IdempotencyTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Transport.{Idempotency, McpPlug}

  test "request without idempotency key processes normally" do
    resp = mcp_request("ping")
    assert resp["result"] == %{}
  end

  test "first request with idempotency key processes and caches" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", "test-key-1")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["result"] == %{}
  end

  test "repeated request with same key returns cached response" do
    key = "test-key-repeat-#{System.unique_integer([:positive])}"
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

    # First request
    conn1 =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", key)
      |> McpPlug.call(McpPlug.init([]))

    assert conn1.status == 200
    first_body = conn1.resp_body

    # Second request with same key — should return cached
    conn2 =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", key)
      |> McpPlug.call(McpPlug.init([]))

    assert conn2.status == 200
    assert conn2.resp_body == first_body
    assert conn2.halted
  end

  test "different keys produce independent responses" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn1 =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "idempotency-key",
        "key-a-#{System.unique_integer([:positive])}"
      )
      |> McpPlug.call(McpPlug.init([]))

    conn2 =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "idempotency-key",
        "key-b-#{System.unique_integer([:positive])}"
      )
      |> McpPlug.call(McpPlug.init([]))

    # Both should process independently (not cached)
    assert conn1.status == 200
    assert conn2.status == 200
    refute conn1.halted
    refute conn2.halted
  end

  test "empty idempotency key header is ignored" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", "")
      |> McpPlug.call(McpPlug.init([]))

    assert conn.status == 200
    refute conn.halted
  end

  test "cached response preserves status code and content type" do
    key = "test-key-status-#{System.unique_integer([:positive])}"
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    # First request
    conn1 =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", key)
      |> McpPlug.call(McpPlug.init([]))

    # Second request with same key
    conn2 =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", key)
      |> McpPlug.call(McpPlug.init([]))

    assert conn2.status == conn1.status

    ct =
      conn2.resp_headers
      |> Enum.find(fn {k, _} -> k == "content-type" end)
      |> elem(1)

    assert ct =~ "application/json"
  end

  test "same external key is isolated by identity, era, method, name, and exact raw body" do
    key = "composite-#{System.unique_integer([:positive])}"

    base_opts = [
      auth: auth(:client_token, "subject-1", "client-1"),
      era: :modern,
      method: "tools/call",
      name: "public::echo",
      raw_body: ~s({"value":"one"})
    ]

    base = idempotency_conn(key, base_opts)

    first = process_response(base, ~s({"source":"base"}))
    assert first.status == 200

    replay = Idempotency.call(base, [])
    assert replay.halted
    assert replay.resp_body == ~s({"source":"base"})

    variants = [
      [http_method: :get],
      [http_method: :delete],
      [auth: auth(:client_token, "subject-1", "client-2")],
      [auth: auth(:oauth, "subject-1", "client-1")],
      [auth: auth(:client_token, "subject-2", "client-1")],
      [era: :legacy],
      [method: "prompts/get"],
      [name: "secret::echo"],
      [raw_body: ~s({"value":"two"})]
    ]

    for overrides <- variants do
      opts = Keyword.merge(base_opts, overrides)
      refute idempotency_conn(key, opts) |> Idempotency.call([]) |> Map.fetch!(:halted)
    end
  end

  test "normalizes atom and string auth keys into the same identity" do
    key = "auth-shape-#{System.unique_integer([:positive])}"

    string_auth = %{
      "kind" => "client_token",
      "subject" => "subject-1",
      "client_id" => "client-1",
      "scopes" => ["public::echo"],
      "principal_metadata" => %{"memory_partition_id" => "host:one"}
    }

    atom_conn =
      idempotency_conn(key,
        auth:
          auth(:client_token, "subject-1", "client-1",
            scopes: ["public::echo"],
            principal_metadata: %{"memory_partition_id" => "host:one"}
          )
      )

    _first = process_response(atom_conn, ~s({"shape":"atom"}))

    replay = idempotency_conn(key, auth: string_auth) |> Idempotency.call([])
    assert replay.halted
    assert replay.resp_body == ~s({"shape":"atom"})
  end

  test "isolates modern validation headers and legacy session headers" do
    key = "header-identity-#{System.unique_integer([:positive])}"

    base_headers = [
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "tools/call"},
      {"mcp-name", "public::echo"},
      {"mcp-param-region", "west"}
    ]

    base = idempotency_conn(key, raw_headers: base_headers)
    _first = process_response(base, ~s({"headers":"valid"}))

    changed_headers = [
      List.keyreplace(base_headers, "mcp-method", 0, {"mcp-method", "tools/list"}),
      List.keyreplace(
        base_headers,
        "mcp-protocol-version",
        0,
        {"mcp-protocol-version", "2099-01-01"}
      ),
      [{"MCP-Protocol-Version", "2026-07-28"} | base_headers],
      List.keyreplace(base_headers, "mcp-param-region", 0, {"mcp-param-region", "east"})
    ]

    for headers <- changed_headers do
      refute idempotency_conn(key, raw_headers: headers)
             |> Idempotency.call([])
             |> Map.fetch!(:halted)
    end

    legacy_key = "legacy-session-#{System.unique_integer([:positive])}"

    legacy_one =
      idempotency_conn(legacy_key,
        era: :legacy,
        raw_headers: [{"mcp-session-id", "session-one"}]
      )

    _first = process_response(legacy_one, ~s({"session":"one"}))

    legacy_two =
      idempotency_conn(legacy_key,
        era: :legacy,
        raw_headers: [{"Mcp-Session-Id", "session-two"}]
      )

    refute Idempotency.call(legacy_two, []).halted
  end

  test "isolates scopes and principal metadata and bypasses malformed auth" do
    key = "auth-grants-#{System.unique_integer([:positive])}"

    base_auth =
      auth(:client_token, "subject-1", "client-1",
        scopes: ["public::echo"],
        principal_metadata: %{"memory_partition_id" => "host:one"}
      )

    base = idempotency_conn(key, auth: base_auth)
    _first = process_response(base, ~s({"grants":"one"}))

    changed_scopes =
      auth(:client_token, "subject-1", "client-1",
        scopes: ["secret::echo"],
        principal_metadata: %{"memory_partition_id" => "host:one"}
      )

    changed_partition =
      auth(:client_token, "subject-1", "client-1",
        scopes: ["public::echo"],
        principal_metadata: %{"memory_partition_id" => "host:two"}
      )

    refute idempotency_conn(key, auth: changed_scopes)
           |> Idempotency.call([])
           |> Map.fetch!(:halted)

    refute idempotency_conn(key, auth: changed_partition)
           |> Idempotency.call([])
           |> Map.fetch!(:halted)

    malformed_auths = [
      %{kind: :open, scopes: ["*"], principal_metadata: :invalid},
      %{"kind" => "oauth", kind: :open, scopes: ["*"], principal_metadata: %{}},
      %{kind: :open, principal_metadata: %{}},
      %{kind: :open, scopes: ["*"], principal_metadata: %{{:bad, :key} => "value"}}
    ]

    for malformed <- malformed_auths do
      malformed_key = "malformed-auth-#{System.unique_integer([:positive])}"
      request = idempotency_conn(malformed_key, auth: malformed)
      _response = process_response(request, ~s({"malformed":true}))
      refute Idempotency.call(request, []).halted
    end
  end

  test "normalizes clean recursive metadata but rejects normalized-key collisions" do
    clean_key = "recursive-metadata-#{System.unique_integer([:positive])}"

    atom_metadata = %{
      partition: "host:one",
      context: %{
        tenant: "one",
        labels: [%{name: "primary"}],
        active: true,
        count: 1,
        ratio: 1.5,
        optional: nil
      }
    }

    string_metadata = %{
      "partition" => "host:one",
      "context" => %{
        "tenant" => "one",
        "labels" => [%{"name" => "primary"}],
        "active" => true,
        "count" => 1,
        "ratio" => 1.5,
        "optional" => nil
      }
    }

    atom_request =
      idempotency_conn(clean_key,
        auth: auth(:client_token, "subject-1", "client-1", principal_metadata: atom_metadata)
      )

    _first = process_response(atom_request, ~s({"metadata":"clean"}))

    clean_replay =
      idempotency_conn(clean_key,
        auth: auth(:client_token, "subject-1", "client-1", principal_metadata: string_metadata)
      )
      |> Idempotency.call([])

    assert clean_replay.halted
    assert clean_replay.resp_body == ~s({"metadata":"clean"})

    for {label, left, right} <- [
          {
            "top",
            %{"partition" => "b", partition: "a"},
            %{"partition" => "a", partition: "b"}
          },
          {
            "nested",
            %{context: %{"partition" => "b", partition: "a"}},
            %{"context" => %{"partition" => "a", partition: "b"}}
          },
          {
            "equal-values",
            %{"partition" => "a", partition: "a"},
            %{"partition" => "a", partition: "a"}
          }
        ] do
      key = "metadata-collision-#{label}-#{System.unique_integer([:positive])}"
      left_request = idempotency_conn(key, auth: auth_with_metadata(left))
      right_request = idempotency_conn(key, auth: auth_with_metadata(right))

      assert {:ok, %Plug.Conn{}} = safe_process_response(left_request, ~s({"side":"left"}))
      assert {:ok, false} = safe_halted(right_request)
      assert {:ok, false} = safe_halted(left_request)
    end
  end

  test "malformed recursive metadata bypasses caching without raising" do
    malformed_metadata = [
      %{1 => "integer-key"},
      %{"nested" => %{1 => "integer-key"}},
      %{"nested" => %{{:tuple, :key} => "tuple-key"}},
      %{self() => "pid-key"},
      %{fn -> :key end => "function-key"},
      %{["proper" | :improper] => "improper-key"},
      %{<<255>> => "invalid-binary-key"},
      %{"value" => {:tuple, :value}},
      %{"value" => self()},
      %{"value" => fn -> :value end},
      %{"value" => ["proper" | :improper]},
      %{"value" => :unsupported_atom},
      %{"value" => <<255>>},
      %{"value" => %URI{scheme: "https"}}
    ]

    for metadata <- malformed_metadata do
      key = "malformed-metadata-#{System.unique_integer([:positive])}"
      request = idempotency_conn(key, auth: auth_with_metadata(metadata))

      assert {:ok, %Plug.Conn{}} = safe_process_response(request, ~s({"cached":false}))
      assert {:ok, false} = safe_halted(request)
    end
  end

  test "bypasses caching when the exact raw body is missing or non-binary" do
    for raw_body <- [:missing, :non_binary] do
      key = "raw-body-#{raw_body}-#{System.unique_integer([:positive])}"
      request = idempotency_conn(key)

      request =
        case raw_body do
          :missing -> %{request | assigns: Map.delete(request.assigns, :raw_body)}
          :non_binary -> assign(request, :raw_body, ["iodata"])
        end

      _response = process_response(request, ~s({"raw":false}))
      refute Idempotency.call(request, []).halted
    end

    empty_key = "empty-raw-body-#{System.unique_integer([:positive])}"
    empty = idempotency_conn(empty_key, raw_body: "")
    _response = process_response(empty, ~s({"raw":"empty"}))
    assert Idempotency.call(empty, []).halted
  end

  test "SSE accept variants never replay or store buffered responses" do
    cached_key = "sse-replay-#{System.unique_integer([:positive])}"
    cached_conn = idempotency_conn(cached_key)
    _first = process_response(cached_conn, ~s({"cached":true}))

    for accept <- [
          "text/event-stream",
          "Text/Event-Stream; charset=utf-8",
          "application/json, text/event-stream; q=0.9"
        ] do
      sse_conn =
        cached_key
        |> idempotency_conn()
        |> put_req_header("accept", accept)
        |> Idempotency.call([])

      refute sse_conn.halted
    end

    for accept <- [
          "text/event-streamish",
          ~s(application/json; profile="text/event-stream")
        ] do
      normal_conn =
        cached_key
        |> idempotency_conn()
        |> put_req_header("accept", accept)
        |> Idempotency.call([])

      assert normal_conn.halted
    end

    uncached_key = "sse-store-#{System.unique_integer([:positive])}"

    sse_response =
      uncached_key
      |> idempotency_conn()
      |> put_req_header("accept", "application/json, TEXT/EVENT-STREAM; q=1")
      |> Idempotency.call([])
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, "event: message\ndata: {}\n\n")

    assert sse_response.status == 200
    refute idempotency_conn(uncached_key) |> Idempotency.call([]) |> Map.fetch!(:halted)
  end

  test "chunked and non-binary responses are not cached" do
    chunked_key = "chunked-#{System.unique_integer([:positive])}"

    chunked =
      chunked_key
      |> idempotency_conn()
      |> Idempotency.call([])
      |> send_chunked(200)

    assert chunked.state == :chunked
    refute idempotency_conn(chunked_key) |> Idempotency.call([]) |> Map.fetch!(:halted)

    iodata_key = "iodata-#{System.unique_integer([:positive])}"

    iodata =
      iodata_key
      |> idempotency_conn()
      |> Idempotency.call([])
      |> then(&%{&1 | status: 200, resp_body: ["not", "-binary"], state: :set})
      |> Plug.Conn.send_resp()

    assert iodata.status == 200
    refute idempotency_conn(iodata_key) |> Idempotency.call([]) |> Map.fetch!(:halted)
  end

  test "replays safe handler headers and lets outer callbacks recompute request headers" do
    key = "safe-headers-#{System.unique_integer([:positive])}"
    request = idempotency_conn(key)

    first =
      process_response(request, ~s({"headers":true}),
        headers: [
          {"mcp-session-id", "session-one"},
          {"etag", ~s("tools-one")},
          {"cache-control", "private, max-age=60"},
          {"x-mcp-protocol-version", "untrusted-old"},
          {"access-control-allow-origin", "https://old.example"},
          {"content-encoding", "gzip"}
        ]
      )

    replay = Idempotency.call(request, [])

    assert replay.halted
    assert get_resp_header(replay, "mcp-session-id") == ["session-one"]
    assert get_resp_header(replay, "etag") == [~s("tools-one")]
    assert get_resp_header(replay, "cache-control") == get_resp_header(first, "cache-control")
    assert get_resp_header(replay, "content-type") == get_resp_header(first, "content-type")
    assert get_resp_header(replay, "x-mcp-protocol-version") == []
    assert get_resp_header(replay, "access-control-allow-origin") == []
    assert get_resp_header(replay, "content-encoding") == []
  end

  test "does not synthesize content type for a headerless buffered response" do
    key = "headerless-#{System.unique_integer([:positive])}"
    request = idempotency_conn(key)

    first = request |> Idempotency.call([]) |> send_resp(202, "")
    assert get_resp_header(first, "content-type") == []

    replay = Idempotency.call(request, [])
    assert replay.halted
    assert replay.status == 202
    assert replay.resp_body == ""
    assert get_resp_header(replay, "content-type") == []
  end

  test "ignores malformed and prior cache entry shapes without crashing" do
    key = "entry-shape-#{System.unique_integer([:positive])}"
    request = idempotency_conn(key)
    _first = process_response(request, ~s({"valid":true}))

    [{composite_key, _entry}] =
      Idempotency
      |> :ets.tab2list()
      |> Enum.filter(fn
        {{^key, _identity}, _entry} -> true
        _other -> false
      end)

    for malformed <- [:invalid, {"old-body", 200, "application/json", 0}] do
      :ets.insert(Idempotency, {composite_key, malformed})
      refute Idempotency.call(request, []).halted
    end
  end

  test "treats corrupt cached response metadata as a miss" do
    key = "corrupt-entry-#{System.unique_integer([:positive])}"
    request = idempotency_conn(key)
    _first = process_response(request, ~s({"valid":true}))
    composite_key = composite_key!(key)
    now = System.monotonic_time(:millisecond)

    invalid_headers = [
      [{"x-injected", "value"}],
      [{"set-cookie", "session=stolen"}],
      [{"location", "https://evil.example"}],
      [{"content-encoding", "gzip"}],
      [{"etag", "safe"}, {"ETag", "duplicate"}],
      [{"etag", "one"}, {"etag", "two"}],
      [{"etag", "safe\r\nx-injected: value"}],
      [{"etag", "unsafe\0value"}],
      ["malformed"],
      [{"etag", "safe"} | :improper]
    ]

    invalid_entries =
      Enum.map(invalid_headers, &{~s({"corrupt":true}), 200, &1, nil, now}) ++
        [
          {["iodata"], 200, [], nil, now},
          {~s({"corrupt":true}), 99, [], nil, now},
          {~s({"corrupt":true}), 600, [], nil, now},
          {~s({"corrupt":true}), 200, [], "2099-01-01", now},
          {~s({"corrupt":true}), 200, [], :invalid_version, now},
          {~s({"corrupt":true}), 200, [], nil, :invalid_timestamp},
          {~s({"corrupt":true}), 200, [], nil, now + 60_000}
        ]

    for entry <- invalid_entries do
      :ets.insert(Idempotency, {composite_key, entry})
      assert {:ok, false} = safe_halted(request)
      assert :ets.lookup(Idempotency, composite_key) == []
    end

    :ets.insert(
      Idempotency,
      {composite_key,
       {~s({"supported":true}), 203, [{"etag", ~s("supported")}], "2026-07-28",
        System.monotonic_time(:millisecond)}}
    )

    replay = Idempotency.call(request, [])
    assert replay.halted
    assert replay.status == 203
    assert replay.assigns.mcp_protocol_version == "2026-07-28"
    assert get_resp_header(replay, "etag") == [~s("supported")]
  end

  test "sweep removes malformed objects and preserves fresh response rows" do
    key = "corrupt-sweep-#{System.unique_integer([:positive])}"
    request = idempotency_conn(key)
    _first = process_response(request, ~s({"valid":true}))
    composite_key = composite_key!(key)
    suffix = System.unique_integer([:positive])

    arity_one = {{"malformed-one", suffix}}
    arity_three = {{"malformed-three", suffix}, :not, :a_row}
    fresh_key = {"fresh-row", suffix}

    fresh_entry =
      {"fresh", 200, [{"etag", ~s("fresh")}], nil, System.monotonic_time(:millisecond)}

    :ets.insert(Idempotency, {composite_key, {"body", 200, [{"etag", :invalid}], nil, :bad}})
    :ets.insert(Idempotency, [arity_one, arity_three, {fresh_key, fresh_entry}])

    for index <- 1..10_001 do
      :ets.insert(Idempotency, {{"force-sweep", index}, :malformed})
    end

    assert {:ok, false} = safe_halted(request)
    assert :ets.lookup(Idempotency, composite_key) == []
    assert :ets.lookup(Idempotency, elem(arity_one, 0)) == []
    assert :ets.lookup(Idempotency, elem(arity_three, 0)) == []
    assert :ets.lookup(Idempotency, fresh_key) == [{fresh_key, fresh_entry}]
  end

  test "McpPlug replay preserves session and ETag headers while recomputing origin and version" do
    previous_cors = Application.get_env(:backplane, Backplane.Transport.CORS)

    Application.put_env(:backplane, Backplane.Transport.CORS,
      allowed_origins: ["https://one.example", "https://two.example"]
    )

    on_exit(fn ->
      if is_nil(previous_cors),
        do: Application.delete_env(:backplane, Backplane.Transport.CORS),
        else: Application.put_env(:backplane, Backplane.Transport.CORS, previous_cors)
    end)

    init_key = "init-headers-#{System.unique_integer([:positive])}"

    init_body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "clientInfo" => %{"name" => "idempotency-test", "version" => "1.0.0"},
          "capabilities" => %{}
        }
      })

    first_init = mcp_conn(init_body, init_key, "https://one.example")
    replayed_init = mcp_conn(init_body, init_key, "https://two.example")

    assert [session_id] = get_resp_header(first_init, "mcp-session-id")
    on_exit(fn -> Backplane.Transport.Session.delete(session_id) end)
    assert replayed_init.halted
    assert get_resp_header(replayed_init, "mcp-session-id") == [session_id]

    assert get_resp_header(replayed_init, "access-control-allow-origin") == [
             "https://two.example"
           ]

    assert get_resp_header(replayed_init, "x-mcp-protocol-version") == ["2025-03-26"]

    list_key = "etag-headers-#{System.unique_integer([:positive])}"
    list_body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    first_list = mcp_conn(list_body, list_key, "https://one.example")
    replayed_list = mcp_conn(list_body, list_key, "https://two.example")

    assert [etag] = get_resp_header(first_list, "etag")
    assert replayed_list.halted
    assert get_resp_header(replayed_list, "etag") == [etag]

    assert get_resp_header(replayed_list, "access-control-allow-origin") == [
             "https://two.example"
           ]

    assert get_resp_header(replayed_list, "x-mcp-protocol-version") == ["2025-11-25"]
  end

  test "high-volume sweep: stale entries are eventually cleaned" do
    table = Idempotency

    if :ets.info(table) == :undefined do
      :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    end

    # Insert many stale entries (expired 10 minutes ago)
    old_ts = System.monotonic_time(:millisecond) - 700_000

    for i <- 1..20 do
      :ets.insert(table, {"stale-sweep-#{i}", {"body", 200, "application/json", old_ts}})
    end

    # Send 200 requests to probabilistically trigger do_sweep (1/50 chance each)
    # With 200 requests, probability of at least one sweep ≈ 98.2%
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

    for i <- 1..200 do
      key = "sweep-vol-#{i}-#{System.unique_integer([:positive])}"

      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", key)
      |> McpPlug.call(McpPlug.init([]))
    end

    # Table should still be healthy
    assert :ets.info(table) != :undefined
  end

  test "init/1 passes through opts" do
    assert Idempotency.init([]) == []
    assert Idempotency.init(foo: :bar) == [foo: :bar]
  end

  test "sweep cleans up expired entries without crashing" do
    table = Idempotency

    # Ensure table exists
    if :ets.info(table) == :undefined do
      :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    end

    # Insert an old entry
    old_ts = System.monotonic_time(:millisecond) - 400_000
    :ets.insert(table, {"sweep-test-key", {"body", 200, "application/json", old_ts}})

    # Trigger multiple requests to probabilistically hit the sweep path
    for i <- 1..60 do
      key = "sweep-trigger-#{i}-#{System.unique_integer([:positive])}"
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})

      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", key)
      |> McpPlug.call(McpPlug.init([]))
    end

    assert :ets.info(table) != :undefined
  end

  defp idempotency_conn(key, opts \\ []) do
    http_method = Keyword.get(opts, :http_method, :post)
    method = Keyword.get(opts, :method, "tools/call")
    name = Keyword.get(opts, :name, "public::echo")
    raw_body = Keyword.get(opts, :raw_body, ~s({"value":"one"}))
    auth = Keyword.get(opts, :auth, auth(:open, nil, nil))
    era = Keyword.get(opts, :era, :modern)
    raw_headers = Keyword.get(opts, :raw_headers, [])

    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => %{"name" => name}
    }

    conn =
      conn(http_method, "/", raw_body)
      |> put_req_header("idempotency-key", key)
      |> assign(:resource_auth, auth)
      |> assign(:mcp_era, era)
      |> assign(:raw_body, raw_body)
      |> then(&%{&1 | body_params: message})

    %{conn | req_headers: raw_headers ++ conn.req_headers}
  end

  defp process_response(conn, body, opts \\ []) do
    conn =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.reduce(Idempotency.call(conn, []), fn {name, value}, conn ->
        put_resp_header(conn, name, value)
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(Keyword.get(opts, :status, 200), body)
  end

  defp auth(kind, subject, client_id, opts \\ []) do
    %{
      kind: kind,
      subject: subject,
      client_id: client_id,
      scopes: Keyword.get(opts, :scopes, ["public::echo"]),
      principal_metadata: Keyword.get(opts, :principal_metadata, %{})
    }
  end

  defp auth_with_metadata(metadata) do
    auth(:client_token, "subject-1", "client-1", principal_metadata: metadata)
  end

  defp safe_process_response(conn, body) do
    {:ok, process_response(conn, body)}
  rescue
    error -> {:raised, error.__struct__}
  end

  defp safe_halted(conn) do
    {:ok, Idempotency.call(conn, []).halted}
  rescue
    error -> {:raised, error.__struct__}
  end

  defp composite_key!(external_key) do
    Enum.find_value(:ets.tab2list(Idempotency), fn
      {{^external_key, _identity} = key, _entry} -> key
      _other -> nil
    end) || flunk("missing idempotency cache key #{inspect(external_key)}")
  end

  defp mcp_conn(body, key, origin) do
    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", key)
    |> put_req_header("origin", origin)
    |> McpPlug.call(McpPlug.init([]))
  end
end
