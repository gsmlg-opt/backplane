defmodule Backplane.Observability do
  @moduledoc """
  Shared Observability v2 infrastructure for Backplane.

  Provides event envelopes, correlation context, redaction, bounded buffering,
  and runtime diagnostic sinks. Domain persistence belongs to LLM/MCP apps.
  """

  alias Backplane.Observability.{Buffer, Flags, Settings}

  defdelegate enabled?(), to: Flags
  defdelegate llm_write?(), to: Flags
  defdelegate mcp_write?(), to: Flags
  defdelegate runtime_sink?(), to: Flags
  defdelegate snapshot(), to: Flags

  @doc "Returns health snapshots for runtime sinks, buffers, writers, and policy."
  @spec health() :: map()
  def health do
    %{
      flags: Flags.snapshot(),
      settings: settings_snapshot(),
      runtime_sink: runtime_sink_health(),
      buffers: buffer_health(),
      writers: writers_health()
    }
  end

  defp settings_snapshot do
    if Process.whereis(Settings) do
      Settings.snapshot()
    else
      %{status: :unavailable}
    end
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

  defp writers_health do
    %{
      llm: writer_health(Backplane.LLM.LogWriter),
      mcp: writer_health(Backplane.MCP.LogWriter),
      mcp_tool: writer_health(Backplane.MCP.ToolLogWriter)
    }
  end

  defp writer_health(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :health, 0) do
      apply(module, :health, [])
    else
      %{status: :unavailable}
    end
  catch
    :exit, _ -> %{status: :unavailable}
  end
end
