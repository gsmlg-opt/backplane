defmodule Backplane.Api.EndpointsMcpTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Clients
  alias Backplane.Endpoints
  alias Backplane.Registry.{PromptRegistry, ToolRegistry}
  alias Backplane.Transport.Session

  defmodule PromptService do
    @moduledoc false
    def get_prompt(_name, _arguments, _auth), do: {:error, :backend_failed}
  end

  @version "2026-07-28"

  setup do
    tools =
      for prefix <- ["day", "web"] do
        %{
          name: "#{prefix}::echo",
          description: "Echo #{prefix}",
          input_schema: %{"type" => "object", "properties" => %{}},
          handler: fn _arguments -> {:ok, %{"ok" => true}} end
        }
      end

    for prefix <- ["day", "web"],
        do: ToolRegistry.register_managed(prefix, Enum.filter(tools, &(&1.name =~ prefix)))

    for prefix <- ["day", "web"] do
      PromptRegistry.register_managed(
        prefix,
        [%{name: "#{prefix}_prompt", description: "Prompt", arguments: []}],
        PromptService
      )
    end

    on_exit(fn ->
      for prefix <- ["day", "web"] do
        ToolRegistry.deregister_managed(prefix)
        PromptRegistry.deregister_managed(prefix)
      end
    end)

    skill_id = "skill/ep-probe-#{System.unique_integer([:positive])}"

    :ets.insert(
      :backplane_skills,
      {skill_id,
       %{
         id: skill_id,
         slug: "ep-probe",
         name: "ep-probe",
         description: "probe",
         tags: [],
         version: nil,
         license: nil,
         homepage: nil,
         content_hash: nil,
         archive_ref: nil,
         size_bytes: 0,
         file_count: 1
       }}
    )

    on_exit(fn -> :ets.delete(:backplane_skills, skill_id) end)

    {:ok, _client, token} =
      Clients.issue_client(%{
        name: "ep-client-#{System.unique_integer([:positive])}",
        scopes: ["*"]
      })

    {:ok, endpoint} =
      Endpoints.create(%{name: "chatgpt", mcp_enabled: true, mcp_prefixes: ["day"]})

    %{token: token, endpoint: endpoint}
  end

  defp rpc(conn, path, token, method, params \\ %{}, headers \\ []) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("authorization", "Bearer #{token}")

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> post(path, body)
  end

  defp modern(conn, path, token, method, params \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{"name" => "ep-test", "version" => "1"}
    }

    rpc(
      conn,
      path,
      token,
      method,
      Map.put(params, "_meta", meta),
      [{"mcp-protocol-version", @version}, {"mcp-method", method}] ++
        if(method == "tools/call",
          do: [{"mcp-name", params["name"]}],
          else: []
        )
    )
  end

  defp names(conn, key) do
    conn |> json_response(200) |> get_in(["result", key]) |> Enum.map(& &1["name"])
  end

  test "legacy tools/list returns only allowed prefixes", %{conn: conn, token: token} do
    init =
      rpc(conn, "/endpoints/chatgpt/mcp", token, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "t", "version" => "1"}
      })

    assert init.status == 200

    list = rpc(build_conn(), "/endpoints/chatgpt/mcp", token, "tools/list")
    assert "day::echo" in names(list, "tools")
    assert Enum.all?(names(list, "tools"), &String.starts_with?(&1, "day::"))

    root = rpc(build_conn(), "/mcp", token, "tools/list")
    assert "web::echo" in names(root, "tools")
    assert "day::echo" in names(root, "tools")
  end

  test "tools/call outside allowed prefixes is rejected", %{conn: conn, token: token} do
    resp =
      rpc(conn, "/endpoints/chatgpt/mcp", token, "tools/call", %{
        "name" => "web::echo",
        "arguments" => %{}
      })

    assert %{"error" => %{"code" => -32_001}} = json_response(resp, 200)

    ok =
      rpc(build_conn(), "/endpoints/chatgpt/mcp", token, "tools/call", %{
        "name" => "day::echo",
        "arguments" => %{}
      })

    assert ok.status == 200
    assert response(ok, 200) =~ "\"result\""
  end

  test "modern era tools/list is filtered identically", %{conn: conn, token: token} do
    resp = modern(conn, "/endpoints/chatgpt/mcp", token, "tools/list")
    assert "day::echo" in names(resp, "tools")
    assert Enum.all?(names(resp, "tools"), &String.starts_with?(&1, "day::"))

    root = modern(build_conn(), "/mcp", token, "tools/list")
    assert "web::echo" in names(root, "tools")
  end

  test "modern era tools/call outside prefixes is denied", %{conn: conn, token: token} do
    resp =
      modern(conn, "/endpoints/chatgpt/mcp", token, "tools/call", %{
        "name" => "web::echo",
        "arguments" => %{}
      })

    assert %{"error" => _} = json_response(resp, 200)
  end

  test "prompts/list has no skill prompts and only allowed managed prompts", %{
    conn: conn,
    token: token
  } do
    resp = rpc(conn, "/endpoints/chatgpt/mcp", token, "prompts/list")
    assert names(resp, "prompts") == ["day_prompt"]

    modern_resp = modern(build_conn(), "/endpoints/chatgpt/mcp", token, "prompts/list")
    assert names(modern_resp, "prompts") == ["day_prompt"]
  end

  test "an Idempotency-Key response cached at one endpoint is not replayed at another", %{
    conn: conn,
    token: token
  } do
    {:ok, _} = Endpoints.create(%{name: "other", mcp_enabled: true, mcp_prefixes: ["web"]})

    # An event-stream Accept bypasses the idempotency cache, so ask for JSON only.
    key = [
      {"idempotency-key", "ep-idem-#{System.unique_integer([:positive])}"},
      {"accept", "application/json"}
    ]

    first = rpc(conn, "/endpoints/chatgpt/mcp", token, "prompts/list", %{}, key)
    assert names(first, "prompts") == ["day_prompt"]

    second = rpc(build_conn(), "/endpoints/other/mcp", token, "prompts/list", %{}, key)
    assert names(second, "prompts") == ["web_prompt"]
  end

  test "logging/setLevel is rejected", %{conn: conn, token: token} do
    resp = rpc(conn, "/endpoints/chatgpt/mcp", token, "logging/setLevel", %{"level" => "debug"})
    assert %{"error" => %{"code" => -32_001}} = json_response(resp, 200)
  end

  test "HEAD returns 204, DELETE removes a session", %{conn: conn, token: token} do
    assert conn |> head("/endpoints/chatgpt/mcp") |> response(204)

    session_id = "ep-session-#{System.unique_integer([:positive])}"
    Session.create(session_id, "2025-11-25", %{}, %{})
    on_exit(fn -> Session.delete(session_id) end)

    deleted =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("mcp-session-id", session_id)
      |> delete("/endpoints/chatgpt/mcp")

    assert deleted.status == 200
    refute Session.get(session_id)
  end

  test "GET opens the SSE stream", %{conn: conn, token: token} do
    task =
      Task.async(fn ->
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("accept", "text/event-stream")
        |> get("/endpoints/chatgpt/mcp")
      end)

    # Stream stays open (keep-alive loop); not answering within the window means it opened.
    assert Task.yield(task, 300) == nil
    Task.shutdown(task, :brutal_kill)
  end

  test "unknown, disabled, mcp-disabled and unknown sub-paths return 404", %{
    conn: conn,
    token: token,
    endpoint: endpoint
  } do
    assert %{"error" => "Not found"} =
             conn |> rpc("/endpoints/nope/mcp", token, "tools/list") |> json_response(404)

    assert rpc(build_conn(), "/endpoints/chatgpt/other", token, "tools/list").status == 404
    assert rpc(build_conn(), "/endpoints/chatgpt/v1/models", token, "tools/list").status == 404

    {:ok, endpoint} = Endpoints.update(endpoint, %{mcp_enabled: false})
    assert rpc(build_conn(), "/endpoints/chatgpt/mcp", token, "tools/list").status == 404

    {:ok, endpoint} = Endpoints.update(endpoint, %{mcp_enabled: true})
    {:ok, _} = Endpoints.set_enabled(endpoint, false)
    assert rpc(build_conn(), "/endpoints/chatgpt/mcp", token, "tools/list").status == 404
  end

  test "missing credentials are rejected with a bearer challenge", %{conn: conn} do
    resp =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/endpoints/chatgpt/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      )

    assert resp.status == 401
    assert [challenge] = get_resp_header(resp, "www-authenticate")
    assert challenge =~ "resource_metadata"
  end
end
