defmodule Backplane.AgentRuntime.Codex.Invocation do
  alias Backplane.AgentRuntime.{Error, InputSchema}

  @moduledoc """
  Lossless decoding of Codex function and custom/raw tool calls.

  Raw custom input is retained verbatim for approval and backend handling. A
  partial stream is never executable until `complete?/1` is true.
  """

  @spec decode(map(), map() | [map()]) :: {:ok, map()} | {:error, Error.t()}
  def decode(call, contracts) when is_map(call) do
    with {:ok, name} <- fetch_string(call, :name),
         {:ok, contract} <- fetch_contract(contracts, name),
         {:ok, raw} <- raw_arguments(call),
         {:ok, arguments} <- validate_arguments(contract, raw) do
      {:ok,
       %{
         id: Map.get(call, :id, Map.get(call, "id")),
         tool_name: contract.tool_name,
         tool_revision: contract.tool_revision,
         input_kind: contract.input_kind,
         arguments: arguments,
         raw_input: raw,
         complete?: Map.get(call, :complete?, Map.get(call, "complete?", true)),
         arguments_digest: digest(raw)
       }}
    end
  end

  def decode(_call, _contracts), do: {:error, Error.new(:validation, "tool call must be a map")}

  @spec append_chunk(map(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def append_chunk(%{raw_input: raw, complete?: false} = invocation, chunk)
      when is_binary(chunk) do
    updated = raw <> chunk
    {:ok, %{invocation | raw_input: updated, arguments_digest: digest(updated)}}
  end

  def append_chunk(_invocation, _chunk),
    do: {:error, Error.new(:resource_conflict, "cannot append to a completed tool call")}

  @spec finish(map()) :: {:ok, map()} | {:error, Error.t()}
  def finish(%{complete?: false, input_kind: :custom, raw_input: raw} = invocation) do
    {:ok, %{invocation | complete?: true, arguments: raw, arguments_digest: digest(raw)}}
  end

  def finish(%{complete?: true} = invocation), do: {:ok, invocation}

  def finish(_invocation),
    do: {:error, Error.new(:validation, "only incomplete custom calls can be finalized")}

  @spec complete?(map()) :: boolean()
  def complete?(%{complete?: value}), do: value == true
  def complete?(_), do: false

  defp fetch_contract(contracts, name) when is_map(contracts) do
    case Map.get(contracts, name) do
      nil -> {:error, Error.new(:not_found, "Codex tool is not admitted", details: %{tool: name})}
      contract -> {:ok, contract}
    end
  end

  defp fetch_contract(contracts, name) when is_list(contracts) do
    case Enum.find(contracts, &(&1.tool_name == name)) do
      nil -> {:error, Error.new(:not_found, "Codex tool is not admitted", details: %{tool: name})}
      contract -> {:ok, contract}
    end
  end

  defp fetch_contract(_contracts, _name),
    do: {:error, Error.new(:validation, "invalid Codex contract catalog")}

  defp raw_arguments(call) do
    value = Map.get(call, :arguments, Map.get(call, "arguments"))

    cond do
      is_map(value) ->
        {:ok, value}

      is_binary(value) ->
        {:ok, value}

      true ->
        {:error, Error.new(:validation, "tool call arguments must be an object or raw string")}
    end
  end

  defp validate_arguments(%{input_kind: :custom}, raw) when is_binary(raw), do: {:ok, raw}

  defp validate_arguments(%{input_kind: :custom}, _raw),
    do: {:error, Error.new(:validation, "custom tool input must be raw text")}

  defp validate_arguments(%{input_kind: :function, schema: schema}, raw) when is_map(raw) do
    case InputSchema.validate(schema, raw) do
      {:ok, arguments} -> {:ok, arguments}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_arguments(%{input_kind: :function}, _raw),
    do: {:error, Error.new(:validation, "function tool input must be an object")}

  defp fetch_string(map, key) do
    value = Map.get(map, key, Map.get(map, Atom.to_string(key)))

    if is_binary(value) and value != "",
      do: {:ok, value},
      else: {:error, Error.new(:validation, "#{key} is required")}
  end

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
end
