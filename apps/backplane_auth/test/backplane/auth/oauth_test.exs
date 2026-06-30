defmodule Backplane.Auth.OAuthTest do
  use Backplane.Auth.DataCase, async: false

  alias Backplane.Auth
  alias Boruta.Ecto.{Client, Scope}

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
  end

  defp scope!(name) do
    assert {:ok, scope} = Auth.OAuth.create_scope(%{name: name, label: name, public: true})
    scope
  end

  defp scope_names(scopes), do: scopes |> Enum.map(& &1.name) |> Enum.sort()
end
