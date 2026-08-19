defmodule Backplane.Application do
  @moduledoc false

  use Application
  require Logger

  alias Backplane.Config.Validator
  alias Backplane.Registry.{Namespace, Tool, ToolRegistry}
  alias Backplane.Tools.{Admin, Hub}

  @drain_timeout 15_000
  @managed_services [
    Backplane.Services.Day,
    Backplane.Services.Web,
    Backplane.Services.Math,
    Backplane.Services.Skills
  ]

  @impl true
  def start(_type, _args) do
    validate_config_at_boot()

    children = [{Oban, Application.fetch_env!(:backplane, Oban)}]

    opts = [strategy: :one_for_one, name: Backplane.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      register_native_tools()

      case reconcile_managed_services() do
        :ok ->
          start_configured_upstreams()
          start_db_upstreams()
          Backplane.LLM.UsageCollector.attach()
          Backplane.Clients.init_cache()
          upsert_config_clients()

          {:ok, pid}

        {:error, _reason} = error ->
          Supervisor.stop(pid)
          error
      end
    end
  end

  @impl true
  def prep_stop(state) do
    Logger.info("Shutting down — draining connections (#{@drain_timeout}ms timeout)")
    Oban.pause_all_queues(Oban)
    state
  rescue
    e ->
      Logger.warning("Error during prep_stop: #{Exception.message(e)}")
      state
  end

  defp register_native_tools do
    tool_modules = [Hub, Admin]

    for module <- tool_modules, tool_def <- module.tools() do
      tool = %Tool{
        name: tool_def.name,
        description: tool_def.description,
        input_schema: tool_def.input_schema,
        origin: :native,
        module: tool_def.module,
        handler: tool_def.handler
      }

      ToolRegistry.register_native(tool)
    end
  end

  @doc false
  def reconcile_managed_services(settings_module \\ Backplane.Settings) do
    setting_keys = [
      "services.day.enabled",
      "services.web.enabled",
      "services.skill.enabled"
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

  defp managed_service_enabled?(Backplane.Services.Skills, values),
    do: values["services.skill.enabled"] == true

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
      config = %{
        name: upstream.name,
        prefix: upstream.prefix,
        transport: upstream.transport,
        url: upstream.url,
        command: upstream.command,
        args: upstream.args || [],
        timeout: upstream.timeout_ms,
        refresh_interval: upstream.refresh_interval_ms,
        headers: upstream.headers || %{},
        credential: upstream.credential,
        auth_scheme: upstream.auth_scheme || "none",
        auth_header_name: upstream.auth_header_name
      }

      start_upstream(config)
    end
  rescue
    e ->
      Logger.warning("Failed to load DB upstreams: #{Exception.message(e)}")
  end

  defp upsert_config_clients do
    seeds = Application.get_env(:backplane, :client_seeds, [])

    for %{name: name} = seed when is_binary(name) <- seeds do
      case Backplane.Clients.upsert_from_config(seed) do
        {:ok, _client} ->
          Logger.info("Upserted client from config: #{name}")

        {:error, reason} ->
          Logger.warning("Failed to upsert client #{name}: #{inspect(reason)}")
      end
    end
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
