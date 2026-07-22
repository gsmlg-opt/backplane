defmodule Backplane.Auth.TokenResourcesTest do
  use Backplane.Auth.DataCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth.Schemas.OAuthTokenResource
  alias Backplane.Auth.TokenResources
  alias Backplane.Repo
  alias Boruta.Ecto.Token

  setup do
    clear_boruta_cache()
    on_exit(&clear_boruta_cache/0)
    :ok
  end

  test "changeset requires a token and a supported resource with named constraints" do
    changeset =
      OAuthTokenResource
      |> struct()
      |> OAuthTokenResource.changeset(%{})

    assert %{oauth_token_id: ["can't be blank"], resource: ["can't be blank"]} =
             errors_on(changeset)

    token_id = Ecto.UUID.generate()

    changeset =
      OAuthTokenResource
      |> struct()
      |> OAuthTokenResource.changeset(%{oauth_token_id: token_id, resource: "admin"})

    assert %{resource: ["is invalid"]} = errors_on(changeset)

    constraint_names = Enum.map(changeset.constraints, &{&1.type, &1.constraint})

    assert {:unique, "oauth_token_resources_oauth_token_id_index"} in constraint_names
    assert {:check, "oauth_token_resources_resource_check"} in constraint_names
  end

  test "database permits exactly one supported resource mapping per OAuth token" do
    client = oauth_client_fixture!()
    token = insert_token!(client_id: client.id, type: "code", value: unique("one-binding"))

    assert {:ok, _binding} =
             insert_binding(token.id, "mcp")

    assert {:error, duplicate_changeset} =
             insert_binding(token.id, "v1")

    assert %{oauth_token_id: ["has already been taken"]} = errors_on(duplicate_changeset)

    invalid_changeset =
      OAuthTokenResource
      |> struct()
      |> Ecto.Changeset.change(oauth_token_id: token.id, resource: "system")

    assert_raise Ecto.ConstraintError, ~r/oauth_token_resources_resource_check/, fn ->
      Repo.insert(invalid_changeset)
    end
  end

  test "deleting an OAuth token cascades to its resource mapping" do
    client = oauth_client_fixture!()
    token = insert_token!(client_id: client.id, type: "code", value: unique("cascade"))
    assert {:ok, binding} = insert_binding(token.id, "mcp")

    Repo.delete!(token)

    refute Repo.get(OAuthTokenResource, binding.id)
  end

  test "bind_issued uses the exact type, client, and value for codes and access tokens" do
    client = oauth_client_fixture!()
    other_client = oauth_client_fixture!()
    shared_value = unique("shared-issued")

    code = insert_token!(client_id: client.id, type: "code", value: shared_value)

    access =
      insert_token!(
        client_id: other_client.id,
        type: "access_token",
        value: shared_value,
        refresh_token: unique("shared-refresh")
      )

    assert {:error, :not_found} =
             TokenResources.bind_issued("access_token", client.id, shared_value, :mcp)

    assert {:error, :not_found} =
             TokenResources.bind_issued("code", other_client.id, shared_value, :mcp)

    assert {:ok, code_binding} =
             TokenResources.bind_issued("code", client.id, shared_value, :mcp)

    assert code_binding.oauth_token_id == code.id
    assert code_binding.resource == "mcp"

    assert {:ok, access_binding} =
             TokenResources.bind_issued("access_token", other_client.id, shared_value, :v1)

    assert access_binding.oauth_token_id == access.id
    assert access_binding.resource == "v1"
  end

  test "bind_issued returns not_found for an unknown token without creating a mapping" do
    client = oauth_client_fixture!()

    assert {:error, :not_found} =
             TokenResources.bind_issued("code", client.id, unique("missing"), :mcp)

    assert Repo.aggregate(OAuthTokenResource, :count) == 0
  end

  test "lookup_code distinguishes unknown, identity-only, and mapped codes by client" do
    client = oauth_client_fixture!()
    other_client = oauth_client_fixture!()
    shared_value = unique("lookup-code")

    mapped = insert_token!(client_id: client.id, type: "code", value: shared_value)
    identity_only = insert_token!(client_id: other_client.id, type: "code", value: shared_value)
    assert {:ok, _binding} = insert_binding(mapped.id, "mcp")

    assert :not_found = TokenResources.lookup_code(client.id, unique("unknown-code"))
    assert {:ok, found_mapped, :mcp} = TokenResources.lookup_code(client.id, shared_value)
    assert {:ok, found_identity, nil} = TokenResources.lookup_code(other_client.id, shared_value)
    assert found_mapped.id == mapped.id
    assert found_identity.id == identity_only.id
  end

  test "lookup_access_token distinguishes unknown, identity-only, and mapped tokens by client" do
    client = oauth_client_fixture!()
    other_client = oauth_client_fixture!()
    shared_value = unique("lookup-access")

    mapped =
      insert_token!(client_id: client.id, type: "access_token", value: shared_value)

    identity_only =
      insert_token!(client_id: other_client.id, type: "access_token", value: shared_value)

    assert {:ok, _binding} = insert_binding(mapped.id, "v1")

    assert :not_found =
             TokenResources.lookup_access_token(client.id, unique("unknown-access"))

    assert {:ok, found_mapped, :v1} =
             TokenResources.lookup_access_token(client.id, shared_value)

    assert {:ok, found_identity, nil} =
             TokenResources.lookup_access_token(other_client.id, shared_value)

    assert found_mapped.id == mapped.id
    assert found_identity.id == identity_only.id
  end

  test "lookup_refresh distinguishes unknown, identity-only, and mapped tokens by client" do
    client = oauth_client_fixture!()
    other_client = oauth_client_fixture!()
    shared_refresh = unique("lookup-refresh")

    mapped =
      insert_token!(
        client_id: client.id,
        type: "access_token",
        value: unique("mapped-access"),
        refresh_token: shared_refresh
      )

    identity_only =
      insert_token!(
        client_id: other_client.id,
        type: "access_token",
        value: unique("identity-access"),
        refresh_token: shared_refresh
      )

    assert {:ok, _binding} = insert_binding(mapped.id, "mcp")

    assert :not_found = TokenResources.lookup_refresh(client.id, unique("unknown-refresh"))
    assert {:ok, found_mapped, :mcp} = TokenResources.lookup_refresh(client.id, shared_refresh)

    assert {:ok, found_identity, nil} =
             TokenResources.lookup_refresh(other_client.id, shared_refresh)

    assert found_mapped.id == mapped.id
    assert found_identity.id == identity_only.id
  end

  test "resource_for_token distinguishes unbound and mapped rows" do
    client = oauth_client_fixture!()
    unbound = insert_token!(client_id: client.id, type: "code", value: unique("unbound"))
    mapped = insert_token!(client_id: client.id, type: "code", value: unique("mapped"))
    assert {:ok, _binding} = insert_binding(mapped.id, "v1")

    assert :unbound = TokenResources.resource_for_token(unbound)
    assert {:ok, :v1} = TokenResources.resource_for_token(mapped)
  end

  test "resource_for_lineage resolves code predecessors without crossing clients" do
    client = oauth_client_fixture!()
    other_client = oauth_client_fixture!()
    shared_code = unique("previous-code")

    code = insert_token!(client_id: client.id, type: "code", value: shared_code)
    other_code = insert_token!(client_id: other_client.id, type: "code", value: shared_code)
    assert {:ok, _binding} = insert_binding(code.id, "mcp")

    access =
      insert_token!(
        client_id: client.id,
        type: "access_token",
        value: unique("code-child"),
        previous_code: shared_code
      )

    other_access =
      insert_token!(
        client_id: other_client.id,
        type: "access_token",
        value: unique("other-code-child"),
        previous_code: shared_code
      )

    missing =
      insert_token!(
        client_id: client.id,
        type: "access_token",
        value: unique("missing-code-child"),
        previous_code: unique("missing-code")
      )

    assert {:ok, :mcp} = TokenResources.resource_for_lineage(access)
    assert :unbound = TokenResources.resource_for_lineage(other_access)
    assert {:error, :lineage_not_found} = TokenResources.resource_for_lineage(missing)
    assert other_code.client_id == other_client.id
  end

  test "resource_for_lineage resolves access-token predecessors without crossing clients" do
    client = oauth_client_fixture!()
    other_client = oauth_client_fixture!()
    shared_token = unique("previous-token")

    previous =
      insert_token!(client_id: client.id, type: "access_token", value: shared_token)

    other_previous =
      insert_token!(client_id: other_client.id, type: "access_token", value: shared_token)

    assert {:ok, _binding} = insert_binding(previous.id, "v1")

    refreshed =
      insert_token!(
        client_id: client.id,
        type: "access_token",
        value: unique("refresh-child"),
        previous_token: shared_token
      )

    other_refreshed =
      insert_token!(
        client_id: other_client.id,
        type: "access_token",
        value: unique("other-refresh-child"),
        previous_token: shared_token
      )

    missing =
      insert_token!(
        client_id: client.id,
        type: "access_token",
        value: unique("missing-refresh-child"),
        previous_token: unique("missing-token")
      )

    assert {:ok, :v1} = TokenResources.resource_for_lineage(refreshed)
    assert :unbound = TokenResources.resource_for_lineage(other_refreshed)
    assert {:error, :lineage_not_found} = TokenResources.resource_for_lineage(missing)
    assert other_previous.client_id == other_client.id
  end

  test "refresh lineage takes precedence when both predecessor fields are present" do
    client = oauth_client_fixture!()
    code = insert_token!(client_id: client.id, type: "code", value: unique("precedence-code"))

    previous =
      insert_token!(
        client_id: client.id,
        type: "access_token",
        value: unique("precedence-token")
      )

    assert {:ok, _binding} = insert_binding(code.id, "mcp")
    assert {:ok, _binding} = insert_binding(previous.id, "v1")

    child =
      insert_token!(
        client_id: client.id,
        type: "access_token",
        value: unique("precedence-child"),
        previous_code: code.value,
        previous_token: previous.value
      )

    missing_immediate_predecessor =
      insert_token!(
        client_id: client.id,
        type: "access_token",
        value: unique("precedence-missing-child"),
        previous_code: code.value,
        previous_token: unique("precedence-missing")
      )

    assert {:ok, :v1} = TokenResources.resource_for_lineage(child)

    assert {:error, :lineage_not_found} =
             TokenResources.resource_for_lineage(missing_immediate_predecessor)
  end

  test "a token without a predecessor has unbound lineage" do
    client = oauth_client_fixture!()

    token =
      insert_token!(client_id: client.id, type: "access_token", value: unique("no-lineage"))

    assert :unbound = TokenResources.resource_for_lineage(token)
  end

  test "binding failure revokes the issued token and invalidates both Boruta cache keys" do
    user = auth_user_fixture!()
    client = oauth_client_fixture!()

    token =
      insert_token!(
        client_id: client.id,
        sub: user.id,
        type: "access_token",
        value: unique("compensated-access"),
        refresh_token: unique("compensated-refresh"),
        expires_at: System.system_time(:second) + 3_600
      )

    assert %Boruta.Oauth.Token{} = Boruta.Ecto.AccessTokens.get_by(value: token.value)
    assert {:ok, _cached} = Boruta.Ecto.TokenStore.get(value: token.value)
    assert {:ok, _cached} = Boruta.Ecto.TokenStore.get(refresh_token: token.refresh_token)

    assert {:ok, _binding} =
             TokenResources.bind_issued("access_token", client.id, token.value, :mcp)

    assert {:error, :binding_failed} =
             TokenResources.bind_issued("access_token", client.id, token.value, :v1)

    revoked = Repo.reload!(token)
    assert %DateTime{} = revoked.revoked_at
    assert %DateTime{} = revoked.refresh_token_revoked_at
    assert {:error, "Not cached."} = Boruta.Ecto.TokenStore.get(value: token.value)

    assert {:error, "Not cached."} =
             Boruta.Ecto.TokenStore.get(refresh_token: token.refresh_token)
  end

  test "LineageError has a fixed non-sensitive message" do
    secret_code = unique("secret-code")
    secret_token = unique("secret-token")
    error = TokenResources.LineageError.exception([])

    assert Exception.message(error) == "OAuth token resource lineage could not be resolved"
    refute Exception.message(error) =~ secret_code
    refute Exception.message(error) =~ secret_token
  end

  defp insert_binding(token_id, resource) do
    OAuthTokenResource
    |> struct()
    |> OAuthTokenResource.changeset(%{oauth_token_id: token_id, resource: resource})
    |> Repo.insert()
  end

  defp insert_token!(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:expires_at, System.system_time(:second) + 300)
      |> Map.put_new(:scope, "")

    %Token{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  defp clear_boruta_cache do
    _ = Boruta.Cache.delete_all()
    :ok
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
