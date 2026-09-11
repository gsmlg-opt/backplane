defmodule Backplane.AgentRuntime.ToolRegistry do
  @moduledoc """
  Versioned tool registry for Backplane agent runtime.
  """

  defstruct tools: %{}

  @type t :: %__MODULE__{
          tools: map()
        }

  @spec register(t(), map()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def register(%__MODULE__{} = registry, descriptor) when is_map(descriptor) do
    with {:ok, name} <- validate_name(descriptor),
         {:ok, revision} <- validate_revision(descriptor),
         {:ok, descriptor} <- validate_metadata(descriptor) do
      {:ok,
       %{
         registry
         | tools: Map.put(registry.tools, name, Map.put(descriptor, :tool_revision, revision))
       }}
    else
      {:error, %Backplane.AgentRuntime.Error{} = error} ->
        {:error, error}
    end
  end

  def register(_registry, descriptor) do
    {:error,
     Backplane.AgentRuntime.Error.new(:validation, "invalid tool descriptor",
       details: %{received: descriptor}
     )}
  end

  @spec lookup(t(), String.t()) :: {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def lookup(%__MODULE__{} = registry, name) when is_binary(name) do
    case Map.get(registry.tools, name) do
      nil ->
        {:error,
         Backplane.AgentRuntime.Error.new(:not_found, "tool is not registered",
           details: %{tool: name}
         )}

      descriptor ->
        {:ok, descriptor}
    end
  end

  def lookup(_registry, name) do
    {:error,
     Backplane.AgentRuntime.Error.new(:validation, "tool name must be a string",
       details: %{received: name}
     )}
  end

  defp validate_name(descriptor) do
    case Map.get(descriptor, :tool_name) || Map.get(descriptor, "tool_name") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, Backplane.AgentRuntime.Error.new(:validation, "tool name is required")}
    end
  end

  defp validate_metadata(descriptor) do
    safety = Map.get(descriptor, :safety)
    schema = Map.get(descriptor, :schema)

    if is_map(safety) and Map.has_key?(safety, :read_only) and
         Map.has_key?(safety, :retry_safe) and Map.has_key?(safety, :parallel_safe) do
      {:ok, Map.put(descriptor, :schema, schema)}
    else
      {:error,
       Backplane.AgentRuntime.Error.new(
         :validation,
         "tool descriptor requires read_only, retry_safe, and parallel_safe metadata"
       )}
    end
  end

  defp validate_revision(descriptor) do
    case Map.get(descriptor, :tool_revision) || Map.get(descriptor, "tool_revision") do
      revision when is_integer(revision) and revision > 0 ->
        {:ok, revision}

      _ ->
        {:error, Backplane.AgentRuntime.Error.new(:validation, "tool revision is required")}
    end
  end
end
