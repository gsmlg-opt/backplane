defmodule Backplane.AiProtocol.Validation do
  @moduledoc """
  Size, depth, field, and atom-safety boundaries for canonical contracts.

  String keys are never converted to atoms. Bounded extension maps keep their string keys.
  """

  alias Backplane.AiProtocol.Error

  @max_depth 32
  @max_map_entries 512
  @max_list_length 4_096
  @max_bytes 1_048_576
  @max_string_bytes 262_144

  @type limits :: %{
          optional(:max_depth) => pos_integer(),
          optional(:max_map_entries) => pos_integer(),
          optional(:max_list_length) => pos_integer(),
          optional(:max_bytes) => pos_integer(),
          optional(:max_string_bytes) => pos_integer()
        }

  @spec reject_unknown(map(), [atom()]) :: :ok | {:error, Error.t()}
  def reject_unknown(attrs, allowed_keys) do
    allowed_strings = MapSet.new(allowed_keys, &Atom.to_string/1)

    attrs
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn
      key, :ok when is_atom(key) ->
        if Enum.member?(allowed_keys, key) do
          {:cont, :ok}
        else
          {:halt, {:error, Error.invalid!("Unknown or invalid field: #{inspect(key)}")}}
        end

      key, :ok when is_binary(key) ->
        if MapSet.member?(allowed_strings, key) do
          {:cont, :ok}
        else
          {:halt, {:error, Error.invalid!("Unknown or invalid field: #{inspect(key)}")}}
        end

      key, :ok ->
        {:halt, {:error, Error.invalid!("Unknown or invalid field: #{inspect(key)}")}}
    end)
  end

  @spec bounded_map(term(), limits()) :: :ok | {:error, Error.t()}
  def bounded_map(value, limits \\ %{})

  def bounded_map(value, limits) when is_map(value) do
    max_entries = Map.get(limits, :max_map_entries, @max_map_entries)

    if map_size(value) <= max_entries do
      :ok
    else
      {:error, Error.invalid!("Map exceeds #{max_entries} entries")}
    end
  end

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
    case term(value, Map.get(limits, :max_depth, @max_depth), 1, {:ok, 0}, limits) do
      {:ok, _bytes} -> :ok
      error -> error
    end
  end

  @doc """
  Returns the default validation limits used by canonical constructors.
  """
  @spec default_limits() :: limits()
  def default_limits do
    %{
      max_depth: @max_depth,
      max_map_entries: @max_map_entries,
      max_list_length: @max_list_length,
      max_bytes: @max_bytes,
      max_string_bytes: @max_string_bytes
    }
  end

  defp term(value, max_depth, depth, {:ok, bytes}, limits) when is_map(value) do
    with :ok <- depth(depth, max_depth),
         :ok <-
           size(
             map_size(value),
             Map.get(limits, :max_map_entries, @max_map_entries),
             "map entries"
           ),
         {:ok, bytes} <- strings(value, bytes, limits),
         {:ok, bytes} <- values(Map.values(value), bytes, limits, max_depth, depth) do
      {:ok, bytes}
    end
  end

  defp term(value, max_depth, depth, {:ok, bytes}, limits) when is_list(value) do
    max_length = Map.get(limits, :max_list_length, @max_list_length)

    with :ok <- depth(depth, max_depth),
         :ok <- size(length(value), max_length, "list items"),
         {:ok, bytes} <- strings(value, bytes, limits),
         {:ok, bytes} <- values(value, bytes, limits, max_depth, depth) do
      {:ok, bytes}
    end
  end

  defp term(value, _max_depth, _depth, {:ok, bytes}, limits) when is_binary(value) do
    add_bytes(
      bytes,
      value,
      Map.get(limits, :max_bytes, @max_bytes),
      Map.get(limits, :max_string_bytes, @max_string_bytes)
    )
  end

  defp term(value, _max_depth, _depth, {:ok, _bytes}, _limits) when is_atom(value) do
    if value in [nil, true, false] or is_existing_atom(value) do
      {:ok, 0}
    else
      {:error, Error.invalid!("Non-existing atoms are not accepted from external input")}
    end
  end

  defp term(_value, _max_depth, _depth, {:ok, _bytes}, _limits), do: {:ok, 0}

  defp strings(map, bytes, limits) when is_map(map) do
    Enum.reduce_while(Map.keys(map), {:ok, bytes}, fn
      key, {:ok, bytes} when is_binary(key) ->
        case add_string(bytes, key, limits) do
          {:ok, bytes} -> {:cont, {:ok, bytes}}
          error -> {:halt, error}
        end

      key, _acc when is_atom(key) ->
        {:cont, :ok}

      _key, _acc ->
        {:halt, {:error, Error.invalid!("Map key must be a string")}}
    end)
  end

  defp strings(list, bytes, _limits) when is_list(list), do: {:ok, bytes}

  defp strings(_value, bytes, _limits), do: {:ok, bytes}

  defp values(values, bytes, limits, max_depth, depth) do
    Enum.reduce_while(values, {:ok, bytes}, fn value, {:ok, bytes} ->
      case term(value, max_depth, depth + 1, {:ok, bytes}, limits) do
        {:ok, bytes} -> {:cont, {:ok, bytes}}
        error -> {:halt, error}
      end
    end)
  end

  defp add_string(bytes, value, limits) do
    add_bytes(
      bytes,
      value,
      Map.get(limits, :max_bytes, @max_bytes),
      Map.get(limits, :max_string_bytes, @max_string_bytes)
    )
  end

  defp add_bytes(bytes, value, max_bytes, max_string_bytes) do
    if byte_size(value) > max_string_bytes do
      {:error, Error.invalid!("String exceeds #{max_string_bytes} bytes")}
    else
      next_bytes = bytes + byte_size(value)

      if next_bytes <= max_bytes do
        {:ok, next_bytes}
      else
        {:error, Error.invalid!("Payload exceeds #{max_bytes} bytes")}
      end
    end
  end

  defp depth(depth, max_depth) when depth <= max_depth, do: :ok

  defp depth(_depth, max_depth),
    do: {:error, Error.invalid!("Payload nesting exceeds #{max_depth} levels")}

  defp size(count, max_count, _label) when count <= max_count, do: :ok

  defp size(count, max_count, label),
    do: {:error, Error.invalid!("#{label} exceeds #{max_count}: #{count}")}

  defp is_existing_atom(atom),
    do: atom in [nil, true, false] or (is_atom(atom) and Code.ensure_loaded?(atom))
end
