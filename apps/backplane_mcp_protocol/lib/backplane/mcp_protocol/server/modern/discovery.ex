defmodule Backplane.McpProtocol.Server.Modern.Discovery do
  @moduledoc """
  Builds the raw result for the mandatory modern `server/discover` method.

  This module intentionally does not add common result metadata or cache
  fields. The executor isolates callback evaluation, then passes this map
  through `Server.Modern.Result` outside the callback failure boundary.
  """

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Server.Modern.RequestContext

  @known_capabilities ~w(experimental logging completions prompts resources tools extensions)

  @type snapshot :: %{
          required(:supported_versions) => [String.t()],
          required(:capabilities) => map(),
          optional(:instructions) => String.t() | nil
        }

  @spec execute(module() | snapshot(), RequestContext.t()) :: {:ok, map()} | {:error, Error.t()}
  def execute(server_module, %RequestContext{} = context) when is_atom(server_module) do
    snapshot = %{
      supported_versions: server_module.supported_protocol_versions(),
      capabilities: server_module.server_capabilities(),
      instructions: server_instructions(server_module)
    }

    execute(snapshot, context)
  end

  def execute(%{supported_versions: versions, capabilities: capabilities} = snapshot, %RequestContext{}) do
    instructions = Map.get(snapshot, :instructions)

    with {:ok, versions} <- modern_versions(versions),
         {:ok, capabilities} <- normalize_capabilities(capabilities),
         :ok <- validate_instructions(instructions) do
      result = %{
        "supportedVersions" => versions,
        "capabilities" => capabilities
      }

      {:ok, if(is_nil(instructions), do: result, else: Map.put(result, "instructions", instructions))}
    else
      _invalid -> {:error, Error.protocol(:internal_error)}
    end
  end

  def execute(_invalid_source, %RequestContext{}), do: {:error, Error.protocol(:internal_error)}

  defp server_instructions(server_module) do
    if Backplane.McpProtocol.exported?(server_module, :server_instructions, 0) do
      server_module.server_instructions()
    end
  end

  defp modern_versions(versions) when is_list(versions) do
    {versions, _seen} =
      Enum.reduce(versions, {[], MapSet.new()}, fn version, {accepted, seen} ->
        cond do
          not is_binary(version) or MapSet.member?(seen, version) ->
            {accepted, seen}

          modern_profile?(version) ->
            {accepted ++ [version], MapSet.put(seen, version)}

          true ->
            {accepted, seen}
        end
      end)

    {:ok, versions}
  end

  defp modern_versions(_invalid), do: :error

  defp modern_profile?(version) do
    match?({:ok, %Profile{era: :modern}}, Registry.profile(version))
  end

  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    capabilities = Map.drop(capabilities, [:tasks, "tasks"])

    with {:ok, capabilities} <- normalize_value(capabilities) do
      {legacy_completion, capabilities} = Map.pop(capabilities, "completion")

      capabilities =
        then(capabilities, fn normalized ->
          if is_nil(legacy_completion) do
            normalized
          else
            Map.put_new(normalized, "completions", legacy_completion)
          end
        end)

      if known_capabilities_are_objects?(capabilities), do: {:ok, capabilities}, else: :error
    end
  end

  defp normalize_capabilities(_invalid), do: :error

  defp normalize_value(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> if is_binary(key), do: 1, else: 0 end)
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, nested}, {:ok, acc} when is_binary(key) or is_atom(key) ->
        case normalize_value(nested) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, normalize_key(key), normalized)}}
          :error -> {:halt, :error}
        end

      _invalid, _acc ->
        {:halt, :error}
    end)
  end

  defp normalize_value(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn nested, {:ok, acc} ->
      case normalize_value(nested) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp normalize_value(value) when is_boolean(value) or is_nil(value) or is_binary(value) or is_number(value),
    do: {:ok, value}

  defp normalize_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_value(_invalid), do: :error

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp known_capabilities_are_objects?(capabilities) do
    Enum.all?(@known_capabilities, fn capability ->
      not Map.has_key?(capabilities, capability) or is_map(capabilities[capability])
    end)
  end

  defp validate_instructions(nil), do: :ok
  defp validate_instructions(instructions) when is_binary(instructions), do: :ok
  defp validate_instructions(_invalid), do: :error
end
