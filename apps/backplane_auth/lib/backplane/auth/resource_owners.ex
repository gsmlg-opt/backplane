defmodule Backplane.Auth.ResourceOwners do
  @moduledoc "Boruta resource-owner adapter backed by Backplane Auth users."

  @behaviour Boruta.Oauth.ResourceOwners

  alias Backplane.Auth.{Accounts, RBAC}
  alias Backplane.Auth.Schemas.User
  alias Boruta.Ecto.OauthMapper
  alias Boruta.Oauth.ResourceOwner

  @impl true
  def get_by(sub: sub) when is_binary(sub) do
    sub
    |> Accounts.get_user()
    |> to_result()
  end

  @impl true
  def get_by(username: _username), do: {:error, "username lookup is not supported"}

  @impl true
  def check_password(%ResourceOwner{}, _password) do
    {:error, "password grant is not supported"}
  end

  @impl true
  def authorized_scopes(%ResourceOwner{sub: sub}) do
    with %User{} = user <- Accounts.get_user(sub) do
      user
      |> RBAC.effective_scope_names()
      |> Boruta.Ecto.Admin.get_scopes_by_names()
      |> Enum.map(&OauthMapper.to_oauth_schema/1)
    else
      _missing -> []
    end
  end

  @impl true
  def claims(%ResourceOwner{extra_claims: claims}, _scope) do
    Map.put_new(claims || %{}, "email_verified", true)
  end

  defp to_result(%User{active: true} = user), do: {:ok, to_resource_owner(user)}
  defp to_result(%User{}), do: {:error, "resource owner is inactive"}
  defp to_result(nil), do: {:error, "resource owner not found"}

  defp to_resource_owner(%User{} = user) do
    %ResourceOwner{
      sub: user.id,
      username: user.email,
      last_login_at: user.last_login_at,
      extra_claims: %{
        "email" => user.email,
        "email_verified" => true,
        "name" => user.name
      }
    }
  end
end
