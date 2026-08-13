defmodule Backplane.HostAgent.Services.Memory do
  @moduledoc """
  Local MCP service for host-agent memory tools.
  """

  @behaviour Backplane.HostAgent.LocalService

  alias Backplane.HostAgent.Memory
  alias Backplane.HostAgent.Memory.{ImportRunner, ImportSupervisor}
  alias Backplane.HostAgent.Memory.Store

  @impl true
  def prefix, do: "memory"

  @impl true
  def tools do
    Enum.map(Memory.methods() ++ ["replay_import"], fn method ->
      %{"name" => "memory::#{method}", "description" => "Memory operation: #{method}"}
    end)
  end

  @impl true
  def call(method, args, ctx) when is_binary(method) and is_map(args) and is_map(ctx) do
    cond do
      method == "replay_import" -> replay_import(args, ctx)
      Memory.valid_method?(method) -> do_call(method, args, memory_opts(ctx[:agent_id]))
      true -> {:error, {:unknown_method, method}}
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

  defp replay_import(%{"profile" => profile} = args, ctx) when is_binary(profile) do
    memory_config = Application.get_env(:backplane_host_agent, :memory_config, %{})
    runtime = Application.get_env(:backplane_host_agent, :capture_runtime, %{})

    with %{path: path, approved_roots: [_ | _] = roots} = policy <-
           get_in(memory_config, [:import_profiles, profile]),
         spool when not is_nil(spool) <- runtime[:spool],
         spool_module when is_atom(spool_module) <- runtime[:spool_module],
         host_id when is_binary(host_id) <- runtime[:host_id],
         channel when is_pid(channel) <- ctx[:channel] do
      batch_id = random_uuid()
      request_id = args["request_id"]
      max_entries = bounded_cap(args["max_entries"], 100_000)

      import_opts =
        [
          approved_roots: roots,
          allow_symlinks: policy.allow_symlinks,
          max_depth: policy.max_depth,
          max_files: bounded_cap(args["max_files"], 1_000),
          max_entries: max_entries,
          max_bytes: bounded_cap(args["max_bytes"], 256 * 1024 * 1024),
          batch_id: batch_id,
          host_id: host_id,
          agent_id: runtime[:agent_id] || "claude_code",
          spool: spool,
          spool_module: spool_module
        ] ++ Map.get(ctx, :import_opts, [])

      runner_opts = [
        request_id: request_id,
        channel: channel,
        channel_module: ctx[:channel_module] || Backplane.HostAgent.Channel,
        import_module: ctx[:import_module] || Backplane.HostAgent.Memory.Import,
        uploader_module: ctx[:uploader_module] || Backplane.HostAgent.Memory.CaptureUploader,
        upload_limit: max_entries + 1,
        host_id: host_id,
        spool: spool,
        spool_module: spool_module
      ]

      supervisor = ctx[:import_supervisor] || ImportSupervisor

      case ImportSupervisor.enqueue(
             fn -> ImportRunner.run(path, import_opts, runner_opts) end,
             supervisor
           ) do
        {:ok, _pid} ->
          {:ok,
           %{
             "status" => "accepted",
             "batch_id" => batch_id,
             "request_id" => request_id
           }}

        {:error, :max_children} ->
          {:error, :import_capacity_reached}

        {:error, _reason} ->
          {:error, :import_unavailable}
      end
    else
      nil -> {:error, :import_profile_not_found}
      _ -> {:error, :capture_unavailable}
    end
  end

  defp replay_import(_args, _ctx), do: {:error, :invalid_import_request}

  defp bounded_cap(value, maximum) when is_integer(value) and value > 0, do: min(value, maximum)
  defp bounded_cap(_value, maximum), do: maximum

  defp random_uuid do
    <<prefix::binary-size(6), _version::4, version_tail::12, _variant::2, variant_tail::62>> =
      :crypto.strong_rand_bytes(16)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> =
      <<prefix::binary, 4::4, version_tail::12, 2::2, variant_tail::62>>
      |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  defp memory_opts(agent_id) do
    [
      store: Application.get_env(:backplane_host_agent, :memory_store, Store),
      config: Application.get_env(:backplane_host_agent, :memory_config, %{}),
      agent_id: agent_id
    ]
  end
end
