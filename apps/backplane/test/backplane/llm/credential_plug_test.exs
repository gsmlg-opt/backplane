defmodule Backplane.LLM.CredentialPlugTest do
  use Backplane.DataCase, async: true

  alias Backplane.LLM.CredentialPlug
  alias Backplane.LLM.Provider

  import Plug.Test
  import Plug.Conn

  @anthropic_attrs %{
    name: "cred-plug-anthropic",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    api_key: "sk-ant-test-key-1234",
    models: ["claude-3-5-sonnet-20241022"]
  }

  @openai_attrs %{
    name: "cred-plug-openai",
    api_type: :openai,
    api_url: "https://api.openai.com",
    api_key: "sk-openai-test-key-5678",
    models: ["gpt-4o"]
  }

  # ── Anthropic ─────────────────────────────────────────────────────────────────

  describe "inject/2 with anthropic provider" do
    setup do
      {:ok, provider} = Provider.create(@anthropic_attrs)
      {:ok, provider: provider}
    end

    test "injects x-api-key header", %{provider: provider} do
      conn = conn(:post, "/") |> CredentialPlug.inject(provider)
      {:ok, expected_key} = Provider.decrypt_api_key(provider)
      assert get_req_header(conn, "x-api-key") == [expected_key]
    end

    test "strips authorization header", %{provider: provider} do
      conn =
        conn(:post, "/")
        |> put_req_header("authorization", "Bearer client-token")
        |> CredentialPlug.inject(provider)

      assert get_req_header(conn, "authorization") == []
    end

    test "injects anthropic-version when not present", %{provider: provider} do
      conn = conn(:post, "/") |> CredentialPlug.inject(provider)
      assert get_req_header(conn, "anthropic-version") == ["2023-06-01"]
    end

    test "preserves client anthropic-version when already present", %{provider: provider} do
      conn =
        conn(:post, "/")
        |> put_req_header("anthropic-version", "2024-01-01")
        |> CredentialPlug.inject(provider)

      assert get_req_header(conn, "anthropic-version") == ["2024-01-01"]
    end

    test "merges default_headers from provider", %{provider: provider} do
      {:ok, provider_with_headers} =
        Provider.update(provider, %{default_headers: %{"x-custom-header" => "custom-value"}})

      conn = conn(:post, "/") |> CredentialPlug.inject(provider_with_headers)
      assert get_req_header(conn, "x-custom-header") == ["custom-value"]
    end
  end

  # ── OpenAI ────────────────────────────────────────────────────────────────────

  describe "inject/2 with openai provider" do
    setup do
      {:ok, provider} = Provider.create(@openai_attrs)
      {:ok, provider: provider}
    end

    test "injects Authorization Bearer header", %{provider: provider} do
      conn = conn(:post, "/") |> CredentialPlug.inject(provider)
      {:ok, expected_key} = Provider.decrypt_api_key(provider)
      assert get_req_header(conn, "authorization") == ["Bearer #{expected_key}"]
    end

    test "strips x-api-key header", %{provider: provider} do
      conn =
        conn(:post, "/")
        |> put_req_header("x-api-key", "client-api-key")
        |> CredentialPlug.inject(provider)

      assert get_req_header(conn, "x-api-key") == []
    end

    test "merges default_headers from provider", %{provider: provider} do
      {:ok, provider_with_headers} =
        Provider.update(provider, %{default_headers: %{"x-org-id" => "org-123"}})

      conn = conn(:post, "/") |> CredentialPlug.inject(provider_with_headers)
      assert get_req_header(conn, "x-org-id") == ["org-123"]
    end
  end
end
