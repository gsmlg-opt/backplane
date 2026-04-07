defmodule Backplane.LLM.HealthCheckerTest do
  use ExUnit.Case, async: false

  alias Backplane.LLM.HealthChecker

  # The HealthChecker GenServer is started by the application supervision tree.
  # We use unique provider IDs per test to avoid interference between tests.

  describe "healthy?/1" do
    test "returns false for unknown provider" do
      refute HealthChecker.healthy?("unknown-provider-#{System.unique_integer([:positive])}")
    end

    test "returns true after mark_healthy/1" do
      provider_id = "provider-#{System.unique_integer([:positive])}"
      :ok = HealthChecker.mark_healthy(provider_id)
      assert HealthChecker.healthy?(provider_id)
    end

    test "returns false after mark_unhealthy/1" do
      provider_id = "provider-#{System.unique_integer([:positive])}"
      :ok = HealthChecker.mark_healthy(provider_id)
      :ok = HealthChecker.mark_unhealthy(provider_id)
      refute HealthChecker.healthy?(provider_id)
    end
  end
end
