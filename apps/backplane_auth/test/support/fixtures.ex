defmodule Backplane.Auth.Fixtures do
  @moduledoc "Test fixtures for Backplane Auth domain records."

  alias Backplane.Auth

  def auth_user_fixture!(attrs \\ []) do
    password = Keyword.get(attrs, :password, "correct horse battery staple")

    attrs =
      attrs
      |> Keyword.drop([:password])
      |> Keyword.put_new(:email, "user-#{unique()}@example.com")
      |> Keyword.put_new(:name, "Test User")
      |> Map.new()

    {:ok, user} = Auth.Accounts.create_user(attrs)
    {:ok, _credential} = Auth.Accounts.set_password(user, password)

    user
  end

  def oauth_client_fixture!(attrs \\ []) do
    attrs =
      attrs
      |> Keyword.put_new(:client_id, "client-#{unique()}")
      |> Keyword.put_new(:name, "Test OAuth Client")
      |> Keyword.put_new(:redirect_uris, ["https://client.example.test/oauth/callback"])
      |> Keyword.put_new(:scopes, ["openid", "profile", "email"])
      |> Keyword.put_new(:confidential, true)
      |> Keyword.put_new(:pkce, true)
      |> Map.new()

    oauth_module = Module.concat(Auth, OAuth)

    case apply(oauth_module, :create_client, [attrs]) do
      {:ok, %{client: client, secret: secret}} ->
        client_with_secret(client, secret)

      {:ok, client} ->
        client
    end
  end

  defp client_with_secret(client, secret) when is_map(client) do
    client
    |> struct_to_map()
    |> Map.put(:plaintext_secret, secret)
  end

  defp struct_to_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp struct_to_map(map), do: map

  defp unique, do: System.unique_integer([:positive])
end
