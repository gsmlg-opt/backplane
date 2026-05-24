defmodule Backplane.LLM.ProxyPlug do
  @moduledoc """
  Endpoint-level plug that intercepts LLM proxy requests before Plug.Parsers
  consumes the body. Delegates to LLM.Router with the public prefix stripped.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["llm" | rest]} = conn, _opts) do
    forward_to_llm_router(conn, rest)
  end

  def call(%Plug.Conn{path_info: ["api", "llm", "v1" | rest]} = conn, _opts) do
    forward_to_llm_router(conn, ["v1" | rest])
  end

  def call(conn, _opts), do: conn

  defp forward_to_llm_router(conn, path_info) do
    conn
    |> Map.put(:path_info, path_info)
    |> Map.put(:request_path, "/" <> Enum.join(path_info, "/"))
    |> Backplane.LLM.Router.call(Backplane.LLM.Router.init([]))
    |> Plug.Conn.halt()
  end
end
