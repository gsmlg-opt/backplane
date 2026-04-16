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
      assert {:ok, [{"x-custom", "v"}]} = AuthInjector.inject([{"x-custom", "v"}], "none", nil, nil)
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
      assert {:ok, headers} = AuthInjector.inject([], "custom_header", "X-Service-Key", "test-api-key")
      assert {"X-Service-Key", "sk-secret-123"} in headers
    end

    test "returns error when credential not found" do
      assert {:error, :credential_unavailable} = AuthInjector.inject([], "bearer", nil, "nonexistent")
    end

    test "preserves existing headers" do
      assert {:ok, headers} = AuthInjector.inject([{"x-custom", "v"}], "bearer", nil, "test-api-key")
      assert {"x-custom", "v"} in headers
      assert {"authorization", "Bearer sk-secret-123"} in headers
    end
  end
end
