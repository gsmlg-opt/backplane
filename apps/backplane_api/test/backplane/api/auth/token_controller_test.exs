defmodule Backplane.Api.Auth.TokenControllerTest do
  use Backplane.Api.ConnCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Api.Auth.TokenController
  alias Backplane.Auth
  alias Backplane.Auth.Resources
  alias Backplane.Repo
  alias Boruta.Ecto.Token
  alias Boruta.Oauth.TokenResponse

  defmodule LineageErrorTokenGenerator do
    @behaviour Boruta.Oauth.TokenGenerator

    @impl true
    def generate(:access_token, %{type: "access_token"}) do
      raise Backplane.Auth.TokenResources.LineageError
    end

    def generate(type, token),
      do: Backplane.Auth.AccessTokenGenerator.generate(type, token)

    @impl true
    def secret(client), do: Backplane.Auth.AccessTokenGenerator.secret(client)
  end

  test "rejects unsupported grants", %{conn: conn} do
    body =
      conn
      |> post("/oauth/token", %{"grant_type" => "password"})
      |> json_response(400)

    assert body["error"] == "unsupported_grant_type"
  end

  test "rejects invalid confidential client credentials", %{conn: conn} do
    client = confidential_client!()

    body =
      conn
      |> put_basic_auth(client.id, "wrong-secret")
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => "missing"
      })
      |> json_response(401)

    assert body["error"] == "invalid_client"
  end

  test "mapped authorization code requires one exact resource and binds the issued access token",
       %{conn: conn} do
    {user, client} = resource_subject!(:mcp)
    {code, verifier} = authorization_code!(user, client, :mcp)

    response =
      conn
      |> exchange_code(client, code, verifier, [{"resource", Resources.uri(:mcp)}])
      |> json_response(200)

    assert {:ok, claims} = Auth.Tokens.verify_access_token(response["access_token"])
    assert claims["aud"] == Resources.uri(:mcp)

    assert {:ok, %Token{value: value}, :mcp} =
             Auth.TokenResources.lookup_access_token(client.id, response["access_token"])

    assert value == response["access_token"]
  end

  test "mapped authorization code rejects omitted resource without consuming the code", %{
    conn: conn
  } do
    {user, client} = resource_subject!(:mcp)
    {code, verifier} = authorization_code!(user, client, :mcp)

    rejected =
      conn
      |> exchange_code(client, code, verifier, [])
      |> json_response(400)

    assert rejected["error"] == "invalid_target"

    accepted =
      conn
      |> recycle()
      |> exchange_code(client, code, verifier, [{"resource", Resources.uri(:mcp)}])
      |> json_response(200)

    assert accepted["access_token"]
  end

  test "mapped authorization code rejects mismatched resource without consuming the code", %{
    conn: conn
  } do
    {user, client} = resource_subject!(:mcp)
    {code, verifier} = authorization_code!(user, client, :mcp)

    rejected =
      conn
      |> exchange_code(client, code, verifier, [{"resource", Resources.uri(:v1)}])
      |> json_response(400)

    assert rejected["error"] == "invalid_target"

    accepted =
      conn
      |> recycle()
      |> exchange_code(client, code, verifier, [{"resource", Resources.uri(:mcp)}])
      |> json_response(200)

    assert accepted["access_token"]
  end

  test "mapped authorization code rejects repeated resource pairs before parser collapse", %{
    conn: conn
  } do
    {user, client} = resource_subject!(:mcp)
    {code, verifier} = authorization_code!(user, client, :mcp)

    for resources <- [
          [
            {"resource", Resources.uri(:mcp)},
            {"resource", Resources.uri(:mcp)}
          ],
          [
            {"resource", Resources.uri(:mcp)},
            {"resource", Resources.uri(:v1)}
          ]
        ] do
      body =
        conn
        |> recycle()
        |> exchange_code(client, code, verifier, resources)
        |> json_response(400)

      assert body["error"] == "invalid_target"
    end
  end

  test "wrong code verifier returns invalid_grant before every resource classification", %{
    conn: conn
  } do
    {user, client} = resource_subject!(:mcp)
    {code, correct_verifier} = authorization_code!(user, client, :mcp)
    wrong_verifier = verifier()

    for resources <- [
          [],
          [{"resource", Resources.uri(:mcp)}],
          [{"resource", Resources.uri(:v1)}],
          [
            {"resource", Resources.uri(:mcp)},
            {"resource", Resources.uri(:mcp)}
          ]
        ] do
      grant_conn =
        conn
        |> recycle()
        |> exchange_code(client, code, wrong_verifier, resources)

      raw_body = response(grant_conn, 400)
      body = Jason.decode!(raw_body)

      assert body["error"] == "invalid_grant"
      refute raw_body =~ code
      refute raw_body =~ Resources.uri(:mcp)
      refute raw_body =~ Resources.uri(:v1)
    end

    assert {:ok, %Token{revoked_at: nil}, :mcp} =
             Auth.TokenResources.lookup_code(client.id, code)

    accepted =
      conn
      |> recycle()
      |> exchange_code(client, code, correct_verifier, [
        {"resource", Resources.uri(:mcp)}
      ])
      |> json_response(200)

    assert accepted["access_token"]
  end

  test "known unmapped authorization code accepts omission and rejects a supplied resource", %{
    conn: conn
  } do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:mcp], scopes: ["openid"])
    {supplied_code, supplied_verifier} = authorization_code!(user, client, nil)

    rejected =
      conn
      |> exchange_code(client, supplied_code, supplied_verifier, [
        {"resource", Resources.uri(:mcp)}
      ])
      |> json_response(400)

    assert rejected["error"] == "invalid_target"

    {omitted_code, omitted_verifier} = authorization_code!(user, client, nil)

    accepted =
      conn
      |> recycle()
      |> exchange_code(client, omitted_code, omitted_verifier, [])
      |> json_response(200)

    assert accepted["access_token"]
  end

  test "mapped refresh inherits omission and accepts one exact resource", %{conn: conn} do
    {user, client} = resource_subject!(:mcp)
    original = issue_resource_token(conn, user, client, :mcp)

    inherited =
      conn
      |> recycle()
      |> refresh(client, original["refresh_token"], [])
      |> json_response(200)

    assert {:ok, inherited_claims} =
             Auth.Tokens.verify_access_token(inherited["access_token"])

    assert inherited_claims["aud"] == Resources.uri(:mcp)

    assert {:ok, %Token{}, :mcp} =
             Auth.TokenResources.lookup_access_token(client.id, inherited["access_token"])

    second_original = issue_resource_token(recycle(conn), user, client, :mcp)

    exact =
      conn
      |> recycle()
      |> refresh(client, second_original["refresh_token"], [
        {"resource", Resources.uri(:mcp)}
      ])
      |> json_response(200)

    assert {:ok, exact_claims} = Auth.Tokens.verify_access_token(exact["access_token"])
    assert exact_claims["aud"] == Resources.uri(:mcp)

    assert {:ok, %Token{}, :mcp} =
             Auth.TokenResources.lookup_access_token(client.id, exact["access_token"])
  end

  test "mapped refresh rejects cross-resource and repeated resource without consuming it", %{
    conn: conn
  } do
    {user, client} = resource_subject!(:mcp)
    original = issue_resource_token(conn, user, client, :mcp)

    cross_resource =
      conn
      |> recycle()
      |> refresh(client, original["refresh_token"], [
        {"resource", Resources.uri(:v1)}
      ])
      |> json_response(400)

    assert cross_resource["error"] == "invalid_target"

    repeated =
      conn
      |> recycle()
      |> refresh(client, original["refresh_token"], [
        {"resource", Resources.uri(:mcp)},
        {"resource", Resources.uri(:mcp)}
      ])
      |> json_response(400)

    assert repeated["error"] == "invalid_target"

    accepted =
      conn
      |> recycle()
      |> refresh(client, original["refresh_token"], [])
      |> json_response(200)

    assert accepted["access_token"]
  end

  test "unmapped refresh rejects a supplied resource", %{conn: conn} do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:mcp], scopes: ["openid"])
    {code, verifier} = authorization_code!(user, client, nil)

    original =
      conn
      |> exchange_code(client, code, verifier, [])
      |> json_response(200)

    body =
      conn
      |> recycle()
      |> refresh(client, original["refresh_token"], [
        {"resource", Resources.uri(:mcp)}
      ])
      |> json_response(400)

    assert body["error"] == "invalid_target"
  end

  test "unknown code and refresh credentials remain invalid_grant when resource is supplied", %{
    conn: conn
  } do
    client = oauth_client_fixture!(resources: [:mcp], scopes: ["openid"])

    code_body =
      conn
      |> exchange_code(client, "unknown-code", verifier(), [
        {"resource", Resources.uri(:mcp)}
      ])
      |> json_response(400)

    assert code_body["error"] == "invalid_grant"

    refresh_body =
      conn
      |> recycle()
      |> refresh(client, "unknown-refresh", [{"resource", Resources.uri(:mcp)}])
      |> json_response(400)

    assert refresh_body["error"] == "invalid_grant"
  end

  test "missing and structured grant credentials return JSON errors instead of crashing", %{
    conn: conn
  } do
    client = oauth_client_fixture!(resources: [:mcp], scopes: ["openid"])

    requests = [
      [
        {"grant_type", "authorization_code"},
        {"client_id", client.id},
        {"redirect_uri", hd(client.redirect_uris)},
        {"code_verifier", verifier()},
        {"resource", Resources.uri(:mcp)}
      ],
      [
        {"grant_type", "authorization_code"},
        {"client_id", client.id},
        {"code[bad]", "value"},
        {"redirect_uri", hd(client.redirect_uris)},
        {"code_verifier", verifier()},
        {"resource", Resources.uri(:mcp)}
      ],
      [
        {"grant_type", "refresh_token"},
        {"client_id", client.id},
        {"resource", Resources.uri(:mcp)}
      ],
      [
        {"grant_type", "refresh_token"},
        {"client_id", client.id},
        {"refresh_token[bad]", "value"},
        {"resource", Resources.uri(:mcp)}
      ]
    ]

    Enum.each(requests, fn pairs ->
      body =
        conn
        |> recycle()
        |> put_basic_auth(client.id, client.plaintext_secret)
        |> post_form(pairs)
        |> json_response(400)

      assert body["error"] == "invalid_request"
    end)
  end

  test "wrong confidential secret is rejected before mapping-dependent target checks", %{
    conn: conn
  } do
    {user, client} = resource_subject!(:mcp)
    {code, verifier} = authorization_code!(user, client, :mcp)

    code_body =
      conn
      |> exchange_code(%{client | plaintext_secret: "wrong-secret"}, code, verifier, [
        {"resource", Resources.uri(:v1)}
      ])
      |> json_response(401)

    assert code_body["error"] == "invalid_client"

    original = issue_resource_token(recycle(conn), user, client, :mcp)

    refresh_body =
      conn
      |> recycle()
      |> refresh(
        %{client | plaintext_secret: "wrong-secret"},
        original["refresh_token"],
        [{"resource", Resources.uri(:v1)}]
      )
      |> json_response(401)

    assert refresh_body["error"] == "invalid_client"
  end

  test "resource is accepted only from one form pair, not query or JSON", %{conn: conn} do
    {user, client} = resource_subject!(:mcp)
    {query_code, query_verifier} = authorization_code!(user, client, :mcp)

    query_body =
      conn
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post(
        "/oauth/token?resource=#{URI.encode_www_form(Resources.uri(:mcp))}",
        URI.encode_query(code_pairs(client, query_code, query_verifier))
      )
      |> json_response(400)

    assert query_body["error"] == "invalid_target"

    {json_code, json_verifier} = authorization_code!(user, client, :mcp)

    json_body =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/oauth/token",
        JSON.encode!(
          code_pairs(client, json_code, json_verifier)
          |> Map.new()
          |> Map.put("resource", Resources.uri(:mcp))
        )
      )
      |> json_response(400)

    assert json_body["error"] == "invalid_target"
  end

  test "LineageError is narrowly translated to JSON server_error without leaking the code", %{
    conn: conn
  } do
    {user, client} = resource_subject!(:mcp)
    {code, verifier} = authorization_code!(user, client, :mcp)

    with_token_generator(LineageErrorTokenGenerator, fn ->
      response =
        exchange_code(conn, client, code, verifier, [
          {"resource", Resources.uri(:mcp)}
        ])

      body = json_response(response, 400)
      assert body["error"] == "server_error"
      refute response(response, 400) =~ code
      refute Map.has_key?(body, "error_description")
    end)
  end

  test "audience verification failure revokes and invalidates the issued access row", %{
    conn: conn
  } do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:mcp], scopes: ["openid"])
    token = access_token_fixture!(user, client, ["openid"])
    oauth_token = Boruta.Ecto.OauthMapper.to_oauth_schema(token)

    assert %Boruta.Oauth.Token{} = Boruta.Ecto.AccessTokens.get_by(value: token.value)
    assert {:ok, _cached} = Boruta.Ecto.TokenStore.get(value: token.value)
    assert {:ok, _cached} = Boruta.Ecto.TokenStore.get(refresh_token: token.refresh_token)

    response =
      conn
      |> put_private(:backplane_oauth_resource, :mcp)
      |> put_private(:backplane_oauth_client_id, client.id)
      |> TokenController.token_success(token_response(oauth_token))

    assert json_response(response, 400)["error"] == "server_error"
    assert %DateTime{} = Repo.reload!(token).revoked_at
    assert {:error, "Not cached."} = Boruta.Ecto.TokenStore.get(value: token.value)

    assert {:error, "Not cached."} =
             Boruta.Ecto.TokenStore.get(refresh_token: token.refresh_token)
  end

  test "binding failure revokes and invalidates the issued access row", %{conn: conn} do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:mcp], scopes: ["github::*"])
    token = resource_access_token_fixture!(user, client, ["github::*"], :mcp)
    oauth_token = Boruta.Ecto.OauthMapper.to_oauth_schema(token)

    assert %Boruta.Oauth.Token{} = Boruta.Ecto.AccessTokens.get_by(value: token.value)
    assert {:ok, _cached} = Boruta.Ecto.TokenStore.get(value: token.value)
    assert {:ok, _cached} = Boruta.Ecto.TokenStore.get(refresh_token: token.refresh_token)

    response =
      conn
      |> put_private(:backplane_oauth_resource, :mcp)
      |> put_private(:backplane_oauth_client_id, client.id)
      |> TokenController.token_success(token_response(oauth_token))

    assert json_response(response, 400)["error"] == "server_error"
    assert %DateTime{} = Repo.reload!(token).revoked_at
    assert {:error, "Not cached."} = Boruta.Ecto.TokenStore.get(value: token.value)

    assert {:error, "Not cached."} =
             Boruta.Ecto.TokenStore.get(refresh_token: token.refresh_token)
  end

  defp confidential_client! do
    assert {:ok, _scope} =
             Auth.OAuth.create_scope(%{name: "openid", label: "openid", public: true})

    assert {:ok, %{client: client}} =
             Auth.OAuth.create_client(%{
               name: "Token Test Client",
               redirect_uris: ["https://app.example.test/auth/callback"],
               scopes: ["openid"],
               confidential: true,
               pkce: true
             })

    client
  end

  defp put_basic_auth(conn, client_id, secret) do
    credentials = Base.encode64("#{client_id}:#{secret}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  defp resource_subject!(resource) do
    user = auth_user_fixture!()

    client =
      oauth_client_fixture!(
        resources: [:mcp, :v1],
        scopes: ["github::*"],
        confidential: true,
        pkce: true
      )

    assert resource in [:mcp, :v1]
    {user, client}
  end

  defp authorization_code!(user, client, resource) do
    verifier = verifier()

    oauth_client =
      client.id
      |> Auth.OAuth.get_client()
      |> Boruta.Ecto.OauthMapper.to_oauth_schema()

    assert {:ok, code} =
             Boruta.Ecto.Codes.create(%{
               client: oauth_client,
               resource_owner: nil,
               redirect_uri: hd(client.redirect_uris),
               sub: user.id,
               scope: if(resource, do: "github::*", else: "openid"),
               state: "state",
               code_challenge: pkce_challenge(verifier),
               code_challenge_method: "S256"
             })

    if resource do
      assert {:ok, _binding} =
               Auth.TokenResources.bind_issued("code", client.id, code.value, resource)
    end

    {code.value, verifier}
  end

  defp issue_resource_token(conn, user, client, resource) do
    {code, verifier} = authorization_code!(user, client, resource)

    conn
    |> exchange_code(client, code, verifier, [{"resource", Resources.uri(resource)}])
    |> json_response(200)
  end

  defp exchange_code(conn, client, code, verifier, resource_pairs) do
    conn
    |> put_basic_auth(client.id, client.plaintext_secret)
    |> post_form(code_pairs(client, code, verifier) ++ resource_pairs)
  end

  defp code_pairs(client, code, verifier) do
    [
      {"grant_type", "authorization_code"},
      {"client_id", client.id},
      {"code", code},
      {"redirect_uri", hd(client.redirect_uris)},
      {"code_verifier", verifier}
    ]
  end

  defp refresh(conn, client, refresh_token, resource_pairs) do
    conn
    |> put_basic_auth(client.id, client.plaintext_secret)
    |> post_form(
      [
        {"grant_type", "refresh_token"},
        {"client_id", client.id},
        {"refresh_token", refresh_token}
      ] ++ resource_pairs
    )
  end

  defp post_form(conn, pairs) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/oauth/token", URI.encode_query(pairs))
  end

  defp verifier do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp pkce_challenge(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  defp token_response(oauth_token) do
    %TokenResponse{
      access_token: oauth_token.value,
      expires_in: 3_600,
      refresh_token: oauth_token.refresh_token,
      token: oauth_token
    }
  end

  defp with_token_generator(generator, fun) do
    oauth_config = Application.fetch_env!(:boruta, Boruta.Oauth)

    Application.put_env(
      :boruta,
      Boruta.Oauth,
      Keyword.put(oauth_config, :token_generator, generator)
    )

    try do
      fun.()
    after
      Application.put_env(:boruta, Boruta.Oauth, oauth_config)
    end
  end
end
