defmodule Backplane.Auth.EndpointAccess do
  @moduledoc """
  Endpoint lifecycle operations that must also withdraw OAuth access.
  """

  import Ecto.Query

  alias Backplane.Auth.{Resources, Tokens}
  alias Backplane.Auth.Schemas.OAuthTokenResource
  alias Backplane.Endpoints
  alias Backplane.Endpoints.Endpoint
  alias Backplane.Repo

  @doc """
  Deletes an endpoint after revoking every OAuth token bound to its resources.
  """
  @spec delete_endpoint(Endpoint.t()) :: {:ok, Endpoint.t()} | {:error, term()}
  def delete_endpoint(%Endpoint{name: name} = endpoint) do
    result =
      Repo.transaction(fn ->
        name |> bound_token_ids() |> Enum.each(&revoke!/1)

        case Endpoints.delete(endpoint) do
          {:ok, deleted} -> deleted
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    # Endpoints.delete/1 invalidated inside the transaction; a concurrent read
    # may have re-cached the row before commit.
    Endpoints.invalidate(name)
    result
  end

  defp bound_token_ids(name) do
    resources = Enum.map([:mcp, :v1], &Resources.to_persisted({:endpoint, name, &1}))

    OAuthTokenResource
    |> where([binding], binding.resource in ^resources)
    |> select([binding], binding.oauth_token_id)
    |> Repo.all()
  end

  defp revoke!(token_id) do
    case Tokens.revoke_token_by_id(token_id) do
      {:ok, _token} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
