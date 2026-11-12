defmodule Boruta.ConfigTest do
  use ExUnit.Case, async: false

  alias Boruta.Config

  test "reads Boruta.Oauth configuration from the :backplane_oauth application" do
    assert Config.issuer() == Application.fetch_env!(:backplane_oauth, Boruta.Oauth)[:issuer]
    assert Config.repo() == Backplane.Repo
  end

  test "the forked application is the :backplane_oauth OTP application" do
    assert Application.get_application(Boruta.Config) == :backplane_oauth
    assert Application.get_application(Boruta.Cache) == :backplane_oauth
  end

  test "outbound fetches require configured trusted hosts or authorities" do
    previous = Application.get_env(:backplane_oauth, Boruta.Oauth)
    on_exit(fn -> Application.put_env(:backplane_oauth, Boruta.Oauth, previous) end)

    Application.put_env(
      :backplane_oauth,
      Boruta.Oauth,
      Keyword.put(previous, :issuer, "not a url")
    )

    assert {:error, "Client must configure trusted hosts or authorities for outbound requests."} =
             Boruta.HttpClient.get("https://example.invalid/jwks")

    assert {:error, "Host is not trusted for outbound requests."} =
             Boruta.HttpClient.get("https://example.invalid/jwks", "", ["trusted.invalid"])
  end
end
