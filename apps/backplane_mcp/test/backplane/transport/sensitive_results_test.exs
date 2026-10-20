defmodule Backplane.Transport.SensitiveResultsTest do
  use BackplaneMcp.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.Clients
  alias Backplane.Transport.{Idempotency, TaskManager}

  @tool "admin::upsert-client"

  test "sensitive responses bypass replay storage and carry no-store in both eras" do
    before = cache_entries()

    for era <- [:legacy, :modern] do
      connection = request(message(), era) |> Idempotency.call([])
      refute connection.halted
      assert get_resp_header(connection, "cache-control") == ["no-store"]
      assert connection.assigns.mcp_idempotency_status == "bypass"
      send_resp(connection, 200, Jason.encode!(%{token: "transient-secret"}))
      assert cache_entries() == before
    end
  end

  test "idempotency keys are rejected before execution for single, batch and SSE requests" do
    before = cache_entries()

    for era <- [:legacy, :modern],
        body <- [
          message(),
          %{"_json" => [%{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}, message()]}
        ],
        accept <- ["application/json", "text/event-stream"] do
      connection =
        request(body, era)
        |> put_req_header("idempotency-key", "sensitive-key")
        |> put_req_header("accept", accept)
        |> Idempotency.call([])

      assert connection.halted
      assert connection.status == 400
      assert get_resp_header(connection, "cache-control") == ["no-store"]
      assert Jason.decode!(connection.resp_body)["error"]["code"] == -32600
      assert Clients.get_client_by_name("sensitive-client") == nil
      assert cache_entries() == before
    end
  end

  test "TaskManager rejects sensitive operations at the storage owner before executing" do
    before = :ets.tab2list(:backplane_mcp_tasks)
    auth = %{kind: :open, subject: nil, client_id: nil, scopes: ["*"], principal_metadata: %{}}

    assert {:error, reason} =
             TaskManager.create(
               @tool,
               %{"name" => "sensitive-client", "scopes" => ["*"]},
               nil,
               auth
             )

    assert reason =~ "synchronous"
    assert :ets.tab2list(:backplane_mcp_tasks) == before
    assert Clients.get_client_by_name("sensitive-client") == nil
  end

  defp message do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => @tool,
        "arguments" => %{"name" => "sensitive-client", "scopes" => ["*"]}
      }
    }
  end

  defp request(body, era) do
    raw = Jason.encode!(body)

    conn(:post, "/", raw)
    |> Map.put(:body_params, body)
    |> assign(:raw_body, raw)
    |> assign(:mcp_era, era)
    |> assign(:resource_auth, %{
      kind: :open,
      subject: nil,
      client_id: nil,
      scopes: ["*"],
      principal_metadata: %{}
    })
  end

  defp cache_entries do
    case :ets.info(Idempotency) do
      :undefined -> []
      _ -> :ets.tab2list(Idempotency) |> Enum.sort()
    end
  end
end
