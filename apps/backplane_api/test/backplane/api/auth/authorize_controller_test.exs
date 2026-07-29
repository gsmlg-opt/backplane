defmodule Backplane.Api.Auth.AuthorizeControllerTest do
  use Backplane.Api.ConnCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Api.Auth.{AuthorizeController, RawBodyReader, ResourceParams}
  alias Backplane.Auth
  alias Backplane.Auth.Resources
  alias Backplane.Auth.Schemas.OAuthTokenResource
  alias Backplane.Repo
  alias Boruta.Ecto.Token
  alias Boruta.Oauth.AuthorizeResponse
  alias Boruta.Oauth.Error

  @redirect_uri "http://localhost:4555/auth/callback"

  test "redirects an unauthenticated valid authorization request to login", %{conn: conn} do
    client = oauth_client!(scopes: ["openid"])

    conn = get(conn, "/oauth/authorize", authorize_params(client, %{"scope" => "openid"}))

    assert redirected_to(conn, 302) == "/oauth/login"
  end

  test "rejects duplicate identical resource query pairs before map collapse", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*"])
    query = URI.encode_query(authorize_params(client, %{"scope" => "github::*"}))
    resource = URI.encode_www_form(Resources.uri(:mcp))

    conn =
      get(conn, "/oauth/authorize?#{query}&resource=#{resource}&resource=#{resource}")

    assert_trusted_error(conn, "invalid_target")
  end

  test "rejects duplicate different resource query pairs", %{conn: conn} do
    client = oauth_client!(resources: [:mcp, :v1], scopes: ["github::*", "llm::invoke"])
    query = URI.encode_query(authorize_params(client, %{"scope" => "github::*"}))
    mcp = URI.encode_www_form(Resources.uri(:mcp))
    v1 = URI.encode_www_form(Resources.uri(:v1))

    conn = get(conn, "/oauth/authorize?#{query}&resource=#{mcp}&resource=#{v1}")

    assert_trusted_error(conn, "invalid_target")
  end

  test "rejects a malformed resource query value", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*"])
    query = URI.encode_query(authorize_params(client, %{"scope" => "github::*"}))

    conn = get(conn, "/oauth/authorize?#{query}&resource")

    assert_trusted_error(conn, "invalid_target")
  end

  test "rejects structured resource query values instead of crashing", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*"])
    query = URI.encode_query(authorize_params(client, %{"scope" => "github::*"}))
    resource = URI.encode_www_form(Resources.uri(:mcp))

    list_conn = get(conn, "/oauth/authorize?#{query}&resource[]=#{resource}")
    assert_trusted_error(list_conn, "invalid_target")

    map_conn =
      conn
      |> recycle()
      |> get("/oauth/authorize?#{query}&resource[key]=#{resource}")

    assert_trusted_error(map_conn, "invalid_target")
  end

  test "rejects mixed exact and structured resource query pollution in either order", %{
    conn: conn
  } do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*"])
    base = URI.encode_query(authorize_params(client, %{"scope" => "github::*"}))
    exact = {"resource", Resources.uri(:mcp)}

    for structured_key <- ["resource[]", "resource[key]"],
        pairs <- [[exact, {structured_key, "evil"}], [{structured_key, "evil"}, exact]] do
      response = get(conn, "/oauth/authorize?#{base}&#{URI.encode_query(pairs)}")
      assert_trusted_error(response, "invalid_target")
    end
  end

  test "rejects unsupported noncanonical resource URIs", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*"])

    conn =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:mcp) <> "/",
          "scope" => "github::*"
        })
      )

    assert_trusted_error(conn, "invalid_target")
  end

  test "rejects a resource that is not assigned to the client", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["llm::invoke"])

    conn =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:v1),
          "scope" => "llm::invoke"
        })
      )

    assert_trusted_error(conn, "invalid_target")
  end

  test "unknown clients and mismatched redirect URIs fail directly before trust", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*"])

    unknown =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{"client_id" => Ecto.UUID.generate()})
      )

    assert response(unknown, 400) == "invalid_request"
    assert get_resp_header(unknown, "location") == []

    mismatched =
      conn
      |> recycle()
      |> get(
        "/oauth/authorize",
        authorize_params(client, %{"redirect_uri" => "https://evil.example.test/callback"})
      )

    assert response(mismatched, 400) == "invalid_request"
    assert get_resp_header(mismatched, "location") == []
  end

  test "trusted response type and PKCE errors redirect with state and no code", %{conn: conn} do
    client = oauth_client!(scopes: ["openid"])

    unsupported_response =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{"response_type" => "token", "scope" => "openid"})
      )

    assert_trusted_error(unsupported_response, "unsupported_response_type")

    plain_pkce =
      conn
      |> recycle()
      |> get(
        "/oauth/authorize",
        authorize_params(client, %{
          "code_challenge_method" => "plain",
          "scope" => "openid"
        })
      )

    assert_trusted_error(plain_pkce, "unsupported_code_challenge_method")

    missing_challenge =
      conn
      |> recycle()
      |> get(
        "/oauth/authorize",
        authorize_params(client, %{
          "code_challenge" => nil,
          "scope" => "openid"
        })
      )

    assert_trusted_error(missing_challenge, "invalid_request")
  end

  test "structured scope values redirect invalid_scope instead of crashing", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*"])

    base =
      client
      |> authorize_params(%{"resource" => Resources.uri(:mcp)})
      |> Map.delete("scope")
      |> URI.encode_query()

    exact = {"scope", "github::*"}

    for structured_key <- ["scope[]", "scope[key]"],
        pairs <-
          [
            [{structured_key, "github::*"}],
            [exact, {structured_key, "evil"}],
            [{structured_key, "evil"}, exact]
          ] do
      response = get(conn, "/oauth/authorize?#{base}&#{URI.encode_query(pairs)}")
      assert_trusted_error(response, "invalid_scope")
    end
  end

  test "structured client and redirect parameters fail directly before trust", %{conn: conn} do
    client = oauth_client!(scopes: ["openid"])

    for {name, value} <- [
          {"client_id", client.id},
          {"redirect_uri", @redirect_uri}
        ],
        structured_key <- ["#{name}[]", "#{name}[key]"],
        pairs <-
          [
            [{structured_key, value}],
            [{name, value}, {structured_key, "evil"}],
            [{structured_key, "evil"}, {name, value}]
          ] do
      base =
        client
        |> authorize_params(%{"scope" => "openid"})
        |> Map.delete(name)
        |> URI.encode_query()

      response = get(conn, "/oauth/authorize?#{base}&#{URI.encode_query(pairs)}")
      assert response(response, 400) == "invalid_request"
      assert get_resp_header(response, "location") == []
    end
  end

  test "structured state redirects invalid_request without serializing attacker data", %{
    conn: conn
  } do
    client = oauth_client!(scopes: ["openid"])

    base =
      client
      |> authorize_params(%{"scope" => "openid"})
      |> Map.delete("state")
      |> URI.encode_query()

    exact = {"state", "state-123"}

    for structured_key <- ["state[]", "state[key]"],
        pairs <-
          [
            [{structured_key, "attacker"}],
            [exact, {structured_key, "attacker"}],
            [{structured_key, "attacker"}, exact]
          ] do
      response = get(conn, "/oauth/authorize?#{base}&#{URI.encode_query(pairs)}")
      assert redirected_to(response, 302)
      params = redirect_params(response)
      assert params["error"] == "invalid_request"
      refute Map.has_key?(params, "state")
      refute Map.has_key?(params, "code")
    end
  end

  test "trusted errors remove registered redirect state when request state is absent", %{
    conn: conn
  } do
    redirect_uri = @redirect_uri <> "?tenant=acme&state=registered"

    client =
      oauth_client_fixture!(
        name: "Registered Redirect State Client",
        redirect_uris: [redirect_uri],
        scopes: ["openid"],
        confidential: false,
        pkce: true
      )

    params =
      client
      |> authorize_params(%{
        "redirect_uri" => redirect_uri,
        "response_type" => "token",
        "scope" => "openid"
      })
      |> Map.delete("state")

    response = get(conn, "/oauth/authorize", params)
    redirect_params = redirect_params(response)

    assert redirect_params["error"] == "unsupported_response_type"
    assert redirect_params["tenant"] == "acme"
    refute Map.has_key?(redirect_params, "state")
  end

  test "trusted errors remove registered redirect state when request state is rejected", %{
    conn: conn
  } do
    redirect_uri = @redirect_uri <> "?tenant=acme&state=registered"

    client =
      oauth_client_fixture!(
        name: "Rejected Request State Client",
        redirect_uris: [redirect_uri],
        scopes: ["openid"],
        confidential: false,
        pkce: true
      )

    query =
      client
      |> authorize_params(%{"redirect_uri" => redirect_uri, "scope" => "openid"})
      |> Map.delete("state")
      |> URI.encode_query()

    response = get(conn, "/oauth/authorize?#{query}&state[]=attacker")
    redirect_params = redirect_params(response)

    assert redirect_params["error"] == "invalid_request"
    assert redirect_params["tenant"] == "acme"
    refute Map.has_key?(redirect_params, "state")
  end

  test "requires a resource for protected operation scopes on assigned clients", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*"])

    conn =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{"scope" => "github::*"})
      )

    assert_trusted_error(conn, "invalid_target")
  end

  test "selected resources use their strict scope vocabulary", %{conn: conn} do
    client =
      oauth_client!(
        resources: [:mcp, :v1],
        scopes: ["github::*", "llm::invoke", "system::admin"]
      )

    system_scope =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:mcp),
          "scope" => "system::admin"
        })
      )

    assert_trusted_error(system_scope, "invalid_scope")

    mcp_scope_on_v1 =
      conn
      |> recycle()
      |> get(
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:v1),
          "scope" => "github::*"
        })
      )

    assert_trusted_error(mcp_scope_on_v1, "invalid_scope")

    llm_scope_on_mcp =
      conn
      |> recycle()
      |> get(
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:mcp),
          "scope" => "llm::invoke"
        })
      )

    assert redirected_to(llm_scope_on_mcp, 302) == "/oauth/login"
  end

  test "explicit resource scopes must belong exactly to both client and user", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*", "docs::read"])
    {conn, user} = authenticated_conn(conn, ["github::*"])

    user_rejected =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:mcp),
          "scope" => "github::* docs::read"
        })
      )

    assert_trusted_error(user_rejected, "invalid_scope")

    client_missing =
      client
      |> authorize_params(%{
        "resource" => Resources.uri(:mcp),
        "scope" => "skill::*"
      })
      |> then(&get(recycle(user_rejected), "/oauth/authorize", &1))

    assert_trusted_error(client_missing, "invalid_scope")

    grant_scopes!(user, ["docs::read"])

    success =
      get(
        recycle(client_missing),
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:mcp),
          "scope" => "docs::read github::*"
        })
      )

    code = authorization_code_from_redirect(success)
    assert Repo.get_by!(Token, value: code).scope == "docs::read github::*"
  end

  test "omitted scope defaults to the sorted client and user operation intersection", %{
    conn: conn
  } do
    client =
      oauth_client!(
        resources: [:mcp],
        scopes: ["openid", "skill::*", "github::*", "system::admin"]
      )

    {conn, _user} =
      authenticated_conn(conn, ["openid", "github::*", "docs::read", "system::admin"])

    success =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:mcp),
          "scope" => ""
        })
      )

    code = authorization_code_from_redirect(success)
    assert Repo.get_by!(Token, value: code).scope == "github::*"
  end

  test "omitted resource scope rejects an empty operation intersection", %{conn: conn} do
    client = oauth_client!(resources: [:v1], scopes: ["openid", "llm::invoke"])
    {conn, _user} = authenticated_conn(conn, ["openid"])

    conn =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:v1),
          "scope" => ""
        })
      )

    assert_trusted_error(conn, "invalid_scope")
  end

  test "keeps identity, no-resource system, and empty-resource clients compatible", %{conn: conn} do
    resource_client =
      oauth_client!(resources: [:mcp], scopes: ["openid", "system::admin"])

    {conn, _user} = authenticated_conn(conn, ["openid", "system::admin"])

    identity =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(resource_client, %{"scope" => "openid"})
      )

    assert authorization_code_from_redirect(identity)

    system =
      get(
        recycle(identity),
        "/oauth/authorize",
        authorize_params(resource_client, %{"scope" => "system::admin"})
      )

    assert authorization_code_from_redirect(system)

    identity_client = oauth_client!(resources: [], scopes: ["openid"])

    empty_allowlist =
      get(
        recycle(system),
        "/oauth/authorize",
        authorize_params(identity_client, %{"scope" => "openid"})
      )

    assert authorization_code_from_redirect(empty_allowlist)
  end

  test "binds the selected resource to the code before disclosing it", %{conn: conn} do
    client = oauth_client!(resources: [:v1], scopes: ["llm::invoke"])
    {conn, _user} = authenticated_conn(conn, ["llm::invoke"])

    authorize_conn =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{
          "resource" => Resources.uri(:v1),
          "scope" => "llm::invoke"
        })
      )

    code = authorization_code_from_redirect(authorize_conn)

    assert {:ok, %Token{value: ^code}, :v1} =
             Auth.TokenResources.lookup_code(client.id, code)
  end

  test "binding failure redirects server_error without disclosing the code", %{conn: conn} do
    client = oauth_client!(resources: [:mcp], scopes: ["github::*"])
    code = "already-bound-#{System.unique_integer([:positive])}"

    token =
      Repo.insert!(%Token{
        type: "code",
        value: code,
        client_id: client.id,
        scope: "github::*",
        expires_at: System.system_time(:second) + 60
      })

    Repo.insert!(
      OAuthTokenResource.changeset(%OAuthTokenResource{}, %{
        oauth_token_id: token.id,
        resource: "mcp"
      })
    )

    response = %AuthorizeResponse{
      type: :code,
      redirect_uri: @redirect_uri,
      code: code,
      state: "state-123"
    }

    conn =
      conn
      |> put_private(:backplane_oauth_resource, :v1)
      |> put_private(:backplane_oauth_client_id, client.id)
      |> AuthorizeController.authorize_success(response)

    params = redirect_params(conn)
    assert params["error"] == "server_error"
    assert params["state"] == "state-123"
    refute Map.has_key?(params, "code")
    assert %DateTime{} = Repo.reload!(token).revoked_at
  end

  test "Boruta authorization errors use the trusted redirect without leaking descriptions", %{
    conn: conn
  } do
    params = %{
      "redirect_uri" => @redirect_uri,
      "state" => "state-123"
    }

    conn =
      conn
      |> Map.put(:query_params, params)
      |> AuthorizeController.authorize_error(%Error{
        status: :bad_request,
        error: :invalid_scope,
        error_description: "secret upstream diagnostic"
      })

    redirect = redirected_to(conn, 302)
    params = redirect_params(conn)
    assert params == %{"error" => "invalid_scope", "state" => "state-123"}
    refute redirect =~ "secret"
    refute redirect =~ "error_description"
  end

  test "chunked raw body parsing clears its completed accumulator" do
    body =
      URI.encode_query([
        {"grant_type", "authorization_code"},
        {"code", "secret-code"},
        {"resource", Resources.uri(:mcp)}
      ])

    conn =
      :post
      |> Plug.Test.conn("/oauth/token", body)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    assert {:more, first, conn} =
             RawBodyReader.read_body(conn, length: byte_size(body) - 1)

    assert conn.private[:oauth_raw_form_body] == first

    assert {:ok, last, conn} = RawBodyReader.read_body(conn, length: byte_size(body))
    assert first <> last == body
    refute Map.has_key?(conn.private, :oauth_raw_form_body)
  end

  test "raw body parsing retains only resource parameter pairs" do
    resource = Resources.uri(:mcp)

    body =
      URI.encode_query([
        {"grant_type", "authorization_code"},
        {"code", "secret-code"},
        {"refresh_token", "secret-refresh"},
        {"client_secret", "secret-client"},
        {"resource", resource},
        {"resource[]", "structured"}
      ])

    conn =
      :post
      |> Plug.Test.conn("/oauth/token", body)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    assert {:ok, ^body, conn} = RawBodyReader.read_body(conn, [])

    assert conn.private[:oauth_form_pairs] == [
             {"resource", resource},
             {"resource[]", "structured"}
           ]
  end

  test "token form resource parsing preserves zero and exact canonical values", %{conn: conn} do
    no_resource = token_form(conn, [{"grant_type", "unsupported"}])
    assert ResourceParams.form(no_resource, no_resource.params) == {:ok, nil}

    mcp =
      token_form(recycle(conn), [
        {"grant_type", "unsupported"},
        {"resource", Resources.uri(:mcp)}
      ])

    assert ResourceParams.form(mcp, mcp.params) == {:ok, :mcp}

    v1 =
      token_form(recycle(conn), [
        {"grant_type", "unsupported"},
        {"resource", Resources.uri(:v1)}
      ])

    assert ResourceParams.form(v1, v1.params) == {:ok, :v1}
  end

  test "token form resource parsing rejects duplicate identical and different values", %{
    conn: conn
  } do
    duplicate =
      token_form(conn, [
        {"grant_type", "unsupported"},
        {"resource", Resources.uri(:mcp)},
        {"resource", Resources.uri(:mcp)}
      ])

    assert ResourceParams.form(duplicate, duplicate.params) == {:error, :invalid_target}

    different =
      token_form(recycle(conn), [
        {"grant_type", "unsupported"},
        {"resource", Resources.uri(:mcp)},
        {"resource", Resources.uri(:v1)}
      ])

    assert ResourceParams.form(different, different.params) == {:error, :invalid_target}
  end

  test "token form parsing rejects mixed exact and structured resource pollution", %{conn: conn} do
    exact = {"resource", Resources.uri(:mcp)}

    for structured_key <- ["resource[]", "resource[key]"],
        pairs <- [[exact, {structured_key, "evil"}], [{structured_key, "evil"}, exact]] do
      response = token_form(conn, [{"grant_type", "unsupported"} | pairs])
      assert ResourceParams.form(response, response.params) == {:error, :invalid_target}
    end
  end

  test "token form resource parsing rejects malformed structured and unsupported values", %{
    conn: conn
  } do
    blank = token_form(conn, [{"grant_type", "unsupported"}, {"resource", ""}])
    assert ResourceParams.form(blank, blank.params) == {:error, :invalid_target}

    structured =
      token_form_raw(
        recycle(conn),
        "grant_type=unsupported&resource%5B%5D=#{URI.encode_www_form(Resources.uri(:mcp))}"
      )

    assert ResourceParams.form(structured, structured.params) == {:error, :invalid_target}

    unsupported =
      token_form(recycle(conn), [
        {"grant_type", "unsupported"},
        {"resource", Resources.uri(:mcp) <> "/"}
      ])

    assert ResourceParams.form(unsupported, unsupported.params) == {:error, :invalid_target}
  end

  test "token resource parsing ignores query and JSON values", %{conn: conn} do
    query_resource =
      conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post(
        "/oauth/token?resource=#{URI.encode_www_form(Resources.uri(:mcp))}",
        "grant_type=unsupported"
      )

    assert ResourceParams.form(query_resource, query_resource.params) == {:ok, nil}

    json_resource =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/oauth/token",
        JSON.encode!(%{"grant_type" => "unsupported", "resource" => Resources.uri(:mcp)})
      )

    assert ResourceParams.form(json_resource, json_resource.params) == {:ok, nil}
  end

  defp oauth_client!(opts) do
    scopes = Keyword.fetch!(opts, :scopes)
    resources = Keyword.get(opts, :resources)

    attrs = [
      name: "Authorize Test Client #{System.unique_integer([:positive])}",
      redirect_uris: [@redirect_uri],
      scopes: scopes,
      confidential: false,
      pkce: true
    ]

    attrs = if is_nil(resources), do: attrs, else: Keyword.put(attrs, :resources, resources)
    oauth_client_fixture!(attrs)
  end

  defp authorize_params(client, overrides) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "scope" => "",
        "state" => "state-123",
        "code_challenge" => "challenge",
        "code_challenge_method" => "S256"
      },
      overrides
    )
  end

  defp authenticated_conn(conn, scopes) do
    user = auth_user_fixture!()
    grant_scopes!(user, scopes)
    assert {:ok, %{token: token}} = Auth.Accounts.create_session(user)
    {init_test_session(conn, auth_session_token: token), user}
  end

  defp grant_scopes!(user, scopes) do
    Enum.each(scopes, fn scope ->
      Auth.OAuth.get_scope(scope) ||
        Auth.OAuth.create_scope(%{name: scope, label: scope, public: true})
    end)

    name = "authorize-role-#{System.unique_integer([:positive])}"
    assert {:ok, role} = Auth.RBAC.create_role(%{name: name, label: name})

    Enum.each(scopes, fn scope ->
      assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(role, scope)
    end)

    assert {:ok, _user_role} = Auth.RBAC.assign_user_role(user, role)
    role
  end

  defp token_form(conn, pairs) do
    token_form_raw(conn, URI.encode_query(pairs))
  end

  defp token_form_raw(conn, body) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/oauth/token", body)
  end

  defp assert_trusted_error(conn, expected_error) do
    assert redirected_to(conn, 302)
    params = redirect_params(conn)
    assert params["error"] == expected_error
    assert params["state"] == "state-123"
    refute Map.has_key?(params, "code")
    params
  end

  defp authorization_code_from_redirect(conn) do
    params = redirect_params(conn)
    assert is_binary(params["code"])
    refute params["error"]
    params["code"]
  end

  defp redirect_params(conn) do
    uri = conn |> redirected_to(302) |> URI.parse()
    assert "#{uri.scheme}://#{uri.host}:#{uri.port}#{uri.path}" == @redirect_uri
    URI.decode_query(uri.query || "")
  end
end
