defmodule Backplane.Memory.Application do
  @moduledoc false

  use Application

  require Logger

  alias Backplane.Memory.{
    ActivityNotifier,
    EventNotifier,
    GeneratedSkills,
    QueryLogFilter,
    ReplayNotifier,
    Service
  }

  alias Backplane.Registry.{PromptRegistry, ToolRegistry}

  @impl true
  def start(_type, _args) do
    :ok = QueryLogFilter.install()

    children = [
      {Task.Supervisor, name: Backplane.Memory.Recall.TaskSupervisor},
      {Task.Supervisor, name: Backplane.Memory.Crystal.TaskSupervisor},
      Supervisor.child_spec(
        {Postgrex.Notifications, EventNotifier.connection_options()},
        id: Backplane.Memory.EventNotifications
      ),
      EventNotifier,
      ActivityNotifier,
      ReplayNotifier,
      GeneratedSkills
    ]

    opts = [strategy: :rest_for_one, name: Backplane.Memory.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        register_service()
        reconcile_generated_skills()
        {:ok, pid}

      error ->
        QueryLogFilter.uninstall()
        error
    end
  end

  @impl true
  def stop(_state) do
    QueryLogFilter.uninstall()

    if Process.whereis(PromptRegistry) do
      PromptRegistry.deregister_managed(Service.prefix())
    end

    :ok
  end

  defp register_service do
    if Service.enabled?() do
      ToolRegistry.register_managed(Service.prefix(), Service.tools())
      PromptRegistry.register_managed(Service.prefix(), Service.prompts(), Service)
    else
      PromptRegistry.deregister_managed(Service.prefix())
    end

    :ok
  end

  defp reconcile_generated_skills do
    case GeneratedSkills.reconcile() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Memory generated skill reconcile failed", reason: inspect(reason))
    end
  end
end
