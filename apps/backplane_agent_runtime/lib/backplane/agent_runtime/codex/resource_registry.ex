defmodule Backplane.AgentRuntime.Codex.ResourceRegistry do
  use GenServer

  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Run-owned in-memory handles for continuations and live tool resources.

  Handles contain owner and incarnation fencing. Cleanup callbacks are live host
  capabilities only; callers must persist intent/results through the existing
  Store boundary instead of storing these values durably.
  """

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def register(pid, owner, kind, value, opts \\ []),
    do: GenServer.call(pid, {:register, owner, kind, value, opts})

  def fetch(pid, handle, owner), do: GenServer.call(pid, {:fetch, handle, owner})
  def release(pid, handle, owner), do: GenServer.call(pid, {:release, handle, owner})
  def cancel_owner(pid, owner), do: GenServer.call(pid, {:cancel_owner, owner})

  def register_session(pid, owner, value, opts \\ []),
    do: GenServer.call(pid, {:register_session, owner, value, opts})

  def fetch_session(pid, session_id, owner),
    do: GenServer.call(pid, {:fetch_session, session_id, owner})

  def update_session(pid, session_id, owner, value),
    do: GenServer.call(pid, {:update_session, session_id, owner, value})

  def forget_session(pid, session_id, owner),
    do: GenServer.call(pid, {:forget_session, session_id, owner})

  @impl true
  def init(_opts), do: {:ok, %{resources: %{}, sessions: %{}}}

  @impl true
  def handle_call({:register, owner, kind, value, opts}, _from, state)
      when is_binary(owner) and is_atom(kind) do
    incarnation = Keyword.get(opts, :incarnation, 1)
    cleanup = Keyword.get(opts, :cleanup)
    monitor = Keyword.get(opts, :owner_pid)

    with :ok <- validate_incarnation(incarnation),
         :ok <- validate_cleanup(cleanup) do
      resource_id = "res_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      handle = %{resource_id: resource_id, owner_id: owner, incarnation: incarnation, kind: kind}
      monitor_ref = if is_pid(monitor), do: Process.monitor(monitor), else: nil
      resource = %{handle: handle, value: value, cleanup: cleanup, monitor_ref: monitor_ref}

      {:reply, {:ok, handle},
       %{state | resources: Map.put(state.resources, resource_id, resource)}}
    end
  end

  def handle_call({:fetch, handle, owner}, _from, state) do
    with {:ok, resource} <- lookup(state, handle, owner) do
      {:reply, {:ok, resource.value}, state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:register_session, owner, value, opts}, _from, state)
      when is_binary(owner) and owner != "" and is_list(opts) do
    cleanup = Keyword.get(opts, :cleanup)
    owner_pid = Keyword.get(opts, :owner_pid)

    with :ok <- validate_cleanup(cleanup) do
      session_id = System.unique_integer([:positive, :monotonic])
      monitor_ref = if is_pid(owner_pid), do: Process.monitor(owner_pid), else: nil

      session = %{
        session_id: session_id,
        owner_id: owner,
        value: value,
        cleanup: cleanup,
        monitor_ref: monitor_ref
      }

      {:reply, {:ok, session_id},
       %{state | sessions: Map.put(state.sessions, session_id, session)}}
    end
  end

  def handle_call({:register_session, _owner, _value, _opts}, _from, state),
    do: {:reply, {:error, Error.new(:validation, "session owner is required")}, state}

  def handle_call({:fetch_session, session_id, owner}, _from, state) do
    with {:ok, session} <- lookup_session(state, session_id, owner) do
      {:reply, {:ok, session.value}, state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:update_session, session_id, owner, value}, _from, state) do
    with {:ok, session} <- lookup_session(state, session_id, owner) do
      sessions = Map.put(state.sessions, session_id, %{session | value: value})
      {:reply, :ok, %{state | sessions: sessions}}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:forget_session, session_id, owner}, _from, state) do
    with {:ok, session} <- lookup_session(state, session_id, owner) do
      if session.monitor_ref, do: Process.demonitor(session.monitor_ref, [:flush])
      {:reply, :ok, %{state | sessions: Map.delete(state.sessions, session_id)}}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:release, handle, owner}, _from, state) do
    with {:ok, resource} <- lookup(state, handle, owner),
         {:ok, cleanup_status} <- run_cleanup(resource.cleanup) do
      {:reply, {:ok, cleanup_status}, remove(state, resource)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cancel_owner, owner}, _from, state) do
    {resources, statuses} =
      state.resources
      |> Enum.filter(fn {_id, resource} -> resource.handle.owner_id == owner end)
      |> Enum.reduce({state.resources, []}, fn {id, resource}, {resources, statuses} ->
        {Map.delete(resources, id), [run_cleanup(resource.cleanup) | statuses]}
      end)

    {sessions, session_statuses} =
      state.sessions
      |> Enum.filter(fn {_id, session} -> session.owner_id == owner end)
      |> Enum.reduce({state.sessions, []}, fn {id, session}, {sessions, statuses} ->
        {Map.delete(sessions, id), [run_cleanup(session.cleanup) | statuses]}
      end)

    {:reply, {:ok, Enum.reverse(statuses) ++ Enum.reverse(session_statuses)},
     %{state | resources: resources, sessions: sessions}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {resources, _statuses} =
      state.resources
      |> Enum.reduce({state.resources, []}, fn {id, resource}, {resources, statuses} ->
        if resource.monitor_ref == ref do
          {Map.delete(resources, id), [run_cleanup(resource.cleanup) | statuses]}
        else
          {resources, statuses}
        end
      end)

    {sessions, _statuses} =
      state.sessions
      |> Enum.reduce({state.sessions, []}, fn {id, session}, {sessions, statuses} ->
        if session.monitor_ref == ref do
          {Map.delete(sessions, id), [run_cleanup(session.cleanup) | statuses]}
        else
          {sessions, statuses}
        end
      end)

    {:noreply, %{state | resources: resources, sessions: sessions}}
  end

  defp lookup(state, %{resource_id: id} = handle, owner)
       when is_binary(id) and is_binary(owner) do
    case Map.get(state.resources, id) do
      %{handle: %{owner_id: actual_owner} = stored_handle} = resource ->
        cond do
          actual_owner != owner ->
            {:error, Error.new(:forbidden, "resource owner does not match")}

          Map.get(handle, :incarnation) != stored_handle.incarnation ->
            {:error, Error.new(:resource_conflict, "stale resource incarnation")}

          true ->
            {:ok, resource}
        end

      nil ->
        {:error, Error.new(:not_found, "resource handle is unknown")}
    end
  end

  defp lookup(_state, _handle, _owner),
    do: {:error, Error.new(:validation, "invalid resource handle")}

  defp lookup_session(state, session_id, owner)
       when is_integer(session_id) and is_binary(owner) do
    case Map.get(state.sessions, session_id) do
      %{owner_id: ^owner} = session -> {:ok, session}
      %{owner_id: _other} -> {:error, Error.new(:forbidden, "session owner does not match")}
      nil -> {:error, Error.new(:not_found, "command session is unknown")}
    end
  end

  defp lookup_session(_state, _session_id, _owner),
    do: {:error, Error.new(:validation, "invalid command session")}

  defp remove(state, %{handle: %{resource_id: id}, monitor_ref: ref}) do
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | resources: Map.delete(state.resources, id)}
  end

  defp run_cleanup(nil), do: {:ok, :not_requested}

  defp run_cleanup(fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    rescue
      exception -> {:ok, {:cleanup_failed, inspect(exception)}}
    catch
      kind, reason -> {:ok, {:cleanup_failed, {kind, reason}}}
    end
  end

  defp validate_incarnation(value) when is_integer(value) and value > 0, do: :ok

  defp validate_incarnation(_),
    do: {:error, Error.new(:validation, "incarnation must be positive")}

  defp validate_cleanup(nil), do: :ok
  defp validate_cleanup(fun) when is_function(fun, 0), do: :ok

  defp validate_cleanup(_),
    do: {:error, Error.new(:validation, "cleanup must be a zero-arity function")}
end
