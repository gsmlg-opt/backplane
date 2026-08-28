defmodule Backplane.HostAgent.MemoryFacade do
  @moduledoc "Routes core host memory operations across canonical and provisional stores."

  alias Backplane.HostAgent.{Memory, MemoryProxy}
  alias Backplane.HostAgent.Memory.Reducer

  @commands ~w(remember forget)
  @reads ~w(recall list stats)

  @transport_errors [
    :not_connected,
    :timeout,
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
      when method in @commands and is_map(args) and is_map(context) do
    local_call(method, args, context)
  end

  def call(method, args, context)
      when method in @reads and is_map(args) and is_map(context) do
    remote_first(method, args, context)
  end

  def call(method, _args, _context), do: {:error, {:unknown_method, method}}

  defp local_call(method, args, context) do
    local_adapter = Map.get(context, :local_adapter, Memory)

    case apply(local_adapter, String.to_existing_atom(method), [args, local_opts(context)]) do
      {:ok, %{} = result} ->
        {:ok,
         Map.merge(result, %{
           "authority" => "provisional",
           "consistency" => "pending_canonical_ack"
         })}

      other ->
        other
    end
  end

  defp remote_first(method, args, context) do
    remote_adapter = Map.get(context, :remote_adapter, MemoryProxy)

    case remote_adapter.call(method, args, remote_opts(context)) do
      {:ok, %{} = canonical} ->
        with {:ok, %{} = overlay} <- pending_overlay(args, context) do
          {:ok, online_result(method, canonical, overlay, args)}
        end

      {:error, reason} = error ->
        if transport_error?(reason) do
          with {:ok, %{} = overlay} <- pending_overlay(args, context) do
            {:ok, offline_result(method, overlay, args)}
          end
        else
          error
        end

      other ->
        other
    end
  end

  defp pending_overlay(args, context) do
    local_adapter = Map.get(context, :local_adapter, Memory)
    local_adapter.pending_overlay(args, local_opts(context))
  end

  defp online_result(method, canonical, overlay, args) do
    pending_operations = pending_operations(overlay)
    pending? = pending_operations > 0

    canonical
    |> merge_overlay(method, overlay, args)
    |> normalize_result(method)
    |> Map.merge(%{
      "mode" => "online",
      "authority" => if(pending?, do: "canonical_with_provisional", else: "canonical"),
      "consistency" => if(pending?, do: "read_your_writes", else: "canonical"),
      "stale" => false,
      "partition_revision" => nil,
      "last_sync_age_seconds" => nil,
      "pending_operations" => pending_operations,
      "history_available" => true
    })
    |> Map.put_new("as_of", nil)
  end

  defp offline_result(method, overlay, args) do
    upserts = limited_results(Map.get(overlay, "upserts", []), method, args)

    overlay
    |> normalize_offline_result(method, upserts)
    |> Map.merge(%{
      "mode" => "offline",
      "authority" => "provisional",
      "consistency" => "provisional_only",
      "stale" => true,
      "as_of" => nil,
      "partition_revision" => nil,
      "last_sync_age_seconds" => nil,
      "pending_operations" => pending_operations(overlay),
      "history_available" => false
    })
  end

  defp normalize_result(result, "recall") do
    Map.put(result, "hits", normalized_results(result))
  end

  defp normalize_result(result, "list") do
    Map.put(result, "items", normalized_results(result))
  end

  defp normalize_result(result, "stats"), do: result

  defp normalize_offline_result(result, "recall", upserts) do
    result
    |> Map.put("results", upserts)
    |> Map.put("hits", upserts)
  end

  defp normalize_offline_result(result, "list", upserts) do
    result
    |> Map.put("results", upserts)
    |> Map.put("items", upserts)
  end

  defp normalize_offline_result(result, "stats", _upserts), do: result

  defp merge_overlay(canonical, "stats", _overlay, _args), do: canonical

  defp merge_overlay(canonical, method, overlay, args) when method in ["recall", "list"] do
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

    merged = limited_results(provisional_results ++ canonical_results, method, args)
    Map.put(canonical, "results", merged)
  end

  defp limited_results(results, "recall", args), do: Enum.take(results, Reducer.limit(args))
  defp limited_results(results, _method, _args), do: results

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

  defp remote_opts(context) do
    context
    |> context_opts([:agent_id, :timeout])
    |> Keyword.put(:inject_agent_id, false)
  end

  defp local_opts(context), do: context_opts(context, [:agent_id, :store, :config])

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

  defp transport_error?(reason) when reason in @transport_errors, do: true
  defp transport_error?({:socket_closed, reason}), do: nested_transport_error?(reason)

  defp transport_error?({wrapper, reason}) when wrapper in @transport_wrappers,
    do: nested_transport_error?(reason)

  defp transport_error?(_reason), do: false

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
