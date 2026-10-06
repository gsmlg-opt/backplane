defmodule Backplane.Admin.AudioPreview do
  @moduledoc "Bounded admin preview ownership using the public audio orchestration."
  use GenServer

  alias Backplane.Audio.{AccessLifecycle, Config, Error, Request, Resolver, Speech, Transcription}
  alias Backplane.Audio.Media.Session

  @limit 1_000_000
  @text_limit 200
  @timeout 120_000

  def start(owner, operation),
    do: GenServer.start(__MODULE__, {owner, operation, Config.policy()})

  def run(pid, params), do: GenServer.cast(pid, {:run, params})
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  def stage_upload(pid, upload) do
    GenServer.call(pid, {:stage_upload, upload}, 10_000)
  catch
    :exit, _ -> {:error, :upload_unavailable}
  end

  @impl true
  def init({owner, operation, policy}) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)
    started = System.monotonic_time(:millisecond)
    timeout = min(policy["request_timeout_ms"], @timeout)
    deadline = started + timeout

    with true <- Config.policy_valid?(),
         {:ok, session} <- Session.start(self(), policy),
         :ok <- admit_upload(operation, session),
         {:ok, observer} <- start_observer(session, operation, deadline) do
      :ok = Session.observe(session, observer)
      AccessLifecycle.update(observer, %{queue_ms: System.monotonic_time(:millisecond) - started})
      Process.send_after(self(), :timeout, max(deadline - System.monotonic_time(:millisecond), 0))

      {:ok,
       %{
         owner: owner,
         owner_ref: owner_ref,
         operation: operation,
         session: session,
         observer: observer,
         policy: policy,
         deadline: deadline,
         worker: nil,
         staged: nil
       }}
    else
      _ -> {:stop, :audio_unavailable}
    end
  end

  @impl true
  def handle_call({:stage_upload, upload}, _from, %{worker: nil, staged: nil} = state) do
    # The source remains inside the admitted session directory. Reserve this copy
    # separately from the input copy subsequently adopted by Transcription.run/4.
    result =
      with {:ok, %{type: :regular, size: size}} <- File.stat(upload.path),
           true <- size > 0 and size <= state.policy["upload_bytes"],
           :ok <- Session.reserve_input(state.session, size),
           {:ok, input} <- Session.input_path(state.session),
           path = Path.join(Path.dirname(input), "preview-upload"),
           :ok <- File.cp(upload.path, path),
           :ok <- File.chmod(path, 0o600) do
        {:ok, %{upload | path: path}}
      else
        _ -> {:error, :upload_unavailable}
      end

    case result do
      {:ok, upload} -> {:reply, :ok, %{state | staged: upload}}
      error -> {:stop, :normal, error, state}
    end
  end

  def handle_call({:stage_upload, _}, _from, state),
    do: {:reply, {:error, :upload_unavailable}, state}

  @impl true
  def handle_cast({:run, params}, %{worker: nil} = state) do
    parent = self()

    # Linking makes an unexpected preview-owner crash terminate its HTTP worker.
    # The session monitors this owner and cancels its own media subprocesses.
    worker = spawn_link(fn -> send(parent, {:result, execute(state, params)}) end)
    {:noreply, %{state | worker: worker}}
  end

  def handle_cast({:run, _}, state), do: {:noreply, state}
  def handle_cast(:cancel, state), do: finish(state, {:error, :cancelled})

  @impl true
  def handle_info({:result, result}, state), do: finish(state, result)
  def handle_info(:timeout, state), do: finish(state, {:error, :timeout})

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: finish(state, {:error, :cancelled})

  def handle_info({:EXIT, pid, _reason}, %{worker: pid} = state),
    do: finish(state, {:error, :preview_failed})

  @impl true
  def terminate(_reason, state) do
    AccessLifecycle.finish(state.observer, :error, nil, "audio_preview_stopped")
    if is_pid(state.worker), do: Process.exit(state.worker, :kill)
    # Session's owner monitor owns cleanup, including cancellation of media work.
    :ok
  end

  defp finish(state, result) do
    case result do
      {:ok, _} ->
        AccessLifecycle.finish(state.observer, :success, nil)

      {:error, %Error{} = error} ->
        AccessLifecycle.finish_error(state.observer, error)

      {:error, :cancelled} ->
        AccessLifecycle.finish(state.observer, :cancelled, nil, "audio_cancelled")

      {:error, :timeout} ->
        AccessLifecycle.finish(state.observer, :timeout, nil, "audio_deadline")

      _ ->
        AccessLifecycle.finish(state.observer, :error, nil, "audio_preview_failed")
    end

    send(state.owner, {:audio_preview, self(), state.operation, result})
    {:stop, :normal, state}
  end

  defp start_observer(session, operation, deadline) do
    case AccessLifecycle.start_preview(self(), operation, deadline_at_ms: deadline) do
      {:ok, observer} ->
        {:ok, observer}

      error ->
        Session.release(session)
        error
    end
  end

  defp admit_upload(:transcription, session), do: Session.admit_upload(session)
  defp admit_upload(:speech, _), do: :ok

  defp execute(%{operation: :speech} = state, params) do
    with true <- Config.policy_valid?(),
         true <- byte_size(params["input"] || "") <= state.policy["speech_json_bytes"],
         true <- String.length(params["input"] || "") <= @text_limit,
         {:ok, request} <- Request.speech(Map.take(params, ~w(model input voice response_format))),
         request = Map.put(request, :observer, state.observer),
         _ <- AccessLifecycle.update(state.observer, %{requested_model: request.model}),
         {:ok, resolution} <- Resolver.resolve(:speech, request.model),
         :ok <- Resolver.validate_request(resolution, request),
         {:ok, bytes, _} <-
           Speech.run(request, resolution, state.session, state.deadline, &collect/2, <<>>) do
      {:ok, %{bytes: bytes, format: request.response_format}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, %Error{} = error, _} -> {:error, error}
      {:error, %Error{} = error, _, _} -> {:error, error}
      _ -> {:error, :preview_failed}
    end
  end

  defp execute(%{operation: :transcription, staged: %Plug.Upload{} = upload} = state, params) do
    params = params |> Map.take(~w(model language)) |> Map.put("file", upload)

    with true <- Config.policy_valid?(),
         {:ok, request} <- Request.transcription(params),
         request = Map.put(request, :observer, state.observer),
         _ <- AccessLifecycle.update(state.observer, %{requested_model: request.model}),
         {:ok, resolution} <- Resolver.resolve(:transcription, request.model),
         :ok <- Resolver.validate_request(resolution, request),
         {:ok, text, _} <- Transcription.run(request, resolution, state.session, state.deadline) do
      {:ok, String.slice(text, 0, 4000)}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, %Error{} = error, _} -> {:error, error}
      {:error, %Error{} = error, _, _} -> {:error, error}
      _ -> {:error, :preview_failed}
    end
  end

  defp execute(_, _), do: {:error, :preview_failed}

  defp collect({:chunk, bytes}, acc), do: append(acc, bytes)

  defp collect({:file, artifact}, acc) do
    case File.open(artifact.path, [:read, :binary], &IO.binread(&1, @limit + 1)) do
      {:ok, bytes} when is_binary(bytes) -> append(acc, bytes)
      _ -> {:error, Error.new(503, "Preview unavailable", nil, "preview_unavailable"), acc}
    end
  end

  defp append(acc, bytes) when byte_size(acc) + byte_size(bytes) <= @limit,
    do: {:ok, acc <> bytes}

  defp append(acc, _),
    do: {:error, Error.new(413, "Preview exceeds 1 MB", nil, "preview_too_large"), acc}
end
