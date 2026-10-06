defmodule Backplane.Audio.Media.TempFiles do
  @moduledoc "Owns bounded, private request directories until the HTTP owner releases them."
  use GenServer

  alias Backplane.Audio.Error

  defstruct [:id, :dir]

  @files %{
    input: "input.media",
    probe: "probe.json",
    decoded: "decoded.pcm",
    output: "output.media",
    staging: "staging.media"
  }
  @pending ".media-pending"
  @confirmed ".cleanup-confirmed"

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def create(owner, policy, server \\ __MODULE__) when is_pid(owner) and is_map(policy) do
    GenServer.call(server, {:create, owner, policy})
  catch
    :exit, _ -> {:error, unavailable()}
  end

  def reserve(%__MODULE__{id: id}, bytes, server \\ __MODULE__)
      when is_integer(bytes) and bytes >= 0 do
    GenServer.call(server, {:reserve, id, bytes})
  catch
    :exit, _ -> {:error, unavailable()}
  end

  def release_reservation(%__MODULE__{id: id}, bytes, server \\ __MODULE__)
      when is_integer(bytes) and bytes >= 0 do
    GenServer.call(server, {:unreserve, id, bytes})
  catch
    :exit, _ -> :ok
  end

  def adopt_upload(
        %__MODULE__{} = handle,
        %Plug.Upload{path: source},
        policy,
        server \\ __MODULE__
      ) do
    with {:ok, %{type: :regular, size: size}} <- File.stat(source),
         true <- size <= policy["upload_bytes"],
         {:ok, target} <- path(handle, :input, server),
         :ok <- reserve(handle, size, server) do
      case File.cp(source, target) do
        :ok ->
          File.chmod(target, 0o600)
          {:ok, target, size}

        {:error, _} ->
          File.rm(target)
          release_reservation(handle, size, server)

          {:error,
           Error.new(400, "Audio upload could not be stored", "file", "audio_upload_failed")}
      end
    else
      false ->
        {:error, Error.new(413, "Uploaded audio is too large", "file", "audio_upload_too_large")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, _} ->
        {:error,
         Error.new(400, "Audio upload could not be stored", "file", "audio_upload_failed")}
    end
  end

  def path(%__MODULE__{id: id}, kind, server \\ __MODULE__) when is_map_key(@files, kind) do
    GenServer.call(server, {:path, id, kind})
  catch
    :exit, _ -> {:error, unavailable()}
  end

  def release(%__MODULE__{id: id}, server \\ __MODULE__) do
    GenServer.call(server, {:release, id})
  catch
    :exit, _ -> :ok
  end

  def pin(%__MODULE__{id: id}, server \\ __MODULE__), do: GenServer.call(server, {:pin, id})
  def unpin(%__MODULE__{id: id}, server \\ __MODULE__), do: GenServer.call(server, {:unpin, id})

  def ready?(server \\ __MODULE__) do
    GenServer.call(server, :ready?)
  catch
    :exit, _ -> false
  end

  def usage(server \\ __MODULE__), do: GenServer.call(server, :usage)

  @impl true
  def init(opts) do
    root =
      Keyword.get(opts, :root) || System.get_env("BACKPLANE_AUDIO_TEMP_DIR") ||
        Path.join(System.tmp_dir() || "/tmp", "backplane-audio")

    policy = Keyword.get(opts, :policy, %{"request_timeout_ms" => 600_000})

    case prepare_root(root) do
      :ok ->
        vm_nonce = vm_nonce()
        janitor(root, policy, vm_nonce, nil)
        boot = Path.join(root, "boot-#{System.pid()}-#{vm_nonce}-#{random()}")

        case prepare_boot(boot) do
          :ok ->
            Process.send_after(self(), :janitor_tick, 1_000)

            {:ok,
             %{
               root: root,
               boot: boot,
               vm_nonce: vm_nonce,
               policy: policy,
               ready: not orphan_present?(root, boot),
               entries: %{},
               refs: %{},
               reserved: 0
             }}

          _ ->
            {:ok, %{root: root, boot: nil, ready: false, entries: %{}, refs: %{}, reserved: 0}}
        end

      _ ->
        {:ok, %{root: root, boot: nil, ready: false, entries: %{}, refs: %{}, reserved: 0}}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.ready, state}

  def handle_call(:usage, _from, state),
    do: {:reply, %{reserved: state.reserved, requests: map_size(state.entries)}, state}

  def handle_call({:create, owner, policy}, _from, state) do
    cond do
      not state.ready ->
        {:reply, {:error, unavailable()}, state}

      not Process.alive?(owner) ->
        {:reply, {:error, cancelled()}, state}

      not is_integer(policy["temporary_storage_bytes"]) ->
        {:reply, {:error, unavailable()}, state}

      true ->
        id = random()
        dir = Path.join(state.boot, "r-#{id}")

        case File.mkdir(dir) do
          :ok ->
            File.chmod(dir, 0o700)
            ref = Process.monitor(owner)

            entry = %{
              dir: dir,
              ref: ref,
              reserved: 0,
              limit: policy["temporary_storage_bytes"],
              pinned: false,
              owner: owner,
              dead: false
            }

            next = %{
              state
              | entries: Map.put(state.entries, id, entry),
                refs: Map.put(state.refs, ref, id)
            }

            {:reply, {:ok, %__MODULE__{id: id, dir: dir}}, next}

          _ ->
            {:reply, {:error, unavailable()}, state}
        end
    end
  end

  def handle_call({:path, id, kind}, _from, state) do
    case state.entries[id] do
      nil -> {:reply, {:error, cancelled()}, state}
      entry -> {:reply, {:ok, Path.join(entry.dir, @files[kind])}, state}
    end
  end

  def handle_call({:reserve, id, bytes}, _from, state) do
    case state.entries[id] do
      nil ->
        {:reply, {:error, cancelled()}, state}

      %{limit: limit} = entry when state.reserved + bytes <= limit ->
        next = put_in(state.entries[id].reserved, entry.reserved + bytes)
        {:reply, :ok, %{next | reserved: state.reserved + bytes}}

      _ ->
        {:reply,
         {:error,
          Error.new(429, "Audio temporary storage is full", nil, "audio_storage_exhausted")},
         state}
    end
  end

  def handle_call({:unreserve, id, bytes}, _from, state) do
    case state.entries[id] do
      nil ->
        {:reply, :ok, state}

      entry ->
        reduction = min(bytes, entry.reserved)
        next = put_in(state.entries[id].reserved, entry.reserved - reduction)
        {:reply, :ok, %{next | reserved: state.reserved - reduction}}
    end
  end

  def handle_call({:release, id}, _from, state) do
    case state.entries[id] do
      %{pinned: true} -> {:reply, :ok, update_entry(state, id, &%{&1 | dead: true})}
      _ -> {:reply, :ok, drop(id, state)}
    end
  end

  def handle_call({:pin, id}, _from, state) do
    case state.entries[id] do
      %{pinned: false, dead: false, owner: owner} = entry ->
        if Process.alive?(owner) do
          # Invalidate the previous generation before publishing new native work.
          with result when result in [:ok, {:error, :enoent}] <- File.rm(entry.dir <> @confirmed),
               :ok <- File.write(entry.dir <> @pending, "1", [:write]),
               :ok <- File.chmod(entry.dir <> @pending, 0o600) do
            {:reply, :ok, update_entry(state, id, &%{&1 | pinned: true})}
          else
            _ -> {:reply, {:error, unavailable()}, state}
          end
        else
          {:reply, {:error, cancelled()}, state}
        end

      _ ->
        {:reply, {:error, cancelled()}, state}
    end
  end

  def handle_call({:unpin, id}, _from, state) do
    case state.entries[id] do
      nil ->
        {:reply, :ok, state}

      entry ->
        File.rm(entry.dir <> @pending)
        next = update_entry(state, id, &%{&1 | pinned: false})
        next = if entry.dead or not Process.alive?(entry.owner), do: drop(id, next), else: next
        {:reply, :ok, next}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    id = state.refs[ref]

    case state.entries[id] do
      %{pinned: true} -> {:noreply, update_entry(state, id, &%{&1 | dead: true})}
      _ -> {:noreply, drop(id, state)}
    end
  end

  def handle_info(:janitor_tick, %{boot: boot} = state) when is_binary(boot) do
    state =
      Enum.reduce(state.entries, state, fn
        {id, %{pinned: true, dead: true, dir: dir}}, acc ->
          if cleanup_confirmed?(dir), do: drop(id, acc), else: acc

        _, acc ->
          acc
      end)

    janitor(state.root, state.policy, state.vm_nonce, boot)
    Process.send_after(self(), :janitor_tick, 1_000)
    {:noreply, %{state | ready: not orphan_present?(state.root, boot)}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.entries, fn {_id, entry} ->
      unless entry.pinned, do: remove_entry_files(entry.dir)
    end)

    if state.boot && not Enum.any?(state.entries, fn {_id, entry} -> entry.pinned end),
      do: File.rm_rf(state.boot)

    :ok
  end

  defp drop(nil, state), do: state

  defp drop(id, state) do
    case Map.pop(state.entries, id) do
      {nil, _} ->
        state

      {entry, entries} ->
        Process.demonitor(entry.ref, [:flush])
        remove_entry_files(entry.dir)

        %{
          state
          | entries: entries,
            refs: Map.delete(state.refs, entry.ref),
            reserved: state.reserved - entry.reserved
        }
    end
  end

  defp update_entry(state, id, function) do
    case state.entries[id] do
      nil -> state
      entry -> put_in(state.entries[id], function.(entry))
    end
  end

  defp prepare_boot(boot) do
    case File.mkdir(boot) do
      :ok ->
        with :ok <- File.chmod(boot, 0o700),
             :ok <-
               File.write(Path.join(boot, ".owner"), :erlang.term_to_binary(self()), [:exclusive]),
             :ok <- File.chmod(Path.join(boot, ".owner"), 0o600) do
          :ok
        else
          error ->
            File.rm_rf(boot)
            error
        end

      error ->
        error
    end
  end

  defp prepare_root(root) do
    with :ok <- File.mkdir_p(root),
         {:ok, %{type: :directory}} <- File.lstat(root),
         :ok <- File.chmod(root, 0o700) do
      :ok
    end
  end

  defp janitor(root, policy, vm_nonce, current_boot) do
    cutoff = max(policy["request_timeout_ms"] || 600_000, 600_000) * 2
    now = System.system_time(:millisecond)

    with {:ok, names} <- File.ls(root) do
      names
      |> Enum.take(100)
      |> Enum.filter(&String.starts_with?(&1, "boot-"))
      |> Enum.reject(&(Path.join(root, &1) == current_boot))
      |> Enum.each(fn name -> clean_old_boot(root, name, vm_nonce, now, cutoff) end)
    end
  end

  defp clean_old_boot(root, name, vm_nonce, now, cutoff) do
    path = Path.join(root, name)
    same_vm = String.contains?(name, "-#{vm_nonce}-")
    old_dead_vm = not owner_alive?(name) and old_enough?(path, now, cutoff)

    if (same_vm and not manager_alive?(path)) or old_dead_vm do
      case File.ls(path) do
        {:ok, requests} ->
          requests
          |> Enum.take(100)
          |> Enum.filter(&(String.starts_with?(&1, "r-") and File.dir?(Path.join(path, &1))))
          |> Enum.each(fn request ->
            dir = Path.join(path, request)
            confirmed = cleanup_confirmed?(dir)
            pending = File.regular?(dir <> @pending)
            if confirmed or not pending, do: remove_entry_files(dir)
          end)

          case File.ls(path) do
            {:ok, [".owner"]} ->
              File.rm(Path.join(path, ".owner"))
              File.rmdir(path)

            {:ok, []} ->
              File.rmdir(path)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end
  end

  # Never admit a new boot while any older request tree is unaccounted for,
  # including another live BEAM sharing this root.
  defp orphan_present?(root, current_boot) do
    case File.ls(root) do
      {:ok, boots} ->
        Enum.any?(boots, fn name ->
          boot = Path.join(root, name)

          boot != current_boot and String.starts_with?(name, "boot-") and
            case File.ls(boot) do
              {:ok, files} -> Enum.any?(files, &String.starts_with?(&1, "r-"))
              _ -> true
            end
        end)

      _ ->
        true
    end
  end

  def cleanup_confirmed?(dir) do
    case File.lstat(dir <> @confirmed) do
      {:ok, %{type: :regular, size: 6}} -> File.read(dir <> @confirmed) == {:ok, "clean\n"}
      _ -> false
    end
  end

  defp manager_alive?(boot) do
    with {:ok, data} when byte_size(data) < 256 <- File.read(Path.join(boot, ".owner")),
         pid when is_pid(pid) <- :erlang.binary_to_term(data, [:safe]),
         true <- node(pid) == node() do
      Process.alive?(pid)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp remove_entry_files(dir) do
    File.rm_rf(dir)
    File.rm(dir <> @pending)
    File.rm(dir <> @confirmed)
    :ok
  end

  defp old_enough?(path, now, cutoff) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory, mtime: mtime}} -> now - mtime * 1_000 > cutoff
      _ -> false
    end
  end

  defp vm_nonce do
    key = {__MODULE__, :vm_nonce}

    case :persistent_term.get(key, nil) do
      nil ->
        nonce = random()
        :persistent_term.put(key, nonce)
        nonce

      nonce ->
        nonce
    end
  end

  defp owner_alive?("boot-" <> rest) do
    case Integer.parse(rest) do
      {pid, "-" <> _nonce} when pid > 0 ->
        case :os.type() do
          {:unix, :linux} ->
            File.exists?("/proc/#{pid}")

          {:unix, :darwin} ->
            case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
              {_, 0} -> true
              _ -> false
            end

          _ ->
            true
        end

      _ ->
        true
    end
  end

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp unavailable,
    do: Error.new(503, "Audio temporary storage is unavailable", nil, "audio_unavailable")

  defp cancelled, do: Error.new(499, "Audio request was cancelled", nil, "audio_cancelled")
end
