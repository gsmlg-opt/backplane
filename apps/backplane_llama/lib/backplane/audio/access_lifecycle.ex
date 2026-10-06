defmodule Backplane.Audio.AccessLifecycle do
  @moduledoc """
  Owns one accepted audio request's terminal access event independently of media sessions.

  Call `dispatched/1` synchronously before a billable provider send. Only bounded,
  typed metadata is retained; no connection, media, request body, or secret is stored.
  """

  use GenServer

  alias Backplane.LLM.AccessEvent

  @default_deadline_ms 600_000
  @max_deadline_ms 4_294_967_295

  def child_spec(args) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}, restart: :temporary}
  end

  @doc "Starts an observer with a relative deadline of 1..4_294_967_295 ms (default 600_000)."
  @spec start(pid(), Plug.Conn.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(owner, %Plug.Conn{} = conn, operation, opts \\ []) when is_pid(owner) do
    start_record(owner, AccessEvent.start_audio(conn, operation), opts)
  end

  def start_preview(owner, operation, opts \\ []) when is_pid(owner) do
    start_record(owner, AccessEvent.start_audio_preview(operation), opts)
  end

  defp start_record(owner, access, opts) do
    now = System.monotonic_time(:millisecond)
    relative = Keyword.get(opts, :deadline_ms, @default_deadline_ms)
    deadline = Keyword.get(opts, :deadline_at_ms)

    deadline =
      cond do
        is_integer(deadline) and deadline - now <= @max_deadline_ms ->
          deadline

        is_nil(deadline) and is_integer(relative) and relative in 1..@max_deadline_ms ->
          now + relative

        true ->
          nil
      end

    if deadline do
      DynamicSupervisor.start_child(
        __MODULE__.Supervisor,
        {__MODULE__, {owner, access, deadline}}
      )
    else
      {:error, :invalid_deadline}
    end
  catch
    :exit, _ -> {:error, :observer_unavailable}
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc "Synchronously merges only allowlisted audio fields."
  def update(nil, fields) when is_map(fields), do: :ok
  def update(pid, fields) when is_pid(pid) and is_map(fields), do: call(pid, {:update, fields})

  @doc "Marks potential provider billing before sending the upstream POST."
  def dispatched(nil), do: :ok
  def dispatched(pid) when is_pid(pid), do: call(pid, :dispatched)

  @doc "Accounts delivered bytes without retaining the delivered content."
  def delivered(pid, bytes) when is_pid(pid) and is_integer(bytes) and bytes >= 0,
    do: call(pid, {:delivered, bytes})

  @doc "Serializes the one terminal outcome. Calls after termination return `{:error, :closed}`."
  def finish(pid, outcome, status, error_code \\ nil, fields \\ %{})
  def finish(nil, _outcome, _status, _error_code, _fields), do: :ok

  def finish(pid, outcome, status, error_code, fields)
      when is_pid(pid) and outcome in [:success, :error, :cancelled, :timeout] and is_map(fields),
      do: call(pid, {:finish, outcome, status, error_code, fields})

  def finish_error(pid, %Backplane.Audio.Error{} = error, status \\ nil) do
    outcome =
      case error.status do
        499 -> :cancelled
        504 -> :timeout
        _ -> :error
      end

    finish(pid, outcome, status || error.status, error.code)
  end

  def resolved(pid, request, resolution) do
    update(pid, %{
      requested_model: request.model,
      resolved_model: resolution.model,
      provider_id: resolution.provider.id,
      provider_name: resolution.provider.name,
      provider_model_id: resolution.provider_model.id,
      credential_ref: resolution.credential_ref,
      input_characters:
        if(is_binary(request[:input]), do: length(String.to_charlist(request.input)))
    })
  end

  def measure(pid, field, fun) do
    started = System.monotonic_time(:millisecond)

    try do
      fun.()
    after
      update(pid, %{field => max(System.monotonic_time(:millisecond) - started, 0)})
    end
  end

  def provider_metadata(pid, metadata) do
    seconds =
      cond do
        is_number(metadata[:duration_ms]) -> metadata.duration_ms / 1000
        is_number(metadata[:duration_seconds]) -> metadata.duration_seconds
        true -> nil
      end

    update(pid, %{
      provider_request_id: metadata[:trace_id],
      usage_characters: metadata[:usage_characters],
      audio_seconds: seconds
    })
  end

  def first_byte(nil), do: :ok
  def first_byte(pid), do: call(pid, :first_byte)

  defp call(pid, message) do
    GenServer.call(pid, message, 5_000)
  catch
    :exit, _ -> {:error, :closed}
  end

  @impl true
  def init({owner, access, deadline}) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)

    timer =
      Process.send_after(
        self(),
        :deadline,
        max(deadline - System.monotonic_time(:millisecond), 0)
      )

    {:ok,
     %{
       access: access,
       fields: %{},
       owner_ref: owner_ref,
       timer: timer,
       deadline: deadline,
       dispatched?: false,
       finalized?: false
     }}
  end

  @impl true
  def handle_call({:update, fields}, _from, state) do
    fields =
      fields
      |> AccessEvent.sanitize_audio_fields()
      |> Map.drop([:provider_dispatched, :paid_uncertain])

    {:reply, :ok, %{state | fields: Map.merge(state.fields, fields)}}
  end

  def handle_call(:dispatched, _from, state) do
    if System.monotonic_time(:millisecond) >= state.deadline do
      {:stop, :normal, {:error, :closed}, emit_terminal(state, :timeout, 504, "audio_deadline")}
    else
      {:reply, :ok, %{state | dispatched?: true}}
    end
  end

  def handle_call(:first_byte, _from, state) do
    elapsed = max(System.monotonic_time(:millisecond) - state.access.started_at_mono, 0)
    {:reply, :ok, %{state | fields: Map.put_new(state.fields, :first_byte_ms, elapsed)}}
  end

  def handle_call({:delivered, bytes}, _from, state) do
    total = min(Map.get(state.fields, :response_bytes, 0) + bytes, 1_000_000_000)
    {:reply, :ok, %{state | fields: Map.put(state.fields, :response_bytes, total)}}
  end

  def handle_call({:finish, outcome, status, error_code, fields}, _from, state) do
    state = %{state | fields: Map.merge(state.fields, AccessEvent.sanitize_audio_fields(fields))}

    state =
      if System.monotonic_time(:millisecond) >= state.deadline,
        do: emit_terminal(state, :timeout, 504, "audio_deadline"),
        else: emit_terminal(state, outcome, status, error_code)

    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner_ref: ref} = state) do
    terminal =
      if System.monotonic_time(:millisecond) >= state.deadline,
        do: emit_terminal(state, :timeout, 504, "audio_deadline"),
        else: emit_terminal(state, :cancelled, nil, "owner_down")

    {:stop, :normal, terminal}
  end

  def handle_info(:deadline, state) do
    {:stop, :normal, emit_terminal(state, :timeout, 504, "audio_deadline")}
  end

  def handle_info({:EXIT, _pid, :shutdown}, state) do
    {:stop, :normal, emit_terminal(state, :error, nil, "lifecycle_shutdown")}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{finalized?: true}), do: :ok

  def terminate(_reason, state) do
    _ = emit_terminal(state, :error, nil, "lifecycle_shutdown")
    :ok
  end

  defp emit_terminal(%{finalized?: true} = state, _outcome, _status, _code), do: state

  defp emit_terminal(state, outcome, status, error_code) do
    fields =
      state.fields
      |> Map.put(:provider_dispatched, state.dispatched?)
      |> Map.put(:paid_uncertain, state.dispatched? and outcome != :success)

    :ok = AccessEvent.finalize_audio(state.access, fields, outcome, status, error_code)
    %{state | finalized?: true}
  end
end
