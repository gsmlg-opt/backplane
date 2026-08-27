defmodule Backplane.Memory.Recall.Candidate do
  @moduledoc "A channel-independent Recall V2 candidate with explicit provenance."

  alias Backplane.Memory.Numeric

  @kinds [:memory, :lesson, :crystal, :summary, :observation]
  @memory_types [:working, :episodic, :semantic, :procedural]
  @lifecycle_states [:candidate, :active, :disputed, :superseded, :archived, :tombstoned]
  @channels [:fts, :vector, :graph, :reranker, :lifecycle, :final]
  @source_types [:memory, :event, :observation, :summary, :request, :crystal, :lesson]
  @partition [:host_id, :client_id, :scope, :namespace]
  @required @partition ++ [:id, :kind, :memory_type, :content, :source_ids]
  @optional [
    :project,
    :session_id,
    :confidence,
    :strength,
    :evidence_count,
    :channel_scores,
    :lifecycle_state,
    :token_estimate,
    :inserted_at,
    :expires_at,
    :application_count,
    :evidence_ids,
    :source_refs
  ]
  @known @required ++ @optional

  @enforce_keys @required ++
                  [
                    :confidence,
                    :strength,
                    :evidence_count,
                    :channel_scores,
                    :lifecycle_state,
                    :token_estimate,
                    :inserted_at,
                    :expires_at,
                    :application_count
                  ]
  defstruct @enforce_keys ++ [:project, :session_id, evidence_ids: [], source_refs: []]

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs = atomize(attrs)
    unknown = Map.keys(attrs) -- (@required ++ @optional)

    with [] <- Enum.sort(unknown),
         {:ok, id} <- uuid(attrs, :id),
         {:ok, kind} <- member(attrs, :kind, @kinds),
         {:ok, memory_type} <- member(attrs, :memory_type, @memory_types),
         {:ok, content} <- required_string(attrs, :content, 1_000_000),
         {:ok, host_id} <- required_string(attrs, :host_id, 512),
         {:ok, client_id} <- required_string(attrs, :client_id, 512),
         {:ok, scope} <- required_string(attrs, :scope, 512),
         {:ok, namespace} <- required_string(attrs, :namespace, 512),
         {:ok, project} <- optional_string(attrs, :project, 1_024),
         {:ok, session_id} <- optional_string(attrs, :session_id, 1_024),
         {:ok, confidence} <- unit_float(Map.get(attrs, :confidence, 1.0), :confidence),
         {:ok, strength} <- unit_float(Map.get(attrs, :strength, 1.0), :strength),
         {:ok, evidence_count} <-
           bounded_integer(Map.get(attrs, :evidence_count, 0), :evidence_count, 0, 1_000_000),
         {:ok, source_ids} <- source_ids(Map.get(attrs, :source_ids)),
         {:ok, evidence_ids} <- evidence_ids(Map.get(attrs, :evidence_ids, [])),
         {:ok, source_refs} <- source_refs(Map.get(attrs, :source_refs, []), source_ids),
         {:ok, channel_scores} <- channel_scores(Map.get(attrs, :channel_scores, %{})),
         {:ok, lifecycle_state} <-
           member(
             %{lifecycle_state: Map.get(attrs, :lifecycle_state, :active)},
             :lifecycle_state,
             @lifecycle_states
           ),
         {:ok, token_estimate} <-
           bounded_integer(
             Map.get(attrs, :token_estimate, estimate_tokens(content)),
             :token_estimate,
             0,
             1_000_000
           ),
         {:ok, inserted_at} <- timestamp(Map.get(attrs, :inserted_at), :inserted_at),
         {:ok, expires_at} <- timestamp(Map.get(attrs, :expires_at), :expires_at),
         {:ok, application_count} <-
           bounded_integer(
             Map.get(attrs, :application_count, 0),
             :application_count,
             0,
             1_000_000
           ) do
      {:ok,
       struct!(__MODULE__, %{
         id: id,
         kind: kind,
         memory_type: memory_type,
         content: content,
         host_id: host_id,
         client_id: client_id,
         scope: scope,
         namespace: namespace,
         project: project,
         session_id: session_id,
         confidence: confidence,
         strength: strength,
         evidence_count: evidence_count,
         source_ids: source_ids,
         evidence_ids: evidence_ids,
         source_refs: source_refs,
         channel_scores: channel_scores,
         lifecycle_state: lifecycle_state,
         token_estimate: token_estimate,
         inserted_at: inserted_at,
         expires_at: expires_at,
         application_count: application_count
       })}
    else
      unknown when is_list(unknown) -> {:error, {:unknown_keys, unknown}}
      {:error, _reason} = error -> error
    end
  end

  def new(_attrs), do: {:error, :invalid_candidate}

  defp atomize(attrs) do
    Map.new(attrs, fn
      {key, value} when key in @known ->
        {key, value}

      {key, value} when is_binary(key) ->
        atom = Enum.find(@known, &(Atom.to_string(&1) == key))
        {atom || key, value}

      pair ->
        pair
    end)
  end

  defp uuid(attrs, key) do
    case Ecto.UUID.cast(Map.get(attrs, key)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid, key}}
    end
  end

  defp member(attrs, key, allowed) do
    value = Map.get(attrs, key)

    value =
      if is_binary(value), do: Enum.find(allowed, &(Atom.to_string(&1) == value)), else: value

    if value in allowed, do: {:ok, value}, else: {:error, {:invalid, key}}
  end

  defp required_string(attrs, key, max_bytes) do
    case normalized_string(Map.get(attrs, key), max_bytes) do
      {:ok, ""} -> {:error, {:invalid, key}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid, key}}
    end
  end

  defp optional_string(attrs, key, max_bytes) do
    case Map.get(attrs, key) do
      nil ->
        {:ok, nil}

      value ->
        case normalized_string(value, max_bytes) do
          {:ok, ""} -> {:ok, nil}
          {:ok, normalized} -> {:ok, normalized}
          :error -> {:error, {:invalid, key}}
        end
    end
  end

  defp normalized_string(value, max_bytes) when is_binary(value) do
    if String.valid?(value) do
      normalized = value |> String.normalize(:nfc) |> String.trim()
      if byte_size(normalized) <= max_bytes, do: {:ok, normalized}, else: :error
    else
      :error
    end
  end

  defp normalized_string(_value, _max_bytes), do: :error

  defp unit_float(value, key) do
    with {:ok, value} <- Numeric.to_float(value),
         true <- Numeric.unit_interval?(value) do
      {:ok, value}
    else
      _invalid -> {:error, {:invalid, key}}
    end
  end

  defp bounded_integer(value, _key, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp bounded_integer(_value, key, _min, _max), do: {:error, {:invalid, key}}

  defp source_ids(values) when is_list(values) and values != [] and length(values) <= 256 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Ecto.UUID.cast(value) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, {:error, {:invalid, :source_ids}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp source_ids(_values), do: {:error, {:invalid, :source_ids}}

  defp evidence_ids([]), do: {:ok, []}

  defp evidence_ids(values) do
    case source_ids(values) do
      {:ok, ids} -> {:ok, ids}
      {:error, _} -> {:error, {:invalid, :evidence_ids}}
    end
  end

  defp source_refs([], _source_ids), do: {:ok, []}

  defp source_refs(refs, source_ids) when is_list(refs) and length(refs) <= 256 do
    refs
    |> Enum.reduce_while({:ok, []}, fn
      ref, {:ok, acc} when is_map(ref) ->
        type = Map.get(ref, :type, Map.get(ref, "type"))
        id = Map.get(ref, :id, Map.get(ref, "id"))

        type =
          if is_binary(type),
            do: Enum.find(@source_types, &(Atom.to_string(&1) == type)),
            else: type

        case Ecto.UUID.cast(id) do
          {:ok, uuid} when type in @source_types ->
            {:cont, {:ok, [%{type: type, id: uuid} | acc]}}

          _invalid ->
            {:halt, {:error, {:invalid, :source_refs}}}
        end

      _invalid, _acc ->
        {:halt, {:error, {:invalid, :source_refs}}}
    end)
    |> case do
      {:ok, reversed} ->
        refs = reversed |> Enum.reverse() |> Enum.uniq()
        ids = refs |> Enum.map(& &1.id) |> Enum.uniq()
        if ids == source_ids, do: {:ok, refs}, else: {:error, {:invalid, :source_refs}}

      error ->
        error
    end
  end

  defp source_refs(_refs, _source_ids), do: {:error, {:invalid, :source_refs}}

  defp channel_scores(scores) when is_map(scores) and not is_struct(scores) do
    scores =
      Map.new(scores, fn
        {key, value} when key in @channels ->
          {key, value}

        {key, value} when key in ~w(fts vector graph reranker lifecycle final) ->
          {String.to_existing_atom(key), value}

        pair ->
          pair
      end)

    if Map.keys(scores) -- @channels == [] and Enum.all?(scores, &valid_channel_score?/1),
      do: {:ok, scores},
      else: {:error, {:invalid, :channel_scores}}
  end

  defp channel_scores(_scores), do: {:error, {:invalid, :channel_scores}}

  defp valid_channel_score?({_channel, value}) when is_number(value), do: true

  defp valid_channel_score?({_channel, value}) when is_map(value) do
    allowed = [:rank, :score, "rank", "score"]

    Map.keys(value) -- allowed == [] and
      Enum.all?(value, fn
        {key, rank} when key in [:rank, "rank"] -> is_integer(rank) and rank > 0
        {key, score} when key in [:score, "score"] -> is_number(score)
      end)
  end

  defp valid_channel_score?(_pair), do: false

  defp timestamp(nil, _key), do: {:ok, nil}
  defp timestamp(%DateTime{} = value, _key), do: {:ok, value}
  defp timestamp(_value, key), do: {:error, {:invalid, key}}

  defp estimate_tokens(content), do: div(byte_size(content) + 3, 4)
end
