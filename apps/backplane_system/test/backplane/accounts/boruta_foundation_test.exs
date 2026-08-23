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

  test "oauth clients include boruta trust controls" do
    assert column_exists?("oauth_clients", "trusted_authorities")
    assert column_exists?("oauth_clients", "trusted_hosts")
  end

  test "oauth token resource bindings have the expected columns" do
    assert table_exists?("oauth_token_resources")

    assert column_definition("oauth_token_resources", "id") ==
             {"uuid", "NO", "gen_random_uuid()"}

    assert column_definition("oauth_token_resources", "oauth_token_id") ==
             {"uuid", "NO", nil}

    assert column_definition("oauth_token_resources", "resource") ==
             {"text", "NO", nil}

    assert column_definition("oauth_token_resources", "inserted_at") ==
             {"timestamp without time zone", "NO", nil}

    assert column_definition("oauth_token_resources", "updated_at") ==
             {"timestamp without time zone", "NO", nil}
  end

  test "oauth token resource bindings enforce their database relationships" do
    assert cascading_foreign_key?(
             "oauth_token_resources",
             "oauth_token_id",
             "oauth_tokens",
             "id"
           )

    assert unique_index?("oauth_token_resources", "oauth_token_id")

    assert check_constraint?(
             "oauth_token_resources",
             "oauth_token_resources_resource_check"
           )
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

  defp column_definition(table, column) do
    case Repo.query!(
           """
           SELECT data_type, is_nullable, column_default
           FROM information_schema.columns
           WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
           """,
           [table, column]
         ).rows do
      [[data_type, is_nullable, column_default]] ->
        {data_type, is_nullable, column_default}

      [] ->
        nil
    end
  end

  defp cascading_foreign_key?(table, column, referenced_table, referenced_column) do
    %{rows: [[exists?]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.table_constraints AS constraints
          JOIN information_schema.key_column_usage AS columns
            ON columns.constraint_schema = constraints.constraint_schema
           AND columns.constraint_name = constraints.constraint_name
          JOIN information_schema.constraint_column_usage AS referenced_columns
            ON referenced_columns.constraint_schema = constraints.constraint_schema
           AND referenced_columns.constraint_name = constraints.constraint_name
          JOIN information_schema.referential_constraints AS relationships
            ON relationships.constraint_schema = constraints.constraint_schema
           AND relationships.constraint_name = constraints.constraint_name
          WHERE constraints.table_schema = 'public'
            AND constraints.table_name = $1
            AND constraints.constraint_type = 'FOREIGN KEY'
            AND columns.column_name = $2
            AND referenced_columns.table_name = $3
            AND referenced_columns.column_name = $4
            AND relationships.delete_rule = 'CASCADE'
        )
        """,
        [table, column, referenced_table, referenced_column]
      )

    exists?
  end

  defp unique_index?(table, column) do
    %{rows: [[exists?]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_indexes
          WHERE schemaname = 'public'
            AND tablename = $1
            AND indexdef LIKE 'CREATE UNIQUE INDEX % (' || $2 || ')'
        )
        """,
        [table, column]
      )

    exists?
  end

  defp check_constraint?(table, constraint) do
    %{rows: [[exists?]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_constraint
          JOIN pg_class ON pg_class.oid = pg_constraint.conrelid
          JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
          WHERE pg_namespace.nspname = 'public'
            AND pg_class.relname = $1
            AND pg_constraint.conname = $2
            AND pg_constraint.contype = 'c'
        )
        """,
        [table, constraint]
      )

    exists?
  end
end
