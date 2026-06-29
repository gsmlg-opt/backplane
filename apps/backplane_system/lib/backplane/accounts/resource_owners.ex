defmodule Backplane.Accounts.ResourceOwners do
  @moduledoc "Boruta resource-owner adapter backed by Backplane users."

  @behaviour Boruta.Oauth.ResourceOwners

  alias Backplane.Accounts
  alias Backplane.Accounts.User
  alias Boruta.Oauth.ResourceOwner

  @impl true
  def get_by(sub: sub) when is_binary(sub) do
    sub
    |> Accounts.get_user()
    |> to_result()
  end

  @impl true
  def get_by(username: username) when is_binary(username) do
    {:error, "username lookup is not supported"}
  end

  @impl true
  def check_password(%ResourceOwner{}, _password) do
    {:error, "password grant is not supported"}
  end

  @impl true
  def authorized_scopes(%ResourceOwner{}) do
    []
  end

  @impl true
  def claims(%ResourceOwner{extra_claims: claims}, _scope) do
    claims || %{}
  end

  defp to_result(%User{active: true} = user), do: {:ok, Accounts.to_resource_owner(user)}
  defp to_result(%User{}), do: {:error, "resource owner is inactive"}
  defp to_result(nil), do: {:error, "resource owner not found"}
end
