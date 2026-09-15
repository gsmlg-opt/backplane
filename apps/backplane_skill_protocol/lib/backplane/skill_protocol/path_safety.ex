defmodule Backplane.SkillProtocol.PathSafety do
  @moduledoc false

  @spec realpath(String.t()) :: {:ok, String.t()} | {:error, term()}
  def realpath(path) when is_binary(path) do
    expanded = Path.expand(path)
    [root | segments] = Path.split(expanded)
    resolve(root, segments, MapSet.new())
  end

  defp resolve(current, [], _seen), do: {:ok, Path.expand(current)}

  defp resolve(current, [segment | rest], seen) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        if MapSet.member?(seen, candidate) do
          {:error, :eloop}
        else
          with {:ok, target} <- File.read_link(candidate) do
            [target_root | target_segments] =
              target |> Path.expand(Path.dirname(candidate)) |> Path.split()

            resolve(target_root, target_segments ++ rest, MapSet.put(seen, candidate))
          end
        end

      {:ok, _stat} ->
        resolve(candidate, rest, seen)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
