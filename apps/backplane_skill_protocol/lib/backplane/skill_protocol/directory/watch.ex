defmodule Backplane.SkillProtocol.Directory.Watch do
  @moduledoc false

  alias Backplane.SkillProtocol.PathSafety

  # A recursive watch follows document changes. A parent watch follows the
  # name of the root across removal or atomic replacement. If the root is
  # absent, the boundary moves down as missing directories are created.
  def targets(path, nil), do: boundary_targets([path])

  def targets(path, {canonical, _, _} = identity),
    do: [{identity, :tree} | boundary_targets([path, canonical])]

  defp boundary_targets(paths) do
    paths
    |> Enum.map(&boundary/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp boundary(path) do
    parent = Path.dirname(path)

    if parent != path do
      with {:ok, canonical} <- PathSafety.realpath(parent),
           {:ok, %{type: :directory} = stat} <- File.stat(canonical, time: :posix) do
        {{canonical, stat.major_device, stat.inode},
         {:entry, Path.join(canonical, Path.basename(path))}}
      else
        _ -> boundary(parent)
      end
    end
  end

  # Only the scan worker waits for the subscription. Snapshot reads remain
  # independent even if starting the watcher takes time.
  def await_start(watcher) do
    ref = Process.monitor(watcher)
    send(watcher, {:watch_ready?, self(), ref})

    receive do
      {:watch_ready, ^ref} -> :ok
      {:DOWN, ^ref, :process, ^watcher, _} -> :ok
    after
      1_000 -> :ok
    end

    Process.demonitor(ref, [:flush])
    :ok
  end

  def run(directory, targets) do
    watches =
      Enum.reduce(targets, %{}, fn {{path, _, _}, filter}, watches ->
        with {:ok, filesystem} <- FileSystem.start_link(watch_options(path, filter)),
             :ok <- FileSystem.subscribe(filesystem) do
          Map.put(watches, filesystem, filter)
        else
          _ -> watches
        end
      end)

    forward(directory, watches)
  end

  defp watch_options(path, filter) do
    case :os.type() do
      {:unix, :darwin} -> [dirs: [path], watch_root: true]
      _ -> [dirs: [path], recursive: filter == :tree]
    end
  end

  defp forward(_directory, watches) when map_size(watches) == 0, do: :ok

  defp forward(directory, watches) do
    receive do
      {:watch_ready?, scanner, ref} ->
        send(scanner, {:watch_ready, ref})
        forward(directory, watches)

      {:file_event, filesystem, :stop} when is_map_key(watches, filesystem) ->
        Process.unlink(filesystem)
        Process.exit(filesystem, :shutdown)
        forward(directory, Map.delete(watches, filesystem))

      {:file_event, filesystem, {path, _events} = event} when is_map_key(watches, filesystem) ->
        if watches[filesystem] in [:tree, {:entry, Path.expand(path)}] do
          send(directory, {:file_event, self(), event})
        end

        forward(directory, watches)
    end
  end
end
