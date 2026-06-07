defmodule Backplane.LLM.CredentialPlugOpenAICodexTest do
  use Backplane.DataCase, async: false

  alias Backplane.LLM.{CredentialPlug, Provider}
  alias Backplane.Settings.{Credentials, TokenCache}

  setup do
    TokenCache.clear()
    expires_at = System.system_time(:millisecond) + 60 * 60 * 1000

    {:ok, _} =
      Credentials.store_device_token(
        "codex-oauth-provider-token",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "auth_mode" => "chatgpt",
          "id_token" => "codex-id-token",
          "access_token" => "chatgpt-access-token",
          "refresh_token" => "refresh-token",
          "expires_at" => expires_at
        },
        %{"account_id" => "acc-123"}
      )

    :ok
  end

  test "uses ChatGPT OAuth bearer and Codex backend headers" do
    {:ok, provider} =
      Provider.create(%{
        name: "cred-plug-openai-codex",
        preset_key: "openai-codex",
        api_type: :openai,
        api_url: "https://chatgpt.com/backend-api/codex",
        credential: "codex-oauth-provider-token",
        models: ["gpt-5.5"]
      })

    assert {:ok, headers} = CredentialPlug.build_auth_headers(provider, :openai)
    assert {"authorization", "Bearer chatgpt-access-token"} in headers
    assert {"chatgpt-account-id", "acc-123"} in headers
    assert {"originator", "codex_cli_rs"} in headers
  end
end
