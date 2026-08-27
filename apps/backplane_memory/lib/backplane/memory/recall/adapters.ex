defmodule Backplane.Memory.Recall.Adapters do
  @moduledoc "Typed adapters from durable Memory V2 retrieval rows to recall candidates."

  alias Backplane.Memory.Recall.Candidate

  defmodule SourceRef do
    @moduledoc "A typed, resolvable durable provenance reference."
    @enforce_keys [:type, :id]
    defstruct [:type, :id]
  end

  defmodule MemoryRow do
    @moduledoc "An exact-partition memory retrieval result with resolved provenance."
    @enforce_keys [:memory, :partition, :source_refs]
    defstruct [:memory, :partition, :source_refs]
  end

  defmodule SummaryRow do
    @moduledoc "A durable summary enriched by its exact partition and source events."
    @enforce_keys [:summary, :partition, :source_refs]
    defstruct [:summary, :partition, :source_refs]
  end

  defmodule ObservationRow do
    @moduledoc "A projected observation retrieval result with its source event."
    @enforce_keys [:observation, :partition, :source_refs]
    defstruct [:observation, :partition, :source_refs]
  end

  defmodule LessonRow do
    @moduledoc "An active lesson and its procedural memory in one exact partition."
    @enforce_keys [:lesson, :memory, :partition, :source_refs]
    defstruct [:lesson, :memory, :partition, :source_refs, evidence_ids: []]
  end

  @source_types [:memory, :event, :observation, :summary, :request, :crystal, :lesson]

  def memory(%MemoryRow{memory: artifact, partition: partition, source_refs: refs}) do
    with :ok <- artifact_partition(artifact, partition),
         {:ok, source_refs, source_ids} <- source_refs(refs, nil, value(artifact, :id), :memory) do
      Candidate.new(%{
        id: value(artifact, :id),
        kind: :memory,
        memory_type: value(artifact, :memory_type),
        content: value(artifact, :content),
        host_id: value(partition, :host_id),
        client_id: value(partition, :client_id),
        scope: value(partition, :scope),
        namespace: value(partition, :namespace),
        project: artifact |> value(:metadata, %{}) |> value(:project),
        session_id: value(artifact, :session_id),
        confidence: value(artifact, :confidence, 1.0),
        strength: metadata_number(artifact, :strength, 1.0),
        evidence_count: metadata_integer(artifact, :evidence_count, 0),
        source_ids: source_ids,
        source_refs: source_refs,
        lifecycle_state: value(artifact, :lifecycle_state, :active),
        channel_scores: value(artifact, :channel_scores, %{}),
        token_estimate: value(artifact, :token_estimate, estimate(value(artifact, :content))),
        inserted_at: value(artifact, :inserted_at),
        expires_at: value(artifact, :expires_at),
        application_count: value(artifact, :application_count, 0)
      })
    end
  end

  def memory(_row), do: {:error, :invalid_retrieval_row}

  def crystal(%MemoryRow{memory: artifact, partition: partition, source_refs: refs}) do
    with :ok <- artifact_partition(artifact, partition),
         true <- value(artifact, :memory_type) == "episodic",
         {:ok, source_refs, source_ids} <- source_refs(refs, nil, value(artifact, :id), :memory) do
      Candidate.new(%{
        id: value(artifact, :id),
        kind: :crystal,
        memory_type: :episodic,
        content: value(artifact, :content),
        host_id: value(partition, :host_id),
        client_id: value(partition, :client_id),
        scope: value(partition, :scope),
        namespace: value(partition, :namespace),
        project: artifact |> value(:metadata, %{}) |> value(:project),
        session_id: value(artifact, :session_id),
        confidence: value(artifact, :confidence, 1.0),
        strength: 1.0,
        evidence_count: length(source_refs),
        source_ids: source_ids,
        source_refs: source_refs,
        lifecycle_state: value(artifact, :lifecycle_state, :active),
        channel_scores: %{},
        token_estimate: estimate(value(artifact, :content)),
        inserted_at: value(artifact, :inserted_at),
        expires_at: value(artifact, :expires_at),
        application_count: 0
      })
    else
      false -> {:error, :invalid_crystal_memory}
      {:error, _reason} = error -> error
    end
  end

  def crystal(_row), do: {:error, :invalid_retrieval_row}

  def summary(%SummaryRow{summary: artifact, partition: partition, source_refs: refs}) do
    with :ok <- artifact_partition(artifact, partition),
         {:ok, source_refs, source_ids} <- source_refs(refs, :event, nil, nil) do
      Candidate.new(
        common(
          artifact,
          partition,
          :summary,
          :episodic,
          value(artifact, :id),
          source_refs,
          source_ids
        )
      )
    end
  end

  def summary(_row), do: {:error, :invalid_retrieval_row}

  def observation(%ObservationRow{observation: artifact, partition: partition, source_refs: refs}) do
    id = value(artifact, :event_id)

    with :ok <- artifact_partition(artifact, partition),
         {:ok, source_refs, [^id] = source_ids} <- source_refs(refs, :event, id, :event) do
      Candidate.new(
        common(artifact, partition, :observation, :working, id, source_refs, source_ids)
      )
    else
      {:ok, _other} -> {:error, :invalid_provenance}
      {:error, _reason} = error -> error
    end
  end

  def observation(_row), do: {:error, :invalid_retrieval_row}

  def lesson(
        %LessonRow{lesson: lesson, memory: memory, partition: partition, source_refs: refs} = row
      ) do
    with :ok <- artifact_partition(memory, partition),
         true <- value(memory, :memory_type) == "procedural",
         {:ok, lifecycle_state} <- lesson_state(value(lesson, :status)),
         {:ok, source_refs, source_ids} <- source_refs(refs, nil, value(memory, :id), :memory) do
      Candidate.new(%{
        id: value(memory, :id),
        kind: :lesson,
        memory_type: :procedural,
        content: value(memory, :content),
        host_id: value(partition, :host_id),
        client_id: value(partition, :client_id),
        scope: value(partition, :scope),
        namespace: value(partition, :namespace),
        project: memory |> value(:metadata, %{}) |> value(:project),
        session_id: value(memory, :session_id),
        confidence: value(memory, :confidence, 1.0),
        strength: max(0.0, 1.0 - value(lesson, :decay_rate, 0.0)),
        evidence_count: length(source_refs),
        source_ids: source_ids,
        evidence_ids: row.evidence_ids,
        source_refs: source_refs,
        lifecycle_state: lifecycle_state,
        channel_scores: value(memory, :channel_scores, %{}),
        token_estimate: estimate(value(memory, :content)),
        inserted_at: value(lesson, :created_at, value(memory, :inserted_at)),
        expires_at: value(memory, :expires_at),
        application_count: value(memory, :application_count, 0)
      })
    else
      false -> {:error, :invalid_lesson_memory}
      {:error, _reason} = error -> error
    end
  end

  def lesson(_row), do: {:error, :invalid_retrieval_row}

  def lessons(partition) when is_map(partition), do: validate_empty_partition(partition)
  def lessons(_partition), do: {:error, :invalid_partition}
  def crystals(partition) when is_map(partition), do: validate_empty_partition(partition)
  def crystals(_partition), do: {:error, :invalid_partition}

  defp common(artifact, partition, kind, memory_type, id, source_refs, source_ids) do
    %{
      id: id,
      kind: kind,
      memory_type: memory_type,
      content: value(artifact, :content),
      host_id: value(partition, :host_id),
      client_id: value(partition, :client_id),
      scope: value(partition, :scope),
      namespace: value(partition, :namespace),
      project: value(artifact, :project),
      session_id: value(artifact, :session_id),
      confidence: value(artifact, :confidence, 1.0),
      strength: value(artifact, :strength, 1.0),
      evidence_count: value(artifact, :evidence_count, 0),
      source_ids: source_ids,
      source_refs: source_refs,
      lifecycle_state: value(artifact, :lifecycle_state, :active),
      channel_scores: value(artifact, :channel_scores, %{}),
      token_estimate: value(artifact, :token_estimate, estimate(value(artifact, :content))),
      inserted_at:
        value(artifact, :inserted_at, value(artifact, :created_at, value(artifact, :occurred_at))),
      expires_at: value(artifact, :expires_at),
      application_count: 0
    }
  end

  defp source_refs([], _required_type, _self_id, _self_type), do: {:error, :missing_provenance}

  defp source_refs(refs, required_type, self_id, self_type)
       when is_list(refs) and length(refs) <= 256 do
    refs
    |> Enum.reduce_while({:ok, []}, fn
      %SourceRef{type: type, id: id}, {:ok, acc} when type in @source_types ->
        with {:ok, uuid} <- Ecto.UUID.cast(id),
             true <- required_type == nil or type == required_type,
             true <- self_id == nil or uuid != self_id or type == self_type do
          {:cont, {:ok, [%{type: type, id: uuid} | acc]}}
        else
          _invalid -> {:halt, {:error, :invalid_provenance}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_provenance}}
    end)
    |> case do
      {:ok, reversed} ->
        source_refs = reversed |> Enum.reverse() |> Enum.uniq()
        {:ok, source_refs, source_refs |> Enum.map(& &1.id) |> Enum.uniq()}

      error ->
        error
    end
  end

  defp source_refs(_refs, _required_type, _self_id, _self_type),
    do: {:error, :invalid_provenance}

  defp artifact_partition(artifact, partition) when is_map(partition) do
    keys = [:host_id, :client_id, :scope, :namespace]

    if Enum.all?(keys, &artifact_partition_matches?(artifact, partition, &1)),
      do: :ok,
      else: {:error, :partition_mismatch}
  end

  defp artifact_partition(_artifact, _partition), do: {:error, :invalid_partition}

  defp validate_empty_partition(partition) do
    if Enum.all?(
         [:host_id, :client_id, :scope, :namespace],
         &valid_partition_value?(value(partition, &1))
       ),
       do: {:ok, []},
       else: {:error, :invalid_partition}
  end

  defp artifact_partition_matches?(artifact, partition, key) do
    expected = value(partition, key)
    actual = value(artifact, key)

    valid_partition_value?(expected) and (is_nil(actual) or actual == expected)
  end

  defp valid_partition_value?(value), do: is_binary(value) and String.trim(value) != ""

  defp lesson_state(status)
       when status in ["candidate", "active", "disputed", "superseded", "archived"],
       do: {:ok, String.to_existing_atom(status)}

  defp lesson_state(_status), do: {:error, :invalid_lesson_state}

  defp metadata_number(row, key, default) do
    case row |> value(:metadata, %{}) |> value(key) do
      value when is_number(value) -> value
      _invalid -> default
    end
  end

  defp metadata_integer(row, key, default) do
    case row |> value(:metadata, %{}) |> value(key) do
      value when is_integer(value) -> value
      _invalid -> default
    end
  end

  defp value(map, key, default \\ nil)
  defp value(%_{} = struct, key, default), do: Map.get(struct, key, default)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default
  defp estimate(content) when is_binary(content), do: div(byte_size(content) + 3, 4)
  defp estimate(_content), do: 0
end
