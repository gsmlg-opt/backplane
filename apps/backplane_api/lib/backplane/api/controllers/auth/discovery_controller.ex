defmodule Backplane.Api.Auth.DiscoveryController do
  use Backplane.Api, :controller

  alias Backplane.Auth.Metadata

  def openid_configuration(conn, _params) do
    json(conn, Metadata.openid_configuration())
  end

  def authorization_server(conn, _params) do
    json(conn, Metadata.authorization_server())
  end

  def protected_resource(conn, %{"resource" => "mcp"}) do
    json(conn, Metadata.protected_resource(:mcp))
  end

  def protected_resource(conn, %{"resource" => "v1"}) do
    json(conn, Metadata.protected_resource(:v1))
  end

  def protected_resource(conn, _params) do
    send_resp(conn, 404, "not found")
  end
end
