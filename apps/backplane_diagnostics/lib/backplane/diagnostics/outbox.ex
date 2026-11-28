defmodule Backplane.Diagnostics.Outbox do
  @moduledoc "Durable work queued in the same transaction as a diagnostics event."

  import Ecto.Query

  alias Backplane.Repo

  defmodule Entry do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:event_key, :id, autogenerate: false}
    schema "diagnostics_outbox" do
      field :available_at, :utc_datetime_usec
      field :attempts, :integer, default: 0
    end
  end

  @doc false
  def insert!(event_key, available_at) do
    Repo.insert!(%Entry{event_key: event_key, available_at: available_at}, log: false)
  end

  @doc "Summarizes pending projection work without reading event bodies."
  def health do
    Entry
    |> select([entry], %{
      pending: count(entry.event_key),
      first_available_at: min(entry.available_at)
    })
    |> Repo.one()
  end
end
