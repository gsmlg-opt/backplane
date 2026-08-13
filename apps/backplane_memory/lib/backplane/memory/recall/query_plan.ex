defmodule Backplane.Memory.Recall.QueryPlan do
  @moduledoc "Typed, partition-complete input to the Recall V2 pipeline."

  alias Backplane.Memory.Privacy.Filter

  @channels [:fts, :vector, :graph]
  @allowed_keys [
    :query,
    :host_id,
    :client_id,
    :scope,
    :namespace,
    :project,
    :facets,
    :temporal_hints,
    :entity_hints,
    :include_working,
    :channel_weights,
    :token_budget
  ]
  @temporal_keys ~w(after before at)

  @enforce_keys [
    :normalized_query,
    :query_hash,
    :host_id,
    :client_id,
    :scope,
    :namespace,
    :facets,
    :entity_hints,
    :include_working,
    :channel_weights,
    :token_budget
  ]
  defstruct @enforce_keys ++ [:project, :temporal_hints]

  @type channel :: :fts | :vector | :graph
  @type t :: %__MODULE__{
          normalized_query: String.t(),
          query_hash: binary(),
          host_id: String.t(),
          client_id: String.t(),
          scope: String.t(),
          namespace: String.t(),
          project: String.t() | nil,
          facets: [map()],
          temporal_hints: map() | nil,
          entity_hints: [String.t()],
          channel_weights: %{channel() => float()},
          token_budget: pos_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs = atomize_known_keys(attrs)
    unknown = Map.keys(attrs) -- @allowed_keys

    with [] <- Enum.sort(unknown),
         {:ok, normalized_query} <- normalized_required(attrs, :query, 16_384),
         {:ok, host_id} <- normalized_required(attrs, :host_id, 512),
         {:ok, client_id} <- normalized_required(attrs, :client_id, 512),
         {:ok, scope} <- normalized_required(attrs, :scope, 512),
         {:ok, namespace} <- normalized_required(attrs, :namespace, 512),
         {:ok, project} <- optional_string(attrs, :project, 1_024),
         {:ok, facets} <- facets(Map.get(attrs, :facets, [])),
         {:ok, temporal_hints} <- temporal_hints(Map.get(attrs, :temporal_hints)),
         {:ok, entity_hints} <- entity_hints(Map.get(attrs, :entity_hints, [])),
         {:ok, include_working} <-
           boolean(Map.get(attrs, :include_working, false), :include_working),
         {:ok, channel_weights} <-
           channel_weights(Map.get(attrs, :channel_weights, default_weights())),
         {:ok, token_budget} <- token_budget(Map.get(attrs, :token_budget, default_budget())) do
      {:ok,
       %__MODULE__{
         normalized_query: normalized_query,
         query_hash: :crypto.hash(:sha256, normalized_query),
         host_id: host_id,
         client_id: client_id,
         scope: scope,
         namespace: namespace,
         project: project,
         facets: facets,
         temporal_hints: temporal_hints,
         entity_hints: entity_hints,
         include_working: include_working,
         channel_weights: channel_weights,
         token_budget: token_budget
       }}
    else
      unknown when is_list(unknown) -> {:error, {:unknown_keys, unknown}}
      {:error, _reason} = error -> error
    end
  end

  def new(_attrs), do: {:error, :invalid_query_plan}

  @doc "Privacy-filtered trace form; the caller's raw query is never represented."
  @spec trace(t()) :: map()
  def trace(%__MODULE__{} = plan) do
    trace = %{
      "normalized_query" => plan.normalized_query,
      "query_hash" => Base.encode16(plan.query_hash, case: :lower),
      "partition" => %{
        "host_id" => plan.host_id,
        "client_id" => plan.client_id,
        "scope" => plan.scope,
        "namespace" => plan.namespace
      },
      "project" => plan.project,
      "facets" => plan.facets,
      "temporal_hints" => plan.temporal_hints,
      "entity_hints" => plan.entity_hints,
      "include_working" => plan.include_working,
      "channel_weights" => stringify_keys(plan.channel_weights),
      "token_budget" => plan.token_budget
    }

    {:ok, filtered} = Filter.apply_payload(trace)
    filtered
  end

  defp atomize_known_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when key in @allowed_keys ->
        {key, value}

      {key, value} when is_binary(key) ->
        atom = Enum.find(@allowed_keys, &(Atom.to_string(&1) == key))
        {atom || key, value}

      pair ->
        pair
    end)
  end

  defp normalized_required(attrs, key, max_bytes) do
    case normalize_string(Map.get(attrs, key), max_bytes) do
      {:ok, value} when value != "" -> {:ok, value}
      _invalid -> {:error, {:invalid, key}}
    end
  end

  defp optional_string(attrs, key, max_bytes) do
    case Map.get(attrs, key) do
      nil ->
        {:ok, nil}

      value ->
        case normalize_string(value, max_bytes) do
          {:ok, ""} -> {:ok, nil}
          {:ok, normalized} -> {:ok, normalized}
          :error -> {:error, {:invalid, key}}
        end
    end
  end

  defp normalize_string(value, max_bytes) when is_binary(value) do
    if String.valid?(value) do
      normalized =
        value
        |> String.normalize(:nfc)
        |> String.replace(~r/[\s\p{Z}]+/u, " ")
        |> String.trim()

      if byte_size(normalized) <= max_bytes, do: {:ok, normalized}, else: :error
    else
      :error
    end
  end

  defp normalize_string(_value, _max_bytes), do: :error

  defp facets(values) when is_list(values) and length(values) <= 32 do
    values
    |> Enum.reduce_while({:ok, []}, fn
      %{"dimension" => dimension, "value" => value} = facet, {:ok, acc}
      when map_size(facet) == 2 ->
        with {:ok, dimension} <- nonempty_string(dimension, 128),
             {:ok, value} <- nonempty_string(value, 512) do
          {:cont, {:ok, [%{"dimension" => dimension, "value" => value} | acc]}}
        else
          :error -> {:halt, {:error, {:invalid, :facets}}}
        end

      _invalid, _acc ->
        {:halt, {:error, {:invalid, :facets}}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp facets(_values), do: {:error, {:invalid, :facets}}

  defp temporal_hints(nil), do: {:ok, nil}

  defp temporal_hints(hints) when is_map(hints) and not is_struct(hints) do
    if map_size(hints) in 1..3 and Enum.all?(Map.keys(hints), &(&1 in @temporal_keys)) do
      Enum.reduce_while(hints, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case normalize_time(value) do
          {:ok, timestamp} -> {:cont, {:ok, Map.put(acc, key, timestamp)}}
          :error -> {:halt, {:error, {:invalid, :temporal_hints}}}
        end
      end)
    else
      {:error, {:invalid, :temporal_hints}}
    end
  end

  defp temporal_hints(_hints), do: {:error, {:invalid, :temporal_hints}}

  defp normalize_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
      _invalid -> :error
    end
  end

  defp normalize_time(_value), do: :error

  defp boolean(value, _key) when is_boolean(value), do: {:ok, value}
  defp boolean(_value, key), do: {:error, {:invalid, key}}

  defp entity_hints(values) when is_list(values) and length(values) <= 32 do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case nonempty_string(value, 512) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, {:invalid, :entity_hints}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp entity_hints(_values), do: {:error, {:invalid, :entity_hints}}

  defp channel_weights(weights) when is_map(weights) and not is_struct(weights) do
    weights = atomize_channels(weights)

    if map_size(weights) > 0 and Map.keys(weights) -- @channels == [] do
      normalized = Map.new(@channels, &{&1, numeric(Map.get(weights, &1, 0.0))})

      if Enum.all?(normalized, fn {_channel, value} -> value >= 0.0 and value <= 100.0 end) and
           Enum.any?(normalized, fn {_channel, value} -> value > 0.0 end) do
        {:ok, normalized}
      else
        {:error, {:invalid, :channel_weights}}
      end
    else
      {:error, {:invalid, :channel_weights}}
    end
  rescue
    ArgumentError -> {:error, {:invalid, :channel_weights}}
  end

  defp channel_weights(_weights), do: {:error, {:invalid, :channel_weights}}

  defp atomize_channels(weights) do
    Map.new(weights, fn
      {key, value} when key in @channels -> {key, value}
      {key, value} when key in ["fts", "vector", "graph"] -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp numeric(value) when is_integer(value), do: value / 1
  defp numeric(value) when is_float(value) and value == value, do: value
  defp numeric(_value), do: raise(ArgumentError)

  defp token_budget(value) when is_integer(value) and value in 1..100_000, do: {:ok, value}
  defp token_budget(_value), do: {:error, {:invalid, :token_budget}}

  defp nonempty_string(value, max_bytes) do
    case normalize_string(value, max_bytes) do
      {:ok, ""} -> :error
      result -> result
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp default_weights do
    if Code.ensure_loaded?(Backplane.Memory.Config),
      do: Backplane.Memory.Config.recall_channel_weights(),
      else: %{fts: 1.0, vector: 1.0, graph: 1.0}
  end

  defp default_budget do
    if Code.ensure_loaded?(Backplane.Memory.Config),
      do: Backplane.Memory.Config.recall_token_budget(),
      else: 4_096
  end
end
