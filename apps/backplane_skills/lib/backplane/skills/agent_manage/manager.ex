defmodule Backplane.Skills.AgentManage.Manager do
  @moduledoc false

  use GenServer

  alias Backplane.Skills.HostAuthToken

  @type token_entry :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          token_hash: String.t()
        }

  def start_link(opts) do
    host = Keyword.fetch!(opts, :host)
    tokens = opts |> Keyword.get(:tokens, []) |> normalize_tokens()

    name =
      {:via, Registry, {Backplane.Skills.AgentManage.Registry, host.id, auth_cache(host, tokens)}}

    GenServer.start_link(__MODULE__, Keyword.put(opts, :tokens, tokens), name: name)
  end

  def register_connection(pid, auth_token, channel_pid, metadata) do
    GenServer.call(pid, {:register_connection, auth_token, channel_pid, metadata})
  end

  def refresh(pid, host, tokens) do
    GenServer.call(pid, {:refresh, host, tokens})
  end

  def snapshot(pid) do
    GenServer.call(pid, :snapshot)
  end

  def update_runtime(pid, runtime) do
    GenServer.call(pid, {:update_runtime, runtime})
  end

  def report_config(pid, config) do
    GenServer.call(pid, {:report_config, config})
  end

  def record_sync(pid, payload) do
    GenServer.call(pid, {:record_sync, payload})
  end

  def disconnect(pid) do
    GenServer.call(pid, :disconnect)
  end

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    tokens = opts |> Keyword.get(:tokens, []) |> normalize_tokens()

    {:ok,
     %{
       host: host,
       tokens: tokens,
       auth_token_id: nil,
       channel_pid: nil,
       monitor_ref: nil,
       status: :offline,
       connected_at: nil,
       connect_ip: nil,
       connect_ip_source: nil,
       runtime: %{},
       config: nil,
       last_sync: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_call({:register_connection, auth_token, channel_pid, metadata}, _from, state) do
    state =
      state
      |> remove_connection(notify?: true, reason: :replaced)
      |> put_connection(auth_token, channel_pid, metadata)

    broadcast_changed()
    {:reply, :ok, state}
  end

  def handle_call({:refresh, host, tokens}, _from, state) do
    tokens = normalize_tokens(tokens)
    update_auth_cache(host, tokens)

    state = %{state | host: host, tokens: tokens}
    broadcast_changed()
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, public_entry(state), state}
  end

  def handle_call({:update_runtime, runtime}, _from, state) do
    state = %{state | runtime: Map.merge(state.runtime, runtime)}
    broadcast_changed()
    {:reply, :ok, state}
  end

  def handle_call({:report_config, config}, _from, state) do
    state = %{state | config: config}
    broadcast_changed()
    {:reply, :ok, state}
  end

  def handle_call({:record_sync, payload}, _from, state) do
    state = %{state | last_sync: DateTime.utc_now(), last_error: sync_error(payload)}
    broadcast_changed()
    {:reply, :ok, state}
  end

  def handle_call(:disconnect, _from, state) do
    state = remove_connection(state, notify?: true, reason: :explicit)
    broadcast_changed()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, reason},
        %{monitor_ref: monitor_ref} = state
      ) do
    state = remove_connection(state, notify?: false, reason: reason)
    broadcast_changed()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp put_connection(state, auth_token, channel_pid, metadata) do
    monitor_ref = Process.monitor(channel_pid)
    now = DateTime.utc_now()

    :telemetry.execute(
      [:backplane, :host_agent, :connect],
      %{system_time: System.system_time()},
      %{host_id: state.host.id, host_name: state.host.name, auth_token_id: auth_token.id}
    )

    %{
      state
      | auth_token_id: auth_token.id,
        channel_pid: channel_pid,
        monitor_ref: monitor_ref,
        status: :online,
        connected_at: now,
        connect_ip: Map.get(metadata, :connect_ip),
        connect_ip_source: Map.get(metadata, :connect_ip_source)
    }
  end

  defp remove_connection(state, opts) do
    if is_reference(state.monitor_ref) do
      Process.demonitor(state.monitor_ref, [:flush])
    end

    if Keyword.get(opts, :notify?, false) and is_pid(state.channel_pid) do
      send(state.channel_pid, :disconnect)
    end

    if state.status == :online do
      :telemetry.execute(
        [:backplane, :host_agent, :disconnect],
        %{system_time: System.system_time()},
        %{
          host_id: state.host.id,
          host_name: state.host.name,
          reason: Keyword.get(opts, :reason, :normal)
        }
      )
    end

    %{
      state
      | auth_token_id: nil,
        channel_pid: nil,
        monitor_ref: nil,
        status: :offline,
        runtime: %{}
    }
  end

  defp public_entry(state) do
    %{
      host: state.host,
      status: state.status,
      auth_token_id: state.auth_token_id,
      pid: state.channel_pid,
      connected_at: state.connected_at,
      connect_ip: state.connect_ip,
      connect_ip_source: state.connect_ip_source,
      runtime: state.runtime,
      config: state.config,
      last_sync: state.last_sync,
      last_error: state.last_error,
      tokens: Enum.map(state.tokens, &Map.take(&1, [:id, :name]))
    }
  end

  defp normalize_tokens(tokens) do
    Enum.map(tokens, fn
      %HostAuthToken{} = token ->
        %{id: token.id, name: token.name, token_hash: token.token_hash}

      %{id: id, name: name, token_hash: token_hash} ->
        %{id: id, name: name, token_hash: token_hash}
    end)
  end

  defp auth_cache(host, tokens) do
    %{host: host, tokens: tokens}
  end

  defp update_auth_cache(host, tokens) do
    Registry.update_value(Backplane.Skills.AgentManage.Registry, host.id, fn _value ->
      auth_cache(host, tokens)
    end)

    :ok
  catch
    :error, :badarg -> :ok
    :exit, _reason -> :ok
  end

  defp sync_error(%{"status" => "failed", "error" => error}), do: error

  defp sync_error(%{"results" => results}) when is_list(results) do
    Enum.find_value(results, fn
      %{"status" => "failed", "error" => error} -> error
      _ -> nil
    end)
  end

  defp sync_error(_payload), do: nil

  defp broadcast_changed do
    if Process.whereis(Backplane.PubSub) do
      Phoenix.PubSub.broadcast(Backplane.PubSub, "host_agents:agents", :agents_changed)
    end
  end
end
