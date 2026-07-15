defmodule Backplane.Settings.CredentialsFigmaOAuthTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo
  alias Backplane.Settings.{Credential, Credentials, Encryption, TokenCache}

  setup do
    TokenCache.clear()
    on_exit(&TokenCache.clear/0)
    :ok
  end

  test "stores a Figma token as an encrypted upstream OAuth credential" do
    expires_at = System.system_time(:millisecond) + 3_600_000

    assert {:ok, credential} =
             Credentials.store_oauth_token(
               "figma-mcp",
               "figma_oauth",
               %{
                 "access_token" => "figma-access",
                 "refresh_token" => "figma-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert credential.kind == "upstream"
    assert credential.metadata == %{"auth_type" => "figma_oauth"}
    refute Map.has_key?(credential.metadata, "client_id")
    refute Map.has_key?(credential.metadata, "client_secret")

    assert {:ok, plaintext} = Encryption.decrypt(credential.encrypted_value)

    assert %{
             "access_token" => "figma-access",
             "refresh_token" => "figma-refresh",
             "expires_at" => ^expires_at
           } = Jason.decode!(plaintext)

    assert {:ok, "figma-access"} = Credentials.fetch("figma-mcp")
  end

  test "reauthorizing the same name invalidates the cached access token" do
    expires_at = System.system_time(:millisecond) + 3_600_000

    assert {:ok, _} =
             Credentials.store_oauth_token(
               "figma-reconnect",
               "figma_oauth",
               %{
                 "access_token" => "old-access",
                 "refresh_token" => "old-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert {:ok, "old-access"} = Credentials.fetch("figma-reconnect")
    assert {:ok, "old-access"} = TokenCache.get("figma-reconnect")

    assert {:ok, _} =
             Credentials.store_oauth_token(
               "figma-reconnect",
               "figma_oauth",
               %{
                 "access_token" => "new-access",
                 "refresh_token" => "new-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert :miss = TokenCache.get("figma-reconnect")
    assert {:ok, "new-access"} = Credentials.fetch("figma-reconnect")

    stored = Repo.get_by!(Credential, name: "figma-reconnect")
    assert stored.kind == "upstream"
  end

  test "existing device OAuth storage keeps the llm kind" do
    assert {:ok, credential} =
             Credentials.store_device_token(
               "legacy-google",
               "google_oauth",
               %{
                 "access_token" => "google-access",
                 "refresh_token" => "google-refresh",
                 "expires_at" => System.system_time(:millisecond) + 3_600_000
               },
               %{}
             )

    assert credential.kind == "llm"
    assert credential.metadata["auth_type"] == "google_oauth"
  end
end
