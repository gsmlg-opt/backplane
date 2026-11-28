defmodule Backplane.Application do
  @moduledoc false

  use Application
  require Logger

  alias Backplane.Config.Validator
  alias Backplane.Registry.{Namespace, ToolRegistry}

  @drain_timeout 15_000
  @managed_services [
    Backplane.Services.Day,
    Backplane.Services.Web,
    Backplane.Services.Math,
    Backplane.Services.Diagnostics
  ]

  @impl true
  def start(_type, _args) do
    validate_config_at_boot()

    children = [
      {Styx, Application.fetch_env!(:backplane, Styx)},
      # Enqueues SecretHub sync jobs; must start after Styx.
      Backplane.SecretHub.SyncListener
    ]

    children = children ++ diagnostics_children()
    opts = [strategy: :one_for_one, name: Backplane.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      case reconcile_managed_services() do
        :ok ->
          start_configured_upstreams()
          start_db_upstreams()
          Backplane.Clients.init_cache()

          {:ok, pid}

        {:error, _reason} = error ->
          Supervisor.stop(pid)
          error
      end
    end
  end

  defp diagnostics_children do
    opts =
      Backplane.DiagnosticsClient.from_env("backplane",
        version: %{"repository" => "gsmlg-opt/backplane"},
        hooks: [:logger, :phoenix]
      )

    if opts do
      Application.put_env(
        :backplane_agent_runtime,
        :error_observer,
        {Backplane.DiagnosticsClient.Integrations.Runtime, :error}
      )

      [{Backplane.DiagnosticsClient, opts}]
    else
      []
    end
  end

  @impl true
  def prep_stop(state) do
    Logger.info("Shutting down — draining connections (#{@drain_timeout}ms timeout)")
    Styx.pause_all_queues(Styx)
    state
  rescue
    e ->
      Logger.warning("Error during prep_stop: #{Exception.message(e)}")
      state
  end

  @doc false
  def reconcile_managed_services(settings_module \\ Backplane.Settings) do
    setting_keys = [
      "services.day.enabled",
      "services.web.enabled"
    ]

    case settings_module.fetch_many(setting_keys) do
      {:ok, values} ->
        deregister_managed_services()

        Enum.each(@managed_services, fn service ->
          if managed_service_enabled?(service, values) do
            ToolRegistry.register_managed(service.prefix(), service.tools())
          end
        end)

      {:error, reason} ->
        deregister_managed_services()
        {:error, {:settings_not_loaded, reason}}
    end
  end

  defp deregister_managed_services do
    Enum.each(@managed_services, fn service ->
      ToolRegistry.deregister_managed(service.prefix())
    end)
  end

  defp managed_service_enabled?(Backplane.Services.Day, values),
    do: values["services.day.enabled"] == true

  defp managed_service_enabled?(Backplane.Services.Web, values),
    do: values["services.web.enabled"] == true

  defp managed_service_enabled?(Backplane.Services.Math, _values),
    do: Backplane.Services.Math.enabled?()

  defp managed_service_enabled?(Backplane.Services.Diagnostics, _values),
    do: Backplane.Services.Diagnostics.enabled?()

  @doc false
  def start_upstream(config, pool_module \\ Backplane.Proxy.Pool) do
    case pool_module.start_upstream(config) do
      {:error, reason} = error ->
        name = Map.get(config, :name, Map.get(config, "name"))

        prefix =
          config
          |> Map.get(:prefix, Map.get(config, "prefix"))
          |> Namespace.normalize_prefix()

        Logger.warning(
          "Failed to start upstream #{inspect(name)} with prefix #{inspect(prefix)}: #{inspect(reason)}"
        )

        error

      result ->
        result
    end
  end

  defp start_configured_upstreams do
    upstreams = Application.get_env(:backplane, :upstreams, [])

    for upstream <- upstreams do
      start_upstream(upstream)
    end
  end

  defp start_db_upstreams do
    for upstream <- Backplane.Proxy.Upstreams.list_enabled() do
      upstream
      |> Backplane.Proxy.Upstreams.runtime_config()
      |> start_upstream()
    end
  rescue
    e ->
      Logger.warning("Failed to load DB upstreams: #{Exception.message(e)}")
  end

  defp validate_config_at_boot do
    config = [
      backplane: %{
        port: Application.get_env(:backplane, :port, 4100)
      },
      upstream: Application.get_env(:backplane, :upstreams, [])
    ]

    Validator.validate!(config)
  end
end
