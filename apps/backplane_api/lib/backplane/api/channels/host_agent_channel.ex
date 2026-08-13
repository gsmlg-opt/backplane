defmodule Backplane.Api.HostAgentChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  require Logger

  alias Backplane.AgentTraces
  alias Backplane.Clients
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.{AgentManage, DesiredState, SyncStatuses}
  alias Backplane.Transport.McpHandler

  @max_memory_event_batch_size 100
  @max_memory_event_payload_bytes 512 * 1024
  @max_memory_sync_batch_size 50
  @max_memory_sync_payload_bytes 512 * 1024
  @default_host_agent_scopes ~w(host_agent.capture host_agent.recall host_agent.import)

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

  def handle_in("memory_call", %{"method" => method, "arguments" => args}, socket)
      when is_binary(method) and is_map(args) do
    case dispatch_memory(method, args, socket.assigns.host, host_agent_scopes()) do
      {:ok, result} ->
        {:reply, {:ok, %{"ok" => true, "result" => result}}, socket}

      {:error, reason} ->
        {:reply, {:ok, %{"ok" => false, "error" => format_memory_error(reason)}}, socket}
    end
  end

  def handle_in("memory_call", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("mcp_tools_list", payload, socket) when is_map(payload) do
    auth = host_memory_auth(socket.assigns.host, host_agent_scopes())

    tools =
      ToolRegistry.list_all()
      |> Clients.filter_tools(auth.scopes)
      |> Enum.map(&tool_to_json/1)

    {:reply, {:ok, %{"ok" => true, "result" => %{"tools" => tools}}}, socket}
  end

  def handle_in("mcp_tools_list", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("mcp_tool_call", %{"name" => name, "arguments" => args}, socket)
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

  def handle_in("mcp_tool_call", _payload, socket) do
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

  def handle_in("memory_sync", %{"protocol" => "host_memory.v1", "items" => items}, socket)
      when is_list(items) do
    payload = %{"protocol" => "host_memory.v1", "items" => items}

    case validate_memory_sync_payload(payload) do
      :ok -> apply_authorized_memory_sync(socket, items)
      {:error, reason} -> {:reply, {:error, %{"reason" => reason}}, socket}
    end
  end

  def handle_in("memory_sync", _payload, socket) do
    invalid_payload(socket)
  end

  def handle_in("memory_import_batch", %{"protocol" => "host_import.v1"} = payload, socket) do
    if authorized?("host_agent.import", host_agent_scopes()) do
      case safe_memory_import_record(socket.assigns.host.id, payload) do
        {:ok, reply} -> {:reply, {:ok, %{"ok" => true, "result" => reply}}, socket}
        {:error, reason} -> {:reply, {:error, %{"reason" => format_memory_error(reason)}}, socket}
      end
    else
      {:reply, {:error, %{"reason" => "unauthorized"}}, socket}
    end
  end

  def handle_in("memory_import_batch", _payload, socket), do: invalid_payload(socket)

  def handle_in("memory_events", payload, socket) when is_map(payload) do
    case validate_and_authorize_memory_events(payload, socket) do
      :ok ->
        auth_context = %{
          host_id: socket.assigns.host.id,
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

      {:error, reason} ->
        {:reply, {:error, %{"reason" => reason}}, socket}

      false ->
        {:reply, {:error, %{"reason" => "unauthorized"}}, socket}
    end
  end

  def handle_in("memory_events", _payload, socket) do
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
    safe_push_memory_reconcile(payload, socket)
    {:noreply, socket}
  end

  def handle_info({:mcp_notification, notification}, socket) do
    push(socket, "mcp_notification", notification)
    {:noreply, socket}
  end

  def handle_info({:agent_push, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(:disconnect, socket) do
    {:stop, :normal, socket}
  end

  defp dispatch_memory(method, args, host, scopes) do
    service = Application.get_env(:backplane_api, :memory_service, Backplane.Memory.Service)
    auth = host_memory_auth(host, scopes)

    with true <- authorized?(memory_method_permission(method), scopes) do
      case method do
        "remember" ->
          service.handle_remember(args, auth)

        "lifecycle_context" ->
          service.handle_lifecycle_context(args, auth)

        operation when operation in ~w(recall list forget stats) ->
          service.call("memory::#{operation}", args, auth)

        _ ->
          {:error, {:unknown_method, method}}
      end
    else
      false -> {:error, :unauthorized}
    end
  end

  defp memory_method_permission(method) when method in ~w(recall list stats lifecycle_context),
    do: "host_agent.recall"

  defp memory_method_permission(method) when method in ~w(remember forget),
    do: "host_agent.import"

  defp memory_method_permission(_method), do: "host_agent.recall"

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
      principal_metadata: %{"memory_partition_id" => "host:#{host.id}"}
    }
  end

  defp maybe_add_memory_scope(memory_scopes, host_agent_scopes, permission, memory_scope) do
    if authorized?(permission, host_agent_scopes),
      do: [memory_scope | memory_scopes],
      else: memory_scopes
  end

  defp push_memory_reconcile(payload, socket) do
    if authorized?("host_agent.recall", host_agent_scopes()) do
      do_push_memory_reconcile(payload, socket)
    else
      :ok
    end
  end

  defp do_push_memory_reconcile(payload, socket) do
    adapter = memory_sync_adapter()
    announced_scopes = announced_memory_scopes(payload)
    entitled_scopes = adapter.entitled_scopes(socket.assigns.host)

    announced_scopes
    |> Enum.filter(fn %{"scope" => scope} -> MapSet.member?(entitled_scopes, scope) end)
    |> Enum.each(fn %{"scope" => scope, "fact_set_hash" => fact_set_hash} ->
      case adapter.facts_for_scope(socket.assigns.host, scope, fact_set_hash) do
        {:full, facts} ->
          push(socket, "memory_facts", %{"scope" => scope, "full" => true, "facts" => facts})

        :unchanged ->
          :ok

        _other ->
          :ok
      end

      case adapter.active_wipes(socket.assigns.host, scope) do
        [] ->
          :ok

        wipes when is_list(wipes) ->
          push(socket, "memory_wipe", wipe_payload(wipes))

        _other ->
          :ok
      end
    end)
  end

  defp host_agent_scopes do
    Application.get_env(:backplane_api, :host_agent_scopes, @default_host_agent_scopes)
  end

  defp authorized?(permission, scopes),
    do: is_list(scopes) and (permission in scopes or "*" in scopes)

  defp safe_push_memory_reconcile(payload, socket) do
    push_memory_reconcile(payload, socket)
  rescue
    error ->
      Logger.warning("Host-agent memory reconcile failed",
        host_id: socket.assigns.host.id,
        failure: inspect(error.__struct__)
      )

      :ok
  catch
    kind, _reason ->
      Logger.warning("Host-agent memory reconcile failed",
        host_id: socket.assigns.host.id,
        failure: Atom.to_string(kind)
      )

      :ok
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

  defp apply_authorized_memory_sync(socket, items) do
    case authorized?("host_agent.import", host_agent_scopes()) &&
           apply_memory_sync(socket.assigns.host, items) do
      {:ok, ack_items} ->
        {:reply, {:ok, %{"items" => ack_items}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => format_memory_error(reason)}}, socket}

      false ->
        {:reply, {:error, %{"reason" => "unauthorized"}}, socket}
    end
  end

  defp validate_memory_sync_payload(%{"items" => items} = payload) do
    cond do
      length(items) > @max_memory_sync_batch_size -> {:error, "batch_too_large"}
      true -> validate_encoded_payload(payload, @max_memory_sync_payload_bytes)
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
      :backplane_api,
      :host_memory_sync_adapter,
      Backplane.Api.HostAgentMemorySync
    )
  end

  defp safe_memory_import_record(host_id, payload) do
    memory_import_adapter().record(host_id, payload)
  rescue
    _error -> {:error, :import_unavailable}
  catch
    :exit, _reason -> {:error, :import_unavailable}
  end

  defp memory_import_adapter do
    Application.get_env(:backplane_api, :host_memory_import_adapter, Backplane.Memory.Imports)
  end

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

  defp authorized_memory_events?(%{"events" => events}) when is_list(events) do
    authorized?("host_agent.capture", host_agent_scopes()) or
      (authorized?("host_agent.import", host_agent_scopes()) and events != [] and
         Enum.all?(events, &(is_map(&1) and Map.get(&1, "integration") == "claude_code_import")))
  end

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
  defp format_memory_error({:unknown_method, name}), do: "unknown memory method: #{name}"
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
