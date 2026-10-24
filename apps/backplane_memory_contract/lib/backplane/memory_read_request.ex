defmodule Backplane.MemoryReadRequest do
  @moduledoc "Process-free validation of public Memory read arguments before authority injection."

  alias Backplane.{MemoryRepository, MemoryToolContract}

  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @source_keys ~w(repository_id checkout_root cwd)

  @spec validate(String.t(), map()) :: {:ok, map()} | {:error, :invalid_arguments}
  def validate(method, args)
      when method in ~w(recall list get) and is_map(args) and not is_struct(args) do
    schema = MemoryToolContract.tool!("memory::" <> method).input_schema

    with {:ok, args} <- stringify_keys(args),
         true <- valid_object?(args, Map.put(schema, "additionalProperties", false)),
         true <- valid_pagination?(args),
         {:ok, args} <- normalize_selector(args),
         {:ok, args} <- normalize_read(method, args) do
      {:ok, args}
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  def validate("memory::" <> method, args), do: validate(method, args)
  def validate(_method, _args), do: {:error, :invalid_arguments}

  @spec normalize_project(term()) :: {:ok, String.t() | nil} | {:error, :invalid_arguments}
  def normalize_project(nil), do: {:ok, nil}

  def normalize_project(value) do
    case normalize_string(value, 1_024) do
      {:ok, ""} -> {:ok, nil}
      result -> result
    end
  end

  defp stringify_keys(args) do
    Enum.reduce_while(args, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      if is_binary(key) and not Map.has_key?(acc, key),
        do: {:cont, {:ok, Map.put(acc, key, value)}},
        else: {:halt, {:error, :invalid_arguments}}
    end)
  end

  defp normalize_read("get", args) do
    with {:ok, id} <- uuid(args["id"]),
         {:ok, args} <- optional_project(args, true),
         {:ok, args} <- optional_source(args) do
      {:ok, Map.put(args, "id", id)}
    end
  end

  defp normalize_read("list", args), do: {:ok, args}

  defp normalize_read("recall", args) do
    with {:ok, query} <- nonempty(args["query"], 16_384),
         {:ok, args} <- optional_project(args, false),
         {:ok, args} <- normalize_optional(args, "facets", &normalize_facets/1),
         {:ok, args} <- normalize_optional(args, "entity_hints", &normalize_entities/1),
         {:ok, args} <- normalize_optional(args, "temporal_hints", &normalize_temporal/1),
         true <- valid_budget?(args),
         true <- valid_weights?(args) do
      {:ok, Map.put(args, "query", query)}
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  defp valid_object?(args, schema) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    Enum.all?(required, &Map.has_key?(args, &1)) and
      (schema["additionalProperties"] != false or Map.keys(args) -- Map.keys(properties) == []) and
      map_size(args) >= Map.get(schema, "minProperties", 0) and
      Enum.all?(args, fn {key, value} -> valid_value?(value, properties[key]) end)
  end

  defp valid_value?(value, %{"type" => "object"} = schema),
    do: is_map(value) and not is_struct(value) and valid_object?(value, schema)

  defp valid_value?(value, %{"type" => "array"} = schema),
    do: is_list(value) and Enum.all?(value, &valid_value?(&1, schema["items"]))

  defp valid_value?(value, %{"type" => "string"}),
    do: is_binary(value) and String.valid?(value)

  defp valid_value?(value, %{"type" => "integer"}), do: is_integer(value)
  defp valid_value?(value, %{"type" => "number"}), do: is_number(value)
  defp valid_value?(value, %{"type" => "boolean"}), do: is_boolean(value)
  defp valid_value?(_value, nil), do: true
  defp valid_value?(_value, _schema), do: false

  defp valid_pagination?(args),
    do:
      Enum.all?(~w(limit offset), fn key ->
        not Map.has_key?(args, key) or (is_integer(args[key]) and args[key] >= 0)
      end)

  defp normalize_selector(args), do: normalize_optional(args, "memory_access_id", &uuid/1)

  defp uuid(value) when is_binary(value) do
    if Regex.match?(@uuid, value),
      do: {:ok, String.downcase(value)},
      else: {:error, :invalid_arguments}
  end

  defp uuid(_value), do: {:error, :invalid_arguments}

  defp optional_project(args, required_nonempty?) do
    with {:ok, args} <-
           normalize_optional(args, "project", fn value ->
             case normalize_project(value) do
               {:ok, nil} when required_nonempty? -> {:error, :invalid_arguments}
               result -> result
             end
           end) do
      if args["project"] == nil, do: {:ok, Map.delete(args, "project")}, else: {:ok, args}
    end
  end

  defp optional_source(args) do
    normalize_optional(args, "source", fn source ->
      valid? =
        is_map(source) and not is_struct(source) and map_size(source) > 0 and
          Map.keys(source) -- @source_keys == [] and
          Enum.all?(source, fn {_key, value} ->
            is_binary(value) and String.valid?(value) and byte_size(value) <= 4_096 and
              String.trim(value) != ""
          end)

      if valid? do
        normalized = source |> List.wrap() |> MemoryRepository.sources() |> List.first()

        if normalized && Enum.all?(Map.keys(source), &is_binary(normalized[&1])),
          do: {:ok, Map.take(normalized, Map.keys(source))},
          else: {:error, :invalid_arguments}
      else
        {:error, :invalid_arguments}
      end
    end)
  end

  defp normalize_optional(args, key, normalizer) do
    case Map.fetch(args, key) do
      :error ->
        {:ok, args}

      {:ok, value} ->
        with {:ok, normalized} <- normalizer.(value) do
          if key == "temporal_hints" and is_nil(normalized),
            do: {:ok, Map.delete(args, key)},
            else: {:ok, Map.put(args, key, normalized)}
        end
    end
  end

  defp normalize_string(value, max_bytes) when is_binary(value) do
    if String.valid?(value) do
      normalized =
        value |> String.normalize(:nfc) |> String.replace(~r/[\s\p{Z}]+/u, " ") |> String.trim()

      if byte_size(normalized) <= max_bytes,
        do: {:ok, normalized},
        else: {:error, :invalid_arguments}
    else
      {:error, :invalid_arguments}
    end
  end

  defp normalize_string(_value, _max_bytes), do: {:error, :invalid_arguments}

  defp nonempty(value, max_bytes) do
    case normalize_string(value, max_bytes) do
      {:ok, ""} -> {:error, :invalid_arguments}
      result -> result
    end
  end

  defp normalize_facets(values) when length(values) <= 32 do
    normalize_items(values, fn
      %{"dimension" => dimension, "value" => value} = facet when map_size(facet) == 2 ->
        with {:ok, dimension} <- nonempty(dimension, 128),
             {:ok, value} <- nonempty(value, 512),
             do: {:ok, %{"dimension" => dimension, "value" => value}}

      _ ->
        {:error, :invalid_arguments}
    end)
  end

  defp normalize_facets(_values), do: {:error, :invalid_arguments}

  defp normalize_entities(values) when length(values) <= 32 do
    with {:ok, values} <- normalize_items(values, &nonempty(&1, 512)),
         do: {:ok, Enum.uniq(values)}
  end

  defp normalize_entities(_values), do: {:error, :invalid_arguments}

  defp normalize_items(values, normalizer) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalizer.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp normalize_temporal(hints) when map_size(hints) == 0, do: {:ok, nil}

  defp normalize_temporal(hints) do
    if Map.keys(hints) -- ~w(after before at) == [] do
      hints
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case is_binary(value) && DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} ->
            {:cont, {:ok, Map.put(acc, key, DateTime.to_iso8601(datetime))}}

          _ ->
            {:halt, {:error, :invalid_arguments}}
        end
      end)
    else
      {:error, :invalid_arguments}
    end
  end

  defp valid_budget?(args),
    do: not Map.has_key?(args, "token_budget") or args["token_budget"] in 1..100_000

  defp valid_weights?(%{"channel_weights" => weights}) do
    map_size(weights) > 0 and Map.keys(weights) -- ~w(fts vector graph) == [] and
      Enum.all?(weights, fn {_key, value} -> is_number(value) and value >= 0 and value <= 100 end) and
      Enum.any?(weights, fn {_key, value} -> value > 0 end)
  end

  defp valid_weights?(_args), do: true
end
