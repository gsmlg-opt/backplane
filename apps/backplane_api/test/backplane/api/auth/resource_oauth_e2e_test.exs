defmodule Backplane.Api.Auth.ResourceOAuthE2ETest do
  use Backplane.Api.ConnCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth
  alias Backplane.Auth.Resources
  alias Backplane.Registry.{Tool, ToolRegistry}

  @password "correct horse battery staple"
  @redirect_uri "https://resource-client.example.test/oauth/callback"

  defmodule EchoTool do
    def call(args), do: {:ok, %{"echo" => args["value"]}}
  end

  setup do
    auth_token = Application.get_env(:backplane, :auth_token)
    auth_tokens = Application.get_env(:backplane, :auth_tokens)
    previous_tools = :ets.tab2list(:backplane_tools)

    Application.delete_env(:backplane, :auth_token)
    Application.delete_env(:backplane, :auth_tokens)

    for name <- ["e2e::echo", "e2e::hidden"] do
      ToolRegistry.register_native(%Tool{
        name: name,
        description: "Resource OAuth E2E tool",
        input_schema: %{"type" => "object", "properties" => %{}},
        origin: :native,
        module: EchoTool,
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

  test "ChatGPT discovers and completes MCP OAuth through the public endpoint", %{conn: conn} do
    %{client: client, user: user} = resource_principals(:mcp, ["e2e::echo"])

    challenge = post_mcp(nil, "initialize", %{})

    assert challenge.status == 401
    assert Jason.decode!(challenge.resp_body)["error"] == "invalid_token"

    metadata_path =
      challenge
      |> bearer_header()
      |> resource_metadata_path()

    assert metadata_path == "/.well-known/oauth-protected-resource/mcp"

    metadata =
      conn
      |> get(metadata_path)
      |> json_response(200)

    assert metadata["resource"] == Resources.uri(:mcp)
    assert metadata["authorization_servers"] == [Backplane.WebOrigins.api_base_url()]
    refute Map.has_key?(metadata, "scopes_supported")

    verifier = "resource-oauth-verifier-with-at-least-43-characters"
    code = authorize_resource_with_login(conn, client, user, :mcp, verifier, nil)
    token = exchange_code(conn, client, code, verifier, :mcp)

    assert {:ok, auth} =
             Auth.Tokens.verify_resource_access_token(token["access_token"], :mcp)

    assert auth.claims["aud"] == Resources.uri(:mcp)
    assert auth.scopes == ["e2e::echo"]

    initialized = post_mcp(token["access_token"], "initialize", %{})
    assert json_response(initialized, 200)["result"]["serverInfo"]["name"] == "backplane"
    assert [session_id] = get_resp_header(initialized, "mcp-session-id")

    listed = post_mcp(token["access_token"], "tools/list", %{}, session_id)

    assert listed
           |> json_response(200)
           |> get_in(["result", "tools"])
           |> Enum.map(& &1["name"]) == ["e2e::echo"]

    called =
      post_mcp(
        token["access_token"],
        "tools/call",
        %{"name" => "e2e::echo", "arguments" => %{"value" => "hello"}},
        session_id
      )
      |> json_response(200)

    refute called["error"]
    assert called["result"]["content"]
  end

  test "v1 grants keep model discovery and invocation separate", %{conn: conn} do
    metadata =
      conn
      |> get("/.well-known/oauth-protected-resource/v1")
      |> json_response(200)

    assert metadata["resource"] == Resources.uri(:v1)
    assert metadata["scopes_supported"] == ["llm::models", "llm::invoke"]

    descriptor = v1_request(:get, "/v1")

    assert json_response(descriptor, 200) == %{
             "resource" => Resources.uri(:v1),
             "resource_documentation" => Resources.documentation_uri(:v1)
           }

    %{client: client, user: user} =
      resource_principals(:v1, ["llm::models", "llm::invoke"])

    models = complete_resource_flow(conn, client, user, :v1, "llm::models")
    invoke = complete_resource_flow(conn, client, user, :v1, "llm::invoke")

    assert v1_request(:get, "/v1/models", models["access_token"]).status == 200

    denied_invoke =
      v1_request(
        :post,
        "/v1/responses",
        models["access_token"],
        %{"model" => "unknown/model", "input" => "hi"}
      )

    assert denied_invoke.status == 403
    assert Jason.decode!(denied_invoke.resp_body)["error"] == "insufficient_scope"

    denied_models = v1_request(:get, "/v1/models", invoke["access_token"])
    assert denied_models.status == 403
    assert Jason.decode!(denied_models.resp_body)["error"] == "insufficient_scope"

    allowed_invoke =
      v1_request(
        :post,
        "/v1/responses",
        invoke["access_token"],
        %{"model" => "unknown/model", "input" => "hi"}
      )

    assert allowed_invoke.status == 404
  end

  test "v1 accepts explicitly assigned resource and global wildcards", %{conn: conn} do
    %{client: client, user: user} = resource_principals(:v1, ["llm::*", "*"])

    for scope <- ["llm::*", "*"] do
      token = complete_resource_flow(conn, client, user, :v1, scope)

      assert v1_request(:get, "/v1/models", token["access_token"]).status == 200

      invoke =
        v1_request(
          :post,
          "/v1/responses",
          token["access_token"],
          %{"model" => "unknown/model", "input" => "hi"}
        )

      assert invoke.status == 404
    end
  end

  test "resource audiences cannot cross between MCP and v1", %{conn: conn} do
    %{client: client, user: user} =
      resource_principals(
        :mcp,
        ["e2e::echo", "llm::models"],
        resources: [:mcp, :v1]
      )

    mcp = complete_resource_flow(conn, client, user, :mcp, "e2e::echo")
    v1 = complete_resource_flow(conn, client, user, :v1, "llm::models")

    wrong_v1 = v1_request(:get, "/v1/models", mcp["access_token"])
    assert wrong_v1.status == 401
    assert Jason.decode!(wrong_v1.resp_body)["error"] == "invalid_token"

    wrong_mcp = post_mcp(v1["access_token"], "initialize", %{})
    assert wrong_mcp.status == 401
    assert Jason.decode!(wrong_mcp.resp_body)["error"] == "invalid_token"
  end

  test "v1 refresh keeps its resource and revocation is immediate", %{conn: conn} do
    %{client: client, user: user} = resource_principals(:v1, ["llm::models"])
    original = complete_resource_flow(conn, client, user, :v1, "llm::models")

    inherited = refresh_token(conn, client, original["refresh_token"], nil)

    assert {:ok, inherited_auth} =
             Auth.Tokens.verify_resource_access_token(inherited["access_token"], :v1)

    assert inherited_auth.claims["aud"] == Resources.uri(:v1)

    cross_resource =
      refresh_token_response(conn, client, inherited["refresh_token"], :mcp)

    assert cross_resource.status == 400
    assert json_response(cross_resource, 400)["error"] == "invalid_target"

    exact = refresh_token(conn, client, inherited["refresh_token"], :v1)

    assert {:ok, exact_auth} =
             Auth.Tokens.verify_resource_access_token(exact["access_token"], :v1)

    assert exact_auth.claims["aud"] == Resources.uri(:v1)

    revoke =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/revoke", %{"token" => exact["access_token"]})

    assert response(revoke, 200) == ""
    assert v1_request(:get, "/v1/models", exact["access_token"]).status == 401
  end

  test "disabled users and clients invalidate v1 access immediately", %{conn: conn} do
    %{client: user_client, user: user} = resource_principals(:v1, ["llm::models"])
    user_token = complete_resource_flow(conn, user_client, user, :v1, "llm::models")

    assert v1_request(:get, "/v1/models", user_token["access_token"]).status == 200
    assert {:ok, _disabled} = Auth.Accounts.disable_user(user)
    assert v1_request(:get, "/v1/models", user_token["access_token"]).status == 401

    %{client: client, user: client_user} = resource_principals(:v1, ["llm::models"])
    client_token = complete_resource_flow(conn, client, client_user, :v1, "llm::models")

    assert v1_request(:get, "/v1/models", client_token["access_token"]).status == 200

    assert {:ok, _disabled} =
             client.id
             |> Auth.OAuth.get_client()
             |> Auth.OAuth.disable_client()

    assert v1_request(:get, "/v1/models", client_token["access_token"]).status == 401
  end

  defp resource_principals(resource, scopes, opts \\ []) do
    unique = System.unique_integer([:positive])

    user =
      auth_user_fixture!(
        email: "resource-e2e-#{unique}@example.com",
        password: @password
      )

    client =
      oauth_client_fixture!(
        name: "Resource E2E #{unique}",
        redirect_uris: [@redirect_uri],
        resources: Keyword.get(opts, :resources, [resource]),
        scopes: scopes,
        confidential: true,
        pkce: true
      )

    grant_scopes!(user, scopes)
    %{client: client, user: user}
  end

  defp complete_resource_flow(conn, client, user, resource, scope) do
    verifier =
      32
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    code = authorize_resource_with_login(conn, client, user, resource, verifier, scope)
    exchange_code(conn, client, code, verifier, resource)
  end

  defp authorize_resource_with_login(conn, client, user, resource, verifier, scope) do
    params =
      %{
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "resource" => Resources.uri(resource),
        "state" => "state-#{System.unique_integer([:positive])}",
        "code_challenge" => pkce_challenge(verifier),
        "code_challenge_method" => "S256"
      }
      |> maybe_put("scope", scope)

    authorize_conn =
      conn
      |> recycle()
      |> get("/oauth/authorize", params)

    login_location = redirected_to(authorize_conn, 302)
    assert URI.parse(login_location).path == "/oauth/login"

    login_conn =
      authorize_conn
      |> recycle()
      |> get(path_with_query(login_location))

    login_params =
      login_conn
      |> html_response(200)
      |> form_inputs("#oauth-login-form")
      |> Map.merge(%{"email" => user.email, "password" => @password})

    callback_params =
      login_conn
      |> recycle()
      |> post("/oauth/login", login_params)
      |> redirected_to(302)
      |> URI.parse()
      |> Map.get(:query)
      |> URI.decode_query()

    refute callback_params["error"]
    Map.fetch!(callback_params, "code")
  end

  defp exchange_code(conn, client, code, verifier, resource) do
    conn
    |> recycle()
    |> put_basic_auth(client.id, client.plaintext_secret)
    |> post_form([
      {"grant_type", "authorization_code"},
      {"client_id", client.id},
      {"code", code},
      {"redirect_uri", @redirect_uri},
      {"code_verifier", verifier},
      {"resource", Resources.uri(resource)}
    ])
    |> json_response(200)
  end

  defp refresh_token(conn, client, refresh_token, resource) do
    conn
    |> refresh_token_response(client, refresh_token, resource)
    |> json_response(200)
  end

  defp refresh_token_response(conn, client, refresh_token, resource) do
    pairs = [
      {"grant_type", "refresh_token"},
      {"client_id", client.id},
      {"refresh_token", refresh_token}
    ]

    pairs =
      if resource do
        pairs ++ [{"resource", Resources.uri(resource)}]
      else
        pairs
      end

    conn
    |> recycle()
    |> put_basic_auth(client.id, client.plaintext_secret)
    |> post_form(pairs)
  end

  defp post_form(conn, pairs) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/oauth/token", URI.encode_query(pairs))
  end

  defp post_mcp(token, method, params, session_id \\ nil) do
    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "id" => System.unique_integer([:positive]),
      "params" => params
    }

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> maybe_put_bearer(token)
      |> maybe_put_session_id(session_id)

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

  defp bearer_header(conn) do
    assert [header] = get_resp_header(conn, "www-authenticate")
    header
  end

  defp resource_metadata_path(header) do
    assert [_, metadata_uri] = Regex.run(~r/resource_metadata="([^"]+)"/, header)
    URI.parse(metadata_uri).path
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_bearer(conn, nil), do: conn

  defp maybe_put_bearer(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp maybe_put_session_id(conn, nil), do: conn

  defp maybe_put_session_id(conn, session_id),
    do: put_req_header(conn, "mcp-session-id", session_id)

  defp put_basic_auth(conn, client_id, secret) do
    credentials = Base.encode64("#{client_id}:#{secret}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  defp pkce_challenge(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  defp path_with_query(location) do
    uri = URI.parse(location)
    query = if uri.query, do: "?#{uri.query}", else: ""
    "#{uri.path}#{query}"
  end

  defp form_inputs(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#{selector} input")
    |> Enum.reduce(%{}, fn input, params ->
      name = input |> Floki.attribute("name") |> List.first()
      value = input |> Floki.attribute("value") |> List.first()

      if name, do: Map.put(params, name, value || ""), else: params
    end)
  end

  defp grant_scopes!(user, scopes) do
    Enum.each(scopes, fn scope ->
      Auth.OAuth.get_scope(scope) ||
        Auth.OAuth.create_scope(%{name: scope, label: scope, public: true})
    end)

    role_name = "resource-e2e-#{System.unique_integer([:positive])}"
    assert {:ok, role} = Auth.RBAC.create_role(%{name: role_name, label: role_name})

    Enum.each(scopes, fn scope ->
      assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(role, scope)
    end)

    assert {:ok, _user_role} = Auth.RBAC.assign_user_role(user, role)
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
