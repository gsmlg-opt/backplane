defmodule BackplaneWeb.PageController do
  use BackplaneWeb, :controller

  def home(conn, _params) do
    base_url = server_base_url(conn)

    conn
    |> assign(:page_title, "Backplane")
    |> assign(:base_url, base_url)
    |> put_layout(html: false)
    |> render(:home)
  end

  defp server_base_url(conn) do
    scheme = to_string(Plug.Conn.get_req_header(conn, "x-forwarded-proto") |> List.first() || conn.scheme)
    host = conn.host
    port = conn.port

    case {scheme, port} do
      {"https", 443} -> "#{scheme}://#{host}"
      {"http", 80} -> "#{scheme}://#{host}"
      _ -> "#{scheme}://#{host}:#{port}"
    end
  end

  def admin(conn, _params) do
    redirect(conn, to: ~p"/admin/dashboard/overview")
  end
end
