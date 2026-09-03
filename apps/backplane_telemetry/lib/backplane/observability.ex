defmodule Backplane.Observability do
  @moduledoc """
  Shared Observability v2 infrastructure for Backplane.

  Provides event envelopes, correlation context, redaction, bounded buffering,
  and runtime diagnostic sinks. Domain persistence belongs to LLM/MCP apps.
  """

  alias Backplane.Observability.{Buffer, Flags}

  defdelegate enabled?(), to: Flags
  defdelegate llm_write?(), to: Flags
  defdelegate mcp_write?(), to: Flags
  defdelegate runtime_sink?(), to: Flags
  defdelegate snapshot(), to: Flags

  @doc "Returns health snapshots for runtime sinks and optional named buffers."
  @spec health() :: map()
  def health do
    %{
      flags: Flags.snapshot(),
      runtime_sink: runtime_sink_health(),
      buffers: buffer_health()
    }
  end

  defp runtime_sink_health do
    if Flags.runtime_sink?() and Process.whereis(Backplane.Observability.RuntimeSink) do
      Backplane.Observability.RuntimeSink.health()
    else
      %{status: :disabled}
    end
  end

  defp buffer_health do
    Buffer.list()
    |> Map.new(fn name -> {name, Buffer.health(name)} end)
  end
end
