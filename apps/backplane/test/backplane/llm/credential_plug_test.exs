defmodule Backplane.LLM.CredentialPlugTest do
  use Backplane.DataCase, async: true

  alias Backplane.LLM.CredentialPlug
  alias Backplane.LLM.Provider
  alias Backplane.Settings.Credentials

  import Plug.Test
  import Plug.Conn

  setup do
    Credentials.store("anthropic-cred", "sk-ant-test-key-1234", "llm")
    Credentials.store("openai-cred", "sk-openai-test-key-5678", "llm")
    :ok
  end

  @anthropic_attrs %{
    name: "cred-plug-anthropic",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    credential: "anthropic-cred",
    models: ["claude-3-5-sonnet-20241022"]
  }

  @openai_attrs %{
    name: "cred-plug-openai",
    api_type: :openai,
    api_url: "https://api.openai.com",
    credential: "openai-cred",
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
      assert get_req_header(conn, "x-api-key") == ["sk-ant-test-key-1234"]
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
      assert get_req_header(conn, "authorization") == ["Bearer sk-openai-test-key-5678"]
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

  # ── No credential ────────────────────────────────────────────────────────────

  describe "inject/2 with missing credential" do
    test "returns 503 when provider has no credential" do
      # Build a provider struct directly (bypass changeset validation)
      provider = %Provider{
        api_type: :anthropic,
        credential: nil
      }

      conn = conn(:post, "/") |> CredentialPlug.inject(provider)
      assert conn.status == 503
      assert conn.halted
    end
  end

  # ── build_auth_headers/1 ──────────────────────────────────────────────────────

  describe "build_auth_headers/1" do
    test "returns anthropic headers" do
      {:ok, provider} = Provider.create(@anthropic_attrs)

      assert {:ok, headers} = CredentialPlug.build_auth_headers(provider)
      assert {"x-api-key", "sk-ant-test-key-1234"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
    end

    test "returns openai headers" do
      {:ok, provider} = Provider.create(@openai_attrs)

      assert {:ok, headers} = CredentialPlug.build_auth_headers(provider)
      assert {"authorization", "Bearer sk-openai-test-key-5678"} in headers
    end

    test "includes default_headers" do
      {:ok, provider} = Provider.create(@anthropic_attrs)

      {:ok, provider} =
        Provider.update(provider, %{default_headers: %{"X-Custom" => "val"}})

      assert {:ok, headers} = CredentialPlug.build_auth_headers(provider)
      assert {"x-custom", "val"} in headers
    end

    test "returns error when credential is missing" do
      provider = %Provider{api_type: :anthropic, credential: nil}
      assert {:error, :no_credential} = CredentialPlug.build_auth_headers(provider)
    end

    test "returns error when credential not found in store" do
      provider = %Provider{api_type: :openai, credential: "nonexistent"}
      assert {:error, :not_found} = CredentialPlug.build_auth_headers(provider)
    end
  end
end
