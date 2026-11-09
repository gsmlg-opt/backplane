defmodule Backplane.Api.HostAgentChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  require Logger
  import Ecto.Query

  alias Backplane.AgentTraces
  alias Backplane.Clients
  alias Backplane.Memory.Records
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.{AgentManage, DesiredState, Hosts, SyncStatuses}
  alias Backplane.Transport.McpHandler

  @max_memory_event_batch_size 100
  @max_memory_event_payload_bytes 512 * 1024
  @default_host_agent_scopes ~w(host_agent.capture host_agent.recall host_agent.import)

  @impl true
  def join("host_agent:" <> host_id, payload, socket) do
    with true <- socket.assigns.host.id == host_id,
         true <- active_token?(socket),
         metadata = Map.get(socket.assigns, :connection_metadata, %{}),
         :ok <-
           AgentManage.register_connection(
             socket.assigns.host,
             socket.assigns.auth_token,
             self(),
             metadata
           ) do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.mcp_notifications_topic())

      socket = Backplane.Api.HostApiChannel.join(socket, payload)
      {:ok, %{}, socket}
    else
      false -> {:error, %{reason: "unauthorized"}}
      {:error, :not_started} -> {:error, %{reason: "registry_unavailable"}}
      {:error, reason} -> {:error, %{reason: format_memory_error(reason)}}
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

  def handle_in("api_services_registered", payload, socket) do
    Backplane.Api.HostApiChannel.registered(socket, payload, active_token?(socket))
  end

  def handle_in("api_response", payload, socket) do
    Backplane.Api.HostApiChannel.response(socket, payload, active_token?(socket))
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

  def handle_in("plugin_call_result", %{"call_id" => call_id} = payload, socket)
      when is_binary(call_id) do
    case AgentManage.complete_plugin_call(socket.assigns.host.id, call_id, payload) do
      :ok -> {:reply, {:ok, %{"ok" => true}}, socket}
      {:error, _reason} -> invalid_payload(socket)
    end
  end

  def handle_in("plugin_call_result", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("trace_sync", %{"protocol" => "host_trace.v1", "items" => items}, socket)
      when is_list(items) do
    ack_items =
      socket.assigns.host.id
      |> AgentTraces.ingest(items)
      |> Enum.map(&trace_sync_ack_item/1)

    {:reply, {:ok, %{"ok" => true, "result" => %{"items" => ack_items}}}, socket}
  end

  def handle_in("trace_sync", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in(event, payload, socket)
      when event in ~w(mcp_tools_list mcp_tool_call memory_events memory_pull) do
    if active_token?(socket) do
      handle_memory_in(event, payload, socket)
    else
      {:reply, {:error, %{"code" => "unauthorized", "retryable" => false}}, socket}
    end
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{"code" => "unsupported_protocol", "retryable" => false}}, socket}
  end

  defp handle_memory_in("mcp_tools_list", payload, socket) when is_map(payload) do
    auth = host_memory_auth(socket.assigns.host, host_agent_scopes())

    tools =
      ToolRegistry.list_all()
      |> Clients.filter_tools(auth.scopes)
      |> Enum.map(&tool_to_json/1)

    {:reply, {:ok, %{"ok" => true, "result" => %{"tools" => tools}}}, socket}
  end

  defp handle_memory_in("mcp_tools_list", _payload, socket) do
    invalid_payload(socket)
  end

  defp handle_memory_in("mcp_tool_call", %{"name" => name, "arguments" => args}, socket)
       when is_binary(name) and is_map(args) do
    auth = host_memory_auth(socket.assigns.host, host_agent_scopes())

    case Clients.scope_matches?(auth.scopes, name) &&
           McpHandler.dispatch_tool_call(name, args, auth) do
      {:ok, result} ->
        {:reply, {:ok, %{"ok" => true, "result" => result}}, socket}

      {:error, reason} ->
        {:reply, {:ok, %{"ok" => false, "error" => format_memory_error(reason)}}, socket}

      false ->
        {:reply, {:ok, %{"ok" => false, "error" => "unauthorized"}}, socket}
    end
  end

  defp handle_memory_in("mcp_tool_call", _payload, socket) do
    invalid_payload(socket)
  end

  defp handle_memory_in("memory_pull", payload, socket) when is_map(payload) do
    with true <- authorized?("host_agent.recall", host_agent_scopes()),
         {:ok, cursor} <- parse_pull_cursor(payload["cursor"]) do
      limit = if is_integer(payload["limit"]), do: payload["limit"], else: 100
      records = Records.changed_since(socket.assigns.host.id, cursor, limit)

      next =
        case List.last(records) do
          nil -> payload["cursor"]
          last -> %{"updated_at" => DateTime.to_iso8601(last.updated_at), "id" => last.id}
        end

      {:reply, {:ok, %{"records" => Enum.map(records, &pull_record/1), "cursor" => next}}, socket}
    else
      false -> {:reply, {:error, %{"code" => "unauthorized", "retryable" => false}}, socket}
      :error -> {:reply, {:error, %{"code" => "invalid_cursor", "retryable" => false}}, socket}
    end
  end

  defp handle_memory_in("memory_pull", _payload, socket), do: invalid_payload(socket)

  defp handle_memory_in("memory_events", payload, socket) when is_map(payload) do
    case validate_and_authorize_memory_events(payload, socket) do
      :ok ->
        case safe_memory_event_host(socket.assigns.host.id) do
          {:ok, host} ->
            ingest_memory_events(host, socket, payload)

          {:error, :ingest_unavailable} ->
            {:reply, {:error, %{"reason" => "ingest_unavailable"}}, socket}
        end

      {:error, reason} ->
        {:reply, {:error, %{"reason" => reason}}, socket}

      false ->
        {:reply, {:error, %{"reason" => "unauthorized"}}, socket}
    end
  end

  defp handle_memory_in("memory_events", _payload, socket) do
    invalid_payload(socket)
  end

  # The host matches a pulled copy to its own pending row by request_key, so
  # pull replies carry it; MCP tool output does not.
  defp pull_record(record),
    do: record |> Records.to_map() |> Map.put("request_key", record.request_key)

  @impl true
  def handle_info(event, socket) when event in [:host_api_services, :host_api_services_changed] do
    Backplane.Api.HostApiChannel.inventory(socket, active_token?(socket))
  end

  def handle_info({:host_api_request, id, payload}, socket) do
    Backplane.Api.HostApiChannel.request(socket, id, payload, active_token?(socket))
  end

  def handle_info({:host_api_ack, reference, result}, socket) do
    Backplane.Api.HostApiChannel.ack(socket, reference, result, active_token?(socket))
  end

  def handle_info({:host_api_cancel, id}, socket) do
    Backplane.Api.HostApiChannel.cancel(socket, id)
  end

  def handle_info({:mcp_notification, notification}, socket) do
    if active_token?(socket), do: push(socket, "mcp_notification", notification)
    {:noreply, socket}
  end

  def handle_info({:agent_push, event, payload}, socket) do
    if active_token?(socket), do: push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(:disconnect, socket) do
    {:stop, :normal, socket}
  end

  defp active_token?(socket) do
    host = socket.assigns.host.id
    token = socket.assigns.auth_token.id

    Backplane.Repo.exists?(
      from a in Backplane.Skills.HostAgentToken,
        join: t in Backplane.Skills.HostAuthToken,
        on: t.id == a.auth_token_id,
        where: a.host_id == ^host and t.id == ^token
    )
  end

  defp host_memory_auth(host, host_agent_scopes) do
    memory_scopes =
      []
      |> maybe_add_memory_scope(host_agent_scopes, "host_agent.recall", "memory.read")
      |> maybe_add_memory_scope(host_agent_scopes, "host_agent.import", "memory.write")

    %{
      kind: :client_token,
      client_id: host.id,
      scopes: memory_scopes,
      subject: host.id,
      principal_metadata: %{"host_id" => host.id}
    }
  end

  defp maybe_add_memory_scope(memory_scopes, host_agent_scopes, permission, memory_scope) do
    if authorized?(permission, host_agent_scopes),
      do: [memory_scope | memory_scopes],
      else: memory_scopes
  end

  defp host_agent_scopes do
    Application.get_env(:backplane_api, :host_agent_scopes, @default_host_agent_scopes)
  end

  defp authorized?(permission, scopes),
    do: is_list(scopes) and (permission in scopes or "*" in scopes)

  defp parse_pull_cursor(nil), do: {:ok, nil}

  defp parse_pull_cursor(%{"updated_at" => at, "id" => id}) when is_binary(at) and is_binary(id) do
    with {:ok, dt, _} <- DateTime.from_iso8601(at),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, %{updated_at: dt, id: uuid}}
    else
      _ -> :error
    end
  end

  defp parse_pull_cursor(_), do: :error

  defp validate_memory_events_payload(
         %{
           "protocol" => "host_events.v1",
           "batch_id" => batch_id,
           "host_id" => host_id,
           "events" => events
         } = payload,
         socket
       )
       when is_binary(batch_id) and is_binary(host_id) do
    cond do
      String.trim(batch_id) == "" or String.trim(host_id) == "" ->
        {:error, "invalid_payload"}

      not proper_list?(events) ->
        {:error, "invalid_payload"}

      host_id != socket.assigns.host.id ->
        {:error, "host_mismatch"}

      length(events) > @max_memory_event_batch_size ->
        {:error, "batch_too_large"}

      true ->
        validate_encoded_payload(payload)
    end
  end

  defp validate_memory_events_payload(_payload, _socket), do: {:error, "invalid_payload"}

  defp validate_and_authorize_memory_events(payload, socket) do
    case validate_memory_events_payload(payload, socket) do
      :ok -> if(authorized_memory_events?(payload), do: :ok, else: false)
      {:error, _reason} = error -> error
    end
  end

  defp authorized_memory_events?(%{"events" => events}) when is_list(events),
    do: authorized?("host_agent.capture", host_agent_scopes())

  defp authorized_memory_events?(_payload), do: false

  defp validate_encoded_payload(payload) do
    validate_encoded_payload(payload, @max_memory_event_payload_bytes)
  end

  defp validate_encoded_payload(payload, max_bytes) do
    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes -> :ok
      {:ok, _encoded} -> {:error, "payload_too_large"}
      {:error, _reason} -> {:error, "invalid_payload"}
    end
  rescue
    _error -> {:error, "invalid_payload"}
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  defp host_event_ingest_adapter do
    Application.get_env(
      :backplane_api,
      :host_event_ingest_adapter,
      Backplane.Memory.Ingest
    )
  end

  defp safe_memory_event_host(host_id) do
    case Hosts.get_host(host_id) do
      %{id: ^host_id} = host ->
        {:ok, host}

      _missing_or_invalid ->
        unavailable_host_registration(host_id)
    end
  rescue
    error ->
      log_host_event_ingest_failure(host_id, {:host_refresh_exception, error.__struct__})
      {:error, :ingest_unavailable}
  catch
    kind, _reason ->
      log_host_event_ingest_failure(host_id, {:host_refresh_caught, kind})
      {:error, :ingest_unavailable}
  end

  defp unavailable_host_registration(host_id) do
    log_host_event_ingest_failure(host_id, :host_registration_unavailable)
    {:error, :ingest_unavailable}
  end

  defp ingest_memory_events(host, socket, payload) do
    auth_context = %{
      host_id: host.id,
      auth_token_id: socket.assigns.auth_token.id,
      scopes: host_agent_scopes()
    }

    case safe_host_event_ingest(auth_context, payload) do
      {:ok, reply} when is_map(reply) ->
        {:reply, {:ok, reply}, socket}

      {:error, :host_mismatch} ->
        {:reply, {:error, %{"reason" => "host_mismatch"}}, socket}

      {:error, :invalid_batch} ->
        invalid_payload(socket)

      {:error, :ingest_unavailable} ->
        {:reply, {:error, %{"reason" => "ingest_unavailable"}}, socket}
    end
  end

  defp safe_host_event_ingest(auth_context, %{"batch_id" => expected_batch_id} = payload) do
    case host_event_ingest_adapter().ingest_batch(auth_context, payload) do
      {:ok, %{"batch_id" => batch_id, "results" => results} = reply} ->
        if batch_id == expected_batch_id and proper_list?(results) and json_encodable?(reply) do
          {:ok, reply}
        else
          unavailable_host_event_ingest(auth_context.host_id)
        end

      {:error, reason} when reason in [:host_mismatch, :invalid_batch] ->
        {:error, reason}

      _unexpected ->
        unavailable_host_event_ingest(auth_context.host_id)
    end
  rescue
    error ->
      log_host_event_ingest_failure(auth_context.host_id, {:exception, error.__struct__})
      {:error, :ingest_unavailable}
  catch
    kind, _reason ->
      log_host_event_ingest_failure(auth_context.host_id, {:caught, kind})
      {:error, :ingest_unavailable}
  end

  defp log_host_event_ingest_failure(host_id, category) do
    Logger.warning("Host event ingest failed for #{host_id}: #{inspect(category)}")
  end

  defp unavailable_host_event_ingest(host_id) do
    log_host_event_ingest_failure(host_id, :unexpected_reply)
    {:error, :ingest_unavailable}
  end

  defp json_encodable?(value) do
    match?({:ok, _encoded}, Jason.encode(value))
  rescue
    _error -> false
  end

  defp format_memory_error(reason) when is_binary(reason), do: reason
  defp format_memory_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_memory_error(reason), do: inspect(reason)

  defp trace_sync_ack_item({seq, :ok}) do
    %{"seq" => seq, "status" => "ok"}
  end

  defp trace_sync_ack_item({seq, {:error, reason}}) do
    %{"seq" => seq, "status" => "error", "error" => format_memory_error(reason)}
  end

  defp tool_to_json(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.input_schema
    }
    |> maybe_put("annotations", tool.annotations)
    |> maybe_put("outputSchema", tool.output_schema)
    |> maybe_put("icon", tool.icon)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp invalid_payload(socket) do
    {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
  end

  defp json_shape(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
