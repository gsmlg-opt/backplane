defmodule Backplane.Auth.TokenResources do
  @moduledoc """
  Persists and resolves protected-resource bindings for Boruta OAuth tokens.

  Boruta records authorization-code exchange through `previous_code` and
  refresh rotation through `previous_token`. Those fields are mutually
  exclusive in Boruta's normal flows. If a noncanonical row contains both,
  `previous_token` takes precedence because it identifies the immediate
  refresh predecessor; a missing named predecessor never falls back to the
  other field.
  """

  import Ecto.Query

  alias Backplane.Auth.Schemas.OAuthTokenResource
  alias Backplane.Auth.Tokens
  alias Backplane.Repo
  alias Boruta.Ecto.Token

  defmodule LineageError do
    @moduledoc false
    defexception message: "OAuth token resource lineage could not be resolved"
  end

  @type resource :: :mcp | :v1
  @type lookup_result :: :not_found | {:ok, Token.t(), nil | resource()}
  @type binding_result :: :unbound | {:ok, resource()}

  @spec bind_issued(String.t(), String.t(), String.t(), resource()) ::
          {:ok, %OAuthTokenResource{}} | {:error, :not_found | :binding_failed}
  def bind_issued(type, client_id, value, resource)
      when type in ["code", "access_token"] and resource in [:mcp, :v1] do
    case Repo.get_by(Token, type: type, client_id: client_id, value: value) do
      nil ->
        {:error, :not_found}

      %Token{} = token ->
        token
        |> binding_changeset(resource)
        |> Repo.insert()
        |> compensate_binding_failure(token)
    end
  end

  @spec lookup_code(String.t(), String.t()) :: lookup_result()
  def lookup_code(client_id, value) do
    lookup(type: "code", client_id: client_id, value: value)
  end

  @spec lookup_refresh(String.t(), String.t()) :: lookup_result()
  def lookup_refresh(client_id, refresh_token) do
    lookup(type: "access_token", client_id: client_id, refresh_token: refresh_token)
  end

  @spec lookup_access_token(String.t(), String.t()) :: lookup_result()
  def lookup_access_token(client_id, value) do
    lookup(type: "access_token", client_id: client_id, value: value)
  end

  @spec resource_for_token(Token.t()) :: binding_result()
  def resource_for_token(%Token{id: token_id}) do
    case Repo.get_by(OAuthTokenResource, oauth_token_id: token_id) do
      nil -> :unbound
      %OAuthTokenResource{resource: resource} -> {:ok, persisted_resource!(resource)}
    end
  end

  @spec resource_for_lineage(Token.t()) ::
          binding_result() | {:error, :lineage_not_found}
  def resource_for_lineage(%Token{client_id: client_id, previous_token: previous_token})
      when is_binary(previous_token) do
    resolve_lineage(
      type: "access_token",
      client_id: client_id,
      value: previous_token
    )
  end

  def resource_for_lineage(%Token{client_id: client_id, previous_code: previous_code})
      when is_binary(previous_code) do
    resolve_lineage(type: "code", client_id: client_id, value: previous_code)
  end

  def resource_for_lineage(%Token{}), do: :unbound

  defp binding_changeset(%Token{id: token_id}, resource) do
    OAuthTokenResource.changeset(%OAuthTokenResource{}, %{
      oauth_token_id: token_id,
      resource: Atom.to_string(resource)
    })
  end

  defp compensate_binding_failure({:ok, %OAuthTokenResource{}} = result, _token), do: result

  defp compensate_binding_failure({:error, _changeset}, %Token{id: token_id}) do
    _ = Tokens.revoke_token_by_id(token_id)
    {:error, :binding_failed}
  end

  defp lookup(filters) do
    Token
    |> where(^filters)
    |> Repo.one()
    |> case do
      nil -> :not_found
      %Token{} = token -> lookup_result(token)
    end
  end

  defp lookup_result(%Token{} = token) do
    case resource_for_token(token) do
      :unbound -> {:ok, token, nil}
      {:ok, resource} -> {:ok, token, resource}
    end
  end

  defp resolve_lineage(filters) do
    case Repo.get_by(Token, filters) do
      nil -> {:error, :lineage_not_found}
      %Token{} = predecessor -> resource_for_token(predecessor)
    end
  end

  defp persisted_resource!("mcp"), do: :mcp
  defp persisted_resource!("v1"), do: :v1
  defp persisted_resource!(_corrupt), do: raise(LineageError)
end
