defmodule Backplane.Api.Auth.UserinfoController do
  use Backplane.Api, :controller

  alias Backplane.Api.Auth.Helpers
  alias Backplane.Auth

  def show(conn, _params) do
    with {:ok, token} <- Helpers.bearer_token(conn),
         {:ok, claims} <- Auth.Tokens.verify_access_token(token),
         user when not is_nil(user) <- Auth.Accounts.get_user(claims["sub"]) do
      json(conn, %{
        sub: user.id,
        email: user.email,
        email_verified: true,
        name: user.name
      })
    else
      _invalid -> Helpers.json_error(conn, 401, "invalid_token")
    end
  end
end
