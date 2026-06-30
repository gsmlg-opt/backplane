defmodule Backplane.Api.Auth.UserinfoController do
  use Backplane.Api, :controller

  alias Backplane.Api.Auth.Helpers
  alias Backplane.Auth

  def show(conn, _params) do
    with {:ok, token} <- Helpers.bearer_token(conn),
         {:ok, claims} <- Auth.Tokens.verify_access_token(token),
         :ok <- validate_openid_scope(claims),
         %{active: true} = user <- Auth.Accounts.get_user(claims["sub"]) do
      json(conn, userinfo_response(user, claims))
    else
      _invalid -> Helpers.json_error(conn, 401, "invalid_token")
    end
  end

  defp validate_openid_scope(claims) do
    if "openid" in scopes(claims), do: :ok, else: {:error, :invalid_token}
  end

  defp userinfo_response(user, claims) do
    scope_names = scopes(claims)

    %{sub: user.id}
    |> maybe_put_email(user, scope_names)
    |> maybe_put_profile(user, scope_names)
  end

  defp maybe_put_email(body, user, scope_names) do
    if "email" in scope_names do
      body
      |> Map.put(:email, user.email)
      |> Map.put(:email_verified, true)
    else
      body
    end
  end

  defp maybe_put_profile(body, user, scope_names) do
    if "profile" in scope_names do
      Map.put(body, :name, user.name)
    else
      body
    end
  end

  defp scopes(%{"scope" => scope}) when is_binary(scope), do: String.split(scope, " ", trim: true)
  defp scopes(_claims), do: []
end
