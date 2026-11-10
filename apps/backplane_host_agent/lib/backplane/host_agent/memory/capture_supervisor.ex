defmodule Backplane.HostAgent.Memory.CaptureSupervisor do
  @moduledoc "Supervises the durable host-capture spool and periodic uploader."

  use Supervisor

  alias Backplane.HostAgent.Collectors.Scheduler
  alias Backplane.HostAgent.Memory.{CaptureUploader, Spool}

  @upload_wrapper_headroom 1_024

  def start_link(%{enabled: false}) do
    Application.delete_env(:backplane_host_agent, :capture_runtime)
    :ignore
  end

  def start_link(%{} = capture_config) do
    opts = normalize(capture_config)

    case Supervisor.start_link(__MODULE__, opts, name: Map.fetch!(opts, :name)) do
      {:ok, _pid} = result ->
        configure_runtime(opts)
        result

      {:error, {:already_started, _pid}} = result ->
        configure_runtime(opts)
        result

      other ->
        other
    end
  end

  @impl true
  def init(opts) do
    spool_name = Map.fetch!(opts, :spool_name)
    uploader_name = Map.fetch!(opts, :uploader_name)

    children = [
      {Spool.Turso,
       database: Map.fetch!(opts, :db_path),
       name: spool_name,
       id: {Spool.Turso, spool_name},
       encryption_key_env: Map.get(opts, :encryption_key_env),
       max_spool_bytes: Map.fetch!(opts, :spool_max_bytes),
       max_event_age_days: Map.fetch!(opts, :spool_max_age_days),
       retry_base_ms: Map.fetch!(opts, :retry_base_ms),
       retry_max_ms: Map.fetch!(opts, :retry_max_ms),
       compaction_batch_size: Map.fetch!(opts, :compaction_batch_size),
       clock: Map.fetch!(opts, :clock)},
      {CaptureUploader,
       spool: spool_name,
       host_id: Map.fetch!(opts, :host_id),
       name: uploader_name,
       id: {CaptureUploader, uploader_name},
       channel_provider: Map.fetch!(opts, :channel_provider),
       channel_module: Map.fetch!(opts, :channel_module),
       interval_ms: Map.fetch!(opts, :upload_interval_ms),
       max_events: Map.fetch!(opts, :batch_size),
       max_bytes: Map.fetch!(opts, :batch_bytes)}
    ]

    Supervisor.init(children ++ collector_children(opts), strategy: :one_for_one)
  end

  defp collector_children(%{collectors: %{enabled: true} = collectors} = opts) do
    [
      {
        Scheduler,
        # Leave room for the uploader's batch wrapper so one snapshot always fits a batch.
        name: Map.get(opts, :scheduler_name, Scheduler),
        host_id: Map.fetch!(opts, :host_id),
        host_label: Map.get(opts, :host_label),
        spool: Map.fetch!(opts, :spool_name),
        max_bytes: Map.fetch!(opts, :batch_bytes) - @upload_wrapper_headroom,
        state_path: Map.fetch!(collectors, :state_path),
        config: collectors,
        interval_ms: Map.fetch!(collectors, :interval_ms),
        initial_delay_ms: Map.fetch!(collectors, :initial_delay_ms)
      }
    ]
  end

  defp collector_children(_opts), do: []

  defp normalize(config) do
    config
    |> Map.put_new(:name, __MODULE__)
    |> Map.put_new(:spool_name, Spool.Turso)
    |> Map.put_new(:uploader_name, CaptureUploader)
    |> Map.put_new(:channel_provider, Backplane.HostAgent.MemoryProxy)
    |> Map.put_new(:channel_module, Backplane.HostAgent.Channel)
    |> Map.put_new(:upload_interval_ms, 5_000)
    |> Map.put_new(:batch_size, 100)
    |> Map.put_new(:batch_bytes, 512 * 1024)
    |> Map.put_new(:encryption_key_env, nil)
    |> Map.put_new(:spool_max_bytes, 64 * 1024 * 1024)
    |> Map.put_new(:spool_max_age_days, 30)
    |> Map.put_new(:retry_base_ms, 1_000)
    |> Map.put_new(:retry_max_ms, 300_000)
    |> Map.put_new(:compaction_batch_size, 100)
    |> Map.put_new(:clock, &DateTime.utc_now/0)
  end

  defp configure_runtime(opts) do
    Application.put_env(:backplane_host_agent, :capture_runtime, %{
      host_id: Map.fetch!(opts, :host_id),
      agent_id: Map.get(opts, :agent_id),
      config: opts,
      spool: Map.fetch!(opts, :spool_name),
      spool_module: Spool.Turso
    })
  end
end
