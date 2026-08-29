defmodule Backplane.Transport.ManagedPromptTest do
  use Backplane.ConnCase, async: false

  alias BackplaneMcp.Fixtures
  alias Backplane.Registry.{PromptCatalog, PromptRegistry}
  alias Backplane.Transport.McpHandler

  import ExUnit.CaptureLog

  defmodule ManagedPrompts do
    def get_prompt("recall_context", %{"query" => "forbidden"}, _auth),
      do: {:error, :unauthorized}

    def get_prompt("recall_context", %{"query" => query}, auth)
        when is_binary(query) and query != "" do
      {:ok,
       %{
         description: "Managed recall",
         messages: [
           %{
             role: "user",
             content: %{type: "text", text: "#{auth.kind}:#{auth.client_id}:#{query}"}
           }
         ]
       }}
    end

    def get_prompt("recall_context", _args, _auth), do: {:error, :invalid_arguments}

    def get_prompt("daily_agenda", _args, _auth),
      do: {:error, {:upstream_secret, "credential-do-not-leak"}}
  end

  setup do
    PromptRegistry.clear()

    :ok =
      PromptRegistry.register_managed(
        "memory",
        [
          %{
            name: "recall_context",
            description: "Managed recall",
            arguments: [%{name: "query", required: true}]
          }
        ],
        ManagedPrompts
      )

    :ok =
      PromptRegistry.register_managed(
        "calendar",
        [%{name: "daily_agenda", description: "Daily agenda", arguments: []}],
        ManagedPrompts
      )

    on_exit(fn -> PromptRegistry.clear() end)
    :ok
  end

  test "managed prompt visibility accepts canonical and compatibility scopes" do
    for scopes <- [["memory.read"], ["*"], ["memory::*"], ["memory::recall_context"]] do
      response = request("prompts/list", nil, auth(:client_token, "client-a", scopes))

      assert Enum.any?(
               response["result"]["prompts"],
               &(&1["name"] == "recall_context")
             )
    end
  end

  test "open and legacy callers retain unrestricted managed prompt access" do
    for kind <- [:open, :legacy] do
      auth = auth(kind, nil, ["*"])

      assert Enum.any?(
               request("prompts/list", nil, auth)["result"]["prompts"],
               &(&1["name"] == "recall_context")
             )

      response =
        request(
          "prompts/get",
          %{"name" => "recall_context", "arguments" => %{"query" => "safe"}},
          auth
        )

      assert get_in(response, ["result", "messages", Access.at(0), "content", "text"]) ==
               "#{kind}::safe"
    end
  end

  test "single and batch dispatch pass only the trusted auth context" do
    auth = auth(:oauth, "client-a", ["memory.read"])
    params = %{"name" => "recall_context", "arguments" => %{"query" => "ports"}}

    single = request("prompts/get", params, auth)

    assert get_in(single, ["result", "messages", Access.at(0), "content", "text"]) ==
             "oauth:client-a:ports"

    [batch] = batch_request([rpc("prompts/get", params, 9)], auth)

    assert get_in(batch, ["result", "messages", Access.at(0), "content", "text"]) ==
             "oauth:client-a:ports"
  end

  test "catalog restart preserves managed prompt listing and dispatch" do
    old_pid = Process.whereis(PromptCatalog)
    Process.exit(old_pid, :kill)
    assert is_pid(wait_for_restart(PromptCatalog, old_pid))

    listed = request("prompts/list", nil, auth(:oauth, "client-a", ["memory.read"]))
    assert Enum.any?(listed["result"]["prompts"], &(&1["name"] == "recall_context"))

    response =
      request(
        "prompts/get",
        %{"name" => "recall_context", "arguments" => %{"query" => "restart"}},
        auth(:oauth, "client-a", ["memory.read"])
      )

    assert get_in(response, ["result", "messages", Access.at(0), "content", "text"]) ==
             "oauth:client-a:restart"
  end

  test "insufficient OAuth scope is indistinguishable from an absent prompt" do
    conn = request_conn("prompts/get", %{"name" => "recall_context"}, auth(:oauth, "c", []))
    response = Jason.decode!(conn.resp_body)
    absent = request("prompts/get", %{"name" => "does-not-exist"}, auth(:oauth, "c", []))

    assert conn.status == 200
    assert response["error"] == absent["error"]
    assert get_resp_header(conn, "www-authenticate") == []
  end

  test "different hidden managed prompts have the same absent response" do
    conn = request_conn("prompts/get", %{"name" => "daily_agenda"}, auth(:oauth, "c", []))
    response = Jason.decode!(conn.resp_body)
    absent = request("prompts/get", %{"name" => "does-not-exist"}, auth(:oauth, "c", []))

    assert conn.status == 200
    assert response["error"] == absent["error"]
    assert get_resp_header(conn, "www-authenticate") == []

    [batch] =
      batch_request(
        [rpc("prompts/get", %{"name" => "daily_agenda"}, 11)],
        auth(:oauth, "c", [])
      )

    assert batch["error"] == absent["error"]
  end

  test "service authorization failure is indistinguishable from an absent prompt" do
    auth = auth(:client_token, "client-a", ["memory.read"])

    hidden =
      request(
        "prompts/get",
        %{"name" => "recall_context", "arguments" => %{"query" => "forbidden"}},
        auth
      )

    absent = request("prompts/get", %{"name" => "does-not-exist"}, auth)
    assert hidden["error"] == absent["error"]
  end

  test "managed prompt failures expose only a fixed internal error" do
    log =
      capture_log(fn ->
        response =
          request(
            "prompts/get",
            %{"name" => "daily_agenda", "arguments" => %{}},
            auth(:client_token, "client-a", ["calendar.read"])
          )

        assert response["error"] == %{"code" => -32_603, "message" => "Internal error"}
        refute Jason.encode!(response) =~ "credential-do-not-leak"
      end)

    refute log =~ "credential-do-not-leak"
    refute log =~ "upstream_secret"
  end

  test "invalid managed arguments map to -32602" do
    response =
      request(
        "prompts/get",
        %{"name" => "recall_context", "arguments" => %{}},
        auth(:client_token, "client-a", ["memory.read"])
      )

    assert response["error"]["code"] == -32_602
  end

  test "managed prompt reserves its name over a colliding Skill" do
    Fixtures.insert_skill(
      id: "prompt/collision",
      slug: "prompt-collision",
      name: "recall_context",
      description: "Untrusted collision",
      content: "generic instruction",
      source_kind: "db"
    )

    Backplane.Skills.Registry.refresh()
    auth = auth(:client_token, "client-a", ["memory.read"])
    response = request("prompts/list", nil, auth)

    assert Enum.count(response["result"]["prompts"], &(&1["name"] == "recall_context")) == 1

    get =
      request(
        "prompts/get",
        %{"name" => "recall_context", "arguments" => %{"query" => "real"}},
        auth
      )

    assert get_in(get, ["result", "description"]) == "Managed recall"
    refute Jason.encode!(get) =~ "generic instruction"
  end

  defp auth(kind, client_id, scopes) do
    %{kind: kind, client_id: client_id, scopes: scopes, subject: client_id}
  end

  defp wait_for_restart(module, old_pid, attempts \\ 50)
  defp wait_for_restart(_module, _old_pid, 0), do: nil

  defp wait_for_restart(module, old_pid, attempts) do
    case Process.whereis(module) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _ -> Process.sleep(10) && wait_for_restart(module, old_pid, attempts - 1)
    end
  end

  defp request(method, params, auth), do: request_conn(method, params, auth) |> decode()

  defp request_conn(method, params, auth) do
    body = rpc(method, params, 1)

    conn(:post, "/")
    |> Map.put(:body_params, body)
    |> assign(:resource_auth, auth)
    |> McpHandler.handle()
  end

  defp batch_request(batch, auth) do
    conn(:post, "/")
    |> Map.put(:body_params, %{"_json" => batch})
    |> assign(:resource_auth, auth)
    |> McpHandler.handle()
    |> decode()
  end

  defp rpc(method, nil, id), do: %{"jsonrpc" => "2.0", "method" => method, "id" => id}

  defp rpc(method, params, id),
    do: %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}

  defp decode(conn), do: Jason.decode!(conn.resp_body)
end
