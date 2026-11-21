defmodule Backplane.LLM.ResponsesWebSocket.Limits do
  @moduledoc """
  Per-connection size and transport lifecycle policy for native Responses WebSocket.

  Local default size policy uses 128 MiB (`134_217_728` bytes) for encoded messages,
  aggregate JSON key/string bytes, and single-string bytes. This is an explicit local
  policy sized to cover the announced 128 MB Codex request class without equating
  MB to MiB; an upstream peer's advertised `x-codex-websocket-max-message-bytes`
  header constrains outbound sends via `min(local, peer)`.

  Structural budgets (`max_depth`, `max_map_entries`, `max_list_length`, `max_nodes`,
  `max_response_ids`) remain independently bounded and are not scaled with message size.
  """

  @default_large_bytes 134_217_728

  @term_defaults %{
    max_depth: 320,
    max_map_entries: 5_120,
    max_list_length: 40_960,
    max_bytes: @default_large_bytes,
    max_string_bytes: @default_large_bytes,
    max_nodes: 327_680
  }

  @size_defaults Map.merge(@term_defaults, %{
                   max_message_bytes: @default_large_bytes,
                   max_response_ids: 20_480
                 })

  @transport_defaults %{
    max_lifetime_ms: :infinity,
    first_create_timeout_ms: 300_000,
    attach_timeout_ms: 5_000,
    connect_timeout_ms: 10_000,
    opening_timeout_ms: 10_000,
    write_timeout_ms: 15_000,
    submission_timeout_ms: 30_000,
    delivery_ack_timeout_ms: 15_000,
    callback_timeout_ms: 15_000,
    close_timeout_ms: 1_000,
    cleanup_timeout_ms: 2_000,
    downstream_read_timeout_ms: :infinity,
    downstream_ping_interval_ms: 30_000,
    downstream_pong_timeout_ms: 15_000,
    upstream_ping_interval_ms: 30_000,
    upstream_pong_timeout_ms: 15_000,
    upstream_idle_timeout_ms: :infinity,
    max_pending_submits: 4
  }

  @defaults Map.merge(@size_defaults, @transport_defaults)
  @term_keys Map.keys(@term_defaults)
  @infinity_allowed_keys [
    :max_lifetime_ms,
    :downstream_read_timeout_ms,
    :downstream_ping_interval_ms,
    :upstream_ping_interval_ms,
    :upstream_idle_timeout_ms
  ]
  @env_keys Map.keys(@defaults)

  @doc "Returns the complete default policy map."
  def defaults, do: @defaults

  @doc "Returns keys configurable via `BACKPLANE_RESPONSES_WS_*` environment variables."
  def env_keys, do: @env_keys

  @doc "Returns keys that accept `:infinity` (or `\"infinity\"` in environment variables)."
  def infinity_allowed_keys, do: @infinity_allowed_keys

  @doc "Returns the active per-connection snapshot of size and transport limits."
  def current do
    overrides = Application.get_env(:backplane_llama, __MODULE__, %{})
    merge(overrides)
  end

  @doc "Merges explicit overrides onto defaults, preserving lower operator limits."
  def merge(overrides) when is_map(overrides) do
    merged = Map.merge(@defaults, overrides)
    max_msg = merged.max_message_bytes

    merged
    |> cap_default_to_message(:max_bytes, overrides, max_msg)
    |> cap_default_to_message(:max_string_bytes, overrides, max_msg)
  end

  def merge(overrides) when is_list(overrides), do: overrides |> Map.new() |> merge()

  @doc "Parses and validates a single environment variable value for `key`."
  def parse_env!(key, env_name, value) when is_atom(key) and is_binary(value) do
    trimmed = String.trim(value)

    if key in @infinity_allowed_keys and String.downcase(trimmed) == "infinity" do
      :infinity
    else
      case Integer.parse(trimmed) do
        {limit, ""} when limit > 0 ->
          limit

        _ ->
          if key in @infinity_allowed_keys do
            raise ArgumentError, "#{env_name} must be a positive integer or \"infinity\""
          else
            raise ArgumentError, "#{env_name} must be a positive integer"
          end
      end
    end
  end

  def codec_options(limits) do
    [max_encoded_bytes: limits.max_message_bytes, limits: Map.take(limits, @term_keys)]
  end

  defp cap_default_to_message(merged, key, overrides, max_msg) do
    if Map.has_key?(overrides, key) or not is_integer(max_msg) do
      merged
    else
      Map.update!(merged, key, &min(&1, max_msg))
    end
  end
end
