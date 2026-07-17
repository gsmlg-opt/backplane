defmodule Backplane.Memory.Application do
  @moduledoc false

  use Application

  alias Backplane.Memory.{EventNotifier, Service}
  alias Backplane.Registry.ToolRegistry

  @impl true
  def start(_type, _args) do
    children = [
      Supervisor.child_spec(
        {Postgrex.Notifications, EventNotifier.connection_options()},
        id: Backplane.Memory.EventNotifications
      ),
      EventNotifier
    ]

    opts = [strategy: :rest_for_one, name: Backplane.Memory.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      register_service()
      {:ok, pid}
    end
  end

  defp register_service do
    if Service.enabled?() do
      ToolRegistry.register_managed(Service.prefix(), Service.tools())
    end

    :ok
  end
end
