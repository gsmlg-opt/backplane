defmodule Backplane.Api.NotFoundPlug do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    Plug.Conn.send_resp(conn, 404, "not found")
  end
end
