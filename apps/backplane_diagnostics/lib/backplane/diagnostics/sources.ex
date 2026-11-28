defmodule Backplane.Diagnostics.Sources do
  @moduledoc "Trusted registration and lookup for diagnostics event producers."

  import Ecto.Query

  alias Backplane.DiagnosticsClient.Envelope
  alias Backplane.Repo

  defmodule Source do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "diagnostics_sources" do
      field :host_id, Ecto.UUID
      field :application, :string
      field :repository, :string
      field :service_instance, :string
      field :enabled, :boolean, default: true
      timestamps(type: :utc_datetime_usec)
    end
  end

  @doc "Registers a source for an authenticated host using trusted operator input."
  def register(host_id, attrs) when is_map(attrs) do
    import Ecto.Changeset

    %Source{host_id: host_id}
    |> cast(attrs, [:id, :application, :repository, :service_instance, :enabled])
    |> validate_required([:id, :host_id, :application, :enabled])
    |> validate_change(:id, fn :id, value ->
      if Envelope.id?(value), do: [], else: [id: "is not a diagnostics identifier"]
    end)
    |> validate_length(:application, min: 1, max: 128, count: :bytes)
    |> validate_length(:repository, max: 256, count: :bytes)
    |> validate_length(:service_instance, max: 128, count: :bytes)
    |> unique_constraint(:id, name: :diagnostics_sources_pkey)
    |> foreign_key_constraint(:host_id)
    |> Repo.insert(log: false)
  end

  @doc false
  def lock_for_host(host_id, source_id) do
    Source
    |> where([source], source.id == ^source_id and source.host_id == ^host_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  @doc false
  def permits_event?(%Source{enabled: true} = source, event) do
    source.application == event["application"] and
      permits?(source.repository, get_in(event, ["version", "repository"])) and
      permits?(source.service_instance, event["service_instance"])
  end

  def permits_event?(_, _), do: false

  defp permits?(nil, _), do: true
  defp permits?(registered, actual), do: registered == actual
end
