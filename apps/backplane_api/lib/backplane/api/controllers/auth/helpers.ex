defmodule Backplane.Api.Auth.Helpers do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias Backplane.Auth
  alias Boruta.Ecto.Client

  def json_error(conn, status, error, description \\ nil) do
    body =
      %{error: error}
      |> maybe_put(:error_description, description)

    conn
    |> put_status(status)
    |> json(body)
  end

  def bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> case do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _headers -> {:error, :invalid_token}
    end
  end

  @doc """
  Rejects requests from clients disabled through the admin UI before they
  reach Boruta, which has no notion of the metadata disabled flag. Missing
  or unknown client credentials fall through so Boruta renders the proper
  protocol error.
  """
  def check_client_enabled(conn, params) do
    with {:ok, client_id, _secret} <- client_credentials(conn, params),
         %Client{} = client <- Auth.OAuth.get_client(client_id) do
      if Auth.OAuth.client_enabled?(client), do: :ok, else: {:error, :invalid_client}
    else
      _unknown -> :ok
    end
  end

  @doc "Extracts client credentials from HTTP basic auth or request params."
  def client_credentials(conn, params) do
    case basic_credentials(conn) do
      {:ok, client_id, secret} ->
        {:ok, client_id, secret}

      :error ->
        client_id = params["client_id"] || params[:client_id]
        secret = params["client_secret"] || params[:client_secret]

        if is_binary(client_id) and client_id != "" do
          {:ok, client_id, secret}
        else
          {:error, :invalid_client}
        end
    end
  end

  defp basic_credentials(conn) do
    conn
    |> get_req_header("authorization")
    |> case do
      ["Basic " <> encoded] ->
        with {:ok, decoded} <- Base.decode64(encoded),
             [client_id, secret] <- String.split(decoded, ":", parts: 2) do
          {:ok, client_id, secret}
        else
          _invalid -> {:error, :invalid_client}
        end

      _headers ->
        :error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
