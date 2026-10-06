defmodule Backplane.Audio.Media.Admission do
  @moduledoc false
  use GenServer

  alias Backplane.Audio.Error
  alias Backplane.Audio.Media.TempFiles

  @limits %{
    operation: "concurrent_operations",
    upload: "concurrent_uploads",
    media: "media_processes"
  }

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  def acquire(kind, owner, policy, server \\ __MODULE__)
      when kind in [:operation, :upload, :media] and is_pid(owner) and is_map(policy) do
    GenServer.call(server, {:acquire, kind, owner, policy})
  catch
    :exit, _ -> {:error, unavailable()}
  end

  def release(ref, server \\ __MODULE__) when is_reference(ref) do
    GenServer.call(server, {:release, ref})
  catch
    :exit, _ -> :ok
  end

  def pin(ref, directory, server \\ __MODULE__) when is_reference(ref) and is_binary(directory),
    do: GenServer.call(server, {:pin, ref, directory})

  def quarantine(ref, server \\ __MODULE__), do: GenServer.call(server, {:quarantine, ref})

  def counts(server \\ __MODULE__), do: GenServer.call(server, :counts)

  @impl true
  def init(_) do
    {:ok, %{leases: %{}, counts: %{operation: 0, upload: 0, media: 0}}}
  end

  @impl true
  def handle_call({:acquire, kind, owner, policy}, _from, state) do
    limit = policy[@limits[kind]]

    cond do
      not is_integer(limit) or limit < 1 ->
        {:reply, {:error, unavailable()}, state}

      state.counts[kind] >= limit ->
        {:reply,
         {:error, Error.new(429, "Audio capacity is exhausted", nil, "audio_capacity_exhausted")},
         state}

      not Process.alive?(owner) ->
        {:reply, {:error, Error.new(499, "Audio request was cancelled", nil, "audio_cancelled")},
         state}

      true ->
        ref = Process.monitor(owner)

        leases =
          Map.put(state.leases, ref, %{
            kind: kind,
            owner: owner,
            pinned: false,
            dead: false,
            directory: nil
          })

        counts = Map.update!(state.counts, kind, &(&1 + 1))
        {:reply, {:ok, ref}, %{state | leases: leases, counts: counts}}
    end
  end

  def handle_call({:release, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, drop(ref, state)}
  end

  def handle_call({:pin, ref, directory}, _from, state) do
    next =
      case state.leases[ref] do
        nil -> state
        lease -> put_in(state.leases[ref], %{lease | pinned: true, directory: directory})
      end

    {:reply, :ok, next}
  end

  def handle_call({:quarantine, ref}, _from, state) do
    case state.leases[ref] do
      nil ->
        {:reply, :ok, state}

      lease ->
        Process.send_after(self(), :reconcile, 1_000)
        {:reply, :ok, put_in(state.leases[ref], %{lease | dead: true})}
    end
  end

  def handle_call(:counts, _from, state), do: {:reply, state.counts, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case state.leases[ref] do
      %{pinned: true} = lease ->
        Process.send_after(self(), :reconcile, 1_000)
        {:noreply, put_in(state.leases[ref], %{lease | dead: true})}

      _ ->
        {:noreply, drop(ref, state)}
    end
  end

  def handle_info(:reconcile, state) do
    next =
      Enum.reduce(state.leases, state, fn
        {ref, %{pinned: true, dead: true, directory: dir}}, acc when is_binary(dir) ->
          if TempFiles.cleanup_confirmed?(dir) or not File.exists?(dir),
            do: drop(ref, acc),
            else: acc

        _, acc ->
          acc
      end)

    if Enum.any?(next.leases, fn {_ref, lease} -> lease.pinned and lease.dead end),
      do: Process.send_after(self(), :reconcile, 1_000)

    {:noreply, next}
  end

  defp drop(ref, state) do
    case Map.pop(state.leases, ref) do
      {nil, _} ->
        state

      {%{kind: kind}, leases} ->
        %{state | leases: leases, counts: Map.update!(state.counts, kind, &(&1 - 1))}
    end
  end

  defp unavailable,
    do: Error.new(503, "Audio media admission is unavailable", nil, "audio_unavailable")
end
