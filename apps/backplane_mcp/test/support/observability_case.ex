defmodule Backplane.MCP.ObservabilityCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using opts do
    quote do
      use BackplaneMcp.DataCase, unquote(opts)
      import Plug.Conn
      import Plug.Test
      import Backplane.MCP.ObservabilityCase

      alias Backplane.MCP.{LogWriter, ProxyRequest}
      alias Backplane.Observability.Buffer

  setup tags do
    if tags[:observability_v2] do
      enable_observability_v2!()
      start_observability_v2!(tags)

      on_exit(fn ->
        Backplane.MCP.LogWriter.detach()
        disable_observability_v2!()
      end)
    end

    if :ets.info(Backplane.Transport.RateLimiter) != :undefined do
      :ets.delete_all_objects(Backplane.Transport.RateLimiter)
    end

    Application.put_env(:backplane, Backplane.Transport.RateLimiter,
      max_requests: 100,
      window_ms: 60_000,
      trust_x_forwarded_for: false
    )

    :ok
  end
    end
  end

  @doc false
  def enable_observability_v2! do
    Application.put_env(:backplane_telemetry, :observability_v2_enabled, true)
    Application.put_env(:backplane_telemetry, :observability_v2_mcp_write, true)
  end

  @doc false
  def disable_observability_v2! do
    Application.put_env(:backplane_telemetry, :observability_v2_enabled, false)
    Application.put_env(:backplane_telemetry, :observability_v2_mcp_write, false)
  end

  @doc false
  def start_observability_v2!(tags \\ []) do
    enable_observability_v2!()
    capacity = Map.get(tags, :buffer_capacity, 100)

    case Process.whereis(:mcp_proxy_root) do
      nil ->
        start_supervised!({Backplane.Observability.Buffer, [name: :mcp_proxy_root, capacity: capacity]})

      _ ->
        :ok
    end

    writer_opts = [
      batch_size: Map.get(tags, :batch_size, 50),
      flush_interval_ms: Map.get(tags, :flush_interval_ms, 60_000)
    ]

    case Process.whereis(Backplane.MCP.LogWriter) do
      nil ->
        start_supervised!({Backplane.MCP.LogWriter, writer_opts})

      _ ->
        Backplane.MCP.LogWriter.detach()
        Backplane.MCP.LogWriter.attach()
        :ok
    end
  end

  @doc false
  def flush_logs! do
    Backplane.MCP.LogWriter.flush()
  end

  @doc false
  def latest_log do
    import Ecto.Query

    Backplane.Repo.one(
      from(r in Backplane.MCP.ProxyRequest, order_by: [desc: r.inserted_at], limit: 1)
    )
  end

  @doc false
  def log_for_rpc_method(method) do
    import Ecto.Query

    Backplane.Repo.one(
      from(r in Backplane.MCP.ProxyRequest,
        where: r.rpc_method == ^method,
        order_by: [desc: r.inserted_at],
        limit: 1
      )
    )
  end
end
