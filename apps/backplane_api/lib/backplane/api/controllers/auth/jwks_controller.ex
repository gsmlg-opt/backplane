defmodule Backplane.Api.Auth.JwksController do
  use Backplane.Api, :controller

  alias Backplane.Auth

  def index(conn, _params) do
    json(conn, Auth.Tokens.jwks())
  end
end
