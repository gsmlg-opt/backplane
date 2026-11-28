defmodule Backplane.DiagnosticsClient.Redaction do
  @moduledoc "Projects diagnostics into the v1 allowlist and bounds or hides sensitive text."

  alias Backplane.DiagnosticsClient.Envelope

  @policy_version 1
  @hidden "[REDACTED]"
  @free_text ~w(message summary expected actual)
  @sensitive_patterns [
    ~r/\b(?:bearer|basic)\s+[^\s,;]+/iu,
    ~r/\b(?:authorization|proxy[\s_.-]*authorization|(?:set[\s_.-]*)?cookie|[\w.-]*token|[\w.-]*password|[\w.-]*secret|(?:x[\s_.-]*)?api[\s_.-]*key|credential|private[\s_.-]*key)\s*["']?\s*[:=]/iu,
    ~r/\b(?:prompt|messages|tool[\s_.-]*(?:arguments|result)|raw[\s_.-]*(?:request|response)|env(?:ironment)?)\s*["']?\s*[:=]/iu,
    ~r{\b[a-z][a-z0-9+.-]*://[^\s/@]*:[^\s/@]+@}iu,
    ~r/-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/u,
    ~r/\b(?:bp2_|sk-|ghp_|gho_|github_pat_|xox[baprs]-|eyJ[A-Za-z0-9_-]+\.)[A-Za-z0-9_-]{6,}/u
  ]

  def policy_version, do: @policy_version

  @doc "Takes only schema-approved fields. Empty or invalid required identity fields fail subsequent validation."
  def project(event) when is_map(event) and not is_struct(event) do
    event = Envelope.project(event, &project_text/3)

    Map.update(event, "quality", %{"redaction_policy_version" => @policy_version}, fn
      quality when is_map(quality) ->
        Map.put(quality, "redaction_policy_version", @policy_version)

      other ->
        other
    end)
  end

  @doc "Returns a bounded and filtered evidence summary."
  def summary(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 11 do
    cond do
      byte_size(value) > max_bytes -> "[TRUNCATED]"
      not String.valid?(value) -> @hidden
      sensitive?(value) -> @hidden
      true -> value
    end
  end

  defp project_text(value, key, max) when key in @free_text, do: summary(value, max)

  defp project_text(value, _key, max) do
    if byte_size(value) <= max and String.valid?(value) and not sensitive?(value),
      do: value,
      else: :omit
  end

  defp sensitive?(value), do: Enum.any?(@sensitive_patterns, &Regex.match?(&1, value))
end
