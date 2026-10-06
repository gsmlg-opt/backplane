defmodule Backplane.Audio.Media.Session do
  @moduledoc "Request-owned media lifecycle. Retain files until HTTP delivery releases the session."
  use GenServer

  alias Backplane.Audio.{AccessLifecycle, Error}
  alias Backplane.Audio.Media.{Admission, Convert, Plan, Probe, TempFiles}

  def start(owner, policy) when is_pid(owner) and is_map(policy) do
    DynamicSupervisor.start_child(
      Backplane.Audio.Media.SessionSupervisor,
      {__MODULE__, {owner, policy}}
    )
  end

  def start_link({owner, policy}), do: GenServer.start_link(__MODULE__, {owner, policy})

  def child_spec(arg) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      type: :worker
    }
  end

  def observe(pid, observer) when is_pid(observer), do: GenServer.call(pid, {:observe, observer})

  def admit_upload(pid), do: GenServer.call(pid, :admit_upload)
  def adopt_upload(pid, upload), do: GenServer.call(pid, {:adopt_upload, upload}, :infinity)
  def input_path(pid), do: GenServer.call(pid, :input_path)
  def reserve_input(pid, bytes), do: GenServer.call(pid, {:reserve_input, bytes})

  def prepare(pid, operation, path, target, capabilities \\ %{})
      when operation in [:speech, :transcription] do
    GenServer.call(pid, {:prepare, operation, path, target, capabilities}, :infinity)
  end

  def release(pid), do: GenServer.call(pid, :release, :infinity)

  @impl true
  def init({owner, policy}) do
    Process.flag(:trap_exit, true)

    with {:ok, operation_lease} <- Admission.acquire(:operation, self(), policy),
         {:ok, handle} <- TempFiles.create(self(), policy) do
      {:ok,
       %{
         owner: owner,
         owner_ref: Process.monitor(owner),
         policy: policy,
         observer: nil,
         operation_lease: operation_lease,
         upload_lease: nil,
         handle: handle,
         active: nil,
         cancelled: false,
         released: false
       }}
    else
      {:error, error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:observe, observer}, _from, state),
    do: {:reply, :ok, %{state | observer: observer}}

  def handle_call(:admit_upload, _from, %{upload_lease: nil} = state) do
    case Admission.acquire(:upload, self(), state.policy) do
      {:ok, lease} -> {:reply, :ok, %{state | upload_lease: lease}}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:admit_upload, _from, state), do: {:reply, :ok, state}

  def handle_call({:adopt_upload, upload}, _from, state) do
    result = TempFiles.adopt_upload(state.handle, upload, state.policy)
    if state.upload_lease, do: Admission.release(state.upload_lease)
    {:reply, result, %{state | upload_lease: nil}}
  end

  def handle_call(:input_path, _from, state),
    do: {:reply, TempFiles.path(state.handle, :input), state}

  def handle_call({:reserve_input, bytes}, _from, state),
    do: {:reply, TempFiles.reserve(state.handle, bytes), state}

  def handle_call({:prepare, operation, path, target, capabilities}, from, %{active: nil} = state) do
    Admission.pin(state.operation_lease, state.handle.dir)
    ref = make_ref()
    session = self()

    case Task.Supervisor.start_child(Backplane.Audio.Media.TaskSupervisor, fn ->
           Process.put(:audio_owner_monitor, Process.monitor(session))
           Process.put(:audio_owner_pid, session)

           result =
             do_prepare(
               state.handle,
               operation,
               path,
               target,
               capabilities,
               state.policy,
               state.observer
             )

           send(session, {:prepared, ref, result})

           if not Process.alive?(session) and
                not match?({:error, %Error{code: "audio_cleanup_uncertain"}}, result),
              do: TempFiles.release(state.handle)
         end) do
      {:ok, pid} ->
        task_ref = Process.monitor(pid)
        {:noreply, %{state | active: %{pid: pid, task_ref: task_ref, ref: ref, from: from}}}

      {:error, _} ->
        TempFiles.unpin(state.handle)

        {:reply, {:error, Error.new(503, "Audio worker unavailable", nil, "audio_unavailable")},
         state}
    end
  end

  def handle_call({:prepare, _, _, _, _}, _from, state) do
    {:reply, {:error, Error.new(429, "Audio request is busy", nil, "audio_capacity_exhausted")},
     state}
  end

  def handle_call(:release, _from, %{active: nil} = state) do
    cleanup(state)
    {:stop, :normal, :ok, %{state | released: true}}
  end

  def handle_call(:release, from, %{active: active} = state) do
    send(active.pid, :cancel)
    {:noreply, Map.put(state, :release_from, from)}
  end

  @impl true
  def handle_info({:prepared, ref, result}, %{active: %{ref: ref} = active} = state) do
    Process.demonitor(active.task_ref, [:flush])
    GenServer.reply(active.from, result)
    uncertain = match?({:error, %Error{code: "audio_cleanup_uncertain"}}, result)
    next = %{state | active: nil}

    cond do
      uncertain ->
        if state[:release_from],
          do: GenServer.reply(state.release_from, {:error, elem(result, 1)})

        {:stop, :normal, %{next | released: true}}

      state.cancelled or state[:release_from] ->
        cleanup(next)
        if state[:release_from], do: GenServer.reply(state.release_from, :ok)
        {:stop, :normal, %{next | released: true}}

      true ->
        TempFiles.unpin(state.handle)
        {:noreply, next}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    if state.active do
      send(state.active.pid, :cancel)
      {:noreply, %{state | cancelled: true}}
    else
      cleanup(state)
      {:stop, :normal, %{state | released: true}}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{active: %{task_ref: ref} = active} = state
      ) do
    error =
      Error.new(
        503,
        "Audio worker stopped before cleanup confirmation",
        nil,
        "audio_cleanup_uncertain"
      )

    GenServer.reply(active.from, {:error, error})
    if state[:release_from], do: GenServer.reply(state.release_from, {:error, error})
    {:stop, :normal, %{state | released: true}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{released: true}), do: :ok
  def terminate(_reason, %{active: nil} = state), do: cleanup(state)
  def terminate(_reason, %{active: active}), do: send(active.pid, :cancel)

  defp do_prepare(handle, :speech, path, target, caps, policy, observer) do
    with {:ok, source} <-
           AccessLifecycle.measure(observer, :probe_ms, fn ->
             Probe.inspect(handle, path, %{
               purpose: :speech,
               policy: policy,
               format: caps[:source_format] || caps["source_format"]
             })
           end),
         {:ok, plan} <- Plan.speech(source, target, caps, policy) do
      prepare_observed(handle, plan, policy, observer)
    end
  end

  defp do_prepare(handle, :transcription, path, extension, caps, policy, observer) do
    with {:ok, source} <-
           AccessLifecycle.measure(observer, :probe_ms, fn ->
             Probe.inspect(handle, path, %{
               purpose: :transcription,
               extension: extension,
               policy: policy
             })
           end),
         {:ok, plan} <- Plan.transcription(source, caps, policy) do
      prepare_observed(handle, plan, policy, observer)
    end
  end

  defp prepare_observed(handle, plan, policy, observer) do
    AccessLifecycle.update(observer, %{
      input_format: plan.source.extension,
      audio_seconds: plan.source.duration,
      strategy: plan.strategy
    })

    result =
      AccessLifecycle.measure(observer, :conversion_ms, fn ->
        Convert.prepare(handle, plan, policy)
      end)

    case result do
      {:ok, _artifact} ->
        AccessLifecycle.update(observer, %{
          output_format: plan.target.extension,
          sample_rate: plan.target[:rate] || plan.target[:sample_rate],
          channels: plan.target.channels
        })

      _ ->
        :ok
    end

    result
  end

  defp cleanup(state) do
    if state.upload_lease, do: Admission.release(state.upload_lease)
    TempFiles.release(state.handle)
    Admission.release(state.operation_lease)
    :ok
  end
end
