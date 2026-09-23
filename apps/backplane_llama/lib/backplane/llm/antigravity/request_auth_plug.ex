defmodule Backplane.LLM.Antigravity.RequestAuthPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Backplane.LLM.Google.Error

  @credential_headers ["authorization", "x-api-key", "api-key", "x-goog-api-key"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["antigravity" | _]} = conn, _opts) do
    cond do
      not allowed_query?(conn) ->
        conn
        |> Map.put(:query_string, "")
        |> Error.send(400, "Query parameters are not accepted on Antigravity routes")

      conflicting_credentials?(conn) ->
        Error.send(conn, 400, "Supply exactly one Backplane credential")

      unsupported_credential?(conn) ->
        Error.send(conn, 400, "Use Authorization bearer authentication for Antigravity routes")

      true ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp conflicting_credentials?(conn) do
    carriers = Enum.map(@credential_headers, &get_req_header(conn, &1))
    Enum.any?(carriers, &(length(&1) > 1)) or Enum.count(carriers, &(&1 != [])) > 1
  end

  defp unsupported_credential?(conn) do
    Enum.any?(@credential_headers -- ["authorization"], &(get_req_header(conn, &1) != []))
  end

  defp allowed_query?(%Plug.Conn{query_string: ""}), do: true

  defp allowed_query?(%Plug.Conn{request_path: path, query_string: query}) do
    String.ends_with?(path, "/v1internal:streamGenerateContent") and
      Enum.to_list(URI.query_decoder(query)) == [{"alt", "sse"}]
  rescue
    ArgumentError -> false
  end
end
