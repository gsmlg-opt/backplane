defmodule Backplane.Transport.SensitiveIssuanceTest do
  use Backplane.MCP.ObservabilityCase, async: false

  import ExUnit.CaptureLog

  alias Backplane.Audit.{ToolCallLog, Writer}
  alias Backplane.Clients
  alias Backplane.Registry.{Tool, ToolRegistry}
  alias Backplane.Tools.Admin
  alias Backplane.Transport.{Idempotency, McpPlug}

  @moduletag observability_v2: true
  @version "2026-07-28"

  setup do
    previous_tools = :ets.tab2list(:backplane_tools)

    for definition <- Admin.tools(),
        do: ToolRegistry.register_native(struct!(Tool, Map.put(definition, :origin, :native)))

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, previous_tools)
    end)

    start_supervised!({Backplane.Audit.Buffer, name: :audit, capacity: 100})

    start_supervised!(
      {Writer, batch_size: 50, flush_interval_ms: 60_000, subscribe_settings: false}
    )

    {:ok, _caller, token} = Clients.issue_client(%{name: "secret-issuer", scopes: ["admin::*"]})
    {:ok, token: token}
  end

  test "real buffered responses deliver secrets without retaining them in logs or telemetry", %{
    token: bearer
  } do
    owner = self()
    handler = "issuance-telemetry-#{System.unique_integer([:positive])}"

    events = [
      [:backplane, :mcp_proxy, :tool_call, :stop],
      [:backplane, :tool_call, :stop],
      [:backplane, :repo, :query]
    ]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn name, measurements, metadata, recipient ->
          send(recipient, {:issuance_telemetry, name, measurements, metadata})
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    before_cache = replay_entries()
    before_tasks = :ets.tab2list(:backplane_mcp_tasks)

    {records, log} =
      with_log([level: :debug], fn ->
        for era <- [:legacy, :modern] do
          result = invoke(era, bearer, "issued-#{era}")
          assert result.status == 200, "#{era}: #{result.resp_body}"
          assert get_resp_header(result, "cache-control") == ["no-store"]
          assert [secret] = Regex.run(~r/bp2_[A-Za-z0-9_-]{43}/, result.resp_body)
          assert {:ok, client} = Clients.verify_token(secret)
          assert client.name == "issued-#{era}"
          send(owner, {:issued_secret, secret, client.token_digest})
        end

        flush_logs!()
        :ok = Writer.flush()
        {Repo.all(ProxyRequest), Repo.all(ToolCall), Repo.all(ToolCallLog)}
      end)

    Logger.configure(level: previous_level)
    assert length(elem(records, 1)) == 2
    assert length(elem(records, 2)) == 2
    telemetry = collect_telemetry([])
    assert length(telemetry) >= 2

    for _ <- 1..2 do
      assert_receive {:issued_secret, token, digest}

      for secret <- [token, digest] do
        refute :erlang.term_to_binary(records) =~ secret
        refute :erlang.term_to_binary(telemetry) =~ secret
        refute log =~ secret
        refute log =~ inspect(secret, limit: :infinity)
      end
    end

    assert replay_entries() == before_cache
    assert :ets.tab2list(:backplane_mcp_tasks) == before_tasks
  end

  test "real pipeline rejects replay keys before creating or rotating a credential", %{
    token: bearer
  } do
    {:ok, client, existing} = Clients.issue_client(%{name: "do-not-rotate", scopes: ["*"]})

    for era <- [:legacy, :modern] do
      response = invoke(era, bearer, client.name, "forbidden-key")
      assert response.status == 400
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert {:ok, current} = Clients.verify_token(existing)
      assert current.id == client.id
    end
  end

  test "parsed batches and modern objects with extra keys reject replay before issuance", %{
    token: bearer
  } do
    before_cache = replay_entries()

    for {era, shape} <- [{:legacy, :batch}, {:legacy, :batch_extra_json}, {:modern, :extra_json}],
        key <- [nil, "batch-key"] do
      name = "parsed-#{era}-#{shape}-#{key || "unkeyed"}"
      response = invoke(era, bearer, name, key, shape)
      assert get_resp_header(response, "cache-control") == ["no-store"]

      if key do
        assert response.status == 400
        assert Clients.get_client_by_name(name) == nil
      else
        assert response.status == 200
        assert [secret] = Regex.run(~r/bp2_[A-Za-z0-9_-]{43}/, response.resp_body)
        assert {:ok, client} = Clients.verify_token(secret)
        assert client.name == name
      end

      assert replay_entries() == before_cache
    end
  end

  defp invoke(era, token, name, key \\ nil, shape \\ :single) do
    params = %{
      "name" => "admin::upsert-client",
      "arguments" => %{"name" => name, "scopes" => ["*"], "rotate_token" => true}
    }

    params =
      if era == :modern do
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{
            "name" => "sensitive-issuance-test",
            "version" => "1.0.0"
          }
        })
      else
        params
      end

    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => params}

    body =
      case shape do
        :batch -> [body]
        :batch_extra_json -> [Map.put(body, "_json", [])]
        :extra_json -> Map.put(body, "_json", [])
        :single -> body
      end

    request =
      conn(:post, "/", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    request =
      if era == :modern do
        request
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "tools/call")
        |> put_req_header("mcp-name", "admin::upsert-client")
      else
        request
      end

    request = if key, do: put_req_header(request, "idempotency-key", key), else: request
    McpPlug.call(request, McpPlug.init([]))
  end

  defp collect_telemetry(acc) do
    receive do
      {:issuance_telemetry, _, _, _} = event -> collect_telemetry([event | acc])
    after
      0 -> acc
    end
  end

  defp replay_entries do
    case :ets.info(Idempotency) do
      :undefined -> []
      _ -> :ets.tab2list(Idempotency) |> Enum.sort()
    end
  end
end
