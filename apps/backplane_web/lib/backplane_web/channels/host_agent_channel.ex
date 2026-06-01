defmodule BackplaneWeb.HostAgentChannel do
  use BackplaneWeb, :channel

  alias Backplane.PubSubBroadcaster
  alias Backplane.Skills.{AgentManage, DesiredState, SyncStatuses}

  @impl true
  def join("host_agent:" <> host_id, _payload, socket) do
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

  @impl true
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
