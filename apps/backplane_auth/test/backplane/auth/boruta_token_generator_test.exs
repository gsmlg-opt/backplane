defmodule Backplane.Auth.BorutaTokenGeneratorTest do
  use Backplane.Auth.DataCase, async: false

  alias Boruta.Ecto.Admin
  alias Boruta.Ecto.Scope

  test "persists a pkce public client and scope through the configured token generator" do
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
end
