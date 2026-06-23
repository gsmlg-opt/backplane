defmodule Backplane.Api.PageController do
  use Backplane.Api, :controller

  alias Backplane.WebOrigins

  def home(conn, _params) do
    conn
    |> assign(:page_title, "Backplane")
    |> assign(:base_url, WebOrigins.api_base_url())
    |> assign(:admin_base_url, WebOrigins.admin_base_url())
    |> put_layout(html: false)
    |> render(:home)
  end
end
