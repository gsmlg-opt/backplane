defmodule Backplane.Accounts.BorutaFoundationTest do
  use Backplane.DataCase, async: false

  alias Boruta.Ecto.Admin
  alias Boruta.Ecto.Client
  alias Boruta.Ecto.Scope
  alias Boruta.Ecto.Token

  test "boruta ecto adapter is configured on Backplane.Repo" do
    oauth_config = Application.fetch_env!(:boruta, Boruta.Oauth)

    assert Keyword.fetch!(oauth_config, :repo) == Backplane.Repo
    assert Boruta.Config.repo() == Backplane.Repo
    assert Boruta.Config.issuer() == Application.fetch_env!(:backplane, :api_url)
    assert Boruta.Config.resource_owners() == Backplane.Auth.ResourceOwners
    assert Code.ensure_loaded?(Client)
    assert Code.ensure_loaded?(Scope)
    assert Code.ensure_loaded?(Token)
  end

  test "boruta tables use oauth prefixes and leave machine clients intact" do
    assert table_exists?("clients")
    assert column_exists?("clients", "token_hash")

    assert table_exists?("oauth_clients")
    assert table_exists?("oauth_scopes")
    assert table_exists?("oauth_clients_scopes")
    assert table_exists?("oauth_tokens")

    refute table_exists?("tokens")
    refute table_exists?("scopes")
    refute table_exists?("clients_scopes")
  end

  test "persists a pkce public client and scope through boruta admin contexts" do
    assert {:ok, scope} =
             Admin.create_scope(%{name: "mcp:tools", label: "MCP tools", public: true})

    assert {:ok, client} =
             Admin.create_client(%{
               name: "Codex OAuth Smoke Client",
               redirect_uris: ["http://localhost:1455/callback"],
               pkce: true,
               confidential: false,
               authorize_scope: true,
               access_token_ttl: 1_800,
               authorization_code_ttl: 60,
               refresh_token_ttl: 2_592_000,
               supported_grant_types: ["authorization_code", "refresh_token"],
               token_endpoint_auth_methods: ["client_secret_post"],
               authorized_scopes: [%{id: scope.id}]
             })

    assert client.pkce
    refute client.confidential
    assert is_binary(client.secret)
    assert client.redirect_uris == ["http://localhost:1455/callback"]
    assert [stored_scope] = Admin.get_scopes_by_names(["mcp:tools"])
    assert stored_scope.id == scope.id

    client = Repo.preload(client, :authorized_scopes)
    assert [%Scope{id: scope_id}] = client.authorized_scopes
    assert scope_id == scope.id
  end

  defp table_exists?(table) do
    %{rows: [[exists?]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.tables
          WHERE table_schema = 'public' AND table_name = $1
        )
        """,
        [table]
      )

    exists?
  end

  defp column_exists?(table, column) do
    %{rows: [[exists?]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        )
        """,
        [table, column]
      )

    exists?
  end
end
