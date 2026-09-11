defmodule Backplane.SkillProtocol.Cache.Ownership do
  @moduledoc false

  use GenServer

  alias Backplane.SkillProtocol.Cache.NativeLock

  @lock_file ".cache-owner.lock"
  @legacy_file ".process-owner"
  @layout ~w(.staging artifacts prepared associations blocks)

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    backend = Keyword.get(opts, :backend, NativeLock)
    GenServer.start_link(__MODULE__, backend, name: name)
  end

  @spec acquire(binary(), binary()) :: :ok | {:error, term()}
  def acquire(root, owner), do: acquire(__MODULE__, root, owner)

  @doc false
  @spec acquire(GenServer.server(), binary(), binary()) :: :ok | {:error, term()}
  def acquire(server, root, owner), do: GenServer.call(server, {:acquire, root, owner}, 15_000)

  @spec canonical_root(binary()) :: {:ok, binary()} | {:error, term()}
  def canonical_root(root) when is_binary(root), do: canonical(Path.expand(root))

  @impl true
  def init(backend) do
    if function_exported?(backend, :load_nif, 0), do: backend.load_nif()
    {:ok, %{backend: backend, roots: %{}}}
  end

  @impl true
  def handle_call({:acquire, root, owner}, _from, state) do
    case Map.fetch(state.roots, root) do
      {:ok, %{owner: ^owner}} ->
        {:reply, :ok, state}

      {:ok, _ownership} ->
        {:reply, {:error, :different_owner}, state}

      :error ->
        acquire_root(state, root, owner)
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.roots, fn {_root, ownership} ->
      state.backend.release(ownership.handle)
    end)

    :ok
  end

  defp acquire_root(state, root, owner) do
    lock_path = Path.join(root, @lock_file)

    with {:ok, handle} <- state.backend.acquire(lock_path) do
      case initialize_root(root, owner) do
        :ok ->
          ownership = %{owner: owner, handle: handle}
          {:reply, :ok, put_in(state.roots[root], ownership)}

        {:error, _reason} = error ->
          :ok = state.backend.release(handle)
          {:reply, error, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp initialize_root(root, owner) do
    with :ok <- reject_legacy_marker(root),
         :ok <- claim_logical_owner(root, owner),
         :ok <- ensure_layout(root) do
      :ok
    end
  end

  defp reject_legacy_marker(root) do
    case File.lstat(Path.join(root, @legacy_file)) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :legacy_process_owner}
      {:error, reason} -> {:error, {:legacy_process_owner, reason}}
    end
  end

  defp claim_logical_owner(root, owner) do
    path = Path.join(root, ".owner")

    case File.read(path) do
      {:ok, ^owner} -> :ok
      {:ok, _other} -> {:error, :different_owner}
      {:error, :enoent} -> publish_owner(path, owner)
      {:error, reason} -> {:error, {:owner_metadata, reason}}
    end
  end

  defp publish_owner(path, owner) do
    candidate = path <> ".candidate." <> unique_id()

    try do
      with :ok <- File.write(candidate, owner, [:binary, :exclusive]),
           {:ok, io} <- File.open(candidate, [:read, :write, :binary]),
           :ok <- :file.sync(io),
           :ok <- File.close(io),
           :ok <- link_owner(candidate, path, owner) do
        :ok
      else
        {:error, reason} -> {:error, {:owner_metadata, reason}}
      end
    after
      File.rm(candidate)
    end
  end

  defp link_owner(candidate, path, owner) do
    case :file.make_link(String.to_charlist(candidate), String.to_charlist(path)) do
      :ok -> :ok
      {:error, :eexist} -> claim_logical_owner(Path.dirname(path), owner)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_layout(root) do
    Enum.reduce_while(@layout, :ok, fn directory, :ok ->
      case File.mkdir_p(Path.join(root, directory)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:layout, reason}}}
      end
    end)
  end

  defp canonical(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, resolved} ->
        {:ok, resolved |> List.to_string() |> Path.expand()}

      {:error, :einval} ->
        parent = Path.dirname(path)

        if parent == path do
          {:ok, path}
        else
          with {:ok, canonical_parent} <- canonical(parent) do
            {:ok, Path.join(canonical_parent, Path.basename(path))}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unique_id, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
end
