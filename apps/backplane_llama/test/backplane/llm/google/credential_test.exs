defmodule Backplane.LLM.Google.CredentialTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{CredentialPlug, Provider}
  alias Backplane.Settings.Credentials

  test "native Google rejects non-API-key bindings before token resolution" do
    {:ok, _} =
      Credentials.store("google-wrong-auth", "not-an-api-key", "llm", %{
        "auth_type" => "unsupported-token-type"
      })

    assert {:error, :unsupported_google_auth_type} =
             CredentialPlug.build_auth_headers(
               %Provider{credential: "google-wrong-auth"},
               :google
             )
  end

  test "native Google accepts the default API-key binding" do
    {:ok, _} = Credentials.store("google-api-key", "local-fixture-key", "llm")

    assert {:ok, headers} =
             CredentialPlug.build_auth_headers(%Provider{credential: "google-api-key"}, :google)

    assert {"x-goog-api-key", "local-fixture-key"} in headers
  end
end
