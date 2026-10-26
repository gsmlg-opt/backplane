defmodule Backplane.HostAgent.MemoryFacade do
  @moduledoc "Routes core host memory operations across canonical and provisional stores."

  alias Backplane.HostAgent.{HubProxy, Memory, MemoryProxy}
  alias Backplane.MemoryReadRequest
  alias Backplane.HostAgent.Memory.{Access, ContextPacker, Reducer, Syncer}

  @commands ~w(remember forget)
  @reads ~w(recall list stats)
  @core_methods @commands ++ @reads
  @overlay_cap 100

  @transport_errors [
    :not_connected,
    :timeout,
    :socket_timeout,
    :econnrefused,
    :econnreset,
    :enetdown,
    :enetunreach,
    :nxdomain,
    :hub_down,
    :closed,
    :disconnected
  ]

  @transport_wrappers [
    :transport,
    :transport_error,
    :socket,
    :socket_error,
    :reconnect_failed,
    :reconnect_lock_failed,
    :channel_exit
  ]
  @nested_transport_wrappers @transport_wrappers ++ [:error, :exit, :EXIT, :shutdown]

  @spec call(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def call(method, args, context)

  def call("get", args, context) when is_map(args) and is_map(context),
    do: Backplane.HostAgent.MemoryRecordRead.call(args, context)

  def call(method, %{"memory_access_id" => selector} = args, context) do
    with true <- method in @core_methods and is_binary(selector),
         true <-
           not Enum.any?(
             ~w(memory_space_id host_id client_id partition_id namespace),
             &Map.has_key?(args, &1)
           ),
         :ok <- MemoryProxy.authorize_command(),
         {:ok, target, ticket} <-
           Access.begin_request(
             {:access_id, selector},
             if(method in @commands, do: String.to_existing_atom(method), else: :read),
             access_server(context)
           ) do
      if Map.has_key?(args, "scope") and args["scope"] != target.partition["scope"] do
        _ = Access.finish_request(ticket, {:error, :invalid_request}, access_server(context))
        {:error, :invalid_request}
      else
        args = Map.delete(args, "memory_access_id")

        if method in @commands,
          do: shared_command(method, args, context, target, ticket),
          else: shared_read(method, args, context, target, ticket)
      end
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def call(method, args, context)
      when method in @core_methods and is_map(args) and is_map(context) do
    with :ok <- MemoryProxy.authorize_private(),
         {:ok, target, ticket} <-
           Access.begin_request(
             :default,
             if(method in @commands, do: String.to_existing_atom(method), else: :read),
             access_server(context)
           ) do
      if Map.has_key?(args, "scope") and args["scope"] != target.partition["scope"] do
        _ = Access.finish_request(ticket, {:error, :invalid_request}, access_server(context))
        {:error, :invalid_request}
      else
        args =
          if method == "remember",
            do: Map.put_new(args, "type", "episodic"),
            else: args

        if method in @commands do
          shared_command(method, args, context, target, ticket)
          |> default_command_result(method, args, target)
        else
          shared_read(method, args, context, target, ticket)
        end
      end
    end
  end

  def call(method, args, context) when method in ~w(facet_tag facet_query) do
    adapter =
      Map.get(
        context,
        :hub_adapter,
        Application.get_env(:backplane_host_agent, :hub_proxy_module, HubProxy)
      )

    adapter.call_tool("memory::" <> method, args)
  end

  def call(method, _args, _context), do: {:error, {:unknown_method, method}}

  defp access_server(context), do: Map.get(context, :access_server, Access)

  defp validate_read(method, args) when method in ~w(recall list),
    do: MemoryReadRequest.validate(method, args)

  defp validate_read(_method, args), do: {:ok, args}

  defp shared_read(method, args, context, target, ticket) do
    case validate_read(method, Map.delete(args, "scope")) do
      {:ok, normalized} ->
        do_shared_read(method, normalized, context, target, ticket)

      {:error, _} = error ->
        _ = Access.finish_request(ticket, error, access_server(context))
        error
    end
  end

  defp do_shared_read(method, args, context, target, ticket) do
    adapter = Map.get(context, :remote_adapter, MemoryProxy)

    reply =
      adapter.call(
        method,
        Map.delete(args, "scope"),
        remote_opts(context)
        |> Keyword.put(:access, Access.claim(target))
        |> Keyword.put(:connection_generation, target.connection_generation)
      )

    case Access.finish_request(ticket, reply, access_server(context)) do
      {:ok, permitted, canonical} ->
        Access.run_local(
          permitted,
          :read,
          fn current ->
            with {:ok, overlay} <- Memory.shared_overlay(current, method, args, :online, -1) do
              {:ok, online_result(method, canonical, overlay, args)}
            end
          end,
          access_server(context)
        )

      {:error, reason} = error ->
        if transport_error?(reason) do
          Access.run_local(
            target,
            :read,
            fn current ->
              opts = [
                store: current.edge_store,
                config: current.edge_config,
                access_target: current
              ]

              with {:ok, canonical} <-
                     Backplane.HostAgent.Memory.Mirror.offline_read(
                       method,
                       Map.merge(args, current.partition),
                       opts
                     ),
                   {:ok, overlay} <-
                     Memory.shared_overlay(
                       current,
                       method,
                       args,
                       :offline,
                       canonical["partition_revision"]
                     ) do
                {:ok, offline_mirror_result(method, canonical, overlay, args)}
              end
            end,
            access_server(context)
          )
        else
          error
        end
    end
  end

  defp shared_command(method, args, context, target, ticket) do
    operation = String.to_existing_atom(method)

    with {:ok, receipt} <-
           Access.run_local(
             target,
             operation,
             &Memory.shared_enqueue(&1, method, args, context.agent_id),
             access_server(context)
           ) do
      opts =
        [store: target.store, access_server: access_server(context)] ++
          Map.get(context, :sync_opts, [])

      result =
        case Syncer.drain_shared(opts) do
          {:error, reason} ->
            _ = Access.finish_request(ticket, {:error, reason}, access_server(context))

            if transport_error?(reason) do
              Access.run_local(
                target,
                operation,
                &Memory.shared_receipt(&1, receipt["command_id"]),
                access_server(context)
              )
            else
              {:error, reason}
            end

          {:ok, _} ->
            # Settlement is durable before the caller is released; rejected ACKs are errors.
            result =
              Access.run_local(
                target,
                operation,
                &Memory.shared_receipt(&1, receipt["command_id"]),
                access_server(context)
              )

            case result do
              {:ok, settled} ->
                envelope = %{
                  "access" => Access.claim(target),
                  "partition" => target.partition,
                  "result" => settled
                }

                with {:ok, permitted, bounded} <-
                       Access.finish_request(ticket, {:ok, envelope}, access_server(context)) do
                  Access.run_local(
                    permitted,
                    operation,
                    fn _ -> {:ok, bounded} end,
                    access_server(context)
                  )
                end

              error ->
                _ =
                  Access.finish_request(
                    ticket,
                    {:error, :invalid_request},
                    access_server(context)
                  )

                error
            end
        end

      case result do
        {:ok, settled} -> {:ok, Map.put(settled, "dedup", receipt["dedup"])}
        error -> error
      end
    else
      error ->
        _ = Access.finish_request(ticket, {:error, :invalid_request}, access_server(context))
        error
    end
  end

  defp default_command_result({:ok, receipt}, method, args, target) do
    id =
      receipt["canonical_id"] ||
        if(method == "forget", do: args["id"], else: receipt["command_id"])

    {:ok,
     Map.merge(receipt, %{
       "id" => id,
       "scope" => target.partition["scope"],
       "sync_state" => if(receipt["status"] == "committed", do: "synced", else: "pending")
     })}
  end

  defp default_command_result(error, _method, _args, _target), do: error

  defp online_result(method, canonical, overlay, args) do
    pending_operations = pending_operations(overlay)
    pending? = pending_operations > 0

    canonical
    |> merge_overlay(method, overlay, args)
    |> pack_context(method, args)
    |> normalize_result(method)
    |> Map.put_new("partition_revision", nil)
    |> Map.put_new("last_sync_age_seconds", nil)
    |> Map.merge(%{
      "mode" => "online",
      "authority" => if(pending?, do: "canonical_with_provisional", else: "canonical"),
      "consistency" => if(pending?, do: "read_your_writes", else: "canonical"),
      "stale" => false,
      "pending_operations" => pending_operations,
      "acknowledged_operations" => Map.get(overlay, "acknowledged_operations", 0),
      "overlay_truncated" => overlay_truncated?(overlay),
      "history_available" => true
    })
    |> Map.put_new("as_of", nil)
  end

  defp offline_mirror_result(method, canonical, overlay, args) do
    pending_operations = pending_operations(overlay)

    canonical =
      if method in ["recall", "list"] do
        Map.put_new(canonical, "results", Map.get(canonical, "items", []))
      else
        canonical
      end

    canonical
    |> merge_overlay(method, overlay, args)
    |> pack_context(method, args)
    |> normalize_result(method)
    |> sync_offline_items(method, canonical)
    |> Map.merge(%{
      "mode" => "offline",
      "authority" =>
        if(pending_operations > 0, do: "canonical_with_provisional", else: "canonical"),
      "source" => "edge_mirror",
      "consistency" => "bounded_stale",
      "stale" => true,
      "pending_operations" => pending_operations,
      "acknowledged_operations" => Map.get(overlay, "acknowledged_operations", 0),
      "overlay_truncated" => overlay_truncated?(overlay),
      "history_available" => true
    })
  end

  defp pack_context(result, "recall", args) do
    budget = Reducer.value(args, "token_budget") || result["token_budget"] || 4_096
    packed = ContextPacker.pack(normalized_results(result), budget)

    result
    |> Map.put("results", packed.results)
    |> Map.put("rendered_context", packed.rendered_context)
    |> Map.put("used_tokens", packed.used_tokens)
    |> Map.put("token_budget", packed.token_budget)
    |> then(fn result ->
      if Map.has_key?(result, "upserts"),
        do: Map.put(result, "upserts", packed.results),
        else: result
    end)
  end

  defp pack_context(result, _method, _args), do: result

  defp normalize_result(result, "recall") do
    Map.put(result, "hits", normalized_results(result))
  end

  defp normalize_result(result, "list") do
    Map.put(result, "items", normalized_results(result))
  end

  defp normalize_result(result, "stats"), do: result

  defp sync_offline_items(result, "recall", %{"items" => _items}),
    do: Map.put(result, "items", result["hits"])

  defp sync_offline_items(result, _method, _canonical), do: result

  defp merge_overlay(canonical, "stats", _overlay, _args), do: canonical

  defp merge_overlay(canonical, "recall", overlay, args) do
    delete_ids = overlay |> Map.get("delete_ids", []) |> MapSet.new()

    canonical_results =
      canonical
      |> normalized_results()
      |> Enum.reject(&(result_identity(&1) in delete_ids))

    canonical_ids = canonical_results |> Enum.map(&result_identity/1) |> MapSet.new()

    provisional_results =
      overlay
      |> Map.get("upserts", [])
      |> Enum.reject(fn result ->
        identity = result_identity(result)
        identity in delete_ids or identity in canonical_ids
      end)

    merged = offline_results(provisional_results ++ canonical_results, "recall", args, false)
    Map.put(canonical, "results", merged)
  end

  defp merge_overlay(canonical, "list", overlay, _args) do
    delete_ids = overlay |> Map.get("delete_ids", []) |> MapSet.new()

    canonical_results =
      canonical
      |> normalized_results()
      |> Enum.reject(&(result_identity(&1) in delete_ids))

    canonical_ids = canonical_results |> Enum.map(&result_identity/1) |> MapSet.new()

    provisional_results =
      overlay
      |> Map.get("upserts", [])
      |> Enum.reject(fn result ->
        identity = result_identity(result)
        identity in delete_ids or identity in canonical_ids
      end)

    {acknowledged, provisional} =
      Enum.split_with(provisional_results, &(&1["authority"] == "canonical"))

    canonical
    |> Map.put("results", canonical_results ++ acknowledged)
    |> Map.put("provisional_results", provisional)
  end

  defp offline_results(results, "recall", args, _offset_applied?),
    do: Enum.take(results, min(nonnegative_integer(args, "limit", 10), @overlay_cap))

  defp offline_results(results, "list", args, offset_applied?) do
    offset = if offset_applied?, do: 0, else: nonnegative_integer(args, "offset", 0)
    limit = nonnegative_integer(args, "limit", 50)

    results
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  defp offline_results(results, _method, _args, _offset_applied?), do: results

  defp nonnegative_integer(args, key, default) do
    case Reducer.value(args, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _value -> default
    end
  end

  defp result_identity(%{"canonical_id" => canonical_id})
       when is_binary(canonical_id) and canonical_id != "",
       do: canonical_id

  defp result_identity(%{"id" => id}), do: id
  defp result_identity(_result), do: nil

  defp normalized_results(%{"results" => results}) when is_list(results), do: results
  defp normalized_results(_result), do: []

  defp pending_operations(%{"pending_operations" => count})
       when is_integer(count) and count >= 0,
       do: count

  defp pending_operations(overlay) do
    length(Map.get(overlay, "upserts", [])) + length(Map.get(overlay, "delete_ids", []))
  end

  defp overlay_truncated?(%{"overlay_truncated" => true}), do: true
  defp overlay_truncated?(_overlay), do: false

  defp remote_opts(context) do
    context
    |> context_opts([:agent_id, :timeout])
    |> Keyword.put(:inject_agent_id, false)
  end

  defp context_opts(context, optional_keys) do
    agent_id = Map.fetch!(context, :agent_id)

    optional_keys
    |> Enum.reject(&(&1 == :agent_id))
    |> Enum.reduce([agent_id: agent_id], fn key, opts ->
      case Map.fetch(context, key) do
        {:ok, value} -> Keyword.put(opts, key, value)
        :error -> opts
      end
    end)
  end

  def transport_error?(reason) when reason in @transport_errors, do: true
  def transport_error?({:socket_closed, reason}), do: nested_transport_error?(reason)

  def transport_error?({wrapper, reason}) when wrapper in @transport_wrappers,
    do: nested_transport_error?(reason)

  def transport_error?(_reason), do: false

  defp nested_transport_error?(reason) when reason in @transport_errors, do: true
  defp nested_transport_error?(:noproc), do: true
  defp nested_transport_error?(:normal), do: true
  defp nested_transport_error?({:noproc, _detail}), do: true
  defp nested_transport_error?({:normal, _detail}), do: true
  defp nested_transport_error?({reason, _detail}) when reason in @transport_errors, do: true
  defp nested_transport_error?({:socket_closed, reason}), do: nested_transport_error?(reason)

  defp nested_transport_error?({wrapper, reason})
       when wrapper in @nested_transport_wrappers,
       do: nested_transport_error?(reason)

  defp nested_transport_error?(_reason), do: false
end
