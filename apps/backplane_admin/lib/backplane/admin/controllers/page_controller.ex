defmodule Backplane.Admin.PageController do
  use Backplane.Admin, :controller

  def admin(conn, _params) do
    redirect(conn, to: ~p"/dashboard/overview")
  end

  def not_found(conn, _params) do
    Plug.Conn.send_resp(conn, 404, "not found")
  end
end
