defmodule BackplaneWeb.PageController do
  use BackplaneWeb, :controller

  def home(conn, _params) do
    conn
    |> assign(:page_title, "Backplane")
    |> put_layout(html: false)
    |> render(:home)
  end

  def admin(conn, _params) do
    redirect(conn, to: ~p"/admin/dashboard/overview")
  end
end
