defmodule BackplaneMcp.Application do
  @moduledoc false

  use Application

  alias Backplane.MCP.LogWriter
  alias Backplane.Observability.{Buffer, Flags}

  @impl true
  def start(_type, _args) do
    cache_opts = [
      max_entries: Application.get_env(:backplane, :cache_max_entries, 10_000)
    ]

    children =
      [
        Backplane.Transport.Session,
        Backplane.Transport.TaskManager,
        Backplane.Math.Supervisor,
        {Task.Supervisor, name: Backplane.MCP.ModernTaskSupervisor},
        {Registry, keys: :unique, name: Backplane.Proxy.ProcessRegistry},
        Backplane.Proxy.ClientPool,
        Backplane.Proxy.ClientLeaseManager,
        Backplane.Proxy.Pool,
        {Backplane.Cache, cache_opts}
      ]
      |> maybe_mcp_observability()

    Supervisor.start_link(children, strategy: :one_for_one, name: BackplaneMcp.Supervisor)
  end

  defp maybe_mcp_observability(children) do
    if Flags.mcp_write?() do
      children ++
        [
          {Buffer, [name: :mcp_proxy_root, capacity: Buffer.default_capacity(:mcp_proxy_root)]},
          {LogWriter, mcp_log_writer_opts()}
        ]
    else
      children
    end
  end

  defp mcp_log_writer_opts do
    Application.get_env(:backplane_mcp, :mcp_log_writer, [])
  end
end
