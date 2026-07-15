defmodule Backplane.Proxy.AuthInjectorTest do
  use Backplane.DataCase, async: true

  alias Backplane.Proxy.AuthInjector
  alias Backplane.Settings.Credentials

  setup do
    Credentials.store("test-api-key", "sk-secret-123", "upstream")
    :ok
  end

  describe "inject/4" do
    test "returns headers unchanged for auth_scheme=none" do
      assert {:ok, []} = AuthInjector.inject([], "none", nil, nil)
    end

    test "returns headers unchanged when credential is nil" do
      assert {:ok, [{"x-custom", "v"}]} =
               AuthInjector.inject([{"x-custom", "v"}], "none", nil, nil)
    end

    test "adds Authorization: Bearer for bearer scheme" do
      assert {:ok, headers} = AuthInjector.inject([], "bearer", nil, "test-api-key")
      assert {"authorization", "Bearer sk-secret-123"} in headers
    end

    test "adds X-Api-Key for x_api_key scheme" do
      assert {:ok, headers} = AuthInjector.inject([], "x_api_key", nil, "test-api-key")
      assert {"x-api-key", "sk-secret-123"} in headers
    end

    test "adds custom header for custom_header scheme" do
      assert {:ok, headers} =
               AuthInjector.inject([], "custom_header", "X-Service-Key", "test-api-key")

      assert {"X-Service-Key", "sk-secret-123"} in headers
    end

    test "returns error when credential not found" do
      assert {:error, :credential_unavailable} =
               AuthInjector.inject([], "bearer", nil, "nonexistent")
    end

    test "preserves existing headers" do
      assert {:ok, headers} =
               AuthInjector.inject([{"x-custom", "v"}], "bearer", nil, "test-api-key")

      assert {"x-custom", "v"} in headers
      assert {"authorization", "Bearer sk-secret-123"} in headers
    end

    test "injects one shared Figma OAuth token for every upstream request" do
      assert {:ok, _credential} =
               Credentials.store_oauth_token(
                 "figma-mcp",
                 "figma_oauth",
                 %{
                   access_token: "figma-shared-access",
                   refresh_token: "figma-shared-refresh",
                   expires_at: System.system_time(:millisecond) + 3_600_000
                 },
                 "upstream",
                 %{}
               )

      for caller_header <- ["backplane-caller-a", "backplane-caller-b"] do
        assert {:ok, headers} =
                 AuthInjector.inject(
                   [{"x-test-caller", caller_header}],
                   "bearer",
                   nil,
                   "figma-mcp"
                 )

        assert {"x-test-caller", caller_header} in headers
        assert {"authorization", "Bearer figma-shared-access"} in headers
      end
    end
  end
end
