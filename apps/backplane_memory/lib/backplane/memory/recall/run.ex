defmodule Backplane.Memory.Recall.Run do
  @moduledoc "Durable, privacy-filtered execution trace for one Recall V2 request."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "memory_recall_runs" do
    field(:host_id, :string)
    field(:client_id, :string)
    field(:scope, :string)
    field(:namespace, :string)
    field(:request_id, :string)
    field(:correlation_id, :string)
    field(:query_hash, :binary)
    field(:normalized_query, :string)
    field(:query_plan, :map, default: %{})
    field(:filters, :map, default: %{})
    field(:channel_weights, :map, default: %{})
    field(:channel_availability, :map, default: %{})
    field(:channel_errors, :map, default: %{})
    field(:token_budget, :integer)
    field(:tokens_used, :integer, default: 0)
    field(:result_count, :integer, default: 0)
    field(:latency_ms, :integer)
    field(:query_embedding_model, :string)
    field(:reranker_model, :string)
    field(:reranker_provider, :string)
    field(:reranker_status, :string)
    field(:reranker_error_class, :string)
    field(:reranker_duration_ms, :integer)
    field(:status, :string, default: "running")
    field(:failure_class, :string)
    field(:terminal_digest, :binary)
    field(:completed_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(host_id client_id scope namespace request_id correlation_id query_hash query_plan filters channel_weights channel_availability channel_errors token_budget status expires_at)a
  def changeset(run, attrs) do
    run
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required(@required)
    |> validate_change(:query_hash, fn :query_hash, value ->
      if byte_size(value) == 32, do: [], else: [query_hash: "must be 32 bytes"]
    end)
    |> validate_change(:terminal_digest, fn :terminal_digest, value ->
      if byte_size(value) == 32, do: [], else: [terminal_digest: "must be 32 bytes"]
    end)
    |> validate_number(:token_budget, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:tokens_used, greater_than_or_equal_to: 0)
    |> validate_number(:result_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 500)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> validate_number(:reranker_duration_ms, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, ~w(running complete failed))
    |> validate_inclusion(
      :reranker_status,
      ~w(ok disabled unavailable empty provider_error exit timeout malformed error)
    )
    |> unique_constraint([:host_id, :client_id, :scope, :namespace, :request_id],
      name: :memory_recall_runs_partition_request_uniq
    )
    |> check_constraint(:tokens_used, name: :memory_recall_runs_counts_check)
    |> check_constraint(:status, name: :memory_recall_runs_completion_check)
  end
end
