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

  def authenticate_client(conn, params) do
    with {:ok, client_id, secret} <- client_credentials(conn, params),
         %Client{} = client <- Auth.OAuth.get_enabled_client(client_id),
         :ok <- verify_client_secret(client, secret) do
      {:ok, client}
    else
      nil -> {:error, :invalid_client}
      {:error, reason} -> {:error, reason}
    end
  end

  def bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> case do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _headers -> {:error, :invalid_token}
    end
  end

  defp client_credentials(conn, params) do
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

  defp verify_client_secret(%Client{confidential: true, secret: secret}, provided)
       when is_binary(provided) do
    if client_secret_matches?(secret, provided) do
      :ok
    else
      {:error, :invalid_client}
    end
  end

  defp verify_client_secret(%Client{confidential: true}, _provided), do: {:error, :invalid_client}
  defp verify_client_secret(%Client{confidential: false}, _provided), do: :ok

  defp client_secret_matches?(stored, provided) do
    Bcrypt.verify_pass(provided, stored) or secure_compare?(stored, provided)
  rescue
    _error -> secure_compare?(stored, provided)
  end

  defp secure_compare?(stored, provided)
       when is_binary(stored) and is_binary(provided) and byte_size(stored) == byte_size(provided) do
    Plug.Crypto.secure_compare(stored, provided)
  end

  defp secure_compare?(_stored, _provided), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
