defmodule Backplane.Skills.HostConnectionRegistry do
  @moduledoc """
  In-memory registry of currently connected host agent WebSocket channels.
  """

  use GenServer

  alias Backplane.Skills.{Host, HostAuthToken}

  @topic "host_agents:connections"

  @type entry :: %{
          host: Host.t(),
          auth_token_id: Ecto.UUID.t(),
          pid: pid(),
          connected_at: DateTime.t(),
          runtime: map(),
          config: map() | nil
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{connections: %{}, monitors: %{}}, name: __MODULE__)
  end

  @doc "Subscribe to live host agent connection changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Backplane.PubSub, @topic)
  end

  @doc "Register a channel process as the live connection for a host."
  @spec register(Host.t(), HostAuthToken.t(), pid()) :: :ok | {:error, :not_started}
  def register(%Host{} = host, %HostAuthToken{} = auth_token, pid) when is_pid(pid) do
    registry_call({:register, host, auth_token, pid}, {:error, :not_started})
  end

  @doc "Disconnect and forget a live host connection."
  @spec disconnect(Ecto.UUID.t()) :: :ok
  def disconnect(host_id) do
    registry_call({:disconnect, host_id}, :ok)
  end

  @doc "List all live host agent connections."
  @spec list_connected() :: [entry()]
  def list_connected do
    registry_call(:list_connected, [])
  end

  @doc "Fetch a live host agent connection by host ID."
  @spec get(Ecto.UUID.t()) :: entry() | nil
  def get(host_id) do
    registry_call({:get, host_id}, nil)
  end

  @doc "Update runtime state reported by heartbeat."
  @spec update_runtime(Ecto.UUID.t(), map()) :: :ok | {:error, :invalid_payload | :not_connected}
  def update_runtime(host_id, payload) when is_map(payload) do
    case normalize_runtime(payload) do
      {:ok, runtime} ->
        registry_call({:update_runtime, host_id, runtime}, {:error, :not_connected})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_runtime(_host_id, _payload), do: {:error, :invalid_payload}

  @doc "Store the latest config reported by a connected host agent."
  @spec report_config(Ecto.UUID.t(), map()) :: :ok | {:error, :invalid_payload | :not_connected}
  def report_config(host_id, config) when is_map(config) do
    registry_call({:report_config, host_id, stringify_keys(config)}, {:error, :not_connected})
  end

  def report_config(_host_id, _config), do: {:error, :invalid_payload}

  @doc "Clear all connections. Intended for tests."
  @spec clear() :: :ok
  def clear do
    registry_call(:clear, :ok)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, host, auth_token, pid}, _from, state) do
    notify? = state.connections[host.id] && state.connections[host.id].pid != pid

    state =
      state
      |> remove_connection(host.id, notify?: notify?, reason: :replaced)
      |> put_connection(host, auth_token, pid)

    broadcast_changed()

    {:reply, :ok, state}
  end

  def handle_call({:disconnect, host_id}, _from, state) do
    state = remove_connection(state, host_id, notify?: true, reason: :explicit)
    broadcast_changed()

    {:reply, :ok, state}
  end

  def handle_call(:list_connected, _from, state) do
    entries =
      state.connections
      |> Map.values()
      |> Enum.map(&public_entry/1)
      |> Enum.sort_by(&String.downcase(&1.host.name || ""))

    {:reply, entries, state}
  end

  def handle_call({:get, host_id}, _from, state) do
    {:reply, public_entry(state.connections[host_id]), state}
  end

  def handle_call({:update_runtime, host_id, runtime}, _from, state) do
    update_connection(state, host_id, fn entry ->
      %{entry | runtime: Map.merge(entry.runtime, runtime)}
    end)
  end

  def handle_call({:report_config, host_id, config}, _from, state) do
    update_connection(state, host_id, fn entry -> %{entry | config: config} end)
  end

  def handle_call(:clear, _from, state) do
    for entry <- Map.values(state.connections) do
      Process.demonitor(entry.monitor_ref, [:flush])
    end

    broadcast_changed()

    {:reply, :ok, %{connections: %{}, monitors: %{}}}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Map.fetch(state.monitors, monitor_ref) do
      {:ok, host_id} ->
        state =
          case state.connections[host_id] do
            %{monitor_ref: ^monitor_ref} ->
              remove_connection(state, host_id, notify?: false, reason: reason)

            _stale_entry ->
              %{state | monitors: Map.delete(state.monitors, monitor_ref)}
          end

        broadcast_changed()
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  defp put_connection(state, host, auth_token, pid) do
    monitor_ref = Process.monitor(pid)

    :telemetry.execute(
      [:backplane, :host_agent, :connect],
      %{system_time: System.system_time()},
      %{host_id: host.id, host_name: host.name, auth_token_id: auth_token.id}
    )

    entry = %{
      host: host,
      auth_token_id: auth_token.id,
      pid: pid,
      monitor_ref: monitor_ref,
      connected_at: DateTime.utc_now(),
      runtime: %{},
      config: nil
    }

    %{
      connections: Map.put(state.connections, host.id, entry),
      monitors: Map.put(state.monitors, monitor_ref, host.id)
    }
  end

  defp update_connection(state, host_id, fun) do
    case Map.fetch(state.connections, host_id) do
      {:ok, entry} ->
        state = %{state | connections: Map.put(state.connections, host_id, fun.(entry))}
        broadcast_changed()
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  defp remove_connection(state, host_id, opts) do
    case Map.fetch(state.connections, host_id) do
      {:ok, entry} ->
        Process.demonitor(entry.monitor_ref, [:flush])

        if Keyword.get(opts, :notify?, false) do
          send(entry.pid, :disconnect)
        end

        reason = Keyword.get(opts, :reason, :normal)
        :telemetry.execute(
          [:backplane, :host_agent, :disconnect],
          %{system_time: System.system_time()},
          %{host_id: host_id, host_name: entry.host.name, reason: reason}
        )

        %{
          connections: Map.delete(state.connections, host_id),
          monitors: Map.delete(state.monitors, entry.monitor_ref)
        }

      :error ->
        state
    end
  end

  defp public_entry(nil), do: nil
  defp public_entry(entry), do: Map.delete(entry, :monitor_ref)

  defp normalize_runtime(payload) do
    payload = stringify_keys(payload)

    with :ok <- validate_targets(payload),
         :ok <- validate_metadata(payload) do
      runtime =
        %{}
        |> maybe_put(:status, payload["status"] || "online")
        |> maybe_put(:agent_version, payload["agent_version"])
        |> maybe_put(:targets, payload["targets"])
        |> maybe_put(:metadata, payload["metadata"])

      {:ok, runtime}
    end
  end

  defp validate_targets(%{"targets" => targets}) when not is_list(targets) do
    {:error, :invalid_payload}
  end

  defp validate_targets(_payload), do: :ok

  defp validate_metadata(%{"metadata" => metadata}) when not is_map(metadata) do
    {:error, :invalid_payload}
  end

  defp validate_metadata(_payload), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp broadcast_changed do
    if Process.whereis(Backplane.PubSub) do
      Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, :connections_changed)
    end
  end

  defp registry_call(request, fallback) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, request)
    else
      fallback
    end
  catch
    :exit, {:noproc, _details} -> fallback
  end
end
