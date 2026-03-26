defmodule Backplane.Transport.MetricsPlug do
  @moduledoc """
  Metrics endpoint returning JSON snapshot.
  """

  @behaviour Plug

  alias Backplane.Metrics

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    metrics = Metrics.snapshot()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(metrics))
  end
end
