defmodule Backplane.LLM.ProxyPlug do
  @moduledoc """
  Endpoint-level plug that intercepts /llm/* requests before Plug.Parsers
  consumes the body. Delegates to LLM.Router with the "llm" prefix stripped.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["llm" | rest]} = conn, _opts) do
    conn
    |> Map.put(:path_info, rest)
    |> Map.put(:request_path, "/" <> Enum.join(rest, "/"))
    |> Backplane.LLM.Router.call(Backplane.LLM.Router.init([]))
    |> Plug.Conn.halt()
  end

  def call(conn, _opts), do: conn
end
