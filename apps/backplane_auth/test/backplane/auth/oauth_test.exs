defmodule Backplane.Auth.OAuthTest do
  use Backplane.Auth.DataCase, async: false

  alias Backplane.Auth
  alias Backplane.Repo
  alias Boruta.Ecto.{Admin, Client, Scope}
  alias Boruta.Ecto.ClientStore
  alias Boruta.Ecto.Clients, as: BorutaClients

  setup do
    old_url = Application.get_env(:backplane, :api_url)
    old_env = Application.get_env(:backplane, :env)
    old_override = Application.get_env(:backplane_auth, :allow_insecure_resource_origins)

    Application.put_env(:backplane, :api_url, "https://backplane.example.test")
    Application.put_env(:backplane, :env, :test)
    Application.put_env(:backplane_auth, :allow_insecure_resource_origins, false)

    on_exit(fn ->
      restore_env(:backplane, :api_url, old_url)
      restore_env(:backplane, :env, old_env)
      restore_env(:backplane_auth, :allow_insecure_resource_origins, old_override)
    end)
  end

  describe "scopes" do
    test "creates and lists OAuth scopes" do
      assert {:ok, %Scope{} = scope} =
               Auth.OAuth.create_scope(%{
                 name: "gsmlg:read",
                 label: "Read GSMLG data",
                 public: true
               })

      assert scope.name == "gsmlg:read"
      assert scope.label == "Read GSMLG data"
      assert scope.public

      assert %Scope{id: scope_id} = Auth.OAuth.get_scope("gsmlg:read")
      assert scope_id == scope.id
      assert [%Scope{name: "gsmlg:read"}] = Auth.OAuth.list_scopes()
    end
  end

  describe "clients" do
    test "creates a confidential OAuth client with a generated secret" do
      scope!("openid")
      scope!("gsmlg:read")

      assert {:ok, %{client: %Client{} = client, secret: secret}} =
               Auth.OAuth.create_client(%{
                 name: "GSMLG App Backend",
                 redirect_uris: ["https://app.example.test/auth/callback"],
                 scopes: ["openid", "gsmlg:read"],
                 confidential: true,
                 pkce: true
               })

      assert client.name == "GSMLG App Backend"
      assert client.confidential
      assert client.pkce
      assert is_binary(secret)
      assert client.secret == secret
      assert ["gsmlg:read", "openid"] = scope_names(client.authorized_scopes)
    end

    test "creates a public PKCE client without exposing a client secret" do
      scope!("openid")

      assert {:ok, %Client{} = client} =
               Auth.OAuth.create_client(%{
                 name: "GSMLG Umbrella",
                 redirect_uris: ["http://localhost:4555/auth/callback"],
                 scopes: ["openid"],
                 confidential: false,
                 pkce: true
               })

      refute client.confidential
      assert client.pkce
      assert ["openid"] = scope_names(client.authorized_scopes)
    end

    test "requires PKCE for public clients" do
      assert {:error, changeset} =
               Auth.OAuth.create_client(%{
                 name: "No PKCE",
                 redirect_uris: ["http://localhost:4555/auth/callback"],
                 scopes: [],
                 confidential: false,
                 pkce: false
               })

      assert %{pkce: [_message]} = errors_on(changeset)
    end

    test "validates exact redirect URI matches" do
      assert {:ok, client} =
               Auth.OAuth.create_client(%{
                 name: "Redirect App",
                 redirect_uris: ["https://app.example.test/auth/callback"],
                 scopes: [],
                 confidential: false,
                 pkce: true
               })

      assert :ok =
               Auth.OAuth.validate_redirect_uri(
                 client,
                 "https://app.example.test/auth/callback"
               )

      assert {:error, :invalid_redirect_uri} =
               Auth.OAuth.validate_redirect_uri(
                 client,
                 "https://evil.example.test/auth/callback"
               )
    end

    test "rejects wildcard redirect URIs" do
      assert {:error, changeset} =
               Auth.OAuth.create_client(%{
                 name: "Wildcard App",
                 redirect_uris: ["https://*.example.test/auth/callback"],
                 scopes: [],
                 confidential: false,
                 pkce: true
               })

      assert %{redirect_uris: [_message]} = errors_on(changeset)
    end

    test "assigns scopes to an existing client" do
      scope!("openid")
      scope!("email")

      assert {:ok, client} =
               Auth.OAuth.create_client(%{
                 name: "Scope App",
                 redirect_uris: ["https://app.example.test/auth/callback"],
                 scopes: ["openid"],
                 confidential: false,
                 pkce: true
               })

      assert {:ok, %Client{} = updated} = Auth.OAuth.assign_client_scopes(client, ["email"])
      assert ["email"] = scope_names(updated.authorized_scopes)
    end

    test "rotates confidential client secrets" do
      scope!("openid")

      assert {:ok, %{client: client, secret: first_secret}} =
               Auth.OAuth.create_client(%{
                 name: "Rotating Secret App",
                 redirect_uris: ["https://app.example.test/auth/callback"],
                 scopes: ["openid"],
                 confidential: true,
                 pkce: true
               })

      assert {:ok, %{client: rotated, secret: second_secret}} =
               Auth.OAuth.rotate_client_secret(client)

      assert is_binary(second_secret)
      refute second_secret == first_secret
      assert rotated.secret == second_secret
    end

    test "marks disabled clients as unusable" do
      assert {:ok, client} =
               Auth.OAuth.create_client(%{
                 name: "Disable App",
                 redirect_uris: ["https://app.example.test/auth/callback"],
                 scopes: [],
                 confidential: false,
                 pkce: true
               })

      refute Auth.OAuth.client_disabled?(client)

      assert {:ok, disabled} = Auth.OAuth.disable_client(client)
      assert Auth.OAuth.client_disabled?(disabled)
      assert is_nil(Auth.OAuth.get_enabled_client(disabled.id))
    end

    test "normalizes resource assignments on create while preserving metadata" do
      assert {:ok, %Client{} = client} =
               Auth.OAuth.create_client(
                 client_attrs(
                   resources: [:v1, "mcp", :mcp, "v1"],
                   metadata: %{"tenant" => "alpha", "feature_flags" => ["beta"]}
                 )
               )

      assert client.metadata["backplane_resources"] == ["mcp", "v1"]
      assert client.metadata["tenant"] == "alpha"
      assert client.metadata["feature_flags"] == ["beta"]
      assert Auth.OAuth.client_resources(client) == [:mcp, :v1]
    end

    test "rejects invalid resource assignments before creating a client" do
      count_before = Repo.aggregate(Client, :count)
      scope_name = unique_scope_name("invalid-resource")

      assert {:error, :invalid_resource} =
               Auth.OAuth.create_client(
                 client_attrs(resources: [:mcp, "invalid"], scopes: [scope_name])
               )

      assert Repo.aggregate(Client, :count) == count_before
      assert is_nil(Auth.OAuth.get_scope(scope_name))
    end

    test "rejects non-map metadata without creating a client or its scopes" do
      count_before = Repo.aggregate(Client, :count)
      scope_name = unique_scope_name("invalid-metadata")

      assert {:error, changeset} =
               Auth.OAuth.create_client(
                 client_attrs(
                   resources: [:mcp],
                   metadata: "not-a-map",
                   scopes: [scope_name]
                 )
               )

      assert %{metadata: [_message]} = errors_on(changeset)
      assert Repo.aggregate(Client, :count) == count_before
      assert is_nil(Auth.OAuth.get_scope(scope_name))
    end

    test "requires HTTPS for resource assignments unless the local override permits them" do
      Application.put_env(:backplane, :api_url, "http://localhost:4220")

      count_before = Repo.aggregate(Client, :count)
      scope_name = unique_scope_name("invalid-origin")

      assert {:error, :https_required} =
               Auth.OAuth.create_client(client_attrs(resources: [:mcp], scopes: [scope_name]))

      assert Repo.aggregate(Client, :count) == count_before
      assert is_nil(Auth.OAuth.get_scope(scope_name))

      identity_client = oauth_client!()

      assert {:error, :https_required} =
               Auth.OAuth.update_client_resources(identity_client, [:v1])

      Application.put_env(:backplane_auth, :allow_insecure_resource_origins, true)

      assigned = oauth_client!(resources: [:mcp])
      assert Auth.OAuth.client_resources(assigned) == [:mcp]

      assert {:ok, updated} = Auth.OAuth.update_client_resources(assigned, [:mcp, :v1])
      assert Auth.OAuth.client_resources(updated) == [:mcp, :v1]
    end

    test "reads normalized resource keys and safely ignores invalid legacy metadata" do
      assert Auth.OAuth.client_resources(%Client{metadata: %{backplane_resources: [:v1, "mcp"]}}) ==
               [:mcp, :v1]

      for metadata <- [
            nil,
            %{},
            %{"backplane_resources" => "mcp"},
            %{"backplane_resources" => ["mcp", "invalid"]},
            %{backplane_resources: nil}
          ] do
        assert Auth.OAuth.client_resources(%Client{metadata: metadata}) == []
      end
    end

    test "checks whether a client allows a resource" do
      client = %Client{metadata: %{"backplane_resources" => ["mcp"]}}

      assert Auth.OAuth.client_allows_resource?(client, :mcp)
      refute Auth.OAuth.client_allows_resource?(client, :v1)
    end

    test "activates a resource only when an enabled client is assigned" do
      _identity_client = oauth_client!()
      refute Auth.OAuth.enabled_client_for_resource?(:mcp)

      assigned = oauth_client!(resources: [:mcp])
      assert {:ok, disabled} = Auth.OAuth.disable_client(assigned)
      assert Auth.OAuth.client_disabled?(disabled)
      refute Auth.OAuth.enabled_client_for_resource?(:mcp)

      _enabled_assignment = oauth_client!(resources: ["mcp"])
      assert Auth.OAuth.enabled_client_for_resource?(:mcp)
      refute Auth.OAuth.enabled_client_for_resource?(:v1)
    end

    test "updates resources while preserving metadata, disabled state, scopes, and cache coherence" do
      created =
        oauth_client!(
          scopes: ["openid", "github::*"],
          resources: ["mcp"],
          metadata: %{"tenant" => "alpha", "disabled" => true}
        )

      assert prime_client_cache(created.id).metadata["backplane_resources"] == ["mcp"]

      client = Auth.OAuth.get_client(created.id)
      assert {:ok, updated} = Auth.OAuth.update_client_resources(client, [:v1, :mcp])

      assert Auth.OAuth.client_resources(updated) == [:mcp, :v1]
      assert updated.metadata["tenant"] == "alpha"
      assert Auth.OAuth.client_disabled?(updated)
      assert scope_names(updated.authorized_scopes) == ["github::*", "openid"]

      cached = BorutaClients.get_client(updated.id)
      assert cached.metadata["backplane_resources"] == ["mcp", "v1"]
      assert cached.metadata["tenant"] == "alpha"
      assert cached.metadata["disabled"]
      assert scope_names(cached.authorized_scopes) == ["github::*", "openid"]
    end

    test "disabling a client preserves resources, metadata, scopes, and cache coherence" do
      client =
        oauth_client!(
          scopes: ["openid", "github::*"],
          resources: [:mcp, :v1],
          metadata: %{"tenant" => "alpha"}
        )

      cached_before = prime_client_cache(client.id)
      refute cached_before.metadata["disabled"]

      assert {:ok, disabled} = Auth.OAuth.disable_client(client)
      assert Auth.OAuth.client_disabled?(disabled)
      assert Auth.OAuth.client_resources(disabled) == [:mcp, :v1]
      assert disabled.metadata["tenant"] == "alpha"
      assert scope_names(disabled.authorized_scopes) == ["github::*", "openid"]

      cached = BorutaClients.get_client(disabled.id)
      assert cached.metadata["disabled"]
      assert cached.metadata["backplane_resources"] == ["mcp", "v1"]
      assert cached.metadata["tenant"] == "alpha"
      assert scope_names(cached.authorized_scopes) == ["github::*", "openid"]
    end

    test "resource updates preserve state changed after the caller snapshot" do
      stale =
        oauth_client!(
          scopes: ["openid"],
          resources: [:mcp],
          metadata: %{"tenant" => "stale"}
        )
        |> then(&Auth.OAuth.get_client(&1.id))

      _cached_stale = prime_client_cache(stale.id)
      concurrent_scope = scope!("github::*")
      current = Auth.OAuth.get_client(stale.id)

      assert {:ok, _current} =
               Admin.update_client(current, %{
                 metadata: %{
                   "backplane_resources" => ["mcp"],
                   "tenant" => "current",
                   "concurrent" => "kept",
                   "disabled" => true
                 },
                 authorized_scopes: [%{id: concurrent_scope.id}]
               })

      assert {:ok, updated} = Auth.OAuth.update_client_resources(stale, [:v1])
      assert Auth.OAuth.client_resources(updated) == [:v1]
      assert updated.metadata["tenant"] == "current"
      assert updated.metadata["concurrent"] == "kept"
      assert Auth.OAuth.client_disabled?(updated)
      assert scope_names(updated.authorized_scopes) == ["github::*"]

      _cached = BorutaClients.get_client(updated.id)
      assert {:ok, cached} = ClientStore.get_client(updated.id)
      assert cached.metadata["backplane_resources"] == ["v1"]
      assert cached.metadata["tenant"] == "current"
      assert cached.metadata["concurrent"] == "kept"
      assert cached.metadata["disabled"]
      assert scope_names(cached.authorized_scopes) == ["github::*"]
    end

    test "disabling preserves state changed after the caller snapshot" do
      stale =
        oauth_client!(
          scopes: ["openid"],
          resources: [:mcp],
          metadata: %{"tenant" => "stale"}
        )
        |> then(&Auth.OAuth.get_client(&1.id))

      _cached_stale = prime_client_cache(stale.id)
      concurrent_scope = scope!("github::*")
      current = Auth.OAuth.get_client(stale.id)

      assert {:ok, _current} =
               Admin.update_client(current, %{
                 metadata: %{
                   "backplane_resources" => ["v1"],
                   "tenant" => "current",
                   "concurrent" => "kept"
                 },
                 authorized_scopes: [%{id: concurrent_scope.id}]
               })

      assert {:ok, disabled} = Auth.OAuth.disable_client(stale)
      assert Auth.OAuth.client_disabled?(disabled)
      assert Auth.OAuth.client_resources(disabled) == [:v1]
      assert disabled.metadata["tenant"] == "current"
      assert disabled.metadata["concurrent"] == "kept"
      assert scope_names(disabled.authorized_scopes) == ["github::*"]

      _cached = BorutaClients.get_client(disabled.id)
      assert {:ok, cached} = ClientStore.get_client(disabled.id)
      assert cached.metadata["disabled"]
      assert cached.metadata["backplane_resources"] == ["v1"]
      assert cached.metadata["tenant"] == "current"
      assert cached.metadata["concurrent"] == "kept"
      assert scope_names(cached.authorized_scopes) == ["github::*"]
    end

    test "HTTPS rejection leaves metadata, scopes, and the Boruta cache unchanged" do
      client =
        oauth_client!(
          scopes: ["openid", "github::*"],
          resources: [:mcp],
          metadata: %{"tenant" => "alpha"}
        )

      persisted_before = Auth.OAuth.get_client(client.id)
      _cached_before = prime_client_cache(client.id)
      assert {:ok, cached_before} = ClientStore.get_client(client.id)

      Application.put_env(:backplane, :api_url, "http://localhost:4220")

      assert {:error, :https_required} = Auth.OAuth.update_client_resources(client, [:v1])

      persisted_after = Auth.OAuth.get_client(client.id)
      assert persisted_after.metadata == persisted_before.metadata
      assert scope_names(persisted_after.authorized_scopes) == ["github::*", "openid"]
      assert ClientStore.get_client(client.id) == {:ok, cached_before}
    end

    test "invalid resource updates leave metadata, scopes, and the Boruta cache unchanged" do
      client =
        oauth_client!(
          scopes: ["openid", "github::*"],
          resources: [:mcp],
          metadata: %{"tenant" => "alpha"}
        )

      persisted_before = Auth.OAuth.get_client(client.id)
      _cached_before = prime_client_cache(client.id)
      assert {:ok, cached_before} = ClientStore.get_client(client.id)

      assert {:error, :invalid_resource} =
               Auth.OAuth.update_client_resources(client, [:mcp, :invalid])

      persisted_after = Auth.OAuth.get_client(client.id)
      assert persisted_after.metadata == persisted_before.metadata
      assert scope_names(persisted_after.authorized_scopes) == ["github::*", "openid"]
      assert ClientStore.get_client(client.id) == {:ok, cached_before}
    end

    test "rejects non-list resource updates without crashing" do
      client = oauth_client!(scopes: ["openid"], resources: [:mcp])
      persisted_before = Auth.OAuth.get_client(client.id)

      assert {:error, :invalid_resource} =
               Auth.OAuth.update_client_resources(client, "mcp")

      persisted_after = Auth.OAuth.get_client(client.id)
      assert persisted_after.metadata == persisted_before.metadata
      assert scope_names(persisted_after.authorized_scopes) == ["openid"]
    end

    test "resource updates return not found when the client was deleted" do
      client = oauth_client!(resources: [:mcp])
      assert {:ok, _deleted} = Repo.delete(client)

      assert {:error, :not_found} = Auth.OAuth.update_client_resources(client, [:v1])
    end

    test "resource updates return not found for invalid client IDs" do
      assert {:error, :not_found} =
               Auth.OAuth.update_client_resources(%Client{id: "not-a-uuid"}, [:v1])
    end

    test "disabling returns not found when the client was deleted" do
      client = oauth_client!(resources: [:mcp])
      assert {:ok, _deleted} = Repo.delete(client)

      assert {:error, :not_found} = Auth.OAuth.disable_client(client)
    end

    test "disabling returns not found for invalid client IDs" do
      assert {:error, :not_found} = Auth.OAuth.disable_client(%Client{id: "not-a-uuid"})
    end

    test "an empty resource update removes assignments while preserving unrelated state" do
      client =
        oauth_client!(
          scopes: ["openid", "github::*"],
          resources: [:mcp, :v1],
          metadata: %{"tenant" => "alpha"}
        )

      _cached_before = prime_client_cache(client.id)

      assert {:ok, updated} = Auth.OAuth.update_client_resources(client, [])
      assert updated.metadata["backplane_resources"] == []
      assert Auth.OAuth.client_resources(updated) == []
      refute Auth.OAuth.client_allows_resource?(updated, :mcp)
      refute Auth.OAuth.client_allows_resource?(updated, :v1)
      assert updated.metadata["tenant"] == "alpha"
      assert scope_names(updated.authorized_scopes) == ["github::*", "openid"]

      cached = BorutaClients.get_client(updated.id)
      assert cached.metadata["backplane_resources"] == []
      assert cached.metadata["tenant"] == "alpha"
      assert scope_names(cached.authorized_scopes) == ["github::*", "openid"]
      refute Auth.OAuth.enabled_client_for_resource?(:mcp)
      refute Auth.OAuth.enabled_client_for_resource?(:v1)
    end

    test "clients without resource metadata remain identity-only clients" do
      Application.put_env(:backplane, :api_url, "http://backplane.example.test:4220")

      client = oauth_client!(scopes: ["openid"], metadata: %{"tenant" => "alpha"})

      refute Map.has_key?(client.metadata, "backplane_resources")
      assert client.metadata["tenant"] == "alpha"
      assert Auth.OAuth.client_resources(client) == []
      refute Auth.OAuth.client_allows_resource?(client, :mcp)
      assert %Client{id: id} = Auth.OAuth.get_enabled_client(client.id)
      assert id == client.id
      refute Auth.OAuth.enabled_client_for_resource?(:mcp)
      refute Auth.OAuth.enabled_client_for_resource?(:v1)
    end

    test "ignores string resource assignments injected through metadata" do
      assert_reserved_metadata_is_identity_only(%{
        "backplane_resources" => ["mcp"],
        "tenant" => "alpha"
      })
    end

    test "ignores atom resource assignments injected through metadata" do
      assert_reserved_metadata_is_identity_only(%{
        :backplane_resources => [:v1],
        "tenant" => "alpha"
      })
    end

    test "top-level resource assignments replace both reserved metadata forms" do
      client =
        oauth_client!(
          resources: [:v1],
          metadata: %{
            :backplane_resources => [:mcp],
            "backplane_resources" => ["mcp"],
            "tenant" => "alpha"
          }
        )

      assert client.metadata["backplane_resources"] == ["v1"]
      refute Map.has_key?(client.metadata, :backplane_resources)
      assert client.metadata["tenant"] == "alpha"
      assert Auth.OAuth.client_resources(client) == [:v1]
    end
  end

  defp scope!(name) do
    assert {:ok, scope} = Auth.OAuth.create_scope(%{name: name, label: name, public: true})
    scope
  end

  defp oauth_client!(attrs \\ []) do
    case Auth.OAuth.create_client(client_attrs(attrs)) do
      {:ok, %{client: %Client{} = client}} -> client
      {:ok, %Client{} = client} -> client
      other -> flunk("expected OAuth client creation to succeed, got: #{inspect(other)}")
    end
  end

  defp client_attrs(attrs) do
    Map.merge(
      %{
        name: "Resource Client #{System.unique_integer([:positive])}",
        redirect_uris: ["https://app.example.test/auth/callback"],
        scopes: [],
        confidential: false,
        pkce: true
      },
      Map.new(attrs)
    )
  end

  defp scope_names(scopes), do: scopes |> Enum.map(& &1.name) |> Enum.sort()

  defp prime_client_cache(client_id) do
    on_exit(fn ->
      ClientStore.invalidate(%Boruta.Oauth.Client{id: client_id})
    end)

    BorutaClients.get_client(client_id)
  end

  defp unique_scope_name(prefix),
    do: "#{prefix}::#{System.unique_integer([:positive])}"

  defp assert_reserved_metadata_is_identity_only(metadata) do
    Application.put_env(:backplane, :api_url, "http://backplane.example.test:4220")
    Application.put_env(:backplane_auth, :allow_insecure_resource_origins, false)

    client = oauth_client!(metadata: metadata)

    refute Map.has_key?(client.metadata, "backplane_resources")
    refute Map.has_key?(client.metadata, :backplane_resources)
    assert client.metadata["tenant"] == "alpha"
    assert Auth.OAuth.client_resources(client) == []
    refute Auth.OAuth.client_allows_resource?(client, :mcp)
    refute Auth.OAuth.client_allows_resource?(client, :v1)
    refute Auth.OAuth.enabled_client_for_resource?(:mcp)
    refute Auth.OAuth.enabled_client_for_resource?(:v1)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
