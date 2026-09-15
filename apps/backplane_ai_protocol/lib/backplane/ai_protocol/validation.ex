defmodule Backplane.AiProtocol.Validation do
  @moduledoc """
  Structural limits for portable protocol values.

  These limits apply after decoding. Encoded JSON is bounded separately by
  `Backplane.AiProtocol.Serialization.from_json/2`.
  """

  alias Backplane.AiProtocol.Error

  @defaults %{
    max_depth: 32,
    max_map_entries: 512,
    max_list_length: 4_096,
    max_bytes: 1_048_576,
    max_string_bytes: 262_144,
    max_nodes: 16_384
  }

  @type limits :: %{optional(atom()) => pos_integer()}

  @spec reject_unknown(map(), [atom()]) :: :ok | {:error, Error.t()}
  def reject_unknown(attrs, allowed_keys) do
    allowed_strings = MapSet.new(allowed_keys, &Atom.to_string/1)

    Enum.reduce_while(Map.keys(attrs), :ok, fn
      key, :ok when is_atom(key) -> continue_if(key in allowed_keys, key)
      key, :ok when is_binary(key) -> continue_if(MapSet.member?(allowed_strings, key), key)
      key, :ok -> {:halt, {:error, Error.invalid!("Unknown or invalid field: #{inspect(key)}")}}
    end)
  end

  @spec bounded_map(term(), limits()) :: :ok | {:error, Error.t()}
  def bounded_map(value, limits \\ %{})
  def bounded_map(value, limits) when is_map(value), do: term(value, limits)
  def bounded_map(_value, _limits), do: {:error, Error.invalid!("Expected a map")}

  @spec bounded_extension(String.t(), term(), limits()) :: :ok | {:error, Error.t()}
  def bounded_extension(name, value, limits \\ %{}) do
    if is_binary(name) and
         String.match?(name, ~r/^[a-z][a-z0-9_-]{0,63}(::[a-z][a-z0-9_-]{0,63})+$/) do
      term(value, limits)
    else
      {:error, Error.invalid!("Extension container must use a namespaced key")}
    end
  end

  @spec term(term(), limits()) :: :ok | {:error, Error.t()}
  def term(value, limits \\ %{}) do
    case walk(value, 1, %{bytes: 0, nodes: 0}, Map.merge(@defaults, limits)) do
      {:ok, _budget} -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  @spec default_limits() :: limits()
  def default_limits, do: @defaults

  defp walk(value, depth, budget, limits) when is_map(value) and not is_struct(value) do
    with :ok <- within(depth, limits.max_depth, "Payload nesting", "levels"),
         :ok <- within(map_size(value), limits.max_map_entries, "Map", "entries"),
         {:ok, budget} <- add_node(budget, limits),
         {:ok, budget} <- map_keys(Map.keys(value), budget, limits) do
      values(Map.values(value), depth, budget, limits)
    end
  end

  defp walk(value, depth, budget, limits) when is_list(value) do
    with :ok <- within(depth, limits.max_depth, "Payload nesting", "levels"),
         :ok <- within(length(value), limits.max_list_length, "List", "items"),
         {:ok, budget} <- add_node(budget, limits) do
      values(value, depth, budget, limits)
    end
  end

  defp walk(value, _depth, budget, limits) when is_binary(value) do
    with {:ok, budget} <- add_node(budget, limits), do: add_bytes(budget, value, limits)
  end

  defp walk(value, _depth, budget, limits)
       when is_integer(value) or is_float(value) or value in [nil, true, false],
       do: add_node(budget, limits)

  defp walk(%module{}, _depth, _budget, _limits),
    do: {:error, Error.invalid!("Unsupported struct: #{inspect(module)}")}

  defp walk(value, _depth, _budget, _limits) when is_atom(value),
    do: {:error, Error.invalid!("Atoms are not portable values: #{inspect(value)}")}

  defp walk(value, _depth, _budget, _limits),
    do: {:error, Error.invalid!("Unsupported portable value: #{inspect_type(value)}")}

  defp map_keys(keys, budget, limits) do
    Enum.reduce_while(keys, {:ok, budget}, fn
      key, {:ok, budget} when is_binary(key) ->
        case add_bytes(budget, key, limits) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end

      key, {:ok, budget} when is_atom(key) ->
        case add_bytes(budget, Atom.to_string(key), limits) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end

      key, _acc ->
        {:halt, {:error, Error.invalid!("Map key must be a string, got: #{inspect(key)}")}}
    end)
  end

  defp values(values, depth, budget, limits) do
    Enum.reduce_while(values, {:ok, budget}, fn value, {:ok, budget} ->
      case walk(value, depth + 1, budget, limits) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp add_node(%{nodes: nodes} = budget, %{max_nodes: max}) when nodes + 1 <= max,
    do: {:ok, %{budget | nodes: nodes + 1}}

  defp add_node(_budget, %{max_nodes: max}),
    do: {:error, Error.invalid!("Payload exceeds #{max} nodes")}

  defp add_bytes(%{bytes: bytes} = budget, value, limits) do
    cond do
      not String.valid?(value) ->
        {:error, Error.invalid!("String is not valid UTF-8")}

      byte_size(value) > limits.max_string_bytes ->
        {:error, Error.invalid!("String exceeds #{limits.max_string_bytes} bytes")}

      bytes + byte_size(value) > limits.max_bytes ->
        {:error, Error.invalid!("Payload exceeds #{limits.max_bytes} bytes")}

      true ->
        {:ok, %{budget | bytes: bytes + byte_size(value)}}
    end
  end

  defp within(value, max, _label, _unit) when value <= max, do: :ok

  defp within(value, max, label, unit),
    do: {:error, Error.invalid!("#{label} exceeds #{max} #{unit}: #{value}")}

  defp continue_if(true, _key), do: {:cont, :ok}

  defp continue_if(false, key),
    do: {:halt, {:error, Error.invalid!("Unknown or invalid field: #{inspect(key)}")}}

  defp inspect_type(value) when is_function(value), do: "function"
  defp inspect_type(value) when is_pid(value), do: "pid"
  defp inspect_type(value) when is_reference(value), do: "reference"
  defp inspect_type(value) when is_tuple(value), do: "tuple"
  defp inspect_type(_value), do: "term"
end
