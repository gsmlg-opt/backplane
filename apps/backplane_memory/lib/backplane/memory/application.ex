defmodule Backplane.Memory.Application do
  @moduledoc false

  use Application

  alias Backplane.Memory.{EventNotifier, QueryLogFilter, ServiceRegistration, Tools}

  alias Backplane.Registry.{PromptRegistry, ToolRegistry}

  @impl true
  def start(_type, _args) do
    :ok = QueryLogFilter.install()

    children = [
      Supervisor.child_spec(
        {Postgrex.Notifications, EventNotifier.connection_options()},
        id: Backplane.Memory.EventNotifications
      ),
      EventNotifier,
      {Task.Supervisor, name: Backplane.Memory.Distill.TaskSupervisor},
      ServiceRegistration
    ]

    opts = [strategy: :rest_for_one, name: Backplane.Memory.Supervisor]

    with {:error, _reason} = error <- Supervisor.start_link(children, opts) do
      QueryLogFilter.uninstall()
      error
    end
  end

  @impl true
  def stop(_state) do
    QueryLogFilter.uninstall()

    if Process.whereis(ToolRegistry) do
      ToolRegistry.deregister_managed(Tools.prefix())
    end

    if Process.whereis(PromptRegistry) do
      PromptRegistry.deregister_managed(Tools.prefix())
    end

    :ok
  end
end
