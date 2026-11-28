defmodule Backplane.HostAgent.Diagnostics.Supervisor do
  @moduledoc false

  use Supervisor

  alias Backplane.DiagnosticsClient.{Envelope, Receipt, Redaction}
  alias Backplane.HostAgent.Diagnostics.{Spool, Uploader}
  alias Backplane.HostAgent.Diagnostics.Collectors.Runner

  @runtime Backplane.HostAgent.Diagnostics.RuntimeSupervisor

  def ensure_started(%{enabled: true} = config, previous) do
    if is_pid(previous) and Process.alive?(previous) do
      previous
    else
      case DynamicSupervisor.start_child(@runtime, {__MODULE__, config}) do
        {:ok, child} -> child
        {:error, _} -> nil
      end
    end
  end

  def ensure_started(_config, _previous), do: nil

  def stop(child) when is_pid(child), do: DynamicSupervisor.terminate_child(@runtime, child)
  def stop(_child), do: :ok

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary,
      type: :supervisor
    }
  end

  def start_link(config), do: Supervisor.start_link(__MODULE__, config)

  @impl true
  def init(config) do
    spool_opts =
      config
      |> Map.take([:path, :max_bytes, :source_max_bytes, :disk_max_bytes, :max_age_seconds])
      |> Map.to_list()

    uploader_opts = Keyword.new(Map.take(config, [:delivery_enabled, :interval_ms]))

    children = [
      {Spool, [name: Spool] ++ spool_opts},
      {Uploader, [name: Uploader] ++ uploader_opts}
    ]

    Supervisor.init(children ++ collector_children(config), strategy: :rest_for_one)
  end

  defp collector_children(%{collector_targets: [_ | _] = targets} = config) do
    [
      {Runner,
       targets: targets,
       cursor_path: config.path <> ".cursors",
       docker_socket: config.docker_socket,
       emit: fn source_id, observation ->
         emit_observation(config.sources, source_id, observation)
       end}
    ]
  end

  defp collector_children(_), do: []

  defp emit_observation(sources, source_id, %{id: id, fields: fields}) do
    with %{enabled: true} = source <- Map.get(sources, source_id),
         event <- collector_event(source, id, fields),
         {:ok, _, digest} <- Envelope.seal(event),
         %{"receipts" => [%{"status" => status}]} when status in ["stored", "duplicate"] <-
           Spool.ingest(Spool, source, id, [Receipt.entry(event, digest)]) do
      :ok
    else
      _ -> {:error, :collector_intake_failed}
    end
  catch
    :exit, _ -> {:error, :collector_intake_failed}
  end

  defp collector_event(source, id, fields) do
    fields
    |> Map.merge(%{
      "event_id" => id,
      "schema_version" => 1,
      "source_id" => source.id,
      "application" => source.application
    })
    |> put_present("service_instance", source.service_instance)
    |> Map.update(
      "version",
      put_present(%{}, "repository", source.repository),
      &put_present(&1, "repository", source.repository)
    )
    |> Redaction.project()
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
