defmodule Backplane.Admin.MemoryDetailPlug do
  @moduledoc false

  import Plug.Conn

  alias Backplane.Memory.Operations

  def init(opts), do: opts

  def call(%{path_params: %{"stream_id" => id}} = conn, _opts) do
    guard_resource(conn, Operations.get_stream(id))
  end

  def call(%{path_params: %{"event_id" => id}} = conn, _opts) do
    guard_resource(conn, Operations.get_event(id))
  end

  def call(conn, _opts), do: conn

  defp guard_resource(conn, {:ok, _resource}), do: conn

  defp guard_resource(conn, {:error, :not_found}) do
    conn
    |> send_resp(404, "not found")
    |> halt()
  end

  defp guard_resource(conn, {:error, _reason}) do
    conn
    |> send_resp(503, "memory unavailable")
    |> halt()
  end
end
