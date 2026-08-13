defmodule Backplane.HostAgent.Memory.CaptureSupervisor do
  @moduledoc "Supervises the durable host-capture spool and periodic uploader."

  use Supervisor

  alias Backplane.HostAgent.Memory.{CaptureUploader, RecallCache, Spool}

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
    recall_cache_name = Map.fetch!(opts, :recall_cache_name)

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
       max_bytes: Map.fetch!(opts, :batch_bytes)},
      {RecallCache,
       name: recall_cache_name,
       id: {RecallCache, recall_cache_name},
       max_entries: Map.fetch!(opts, :recall_cache_max_entries),
       max_bytes: Map.fetch!(opts, :recall_cache_max_bytes),
       ttl_ms: Map.fetch!(opts, :recall_cache_ttl_ms)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp normalize(config) do
    config
    |> Map.put_new(:name, __MODULE__)
    |> Map.put_new(:spool_name, Spool.Turso)
    |> Map.put_new(:uploader_name, CaptureUploader)
    |> Map.put_new(:recall_cache_name, RecallCache)
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
    |> Map.put_new(:inject_context, false)
    |> Map.put_new(:context_timeout_ms, 1_200)
    |> Map.update!(:context_timeout_ms, &bounded_context_timeout/1)
    |> Map.put_new(:recall_cache_max_entries, 128)
    |> Map.put_new(:recall_cache_max_bytes, 2 * 1024 * 1024)
    |> Map.put_new(:recall_cache_ttl_ms, 15 * 60 * 1_000)
  end

  defp bounded_context_timeout(timeout) when is_integer(timeout) and timeout > 0,
    do: min(timeout, 1_500)

  defp bounded_context_timeout(_timeout), do: 1_200

  defp configure_runtime(opts) do
    Application.put_env(:backplane_host_agent, :capture_runtime, %{
      host_id: Map.fetch!(opts, :host_id),
      agent_id: Map.get(opts, :agent_id),
      config: opts,
      spool: Map.fetch!(opts, :spool_name),
      spool_module: Spool.Turso,
      recall_cache: Map.fetch!(opts, :recall_cache_name),
      memory_proxy_module: Map.get(opts, :memory_proxy_module, Backplane.HostAgent.MemoryProxy)
    })
  end
end
