defmodule Backplane.LLM.UsageLog do
  @moduledoc """
  Legacy compatibility schema for `llm_logs`.

  New observability v2 code uses `Backplane.LLM.ProxyRequest`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "llm_logs" do
    belongs_to(:provider, Backplane.LLM.Provider, type: :binary_id)

    field(:event_id, :string)
    field(:operation, :string)
    field(:outcome, :string)
    field(:model, :string, source: :requested_model)
    field(:status, :integer)
    field(:latency_ms, :integer, source: :duration_ms)
    field(:input_tokens, :integer)
    field(:output_tokens, :integer)
    field(:stream, :boolean, default: false)
    field(:client_ip, :string)
    field(:error_reason, :string)

    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @required_fields ~w(provider_id model)a

  @optional_fields ~w(
    event_id operation outcome status latency_ms input_tokens output_tokens stream
    client_ip error_reason
  )a

  @doc "Changeset for legacy usage log insertion."
  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> put_legacy_defaults()
  end

  defp put_legacy_defaults(changeset) do
    changeset
    |> put_change(:event_id, get_field(changeset, :event_id) || Backplane.Observability.Id.event_id())
    |> put_change(:operation, get_field(changeset, :operation) || "legacy")
    |> put_change(:outcome, get_field(changeset, :outcome) || outcome_for_status(get_field(changeset, :status)))
  end

  defp outcome_for_status(status) when status in 200..299, do: "success"
  defp outcome_for_status(_), do: "error"
end
