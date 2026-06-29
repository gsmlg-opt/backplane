defmodule Backplane.Accounts.FederatedLoginTest do
  use Backplane.DataCase, async: false

  alias Backplane.Accounts
  alias Backplane.Accounts.FederatedLogin
  alias Backplane.Accounts.{User, UserIdentity}
  alias Backplane.Settings.OAuthStateStore

  setup do
    previous_req_options = Application.get_env(:backplane, :federated_login_req_options)

    Application.put_env(:backplane, :federated_login_req_options, plug: {Req.Test, __MODULE__})

    OAuthStateStore.clear()

    on_exit(fn ->
      OAuthStateStore.clear()

      if is_nil(previous_req_options) do
        Application.delete_env(:backplane, :federated_login_req_options)
      else
        Application.put_env(:backplane, :federated_login_req_options, previous_req_options)
      end
    end)

    :ok
  end

  describe "start/3" do
    test "builds an OIDC authorization URL with S256 PKCE and stored nonce state" do
      {:ok, provider} = auth_provider("google")
      provider_id = provider.id

      assert {:ok, %{authorization_url: authorization_url, state: state}} =
               FederatedLogin.start("google", %{"return_to" => "/mcp"})

      uri = URI.parse(authorization_url)
      query = URI.decode_query(uri.query)

      assert uri.scheme == "https"
      assert uri.host == "accounts.example.com"
      assert uri.path == "/authorize"
      assert query["response_type"] == "code"
      assert query["client_id"] == "google-client"
      assert query["redirect_uri"] == "http://localhost:4002/auth/google/callback"
      assert query["scope"] == "openid email profile"
      assert query["state"] == state
      assert query["code_challenge_method"] == "S256"
      assert is_binary(query["code_challenge"])
      assert byte_size(query["code_challenge"]) >= 32
      assert is_binary(query["nonce"])
      assert byte_size(query["nonce"]) >= 16

      assert {:ok,
              %{
                "purpose" => "accounts_federated_login",
                "provider_id" => ^provider_id,
                "provider_slug" => "google",
                "code_verifier" => code_verifier,
                "nonce" => nonce,
                "redirect_uri" => "http://localhost:4002/auth/google/callback",
                "resume_params" => %{"return_to" => "/mcp"}
              }} = OAuthStateStore.pop(state)

      assert is_binary(code_verifier)
      assert byte_size(code_verifier) >= 32
      assert nonce == query["nonce"]
    end

    test "rejects missing providers" do
      assert {:error, :provider_not_found} = FederatedLogin.start("missing")
    end

    test "rejects disabled providers" do
      {:ok, _provider} = auth_provider("disabled", enabled: false)

      assert {:error, :provider_disabled} = FederatedLogin.start("disabled")
    end

    test "rejects external return_to resume params" do
      {:ok, _provider} = auth_provider("google")

      assert {:error, :invalid_return_to} =
               FederatedLogin.start("google", %{"return_to" => "https://evil.example/mcp"})
    end
  end

  describe "complete/3 with OIDC providers" do
    setup do
      jwk = JOSE.JWK.generate_key({:rsa, 2048})

      {:ok, jwk: jwk, public_jwk: public_jwk(jwk)}
    end

    test "exchanges the code, verifies the ID token, provisions a user, and returns resume params",
         %{jwk: jwk, public_jwk: public_jwk} do
      {:ok, provider} = auth_provider("google", allowed_email_domains: ["example.com"])

      {:ok, %{authorization_url: authorization_url, state: state}} =
        FederatedLogin.start("google", %{"return_to" => "/mcp"})

      id_token =
        signed_id_token(
          jwk,
          valid_oidc_claims(provider, nonce_from(authorization_url))
        )

      stub_oidc_provider(id_token, public_jwk)

      assert {:ok,
              %{
                user: %User{} = user,
                identity: %UserIdentity{} = identity,
                resume_params: %{"return_to" => "/mcp"}
              }} =
               FederatedLogin.complete("google", %{
                 "code" => "auth-code",
                 "state" => state
               })

      assert user.email == "alice@example.com"
      assert user.name == "Alice Example"
      assert identity.provider_id == provider.id
      assert identity.subject == "google-sub-1"
      assert identity.raw_claims["email"] == "alice@example.com"

      assert {:error, :invalid_state} =
               FederatedLogin.complete("google", %{"code" => "auth-code", "state" => state})
    end

    test "rejects invalid state before exchanging the code" do
      {:ok, _provider} = auth_provider("google")

      assert {:error, :invalid_state} =
               FederatedLogin.complete("google", %{
                 "code" => "auth-code",
                 "state" => "missing-state"
               })
    end

    test "rejects state created for another provider" do
      {:ok, _google} = auth_provider("google")
      {:ok, _github} = auth_provider("github")

      {:ok, %{state: google_state}} = FederatedLogin.start("google")

      assert {:error, :provider_mismatch} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => google_state
               })
    end

    test "rejects an ID token with an invalid signature", %{
      jwk: jwk,
      public_jwk: public_jwk
    } do
      wrong_jwk = JOSE.JWK.generate_key({:rsa, 2048})

      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, {:invalid_id_token, :signature}},
        signer: wrong_jwk
      )
    end

    test "rejects an ID token whose kid is not in the provider JWKS", %{
      jwk: jwk,
      public_jwk: public_jwk
    } do
      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, {:invalid_id_token, :signature}},
        kid: "unknown-key"
      )
    end

    test "rejects an ID token with the wrong issuer", %{jwk: jwk, public_jwk: public_jwk} do
      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, {:invalid_id_token, :issuer}},
        claims: %{"iss" => "https://issuer.invalid"}
      )
    end

    test "rejects an ID token with the wrong audience", %{jwk: jwk, public_jwk: public_jwk} do
      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, {:invalid_id_token, :audience}},
        claims: %{"aud" => "other-client"}
      )
    end

    test "rejects a multi-audience ID token with the wrong authorized party", %{
      jwk: jwk,
      public_jwk: public_jwk
    } do
      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, {:invalid_id_token, :audience}},
        claims: %{"aud" => ["google-client", "other-client"], "azp" => "other-client"}
      )
    end

    test "rejects an ID token when the provider issuer is missing", %{
      jwk: jwk,
      public_jwk: public_jwk
    } do
      {:ok, provider} = auth_provider("google", issuer: nil)

      {:ok, %{authorization_url: authorization_url, state: state}} =
        FederatedLogin.start("google")

      id_token =
        signed_id_token(
          jwk,
          valid_oidc_claims(provider, nonce_from(authorization_url))
        )

      stub_oidc_provider(id_token, public_jwk)

      assert {:error, {:invalid_id_token, :issuer}} =
               FederatedLogin.complete("google", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end

    test "rejects an expired ID token", %{jwk: jwk, public_jwk: public_jwk} do
      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, {:invalid_id_token, :expired}},
        claims: %{"exp" => System.system_time(:second) - 10}
      )
    end

    test "rejects an ID token with the wrong nonce", %{jwk: jwk, public_jwk: public_jwk} do
      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, {:invalid_id_token, :nonce}},
        claims: %{"nonce" => "wrong-nonce"}
      )
    end

    test "rejects an ID token without a subject", %{jwk: jwk, public_jwk: public_jwk} do
      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, {:invalid_id_token, :missing_sub}},
        claims: &Map.delete(&1, "sub")
      )
    end

    test "rejects claims outside the provider email-domain allowlist", %{
      jwk: jwk,
      public_jwk: public_jwk
    } do
      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, :email_domain_not_allowed},
        claims: %{"email" => "alice@outside.test"}
      )
    end

    test "rejects unverified OIDC email claims", %{
      jwk: jwk,
      public_jwk: public_jwk
    } do
      assert_oidc_rejected(
        jwk,
        public_jwk,
        {:error, :email_not_verified},
        claims: %{"email_verified" => false}
      )
    end
  end

  describe "complete/3 with OAuth2 userinfo providers" do
    test "fetches userinfo with the access token and provisions a user" do
      {:ok, provider} =
        auth_provider("github",
          kind: "oauth2",
          authorization_url: "https://github.example.com/login/oauth/authorize",
          token_url: "https://github.example.com/login/oauth/access_token",
          userinfo_url: "https://api.github.example.com/user",
          scopes: ["read:user", "user:email"],
          allowed_email_domains: ["example.com"]
        )

      {:ok, %{state: state}} = FederatedLogin.start("github", %{"return_to" => "/settings"})

      stub_oauth2_provider(%{
        "id" => 12_345,
        "email" => "octo@example.com",
        "name" => "Octo Cat",
        "email_verified" => true
      })

      assert {:ok,
              %{
                user: %User{} = user,
                identity: %UserIdentity{} = identity,
                resume_params: %{"return_to" => "/settings"}
              }} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })

      assert user.email == "octo@example.com"
      assert user.name == "Octo Cat"
      assert identity.provider_id == provider.id
      assert identity.subject == "12345"
      assert identity.raw_claims["sub"] == "12345"
      assert identity.raw_claims["id"] == 12_345
    end

    test "rejects userinfo without sub or id" do
      {:ok, _provider} = oauth2_provider()
      {:ok, %{state: state}} = FederatedLogin.start("github")

      stub_oauth2_provider(%{
        "email" => "octo@example.com",
        "name" => "Octo Cat",
        "email_verified" => true
      })

      assert {:error, {:missing_claim, "sub"}} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end

    test "rejects token exchange failures" do
      {:ok, _provider} = oauth2_provider()
      {:ok, %{state: state}} = FederatedLogin.start("github")

      stub_oauth2_provider(%{}, token_status: 500)

      assert {:error, {:token_exchange_failed, 500}} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end

    test "rejects token responses without an access token" do
      {:ok, _provider} = oauth2_provider()
      {:ok, %{state: state}} = FederatedLogin.start("github")

      stub_oauth2_provider(%{}, token_body: %{"token_type" => "Bearer"})

      assert {:error, :missing_access_token} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end

    test "rejects OAuth2 providers without a userinfo URL" do
      {:ok, _provider} =
        auth_provider("github",
          kind: "oauth2",
          authorization_url: "https://github.example.com/login/oauth/authorize",
          token_url: "https://github.example.com/login/oauth/access_token",
          userinfo_url: nil,
          scopes: ["read:user", "user:email"]
        )

      {:ok, %{state: state}} = FederatedLogin.start("github")
      stub_oauth2_provider(%{})

      assert {:error, :missing_userinfo_url} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end

    test "rejects OAuth2 providers without a token URL" do
      {:ok, _provider} =
        auth_provider("github",
          kind: "oauth2",
          authorization_url: "https://github.example.com/login/oauth/authorize",
          token_url: nil,
          userinfo_url: "https://api.github.example.com/user",
          scopes: ["read:user", "user:email"]
        )

      {:ok, %{state: state}} = FederatedLogin.start("github")

      assert {:error, :missing_token_url} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end

    test "rejects userinfo transport failures" do
      {:ok, _provider} = oauth2_provider()
      {:ok, %{state: state}} = FederatedLogin.start("github")

      stub_oauth2_provider(%{}, userinfo_status: 500)

      assert {:error, {:userinfo_failed, 500}} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end

    test "rejects userinfo claims outside the provider email-domain allowlist" do
      {:ok, _provider} = oauth2_provider()
      {:ok, %{state: state}} = FederatedLogin.start("github")

      stub_oauth2_provider(%{
        "id" => 12_345,
        "email" => "octo@outside.test",
        "name" => "Octo Cat",
        "email_verified" => true
      })

      assert {:error, :email_domain_not_allowed} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end

    test "rejects unverified userinfo email claims" do
      {:ok, _provider} = oauth2_provider()
      {:ok, %{state: state}} = FederatedLogin.start("github")

      stub_oauth2_provider(%{
        "id" => 12_345,
        "email" => "octo@example.com",
        "name" => "Octo Cat",
        "email_verified" => false
      })

      assert {:error, :email_not_verified} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end

    test "wraps malformed successful token responses with operation context" do
      {:ok, _provider} = oauth2_provider()
      {:ok, %{state: state}} = FederatedLogin.start("github")

      stub_oauth2_provider(%{}, token_body: "not-json")

      assert {:error, {:token_exchange_failed, :invalid_response}} =
               FederatedLogin.complete("github", %{
                 "code" => "auth-code",
                 "state" => state
               })
    end
  end

  defp auth_provider(slug, attrs \\ []) do
    attrs =
      Map.merge(
        %{
          slug: slug,
          name: String.capitalize(slug),
          kind: "oidc",
          issuer: "https://accounts.example.com",
          authorization_url: "https://accounts.example.com/authorize",
          token_url: "https://accounts.example.com/token",
          jwks_uri: "https://accounts.example.com/jwks",
          client_id: "#{slug}-client",
          client_secret: "#{slug}-secret",
          scopes: ["openid", "email", "profile"]
        },
        Map.new(attrs)
      )

    Accounts.create_auth_provider(attrs)
  end

  defp oauth2_provider do
    auth_provider("github",
      kind: "oauth2",
      authorization_url: "https://github.example.com/login/oauth/authorize",
      token_url: "https://github.example.com/login/oauth/access_token",
      userinfo_url: "https://api.github.example.com/user",
      scopes: ["read:user", "user:email"],
      allowed_email_domains: ["example.com"]
    )
  end

  defp assert_oidc_rejected(jwk, public_jwk, expected_error, opts) do
    {:ok, provider} = auth_provider("google", allowed_email_domains: ["example.com"])

    {:ok, %{authorization_url: authorization_url, state: state}} =
      FederatedLogin.start("google")

    claims =
      provider
      |> valid_oidc_claims(nonce_from(authorization_url))
      |> apply_claim_override(Keyword.get(opts, :claims, %{}))

    signer = Keyword.get(opts, :signer, jwk)
    kid = Keyword.get(opts, :kid, "test-key")
    stub_oidc_provider(signed_id_token(signer, claims, kid), public_jwk)

    assert ^expected_error =
             FederatedLogin.complete("google", %{
               "code" => "auth-code",
               "state" => state
             })
  end

  defp apply_claim_override(claims, fun) when is_function(fun, 1), do: fun.(claims)
  defp apply_claim_override(claims, overrides), do: Map.merge(claims, overrides)

  defp stub_oidc_provider(id_token, public_jwk) do
    Req.Test.stub(__MODULE__, fn
      %Plug.Conn{method: "POST", request_path: "/token"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)

        assert %{
                 "grant_type" => "authorization_code",
                 "code" => "auth-code",
                 "redirect_uri" => "http://localhost:4002/auth/google/callback",
                 "client_id" => "google-client",
                 "client_secret" => "google-secret",
                 "code_verifier" => code_verifier
               } = form

        assert is_binary(code_verifier)
        assert byte_size(code_verifier) >= 32

        Req.Test.json(conn, %{
          "access_token" => "google-access",
          "id_token" => id_token,
          "token_type" => "Bearer"
        })

      %Plug.Conn{method: "GET", request_path: "/jwks"} = conn ->
        Req.Test.json(conn, %{"keys" => [public_jwk]})
    end)
  end

  defp stub_oauth2_provider(userinfo, opts \\ []) do
    token_status = Keyword.get(opts, :token_status, 200)
    userinfo_status = Keyword.get(opts, :userinfo_status, 200)

    token_body =
      Keyword.get(opts, :token_body, %{
        "access_token" => "github-access",
        "token_type" => "Bearer"
      })

    Req.Test.stub(__MODULE__, fn
      %Plug.Conn{method: "POST", request_path: "/login/oauth/access_token"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)

        assert %{
                 "grant_type" => "authorization_code",
                 "code" => "auth-code",
                 "redirect_uri" => "http://localhost:4002/auth/github/callback",
                 "client_id" => "github-client",
                 "client_secret" => "github-secret",
                 "code_verifier" => code_verifier
               } = form

        assert is_binary(code_verifier)
        assert byte_size(code_verifier) >= 32

        if token_status in 200..299 do
          Req.Test.json(conn, token_body)
        else
          Plug.Conn.resp(conn, token_status, "token error")
        end

      %Plug.Conn{method: "GET", request_path: "/user"} = conn ->
        assert ["Bearer github-access"] = Plug.Conn.get_req_header(conn, "authorization")

        if userinfo_status in 200..299 do
          Req.Test.json(conn, userinfo)
        else
          Plug.Conn.resp(conn, userinfo_status, "userinfo error")
        end
    end)
  end

  defp valid_oidc_claims(provider, nonce) do
    now = System.system_time(:second)

    %{
      "iss" => provider.issuer,
      "aud" => provider.client_id,
      "exp" => now + 300,
      "iat" => now,
      "nonce" => nonce,
      "sub" => "google-sub-1",
      "email" => "alice@example.com",
      "email_verified" => true,
      "name" => "Alice Example"
    }
  end

  defp signed_id_token(jwk, claims, kid \\ "test-key") do
    signer = JOSE.JWS.from_map(%{"alg" => "RS256", "kid" => kid})

    jwk
    |> JOSE.JWT.sign(signer, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp public_jwk(jwk) do
    {_modules, jwk_map} =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()

    Map.merge(jwk_map, %{"alg" => "RS256", "kid" => "test-key", "use" => "sig"})
  end

  defp nonce_from(authorization_url) do
    authorization_url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("nonce")
  end
end
