defmodule Backplane.Transport.HealthPlug do
  @moduledoc """
  Simple health check plug returning JSON status.
  """

  @behaviour Plug

  alias Backplane.Transport.HealthCheck

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    health = HealthCheck.check()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(health))
  end
end
