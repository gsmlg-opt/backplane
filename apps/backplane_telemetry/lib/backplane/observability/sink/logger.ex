defmodule Backplane.Observability.Sink.Logger do
  @moduledoc false

  require Logger

  @doc "Writes a sanitized runtime log line for an observability event."
  @spec log(map()) :: :ok
  def log(event) when is_map(event) do
    level = level(event)
    metadata = logger_metadata(event)

    Logger.log(level, format(event), metadata)
    :ok
  end

  defp level(%{phase: :exception}), do: :error
  defp level(%{severity: severity}) when severity in [:debug, :info, :warning, :error], do: severity
  defp level(_), do: :info

  defp logger_metadata(event) do
    context = Map.get(event, :context, %{})
    attributes = Map.get(event, :attributes, %{})

    [
      domain: event[:domain],
      operation: event[:operation],
      phase: event[:phase],
      request_id: context[:request_id] || context["request_id"],
      trace_id: context[:trace_id] || context["trace_id"],
      span_id: context[:span_id] || context["span_id"],
      client_id: context[:client_id] || context["client_id"],
      tool: attributes[:tool] || attributes["tool"],
      provider: attributes[:provider] || attributes["provider"],
      upstream: attributes[:upstream] || attributes["upstream"],
      outcome: attributes[:outcome] || attributes["outcome"],
      duration_ms: event[:measurements][:duration_ms] || event[:measurements]["duration_ms"],
      error_kind: event[:error][:kind] || event[:error]["kind"]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp format(event) do
    domain = event[:domain]
    operation = event[:operation]
    phase = event[:phase]
    outcome = get_in(event, [:attributes, :outcome]) || get_in(event, [:attributes, "outcome"])

    ["Observability", domain, operation, phase, outcome]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
  end
end
