defmodule Backplane.LLM.HostServices do
  @moduledoc "Platform configuration and safe host inventories for API services."

  import Ecto.Query
  alias Backplane.LLM.HostService
  alias Backplane.Repo

  @max_services_per_host 64

  def list do
    Repo.all(from service in HostService, order_by: [asc: service.name])
  end

  def list_for_host(host_id) do
    Repo.all(
      from service in HostService, where: service.host_id == ^host_id, order_by: service.name
    )
  end

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(HostService, id)
      :error -> nil
    end
  end

  def create(attrs) do
    changeset = HostService.changeset(%HostService{}, attrs)

    if changeset.valid? do
      Repo.transaction(fn ->
        host_id = Ecto.Changeset.get_field(changeset, :host_id)

        Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "host_api_services:#{host_id}"
        ])

        count =
          Repo.aggregate(from(service in HostService, where: service.host_id == ^host_id), :count)

        if count >= @max_services_per_host do
          Repo.rollback(
            Ecto.Changeset.add_error(changeset, :host_id, "supports at most 64 API services")
          )
        end

        case Repo.insert(changeset) do
          {:ok, service} -> service
          {:error, invalid} -> Repo.rollback(invalid)
        end
      end)
      |> broadcast()
    else
      {:error, changeset}
    end
  end

  def update(%HostService{} = service, attrs) do
    service
    |> HostService.changeset(attrs)
    |> Ecto.Changeset.validate_change(:host_id, fn :host_id, host_id ->
      if host_id == service.host_id,
        do: [],
        else: [host_id: "cannot move an existing service to another host"]
    end)
    |> Ecto.Changeset.optimistic_lock(:revision)
    |> Repo.update(stale_error_field: :revision)
    |> broadcast()
  end

  def delete(%HostService{} = service) do
    service
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :llm_providers_host_service_id_fkey,
      message: "is used by an LLM provider; detach the provider first"
    )
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :embedding_providers_host_service_id_fkey,
      message: "is used by an embedding provider; detach the provider first"
    )
    |> Repo.delete()
    |> broadcast()
  end

  def snapshot(host_id) do
    host_id
    |> list_for_host()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(fn service ->
      %{
        "id" => service.id,
        "endpoints" => service.endpoints,
        "enabled" => true,
        "revision" => service.revision
      }
    end)
  end

  def endpoint(service_id, api) do
    with %HostService{enabled: true} = service <- get(service_id),
         url when is_binary(url) <- service.endpoints[to_string(api)] do
      {:ok, service, url}
    else
      %HostService{} ->
        {:error, :host_service_unavailable}

      nil ->
        case get(service_id) do
          %HostService{enabled: true} -> {:error, :unsupported_api}
          _ -> {:error, :host_service_unavailable}
        end
    end
  end

  def options(api \\ nil) do
    list()
    |> Enum.filter(&(is_nil(api) or Map.has_key?(&1.endpoints, to_string(api))))
    |> Enum.map(
      &{&1.id, "#{&1.name} (#{&1.host_id})#{if &1.enabled, do: "", else: " [disabled]"}"}
    )
  end

  defp broadcast({:ok, service} = result) do
    Phoenix.PubSub.broadcast(
      Backplane.PubSub,
      "host_api_services:#{service.host_id}",
      :host_api_services_changed
    )

    result
  end

  defp broadcast(error), do: error
end
