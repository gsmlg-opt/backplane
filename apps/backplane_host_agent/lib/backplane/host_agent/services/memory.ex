defmodule Backplane.HostAgent.Services.Memory do
  @moduledoc """
  Local MCP service for host-agent memory tools.
  """

  @behaviour Backplane.HostAgent.LocalService

  alias Backplane.HostAgent.Memory
  alias Backplane.HostAgent.Memory.Store

  @impl true
  def prefix, do: "memory"

  @impl true
  def tools do
    Enum.map(Memory.methods(), fn method ->
      %{"name" => "memory::#{method}", "description" => "Memory operation: #{method}"}
    end)
  end

  @impl true
  def call(method, args, ctx) when is_binary(method) and is_map(args) and is_map(ctx) do
    if Memory.valid_method?(method) do
      do_call(method, args, memory_opts(Map.fetch!(ctx, :agent_id)))
    else
      {:error, {:unknown_method, method}}
    end
  rescue
    error -> {:error, {:memory_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:memory_unavailable, reason}}
  end

  defp do_call("remember", args, opts), do: Memory.remember(args, opts)
  defp do_call("recall", args, opts), do: Memory.recall(args, opts)
  defp do_call("list", args, opts), do: Memory.list(args, opts)
  defp do_call("forget", args, opts), do: Memory.forget(args, opts)
  defp do_call("stats", args, opts), do: Memory.stats(args, opts)
  defp do_call("slot_read", args, opts), do: Memory.slot_read(args, opts)
  defp do_call("slot_write", args, opts), do: Memory.slot_write(args, opts)
  defp do_call("slot_list", args, opts), do: Memory.slot_list(args, opts)
  defp do_call("facet_tag", args, opts), do: Memory.facet_tag(args, opts)
  defp do_call("facet_query", args, opts), do: Memory.facet_query(args, opts)

  defp memory_opts(agent_id) do
    [
      store: Application.get_env(:backplane_host_agent, :memory_store, Store),
      config: Application.get_env(:backplane_host_agent, :memory_config, %{}),
      agent_id: agent_id
    ]
  end
end
