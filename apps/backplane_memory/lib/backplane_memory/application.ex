defmodule BackplaneMemory.Application do
  @moduledoc false

  use Application

  alias Backplane.Registry.ToolRegistry
  alias BackplaneMemory.Service

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: BackplaneMemory.Supervisor]

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
