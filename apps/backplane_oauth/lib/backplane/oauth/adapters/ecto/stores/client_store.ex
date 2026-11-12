# credo:disable-for-this-file Credo.Check.Warning.SpecWithStruct
defmodule Backplane.Oauth.Ecto.ClientStore do
  @moduledoc false

  import Backplane.Oauth.Config, only: [cache_backend: 0]

  alias Backplane.Oauth.Client

  @spec get_client(String.t()) ::
          {:ok, token :: Backplane.Oauth.Client.t()} | {:error, reason :: String.t()}
  def get_client(id) do
    case get_by_id(id) do
      {:ok, nil} -> {:error, "Client not cached."}
      {:ok, %Client{} = client} -> {:ok, client}
    end
  end

  defp get_by_id(id) do
    cache_backend().get({Client, id})
  end

  def authorized_scopes(%Client{id: id}) do
    case get_by_id(id) do
      {:ok, nil} -> {:error, "Client not cached."}
      {:ok, %Client{} = client} -> {:ok, client.authorized_scopes}
    end
  end

  @spec put(client :: Backplane.Oauth.Client.t()) ::
          {:ok, client :: Backplane.Oauth.Client.t()} | {:error, reason :: String.t()}
  def put(client) do
    with :ok <- cache_backend().put({Client, client.id}, client) do
      {:ok, client}
    end
  end

  @spec invalidate(client :: %Client{}) :: :ok
  def invalidate(client) do
    cache_backend().delete({Client, client.id})
  end
end
