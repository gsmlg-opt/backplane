defmodule Backplane.Memory.Recall.TraceCandidate do
  @moduledoc "Compact per-candidate score and selection trace. Candidate content is never stored."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @rejection_reasons ~w(diversity token_budget lifecycle duplicate below_threshold superseded disputed archived channel_error review)
  @source_types ~w(memory event observation summary request crystal lesson)
  @type t :: %__MODULE__{}
  schema "memory_recall_candidates" do
    field(:recall_run_id, :binary_id)
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:candidate_id, :binary_id)
    field(:candidate_kind, :string)
    field(:memory_type, :string)
    field(:source_ids, {:array, :binary_id})
    field(:source_refs, :map, default: %{"refs" => []})
    field(:channel_scores, :map, default: %{})
    field(:fts_rank, :integer)
    field(:vector_rank, :integer)
    field(:graph_rank, :integer)
    field(:fts_score, :float)
    field(:vector_score, :float)
    field(:graph_score, :float)
    field(:rrf_score, :float)
    field(:lifecycle_score, :float)
    field(:reranker_score, :float)
    field(:final_score, :float)
    field(:pre_reranker_rank, :integer)
    field(:post_reranker_rank, :integer)
    field(:selected, :boolean, default: false)
    field(:rejection_reason, :string)
    field(:token_estimate, :integer)
    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(recall_run_id host_id client_id scope namespace candidate_id candidate_kind memory_type source_ids source_refs channel_scores selected token_estimate)a
  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required(@required)
    |> validate_inclusion(:candidate_kind, ~w(memory lesson crystal summary observation))
    |> validate_inclusion(:memory_type, ~w(working episodic semantic procedural))
    |> validate_length(:source_ids, min: 1, max: 256)
    |> validate_number(:token_estimate,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1_000_000
    )
    |> validate_selection_truth()
    |> validate_ranks()
    |> validate_source_refs()
    |> foreign_key_constraint(:recall_run_id, name: :memory_recall_candidates_partition_fkey)
    |> unique_constraint([:recall_run_id, :candidate_id, :candidate_kind],
      name: :memory_recall_candidates_run_candidate_uniq
    )
    |> check_constraint(:source_refs, name: :memory_recall_candidates_source_refs_check)
  end

  defp validate_source_refs(changeset) do
    source_ids = get_field(changeset, :source_ids)
    source_refs = get_field(changeset, :source_refs)

    if valid_source_refs?(source_refs, source_ids) do
      changeset
    else
      add_error(changeset, :source_refs, "must exactly match typed source IDs")
    end
  end

  defp valid_source_refs?(%{"refs" => refs} = wrapper, source_ids)
       when is_list(refs) and refs != [] and length(refs) <= 256 and is_list(source_ids) and
              map_size(wrapper) == 1 do
    parsed =
      Enum.reduce_while(refs, [], fn
        %{"type" => type, "id" => id} = ref, acc
        when map_size(ref) == 2 and type in @source_types ->
          case Ecto.UUID.cast(id) do
            {:ok, uuid} -> {:cont, [uuid | acc]}
            :error -> {:halt, :error}
          end

        _invalid, _acc ->
          {:halt, :error}
      end)

    parsed != :error and MapSet.new(parsed) == MapSet.new(source_ids)
  end

  defp valid_source_refs?(_source_refs, _source_ids), do: false

  defp validate_ranks(changeset) do
    Enum.reduce(
      [:fts_rank, :vector_rank, :graph_rank, :pre_reranker_rank, :post_reranker_rank],
      changeset,
      fn field, changeset ->
        validate_number(changeset, field, greater_than: 0)
      end
    )
  end

  defp validate_selection_truth(changeset) do
    selected = get_field(changeset, :selected)
    reason = get_field(changeset, :rejection_reason)

    cond do
      selected == true and not is_nil(reason) ->
        add_error(changeset, :rejection_reason, "must be empty when selected")

      selected == false and (not is_binary(reason) or String.trim(reason) == "") ->
        add_error(changeset, :rejection_reason, "must explain an unselected candidate")

      selected == false and reason not in @rejection_reasons ->
        add_error(changeset, :rejection_reason, "is not an allowed reason")

      true ->
        changeset
    end
  end
end
