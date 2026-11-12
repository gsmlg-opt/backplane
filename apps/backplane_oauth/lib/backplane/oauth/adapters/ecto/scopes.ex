defmodule Backplane.Oauth.Ecto.Scopes do
  @moduledoc false

  @behaviour Backplane.Oauth.Scopes

  import Ecto.Query, only: [from: 2]
  import Backplane.Oauth.Config, only: [repo: 0]
  import Backplane.Oauth.Ecto.OauthMapper, only: [to_oauth_schema: 1]

  alias Backplane.Oauth.Ecto
  alias Backplane.Oauth.Ecto.ScopeStore

  @impl Backplane.Oauth.Scopes
  def public do
    case ScopeStore.get(:public) do
      {:ok, scopes} ->
        scopes

      {:error, _reason} ->
        repo().all(
          from s in Ecto.Scope,
            where: s.public == true
        )
        |> Enum.map(&to_oauth_schema/1)
        |> ScopeStore.put_public()
    end
  end

  def all do
    case ScopeStore.get(:all) do
      {:ok, scopes} ->
        scopes

      {:error, _reason} ->
        repo().all(Ecto.Scope)
        |> Enum.map(&to_oauth_schema/1)
        |> ScopeStore.put_all()
    end
  end

  def invalidate(:public) do
    ScopeStore.invalidate(:public)
  end

  def invalidate(:all) do
    ScopeStore.invalidate(:all)
  end
end
