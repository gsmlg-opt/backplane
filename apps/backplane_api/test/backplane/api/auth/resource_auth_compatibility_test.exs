defmodule Backplane.Api.Auth.ResourceAuthCompatibilityTest do
  use Backplane.Api.ConnCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth
  alias Backplane.Auth.Resources
  alias Backplane.Clients
  alias Backplane.Registry.{Tool, ToolRegistry}

  defmodule CompatibilityTool do
    def call(args), do: {:ok, args}
  end

  setup do
    auth_token = Application.get_env(:backplane, :auth_token)
    auth_tokens = Application.get_env(:backplane, :auth_tokens)
    previous_tools = :ets.tab2list(:backplane_tools)

    Application.delete_env(:backplane, :auth_token)
    Application.delete_env(:backplane, :auth_tokens)

    for name <- ["compat::allowed", "compat::blocked"] do
      ToolRegistry.register_native(%Tool{
        name: name,
        description: "Resource authentication compatibility tool",
        input_schema: %{"type" => "object", "properties" => %{}},
        origin: :native,
        module: CompatibilityTool,
        handler: nil
      })
    end

    on_exit(fn ->
      restore_env(:auth_token, auth_token)
      restore_env(:auth_tokens, auth_tokens)
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, previous_tools)
    end)

    :ok
  end

  test "PAT scopes still filter MCP tools without restricting v1" do
    {client, pat} = pat_fixture!(scopes: ["compat::allowed"])

    tools =
      client
      |> pat_request(fn -> post_mcp(pat, "tools/list", %{}) end)
      |> json_response(200)
      |> get_in(["result", "tools"])

    assert Enum.map(tools, & &1["name"]) == ["compat::allowed"]

    models =
      pat_request(client, fn ->
        v1_request(:get, "/v1/models", pat)
      end)

    assert models.status == 200

    invoke =
      pat_request(client, fn ->
        v1_request(
          :post,
          "/v1/responses",
          pat,
          %{"model" => "unknown/model", "input" => "hi"}
        )
      end)

    assert invoke.status == 404
  end

  test "legacy credentials retain full MCP and v1 access" do
    Application.put_env(:backplane, :auth_token, "legacy-compatibility")

    names =
      "legacy-compatibility"
      |> post_mcp("tools/list", %{})
      |> json_response(200)
      |> get_in(["result", "tools"])
      |> Enum.map(& &1["name"])

    assert "compat::allowed" in names
    assert "compat::blocked" in names
    assert v1_request(:get, "/v1/models", "legacy-compatibility").status == 200

    invoke =
      v1_request(
        :post,
        "/v1/responses",
        "legacy-compatibility",
        %{"model" => "unknown/model", "input" => "hi"}
      )

    assert invoke.status == 404
  end

  test "surfaces stay open without PAT legacy or assigned OAuth clients" do
    assert post_mcp(nil, "initialize", %{}).status == 200
    assert v1_request(:get, "/v1/models").status == 200
  end

  test "a supplied bad bearer rejects both otherwise-open resources" do
    for conn <- [
          post_mcp("bad-bearer", "initialize", %{}),
          v1_request(:get, "/v1/models", "bad-bearer")
        ] do
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
      assert get_resp_header(conn, "www-authenticate") == []
    end
  end

  test "the first OAuth assignment protects only its selected resource" do
    client =
      oauth_client_fixture!(
        resources: [:mcp],
        scopes: ["compat::allowed", "llm::models"]
      )

    mcp_challenge = post_mcp(nil, "initialize", %{})
    assert_oauth_challenge(mcp_challenge, :mcp)
    assert v1_request(:get, "/v1/models").status == 200

    client = update_resources!(client, [:v1])

    assert post_mcp(nil, "initialize", %{}).status == 200
    assert_oauth_challenge(v1_request(:get, "/v1"), :v1)

    _client = update_resources!(client, [])

    assert post_mcp(nil, "initialize", %{}).status == 200
    assert v1_request(:get, "/v1/models").status == 200
  end

  test "removing the last assignment restores PAT policy without OAuth metadata" do
    {pat_client, pat} = pat_fixture!(scopes: ["compat::allowed"])
    oauth_client = oauth_client_fixture!(resources: [:mcp], scopes: ["compat::allowed"])

    assert_oauth_challenge(post_mcp(nil, "initialize", %{}), :mcp)
    _client = update_resources!(oauth_client, [])

    assert_compatibility_challenge(post_mcp(nil, "initialize", %{}))
    assert_compatibility_challenge(v1_request(:get, "/v1"))

    mcp = pat_request(pat_client, fn -> post_mcp(pat, "initialize", %{}) end)
    assert mcp.status == 200

    models =
      pat_request(pat_client, fn ->
        v1_request(:get, "/v1/models", pat)
      end)

    assert models.status == 200
  end

  test "removing the last assignment restores legacy policy without OAuth metadata" do
    Application.put_env(:backplane, :auth_token, "legacy-after-oauth")
    oauth_client = oauth_client_fixture!(resources: [:mcp], scopes: ["compat::allowed"])

    assert_oauth_challenge(post_mcp(nil, "initialize", %{}), :mcp)
    _client = update_resources!(oauth_client, [])

    assert_compatibility_challenge(post_mcp(nil, "initialize", %{}))
    assert_compatibility_challenge(v1_request(:get, "/v1"))
    assert post_mcp("legacy-after-oauth", "initialize", %{}).status == 200
    assert v1_request(:get, "/v1/models", "legacy-after-oauth").status == 200
  end

  test "OAuth clients with an empty resource allowlist preserve open resource policy" do
    oauth_client_fixture!(
      resources: [],
      scopes: ["compat::allowed", "llm::models", "openid"]
    )

    assert post_mcp(nil, "initialize", %{}).status == 200
    assert v1_request(:get, "/v1/models").status == 200
  end

  defp pat_fixture!(attrs) do
    token = "pat-#{System.unique_integer([:positive])}"

    assert {:ok, client} =
             Clients.create_client(%{
               name: "Compatibility PAT #{System.unique_integer([:positive])}",
               token: token,
               scopes: Keyword.fetch!(attrs, :scopes),
               active: true
             })

    {client, token}
  end

  defp update_resources!(client, resources) do
    current = Auth.OAuth.get_client(client.id)
    assert {:ok, updated} = Auth.OAuth.update_client_resources(current, resources)
    updated
  end

  defp pat_request(client, request) when is_function(request, 0) do
    previous_last_seen = Clients.get_client(client.id).last_seen_at
    result = request.()
    await_pat_touch!(client.id, previous_last_seen)
    result
  end

  defp await_pat_touch!(client_id, previous_last_seen) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_await_pat_touch!(client_id, previous_last_seen, deadline)
  end

  defp do_await_pat_touch!(client_id, previous_last_seen, deadline) do
    current_last_seen = Clients.get_client(client_id).last_seen_at

    cond do
      current_last_seen != previous_last_seen ->
        current_last_seen

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(5)
        do_await_pat_touch!(client_id, previous_last_seen, deadline)

      true ->
        flunk("PAT last_seen_at did not change within 1000ms for client #{client_id}")
    end
  end

  defp post_mcp(token, method, params) do
    conn =
      Plug.Test.conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => method,
          "id" => System.unique_integer([:positive]),
          "params" => params
        })
      )
      |> put_req_header("content-type", "application/json")
      |> maybe_put_bearer(token)

    Backplane.Api.Endpoint.call(conn, Backplane.Api.Endpoint.init([]))
  end

  defp v1_request(method, path, token \\ nil, body \\ nil) do
    conn_body = if body, do: Jason.encode!(body), else: ""

    conn =
      Plug.Test.conn(method, path, conn_body)
      |> put_req_header("content-type", "application/json")
      |> maybe_put_bearer(token)

    Backplane.Api.Endpoint.call(conn, Backplane.Api.Endpoint.init([]))
  end

  defp assert_oauth_challenge(conn, resource) do
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_token"}

    assert get_resp_header(conn, "www-authenticate") == [
             ~s(Bearer resource_metadata="#{Resources.metadata_uri(resource)}")
           ]
  end

  defp assert_compatibility_challenge(conn) do
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized"}
    assert get_resp_header(conn, "www-authenticate") == []
  end

  defp maybe_put_bearer(conn, nil), do: conn

  defp maybe_put_bearer(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
