defmodule BackplaneWeb.HostAgentChannel do
  use BackplaneWeb, :channel

  alias Backplane.PubSubBroadcaster
  alias Backplane.Skills.{AgentManage, DesiredState, SyncStatuses}

  @impl true
  def join("host_agent:" <> host_id, payload, socket) do
    if socket.assigns.host.id == host_id do
      metadata = Map.get(socket.assigns, :connection_metadata, %{})

      case AgentManage.register_connection(
             socket.assigns.host,
             socket.assigns.auth_token,
             self(),
             metadata
           ) do
        :ok ->
          PubSubBroadcaster.subscribe(PubSubBroadcaster.mcp_notifications_topic())
          send(self(), {:memory_reconcile, payload})
          {:ok, socket}

        {:error, :not_started} ->
          {:error, %{reason: "registry_unavailable"}}
      end
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("heartbeat", payload, socket) when is_map(payload) do
    case AgentManage.update_runtime(socket.assigns.host.id, payload) do
      :ok -> {:reply, {:ok, %{"ok" => true}}, socket}
      {:error, _reason} -> invalid_payload(socket)
    end
  end

  def handle_in("heartbeat", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("config_report", payload, socket) when is_map(payload) do
    case AgentManage.report_config(socket.assigns.host.id, payload) do
      :ok -> {:reply, {:ok, %{"ok" => true}}, socket}
      {:error, _reason} -> invalid_payload(socket)
    end
  end

  def handle_in("config_report", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("get_desired", _payload, socket) do
    {:ok, desired_state} = DesiredState.for_host(socket.assigns.host)

    {:reply, {:ok, json_shape(desired_state)}, socket}
  end

  def handle_in("get_skill_bundle", payload, socket) when is_map(payload) do
    slug_or_id = payload["slug"] || payload["id"]
    chunk_index = payload["chunk_index"] || 0
    chunk_size = payload["chunk_size"] || 49_152

    if is_binary(slug_or_id) and is_integer(chunk_index) and is_integer(chunk_size) do
      case AgentManage.skill_bundle_chunk(
             socket.assigns.host.id,
             slug_or_id,
             chunk_index,
             chunk_size
           ) do
        {:ok, chunk} ->
          {:reply, {:ok, %{"ok" => true, "result" => chunk}}, socket}

        {:error, reason} ->
          {:reply, {:ok, %{"ok" => false, "error" => format_memory_error(reason)}}, socket}
      end
    else
      invalid_payload(socket)
    end
  end

  def handle_in("get_skill_bundle", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("sync_started", payload, socket) when is_map(payload) do
    {:reply, {:ok, %{"ok" => true}}, socket}
  end

  def handle_in("sync_started", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("sync_result", payload, socket) when is_map(payload) do
    case SyncStatuses.record_sync_result(socket.assigns.host, payload) do
      {:ok, _statuses} ->
        AgentManage.record_sync(socket.assigns.host.id, payload)
        {:reply, {:ok, %{"ok" => true}}, socket}

      {:error, _reason} ->
        invalid_payload(socket)
    end
  end

  def handle_in("sync_result", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("sync_error", payload, socket) when is_map(payload) do
    {:reply, {:ok, Map.put(payload, "ok", true)}, socket}
  end

  def handle_in("sync_error", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("memory_call", %{"method" => method, "arguments" => args}, socket)
      when is_binary(method) and is_map(args) do
    case dispatch_memory(method, args, socket.assigns.host.id) do
      {:ok, result} ->
        {:reply, {:ok, %{"ok" => true, "result" => result}}, socket}

      {:error, reason} ->
        {:reply, {:ok, %{"ok" => false, "error" => format_memory_error(reason)}}, socket}
    end
  end

  def handle_in("memory_call", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("memory_sync", %{"protocol" => "host_memory.v1", "items" => items}, socket)
      when is_list(items) do
    case apply_memory_sync(socket.assigns.host, items) do
      {:ok, ack_items} ->
        {:reply, {:ok, %{"items" => ack_items}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => format_memory_error(reason)}}, socket}
    end
  end

  def handle_in("memory_sync", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("memory_facts_ack", payload, socket) when is_map(payload) do
    {:reply, {:ok, %{"ok" => true}}, socket}
  end

  def handle_in("memory_facts_ack", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("memory_wipe_ack", payload, socket) when is_map(payload) do
    {:reply, {:ok, %{"ok" => true}}, socket}
  end

  def handle_in("memory_wipe_ack", _payload, socket) do
    invalid_payload(socket)
  end

  @impl true
  def handle_info({:memory_reconcile, payload}, socket) do
    push_memory_reconcile(payload, socket)
    {:noreply, socket}
  end

  def handle_info({:mcp_notification, notification}, socket) do
    push(socket, "mcp_notification", notification)
    {:noreply, socket}
  end

  def handle_info(:disconnect, socket) do
    {:stop, :normal, socket}
  end

  defp dispatch_memory(method, args, host_id) do
    args = Map.put(args, "host_id", host_id)
    service = Application.get_env(:backplane_web, :memory_service, BackplaneMemory.Service)

    case method do
      "remember" -> service.handle_remember(args)
      "recall" -> service.handle_recall(args)
      "list" -> service.handle_list(args)
      "forget" -> service.handle_forget(args)
      "stats" -> service.handle_stats(args)
      _ -> {:error, {:unknown_method, method}}
    end
  end

  defp push_memory_reconcile(payload, socket) do
    adapter = memory_sync_adapter()
    announced_scopes = announced_memory_scopes(payload)
    entitled_scopes = adapter.entitled_scopes(socket.assigns.host)

    announced_scopes
    |> Enum.filter(fn %{"scope" => scope} -> MapSet.member?(entitled_scopes, scope) end)
    |> Enum.each(fn %{"scope" => scope, "fact_set_hash" => fact_set_hash} ->
      case adapter.facts_for_scope(scope, fact_set_hash) do
        {:full, facts} ->
          push(socket, "memory_facts", %{"scope" => scope, "full" => true, "facts" => facts})

        :unchanged ->
          :ok

        _other ->
          :ok
      end

      case adapter.active_wipes(scope) do
        [] ->
          :ok

        wipes when is_list(wipes) ->
          push(socket, "memory_wipe", wipe_payload(wipes))

        _other ->
          :ok
      end
    end)
  end

  defp announced_memory_scopes(%{
         "memory" => %{"protocol" => "host_memory.v1", "scopes" => scopes}
       })
       when is_list(scopes) do
    scopes
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn scope ->
      case scope do
        %{"scope" => name} when is_binary(name) ->
          [%{"scope" => name, "fact_set_hash" => scope["fact_set_hash"] || ""}]

        _other ->
          []
      end
    end)
  end

  defp announced_memory_scopes(_payload), do: []

  defp wipe_payload([first | _] = wipes) do
    directive_id = first["directive_id"] || "active"

    %{
      "directive_id" => directive_id,
      "items" => Enum.map(wipes, &Map.drop(&1, ["directive_id"]))
    }
  end

  defp apply_memory_sync(host, items) do
    adapter = memory_sync_adapter()

    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case apply_memory_sync_item(adapter, host, item) do
        {:ok, ack} -> {:cont, {:ok, [ack | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ack_items} -> {:ok, Enum.reverse(ack_items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_memory_sync_item(adapter, host, %{"id" => id} = item) when is_binary(id) do
    case adapter.apply_sync_item(host, item) do
      {:ok, %{status: status, canonical_id: canonical_id}} when status in [:ok, :duplicate] ->
        {:ok,
         %{
           "id" => id,
           "status" => Atom.to_string(status),
           "canonical_id" => canonical_id,
           "error" => nil
         }}

      {:error, :validation, reason} ->
        {:ok,
         %{
           "id" => id,
           "status" => "error",
           "canonical_id" => nil,
           "error" => format_memory_error(reason)
         }}

      {:error, :transient, reason} ->
        {:error, reason}

      other ->
        {:ok,
         %{
           "id" => id,
           "status" => "error",
           "canonical_id" => nil,
           "error" => format_memory_error({:unexpected_sync_reply, other})
         }}
    end
  end

  defp apply_memory_sync_item(_adapter, _host, _item) do
    {:error, "memory sync item id is required"}
  end

  defp memory_sync_adapter do
    Application.get_env(
      :backplane_web,
      :host_memory_sync_adapter,
      BackplaneWeb.HostAgentMemorySync
    )
  end

  defp format_memory_error(reason) when is_binary(reason), do: reason
  defp format_memory_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_memory_error({:unknown_method, name}), do: "unknown memory method: #{name}"
  defp format_memory_error(reason), do: inspect(reason)

  defp invalid_payload(socket) do
    {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
  end

  defp json_shape(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
