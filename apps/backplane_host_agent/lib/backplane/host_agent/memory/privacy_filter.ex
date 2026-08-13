defmodule Backplane.HostAgent.Memory.PrivacyFilter do
  @moduledoc "Host-local recursive privacy filter for capture payloads."

  @filter_version "1"
  @sensitive_keys ~w(authorization cookie set_cookie password passwd pwd secret client_secret token api_key access_token access_key access_key_id private_key)
  @benign_sensitive_keys ~w(token_count token_usage token_budget token_estimate authorization_status)
  @sensitive_suffix ~r/(^|_)(authorization|cookie|set_cookie|password|passwd|pwd|secret|client_secret|token|api_key|access_token|access_key|access_key_id|private_key)$/
  @private_blocks ~r/<private>.*?<\/private>/is

  @doc "Filters a payload and returns the filtered payload plus wire-format metadata."
  def filter(payload) when is_map(payload) do
    {filtered, redactions, private_blocks} = walk(payload)

    {filtered,
     %{
       "filtered" => true,
       "filter_version" => @filter_version,
       "redaction_count" => redactions,
       "private_blocks_removed" => private_blocks
     }}
  end

  defp walk(map) when is_map(map) do
    Enum.reduce(map, {%{}, 0, 0}, fn {key, value}, {acc, redactions, blocks} ->
      if secret_key?(key) do
        {Map.put(acc, key, "[REDACTED]"), redactions + 1, blocks + private_block_count(value)}
      else
        {filtered, child_redactions, child_blocks} = walk(value)
        {Map.put(acc, key, filtered), redactions + child_redactions, blocks + child_blocks}
      end
    end)
  end

  defp walk(list) when is_list(list) do
    Enum.map_reduce(list, {0, 0}, fn value, {redactions, blocks} ->
      {filtered, child_redactions, child_blocks} = walk(value)
      {filtered, {redactions + child_redactions, blocks + child_blocks}}
    end)
    |> then(fn {filtered, {redactions, blocks}} -> {filtered, redactions, blocks} end)
  end

  defp walk(value) when is_binary(value) do
    private_blocks = Regex.scan(@private_blocks, value) |> length()
    without_private = Regex.replace(@private_blocks, value, "[PRIVATE]")
    {filtered, secret_matches} = redact_secrets(without_private)
    {filtered, secret_matches, private_blocks}
  end

  defp walk(value), do: {value, 0, 0}

  defp redact_secrets(value) do
    Enum.reduce(secret_patterns(), {value, 0}, fn pattern, {current, count} ->
      matches = Regex.scan(pattern, current) |> length()
      {Regex.replace(pattern, current, "[REDACTED]"), count + matches}
    end)
  end

  defp secret_patterns do
    [
      ~r/\bsk-[A-Za-z0-9_-]{6,}\b/,
      ~r/\bAKIA[0-9A-Z]{16}\b/,
      ~r/\bgh[pohur]_[A-Za-z0-9]{36,}\b/,
      ~r/\bxox[baprs]-[A-Za-z0-9-]{6,}\b/,
      ~r/(?i)\bBearer\s+\S+/,
      ~r/(?i)(?:api[_-]?key|access[_-]?token)\s*[:=]\s*["']?[A-Za-z0-9+\/_-]{20,}["']?/,
      ~r/(?i)Authorization\s*:\s*Bearer\s+[A-Za-z0-9._~+\/-]+=*/,
      ~r/(?i)\b(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|access[_-]?token)\b\s*[:=]\s*(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}\]]+)/
    ]
  end

  defp private_block_count(map) when is_map(map) do
    Enum.reduce(map, 0, fn {_key, value}, count -> count + private_block_count(value) end)
  end

  defp private_block_count(list) when is_list(list) do
    Enum.reduce(list, 0, fn value, count -> count + private_block_count(value) end)
  end

  defp private_block_count(value) when is_binary(value) do
    @private_blocks |> Regex.scan(value) |> length()
  end

  defp private_block_count(_value), do: 0

  defp secret_key?(key) when is_binary(key) do
    normalized = normalize_secret_key(key)

    normalized not in @benign_sensitive_keys and
      (normalized in @sensitive_keys or Regex.match?(@sensitive_suffix, normalized))
  end

  defp secret_key?(key) when is_atom(key), do: key |> Atom.to_string() |> secret_key?()
  defp secret_key?(_key), do: false

  defp normalize_secret_key(key) do
    key
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.replace(~r/[^A-Za-z0-9]+/u, "_")
    |> String.downcase()
  end
end
