defmodule Backplane.Hub.Inspect do
  @moduledoc """
  Tool introspection: full schema, origin, health, and usage metadata for any registered tool.
  """

  alias Backplane.Metrics
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Utils

  @doc """
  Introspect a tool by its fully-qualified name.

  Returns the tool's schema, origin, upstream health, and last-called timestamp.
  """
  @spec introspect(String.t()) :: {:ok, map()} | {:error, String.t()}
  def introspect(tool_name) when is_binary(tool_name) do
    case ToolRegistry.lookup(tool_name) do
      nil ->
        {:error, "Unknown tool: #{tool_name}"}

      tool ->
        {:ok, build_introspection(tool)}
    end
  end

  defp build_introspection(tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema,
      origin: Utils.format_origin(tool.origin),
      upstream_name: upstream_name(tool),
      upstream_healthy: upstream_healthy?(tool),
      last_called_at: Metrics.last_called_at(tool.name)
    }
  end

  defp upstream_name(%{origin: {:upstream, prefix}}), do: prefix
  defp upstream_name(_), do: nil

  defp upstream_healthy?(%{upstream_pid: pid}) when is_pid(pid), do: Process.alive?(pid)
  defp upstream_healthy?(_), do: nil
end
