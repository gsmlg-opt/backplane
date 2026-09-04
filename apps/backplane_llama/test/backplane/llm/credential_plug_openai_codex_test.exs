defmodule Backplane.LLM.CredentialPlugOpenAICodexTest do
  use BackplaneLlama.DataCase, async: false

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

  test "reads account and FedRAMP metadata from the fetch_with_meta wrapper" do
    meta = %{
      auth_type: "openai_oauth",
      extra_headers: [],
      metadata: %{"account_id" => "wrapped-account", "x-openai-fedramp" => true}
    }

    {replace, _defaults} = CredentialPlug.codex_headers("wrapped-token", meta)

    assert {"chatgpt-account-id", "wrapped-account"} in replace
    assert {"x-openai-fedramp", "true"} in replace
  end

  test "provider-owned replacements are case insensitive" do
    {replace, defaults} =
      CredentialPlug.codex_headers("wrapped-token", %{
        auth_type: "openai_oauth",
        extra_headers: [],
        metadata: %{}
      })

    headers =
      Relayixir.Proxy.Headers.merge_request_headers(
        [
          {"Authorization", "client-auth"},
          {"X-API-KEY", "client-key"},
          {"ChatGPT-Account-ID", "client-account"},
          {"X-OpenAI-FedRAMP", "client-fedramp"}
        ],
        replace,
        defaults
      )

    assert Enum.count(headers, fn {name, _} -> String.downcase(name) == "authorization" end) == 1
    assert Enum.count(headers, fn {name, _} -> String.downcase(name) == "x-api-key" end) == 0

    assert Enum.count(headers, fn {name, _} -> String.downcase(name) == "chatgpt-account-id" end) ==
             0

    assert Enum.count(headers, fn {name, _} -> String.downcase(name) == "x-openai-fedramp" end) ==
             0

    assert {"authorization", "Bearer wrapped-token"} in headers
  end
end
