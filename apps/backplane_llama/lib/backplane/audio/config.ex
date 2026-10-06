defmodule Backplane.Audio.Config do
  @moduledoc false

  alias Backplane.Settings

  @enabled_key "llm.audio.enabled"
  @policy_key "llm.audio.policy"
  @voices_key "llm.audio.voices"

  @default_policy %{
    "upload_bytes" => 25_000_000,
    "multipart_overhead_bytes" => 65_536,
    "speech_json_bytes" => 65_536,
    "probe_timeout_ms" => 10_000,
    "input_duration_seconds" => 500,
    "upstream_upload_bytes" => 50_000_000,
    "conversion_timeout_ms" => 120_000,
    "request_timeout_ms" => 600_000,
    "media_processes" => 2,
    "max_sample_rate" => 96_000,
    "max_channels" => 2,
    "max_decoded_samples" => 96_000_000,
    "max_output_bytes" => 100_000_000,
    "max_provider_response_bytes" => 100_000_000,
    "max_provider_event_bytes" => 1_000_000,
    "concurrent_uploads" => 2,
    "concurrent_operations" => 4,
    "temporary_storage_bytes" => 500_000_000
  }

  def enabled?, do: Settings.get(@enabled_key) == true

  def policy do
    case Settings.get(@policy_key) do
      value when is_map(value) ->
        merged = Map.merge(@default_policy, value)
        if valid_policy?(merged), do: merged, else: @default_policy

      _ ->
        @default_policy
    end
  end

  def policy_valid? do
    case Settings.get(@policy_key) do
      nil -> true
      value when is_map(value) -> valid_policy?(Map.merge(@default_policy, value))
      _ -> false
    end
  end

  def voices do
    case Settings.get(@voices_key) do
      value when is_map(value) -> if valid_voices?(value), do: value, else: %{}
      _ -> %{}
    end
  end

  def set_enabled(value) when is_boolean(value), do: Settings.set(@enabled_key, value)
  def set_enabled(_), do: {:error, :invalid_enabled}

  def set_policy(value) when is_map(value) do
    merged = Map.merge(@default_policy, value)

    if valid_policy?(merged),
      do: Settings.set(@policy_key, merged),
      else: {:error, :invalid_policy}
  end

  def set_policy(_), do: {:error, :invalid_policy}

  # Each provider maps public names to native voice ids and may explicitly allow
  # unaliased native voice ids. No voice is silently supplied by default.
  def set_voices(value) when is_map(value) do
    if valid_voices?(value), do: Settings.set(@voices_key, value), else: {:error, :invalid_voices}
  end

  def set_voices(_), do: {:error, :invalid_voices}

  defp valid_policy?(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(@default_policy)) and
      Enum.all?(value, fn {_key, number} -> is_integer(number) and number > 0 end) and
      value["input_duration_seconds"] <= 500 and
      value["upstream_upload_bytes"] <= 50_000_000 and
      value["max_channels"] <= 8 and value["max_sample_rate"] <= 192_000 and
      value["probe_timeout_ms"] <= value["request_timeout_ms"] and
      value["conversion_timeout_ms"] <= value["request_timeout_ms"] and
      value["concurrent_uploads"] <= value["concurrent_operations"] and
      value["media_processes"] <= value["concurrent_operations"] and
      value["max_provider_event_bytes"] <= value["max_provider_response_bytes"] and
      Enum.all?(~w(upload_bytes upstream_upload_bytes max_output_bytes), fn key ->
        value[key] <= value["temporary_storage_bytes"]
      end)
  end

  defp valid_voices?(value) do
    Enum.all?(value, fn
      {provider, %{"aliases" => aliases, "allow_native" => allow_native} = policy}
      when is_binary(provider) and is_map(aliases) and is_boolean(allow_native) ->
        String.trim(provider) != "" and map_size(policy) == 2 and
          Enum.all?(aliases, fn {public, native} ->
            is_binary(public) and String.trim(public) != "" and is_binary(native) and
              String.trim(native) != ""
          end)

      _ ->
        false
    end)
  end
end
