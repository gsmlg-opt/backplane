defmodule Backplane.Api.EndpointsPlug do
  @moduledoc """
  Routes `/endpoints/:name/mcp` to the MCP transport and `/endpoints/:name/v1/*`
  to the LLM router as a named endpoint.

  Runs before `Plug.Parsers`, so it never reads the request body. The matched
  endpoint is stored in `conn.private[:backplane_endpoint]`; authentication and
  scope narrowing happen in `Backplane.Auth.ResourceAuthPlug`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Backplane.Endpoints

  @llm_routes [
    {"GET", []},
    {"GET", ["models"]},
    {"POST", ["messages"]},
    {"POST", ["chat", "completions"]},
    {"POST", ["responses"]},
    {"POST", ["embeddings"]}
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["endpoints", name, "mcp" | rest]} = conn, _opts) do
    case Endpoints.active(name, :mcp) do
      {:ok, endpoint} ->
        conn
        |> put_private(:backplane_endpoint, endpoint)
        |> Map.merge(%{
          path_info: rest,
          script_name: conn.script_name ++ ["endpoints", name, "mcp"]
        })
        |> Backplane.Transport.McpPlug.call(Backplane.Transport.McpPlug.init([]))
        |> halt()

      :error ->
        not_found(conn)
    end
  end

  def call(%Plug.Conn{path_info: ["endpoints", name, "v1" | rest]} = conn, _opts) do
    with true <- {conn.method, rest} in @llm_routes,
         {:ok, endpoint} <- Endpoints.active(name, :llm) do
      path_info = ["v1" | rest]

      conn
      |> put_private(:backplane_endpoint, endpoint)
      |> Map.merge(%{path_info: path_info, request_path: "/" <> Enum.join(path_info, "/")})
      |> Backplane.LLM.Router.call(Backplane.LLM.Router.init([]))
      |> halt()
    else
      _ -> llm_not_found(conn)
    end
  end

  def call(%Plug.Conn{path_info: ["endpoints" | _]} = conn, _opts), do: not_found(conn)
  def call(conn, _opts), do: conn

  defp llm_not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      404,
      Jason.encode!(%{
        "type" => "error",
        "error" => %{"type" => "not_found_error", "message" => "Route not found"}
      })
    )
    |> halt()
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
    |> halt()
  end
end
