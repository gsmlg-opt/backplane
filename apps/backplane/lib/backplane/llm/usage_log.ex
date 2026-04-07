defmodule Backplane.LLM.UsageLog do
  @moduledoc """
  Insert-only schema for tracking LLM provider usage.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "llm_usage_logs" do
    belongs_to(:provider, Backplane.LLM.Provider, type: :binary_id)

    field(:model, :string)
    field(:status, :integer)
    field(:latency_ms, :integer)
    field(:input_tokens, :integer)
    field(:output_tokens, :integer)
    field(:stream, :boolean, default: false)
    field(:client_ip, :string)
    field(:error_reason, :string)

    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @required_fields ~w(provider_id model)a
  @optional_fields ~w(status latency_ms input_tokens output_tokens stream client_ip error_reason)a

  @doc "Changeset for inserting a usage log entry."
  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
