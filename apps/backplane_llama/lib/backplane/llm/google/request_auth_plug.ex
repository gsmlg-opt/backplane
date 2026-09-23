defmodule Backplane.LLM.Google.RequestAuthPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Backplane.LLM.Google.Error

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["v1beta" | _]} = conn, _opts) do
    cond do
      query_key?(conn.query_string) ->
        conn
        |> Map.put(:query_string, redact_query(conn.query_string))
        |> Error.send(
          400,
          "The query parameter 'key' is not accepted; authenticate to Backplane with a request header"
        )

      conflicting_credentials?(conn) ->
        Error.send(conn, 400, "Supply exactly one Backplane credential")

      get_req_header(conn, "x-api-key") != [] ->
        Error.send(
          conn,
          400,
          "x-api-key is not a supported Backplane credential for Google routes"
        )

      true ->
        adapt_google_header(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp adapt_google_header(conn) do
    case get_req_header(conn, "x-goog-api-key") do
      [token] when token != "" ->
        conn
        |> delete_req_header("x-goog-api-key")
        |> put_req_header("authorization", "Bearer #{token}")

      [] ->
        conn

      _ ->
        Error.send(conn, 400, "Supply exactly one Backplane credential")
    end
  end

  defp conflicting_credentials?(conn) do
    google = get_req_header(conn, "x-goog-api-key")
    authorization = get_req_header(conn, "authorization")
    api_key = get_req_header(conn, "x-api-key")

    length(google) > 1 or length(authorization) > 1 or length(api_key) > 1 or
      Enum.count([google != [], authorization != [], api_key != []], & &1) > 1
  end

  defp query_key?(query_string) do
    query_string
    |> URI.query_decoder()
    |> Enum.any?(fn {key, _value} -> key == "key" end)
  rescue
    ArgumentError -> String.contains?(query_string, "key=")
  end

  defp redact_query(query_string) do
    query_string
    |> URI.query_decoder()
    |> Enum.reject(fn {key, _value} -> key == "key" end)
    |> URI.encode_query()
  rescue
    ArgumentError -> ""
  end
end
