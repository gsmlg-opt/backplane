defmodule Backplane.Diagnostics.Analyses.Policy do
  @moduledoc false

  alias Backplane.Settings

  def load(opts) do
    override = Keyword.get(opts, :policy, %{})

    %{
      model: model(override),
      version: integer(override, :version, "policy_version", 1, 1..2_147_483_647),
      max_concurrent: integer(override, :max_concurrent, "max_concurrent", 2, 1..16),
      daily_calls: integer(override, :daily_calls, "daily_calls", 50, 0..5_000),
      daily_tokens: integer(override, :daily_tokens, "daily_tokens", 1_024_000, 0..50_000_000),
      daily_cost_micros:
        integer(override, :daily_cost_micros, "daily_cost_micros", 0, 0..10_000_000_000),
      request_cost_micros:
        integer(override, :request_cost_micros, "request_cost_micros", 0, 0..100_000_000),
      max_input_tokens:
        integer(override, :max_input_tokens, "max_input_tokens", 16_384, 1..16_384),
      max_output_tokens:
        integer(override, :max_output_tokens, "max_output_tokens", 4_096, 1..4_096),
      timeout_ms: integer(override, :timeout_ms, "timeout_ms", 300_000, 1..300_000),
      cooldown_seconds:
        integer(override, :cooldown_seconds, "cooldown_seconds", 1_800, 0..86_400),
      queue_limit: integer(override, :queue_limit, "queue_limit", 500, 1..5_000)
    }
  end

  defp model(override) do
    value = Map.get_lazy(override, :model, fn -> Settings.get("diagnostics.analysis.model") end)

    if is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
         String.trim(value) != "" do
      value
    end
  end

  defp integer(override, key, setting, default, range) do
    case Map.get_lazy(override, key, fn -> Settings.get("diagnostics.analysis." <> setting) end) do
      value when is_integer(value) -> if value in range, do: value, else: default
      _ -> default
    end
  end
end
