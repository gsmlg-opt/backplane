defmodule Backplane.Api.HostAgentChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false

  require Logger
  import Ecto.Query

  alias Backplane.AgentTraces
  alias Backplane.Clients
  alias Backplane.MemorySpaces
  alias Backplane.Memory.{Config, EdgeSync}
  alias Backplane.Api.HostAgentMemorySync
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.{AgentManage, DesiredState, Hosts, SyncStatuses}
  alias Backplane.Transport.McpHandler

  @max_memory_event_batch_size 100
  @max_memory_event_payload_bytes 512 * 1024
  @default_host_agent_scopes ~w(host_agent.capture host_agent.recall host_agent.import)
  @memory_authority_keys ~w(memory_space_id partition_id host_id client_id scope namespace)
  @memory_authority_atom_keys ~w(memory_space_id partition_id host_id client_id scope namespace)a

  @impl true
  def join("host_agent:" <> host_id, payload, socket) do
    with true <- socket.assigns.host.id == host_id,
         true <- active_token?(socket),
         {:ok, negotiation} <- negotiate_memory(socket, payload),
         {:ok, partition} <- join_partition(host_id, negotiation),
         metadata = Map.get(socket.assigns, :connection_metadata, %{}),
         :ok <-
           AgentManage.register_connection(
             socket.assigns.host,
             socket.assigns.auth_token,
             self(),
             metadata
           ) do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.mcp_notifications_topic())

      if negotiation.selected == "host_memory.v2",
        do: Backplane.Memory.EdgeSync.Notifier.subscribe()

      # Phoenix.Channel subscribes this process to its host topic after join.
      # A second subscription would duplicate each memory_access_changed hint.

      partition =
        if partition,
          do:
            Map.merge(partition, %{
              host_id: host_id,
              client_id: host_id,
              source_client_id: host_id
            })

      socket =
        socket
        |> assign(:memory_partition, partition)
        |> assign(:memory_protocol, negotiation.selected)
        |> assign(:memory_limits, Map.get(negotiation, :limits, %{}))
        |> assign(:memory_extensions, Map.get(negotiation, :extensions, []))

      reply =
        if is_nil(negotiation.selected),
          do:
            json_shape(%{
              memory_partition: Map.take(partition, [:memory_space_id, :scope, :namespace])
            }),
          else: json_shape(negotiation)

      {:ok, reply, socket}
    else
      false -> {:error, %{reason: "unauthorized"}}
      {:error, :not_started} -> {:error, %{reason: "registry_unavailable"}}
      {:error, %{code: _} = error} -> {:error, json_shape(error)}
      {:error, reason} -> {:error, %{reason: format_memory_error(reason)}}
    end
  end

  defp negotiate_memory(socket, payload) when is_map(payload) do
    cond do
      not Map.has_key?(payload, "memory") and not Map.has_key?(payload, "memory_v2") and
          not Map.has_key?(payload, "selected") ->
        {:ok, %{selected: nil}}

      not authorized?("host_agent.recall", host_agent_scopes()) and
          not access_offered?(payload) ->
        {:error, %{code: :unauthorized, retryable: false}}

      not valid_memory_offer?(payload) ->
        {:error, %{code: :invalid_request, retryable: false}}

      true ->
        EdgeSync.negotiate(shared_auth(socket), payload)
    end
  end

  defp negotiate_memory(_, _), do: {:error, %{code: :invalid_request, retryable: false}}

  defp access_offered?(%{"memory_v2" => %{"extensions" => extensions}}) when is_list(extensions),
    do: "memory_access.v1" in extensions

  defp access_offered?(_), do: false

  defp join_partition(host, negotiation) do
    case MemorySpaces.resolve_host_partition(host, nil, "private") do
      {:ok, partition} ->
        {:ok, partition}

      {:error, reason} when reason in [:unauthorized, :partition_not_ready] ->
        if "memory_access.v1" in Map.get(negotiation, :extensions, []),
          do: {:ok, nil},
          else: {:error, reason}

      error ->
        error
    end
  end

  defp valid_memory_offer?(payload),
    do:
      not Map.has_key?(payload, "memory") and
        validate_encoded_payload(payload, @max_memory_event_payload_bytes) == :ok

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
      when event in ~w(memory_access_refresh memory_call mcp_tools_list mcp_tool_call memory_sync memory_import_batch memory_events memory_next memory_ack) do
    if active_token?(socket) do
      handle_memory_in(event, payload, socket)
    else
      {:reply, {:error, %{"code" => "unauthorized", "retryable" => false}}, socket}
    end
  end

  def handle_in(_event, _payload, socket) do
    memory_reply({:error, :unsupported_protocol}, socket)
  end

  defp handle_memory_in("memory_access_refresh", payload, socket)
       when is_map(payload) and map_size(payload) == 0 do
    result =
      with :ok <- selected_extension(socket, "memory_access.v1") do
        offer =
          socket.assigns.memory_limits
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.merge(%{
            "offers" => ["host_memory.v2"],
            "partitions" => [],
            "extensions" => socket.assigns.memory_extensions
          })

        EdgeSync.negotiate(shared_auth(socket), %{"memory_v2" => offer})
      end

    memory_reply(result, socket)
  end

  defp handle_memory_in("memory_access_refresh", _payload, socket), do: invalid_payload(socket)

  defp handle_memory_in(
         "memory_call",
         %{"access" => access, "method" => method, "arguments" => args} = payload,
         socket
       )
       when is_binary(method) and is_map(args) do
    result =
      with :ok <- selected_extension(socket, "memory_access.v1"),
           true <- Map.drop(payload, ~w(method arguments access traceparent)) == %{},
           {:ok, claim} <- access_claim(access) do
        service = Application.get_env(:backplane_api, :memory_service, Backplane.Memory.Service)
        service.call_shared("memory::" <> method, args, shared_auth(socket), claim)
      else
        false -> {:error, :invalid_request}
        error -> error
      end

    case result do
      {:ok, reply} ->
        {:reply, {:ok, %{"ok" => true, "result" => json_shape(reply)}}, socket}

      {:error, reason} ->
        {:reply, {:ok, %{"ok" => false, "error" => format_memory_error(reason)}}, socket}
    end
  end

  defp handle_memory_in("memory_sync", %{"protocol" => "memory_commands.v2"} = payload, socket) do
    result =
      with :ok <- selected_extension(socket, "memory_access.v1"),
           :ok <- selected_extension(socket, "memory_commands.v2"),
           :ok <- selected_sources_extension(socket, payload) do
        EdgeSync.safe(fn -> HostAgentMemorySync.settle_commands(shared_auth(socket), payload) end)
      end

    memory_reply(result, socket)
  end

  defp handle_memory_in("memory_call", _payload, %{assigns: %{memory_partition: nil}} = socket),
    do: {:reply, {:ok, %{"ok" => false, "error" => "unauthorized"}}, socket}

  defp handle_memory_in(event, _payload, %{assigns: %{memory_partition: nil}} = socket)
       when event in ~w(mcp_tools_list mcp_tool_call memory_sync memory_import_batch memory_events),
       do: memory_reply({:error, %{code: :unauthorized}}, socket)

  defp handle_memory_in("memory_call", %{"method" => method, "arguments" => args}, socket)
       when is_binary(method) and is_map(args) do
    case dispatch_memory(
           method,
           args,
           socket.assigns.host,
           socket.assigns.memory_partition,
           host_agent_scopes()
         ) do
      {:ok, result} ->
        {:reply, {:ok, %{"ok" => true, "result" => result}}, socket}

      {:error, reason} ->
        {:reply, {:ok, %{"ok" => false, "error" => format_memory_error(reason)}}, socket}
    end
  end

  defp handle_memory_in("memory_call", _payload, socket) do
    invalid_payload(socket)
  end

  defp handle_memory_in("mcp_tools_list", payload, socket) when is_map(payload) do
    auth =
      host_memory_auth(
        socket.assigns.host,
        socket.assigns.memory_partition,
        host_agent_scopes()
      )

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
    auth =
      host_memory_auth(
        socket.assigns.host,
        socket.assigns.memory_partition,
        host_agent_scopes()
      )

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

  defp handle_memory_in("memory_sync", _payload, socket) do
    memory_reply({:error, :unsupported_protocol}, socket)
  end

  defp handle_memory_in(
         "memory_import_batch",
         %{"protocol" => "host_import.v1"} = payload,
         socket
       ) do
    if authorized?("host_agent.import", host_agent_scopes()) do
      case safe_memory_import_record(socket.assigns.memory_partition, payload) do
        {:ok, reply} -> {:reply, {:ok, %{"ok" => true, "result" => reply}}, socket}
        {:error, reason} -> {:reply, {:error, %{"reason" => format_memory_error(reason)}}, socket}
      end
    else
      {:reply, {:error, %{"reason" => "unauthorized"}}, socket}
    end
  end

  defp handle_memory_in("memory_import_batch", _payload, socket), do: invalid_payload(socket)

  defp handle_memory_in("memory_events", payload, socket) when is_map(payload) do
    case validate_and_authorize_memory_events(payload, socket) do
      :ok ->
        case safe_memory_event_host(socket.assigns.host.id) do
          {:ok, host} ->
            ingest_bound_memory_events(host, socket, payload)

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

  defp handle_memory_in("memory_next", payload, socket), do: edge_request(:next, payload, socket)
  defp handle_memory_in("memory_ack", payload, socket), do: edge_request(:ack, payload, socket)

  defp selected_sources_extension(socket, %{"items" => items}) when is_list(items) do
    cond do
      not Enum.all?(items, &is_map/1) ->
        {:error, :invalid_request}

      Enum.any?(items, &(&1["op"] in ~w(source_mutate source_reconcile))) ->
        with :ok <- selected_extension(socket, "memory_sources.v1") do
          if Enum.any?(
               items,
               &(get_in(&1, ["arguments", "source", "integration"]) == "openclaw")
             ),
             do: selected_extension(socket, "openclaw_source.v1"),
             else: :ok
        end

      true ->
        :ok
    end
  end

  defp selected_sources_extension(_, _), do: {:error, :invalid_request}

  @impl true
  def handle_info({:memory_access_changed, hint}, socket) do
    if active_token?(socket) and selected_extension(socket, "memory_access.v1") == :ok,
      do: push(socket, "memory_access_changed", hint)

    {:noreply, socket}
  end

  def handle_info({:memory_available, hint}, socket) do
    if active_token?(socket) and valid_memory_hint?(hint, socket),
      do: push(socket, "memory_available", hint)

    {:noreply, socket}
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

  defp shared_auth(socket) do
    scopes = host_agent_scopes()
    scopes = if "*" in scopes, do: @default_host_agent_scopes, else: scopes

    %{
      kind: :host_agent,
      host_id: socket.assigns.host.id,
      auth_token_id: socket.assigns.auth_token.id,
      scopes: scopes,
      source_client_id: socket.assigns.host.id
    }
  end

  defp access_claim(%{"access_id" => id, "authority_version" => version} = claim)
       when map_size(claim) == 2 and is_integer(version) and version > 0 do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> {:ok, %{access_id: id, authority_version: version}}
      _ -> {:error, :invalid_request}
    end
  end

  defp access_claim(_), do: {:error, :invalid_request}

  defp selected_extension(socket, extension) do
    cond do
      socket.assigns.memory_protocol == "host_memory.v2" and
          extension in socket.assigns.memory_extensions ->
        :ok

      true ->
        {:error, :unsupported_protocol}
    end
  end

  defp valid_memory_hint?(hint, socket) when is_map(hint) do
    with :ok <- selected_memory_protocol(socket, "host_memory.v2"),
         true <- Config.host_sync_enabled?(),
         true <-
           Enum.sort(Map.keys(hint)) == ~w(current_revision memory_space_id namespace scope),
         true <- is_integer(hint["current_revision"]) and hint["current_revision"] >= 0,
         :ok <- validate_encoded_payload(hint, 8000),
         {:ok, inventory} <-
           memory_hint_inventory(socket) do
      Enum.any?(inventory, fn p ->
        p.memory_space_id == hint["memory_space_id"] and p.scope == hint["scope"] and
          p.namespace == hint["namespace"]
      end)
    else
      _ -> false
    end
  end

  defp valid_memory_hint?(_, _), do: false

  defp memory_hint_inventory(socket) do
    if "memory_access.v1" in socket.assigns.memory_extensions do
      offer = %{
        "memory_v2" => %{
          "offers" => ["host_memory.v2"],
          "partitions" => [],
          "extensions" => ["memory_access.v1"]
        }
      }

      with {:ok, inventory} <- EdgeSync.negotiate(shared_auth(socket), offer) do
        partitions =
          for access <- inventory.accesses,
              :read in access.capabilities and :deliver in access.capabilities,
              do: access.partition

        {:ok, partitions}
      end
    else
      EdgeSync.safe(fn -> MemorySpaces.host_entitlements(socket.assigns.host.id) end)
    end
  end

  defp dispatch_memory(method, args, host, partition, scopes) do
    service = Application.get_env(:backplane_api, :memory_service, Backplane.Memory.Service)
    auth = host_memory_auth(host, partition, scopes)

    with true <- authorized?(memory_method_permission(method), scopes),
         {:ok, args} <- memory_arguments(method, args, partition) do
      case method do
        operation when operation in ~w(remember forget) ->
          {:error, :unsupported_protocol}

        "lifecycle_context" ->
          service.handle_lifecycle_context(args, auth)

        operation when operation in ~w(recall list get stats) ->
          service.call("memory::#{operation}", args, auth)

        _ ->
          {:error, {:unknown_method, method}}
      end
    else
      false -> {:error, :unauthorized}
      {:error, :authority_claim} -> {:error, :invalid_arguments}
    end
  end

  defp memory_method_permission(method)
       when method in ~w(recall list get stats lifecycle_context),
       do: "host_agent.recall"

  defp memory_method_permission(method) when method in ~w(remember forget),
    do: "host_agent.import"

  defp memory_method_permission(_method), do: "host_agent.recall"

  defp host_memory_auth(host, partition, host_agent_scopes) do
    memory_scopes =
      []
      |> maybe_add_memory_scope(host_agent_scopes, "host_agent.recall", "memory.read")
      |> maybe_add_memory_scope(host_agent_scopes, "host_agent.import", "memory.write")

    %{
      kind: :client_token,
      client_id: host.id,
      scopes: memory_scopes,
      subject: host.id,
      principal_metadata: %{
        "memory_partition_id" => "host:#{host.id}",
        "memory_space_id" => partition.memory_space_id,
        "scope" => partition.scope,
        "namespace" => partition.namespace
      }
    }
  end

  # The public read contract exposes scope as a selector. It can confirm the
  # authenticated scope, but cannot supply or override canonical authority.
  defp memory_arguments(method, args, partition) when method in ~w(recall list) do
    case Map.fetch(args, "scope") do
      {:ok, scope} when scope == partition.scope ->
        memory_arguments(nil, Map.delete(args, "scope"), partition)

      {:ok, _other} ->
        {:error, :authority_claim}

      :error ->
        memory_arguments(nil, args, partition)
    end
  end

  defp memory_arguments(_method, args, _partition) do
    with :ok <- reject_authority_claim(args), do: {:ok, args}
  end

  defp reject_authority_claim(args) do
    if Enum.any?(@memory_authority_keys, &Map.has_key?(args, &1)) or
         Enum.any?(@memory_authority_atom_keys, &Map.has_key?(args, &1)),
       do: {:error, :authority_claim},
       else: :ok
  end

  defp maybe_add_memory_scope(memory_scopes, host_agent_scopes, permission, memory_scope) do
    if authorized?(permission, host_agent_scopes),
      do: [memory_scope | memory_scopes],
      else: memory_scopes
  end

  defp edge_request(operation, payload, socket) do
    result =
      with :ok <- selected_memory_protocol(socket, "host_memory.v2"),
           :ok <- edge_access_mode(socket, payload) do
        apply(EdgeSync, operation, [
          shared_auth(socket),
          bound_edge_request(operation, payload, socket.assigns.memory_limits)
        ])
      end

    result =
      case result do
        {:error, %{code: :unauthorized}} ->
          if "memory_access.v1" in socket.assigns.memory_extensions,
            do: {:error, %{code: :unauthorized}},
            else: result

        other ->
          other
      end

    memory_reply(result, socket)
  end

  defp edge_access_mode(socket, payload) when is_map(payload) do
    cond do
      Map.has_key?(payload, "access") -> selected_extension(socket, "memory_access.v1")
      is_nil(socket.assigns.memory_partition) -> {:error, :unauthorized}
      true -> :ok
    end
  end

  defp edge_access_mode(_socket, _payload), do: {:error, :invalid_request}

  defp bound_edge_request(:next, payload, limits) when is_map(payload) do
    Enum.reduce(limits, payload, fn {key, maximum}, request ->
      key = to_string(key)

      case Map.fetch(request, key) do
        :error ->
          Map.put(request, key, maximum)

        {:ok, requested} when is_integer(requested) and requested > 0 ->
          Map.put(request, key, min(requested, maximum))

        _ ->
          request
      end
    end)
  end

  defp bound_edge_request(_, payload, _), do: payload

  defp selected_memory_protocol(socket, protocol) do
    cond do
      not authorized?("host_agent.recall", host_agent_scopes()) ->
        {:error, %{code: :unauthorized, retryable: false}}

      not Config.host_sync_enabled?() ->
        {:error, %{code: :protocol_disabled, retryable: false}}

      socket.assigns.memory_protocol != protocol ->
        {:error, %{code: :unsupported_protocol, retryable: false}}

      true ->
        :ok
    end
  end

  defp memory_reply({:ok, result}, socket), do: {:reply, {:ok, json_shape(result)}, socket}

  defp memory_reply({:error, error}, socket) when is_atom(error),
    do: memory_reply(EdgeSync.safe(fn -> {:error, error} end), socket)

  defp memory_reply({:error, error}, socket), do: {:reply, {:error, json_shape(error)}, socket}

  defp host_agent_scopes do
    Application.get_env(:backplane_api, :host_agent_scopes, @default_host_agent_scopes)
  end

  defp authorized?(permission, scopes),
    do: is_list(scopes) and (permission in scopes or "*" in scopes)

  defp safe_memory_import_record(partition, payload) do
    memory_import_adapter().record(partition, payload)
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

  defp safe_memory_event_host(host_id) do
    case Hosts.get_host(host_id) do
      %{id: ^host_id, memory_scope: memory_scope} = host when is_binary(memory_scope) ->
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

  defp ingest_bound_memory_events(host, socket, payload) do
    openclaw = Enum.filter(payload["events"], &(is_map(&1) and &1["integration"] == "openclaw"))

    if openclaw == [] do
      ingest_memory_events(host, socket, payload)
    else
      with :ok <- selected_extension(socket, "openclaw_capture.v1"),
           :ok <- selected_extension(socket, "openclaw_source.v1"),
           true <- Enum.all?(openclaw, &valid_openclaw_event?/1),
           {:ok, actor} <-
             Backplane.Memory.Authorization.host_actor(shared_auth(socket), :remember),
           {:ok, reply} <-
             MemorySpaces.with_host_access(actor, :default, :remember, nil, fn access ->
               fingerprint =
                 Backplane.MemorySourceContract.digest(%{
                   "access_id" => access.access_id,
                   "authority_version" => access.authority_version,
                   "partition" =>
                     Map.new(access.partition, fn {key, value} -> {to_string(key), value} end)
                 })

               with true <-
                      Enum.all?(
                        openclaw,
                        &(get_in(&1, ["payload", "source", "binding_fingerprint"]) == fingerprint)
                      ),
                    {:ok, _} <-
                      MemorySpaces.resolve_host_access(
                        host.id,
                        {:access_id, access.access_id},
                        :forget
                      ),
                    {:ok, partition} <-
                      MemorySpaces.resolve_host_partition(host.id, host.memory_scope, "private"),
                    true <-
                      Map.take(partition, [:memory_space_id, :scope, :namespace]) ==
                        access.partition do
                 {:ok, ingest_memory_events(host, socket, payload)}
               else
                 _ -> {:error, :authority_changed}
               end
             end) do
        reply
      else
        false -> {:reply, {:error, %{"reason" => "invalid_event"}}, socket}
        {:error, reason} -> {:reply, {:error, %{"reason" => format_memory_error(reason)}}, socket}
      end
    end
  end

  defp valid_openclaw_event?(%{"payload" => %{"hook" => hook, "source" => source}} = event) do
    with {:ok, type} <-
           Backplane.OpenClawCaptureContract.validate(hook, source,
             filtered: get_in(event, ["privacy", "filtered"]) == true
           ) do
      event["event_type"] == type and event["event_id"] == source["event_id"] and
        event["session_id"] == source["session_id"] and event["agent_id"] == source["agent_id"] and
        event["client_id"] == "openclaw"
    else
      _ -> false
    end
  end

  defp valid_openclaw_event?(_), do: false

  defp ingest_memory_events(host, socket, payload) do
    with {:ok, partition} <-
           MemorySpaces.resolve_host_partition(host.id, host.memory_scope, "private") do
      partition =
        Map.merge(partition, %{
          host_id: host.id,
          client_id: host.id,
          source_client_id: host.id
        })

      auth_context = %{
        host_id: host.id,
        auth_token_id: socket.assigns.auth_token.id,
        scopes: host_agent_scopes(),
        partition: Map.put(partition, :partition_id, "host:#{host.id}")
      }

      case safe_host_event_ingest(auth_context, payload) do
        {:ok, reply} when is_map(reply) ->
          {:reply, {:ok, reply}, assign(socket, :memory_partition, partition)}

        {:error, :host_mismatch} ->
          {:reply, {:error, %{"reason" => "host_mismatch"}}, socket}

        {:error, :invalid_batch} ->
          invalid_payload(socket)

        {:error, :ingest_unavailable} ->
          {:reply, {:error, %{"reason" => "ingest_unavailable"}}, socket}
      end
    else
      {:error, reason} ->
        {:reply, {:error, %{"reason" => format_memory_error(reason)}}, socket}
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
