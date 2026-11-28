defmodule Backplane.Diagnostics.Evidence.Source do
  @moduledoc false

  alias Backplane.DiagnosticsClient.Redaction

  @max_blob_bytes 65_536
  @max_line_bytes 180
  @timeout_ms 1_500
  @radius 3

  def read(repositories, repository, sha, path, line) when is_map(repositories) do
    with root when is_binary(root) <- Map.get(repositories, repository),
         true <- File.dir?(root) and valid_ref?(sha, path, line),
         git when is_binary(git) <- System.find_executable("git"),
         :ok <- commit_exists(git, root, sha),
         {:ok, blob} <- blob(git, root, sha, path) do
      excerpt(blob, line)
    else
      {:error, :version_mismatch} = error -> error
      _ -> {:error, :source_unavailable}
    end
  end

  defp valid_ref?(sha, path, line) do
    is_binary(sha) and sha =~ ~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/ and
      is_binary(path) and byte_size(path) in 1..512 and valid_path?(path) and
      is_integer(line) and line > 0
  end

  defp valid_path?(path) do
    not String.contains?(path, ["\\", ":", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp commit_exists(git, root, sha) do
    case git_output(git, root, ["cat-file", "-t", sha], 128) do
      {:ok, "commit\n"} -> :ok
      {:ok, _other} -> {:error, :version_mismatch}
      {:error, :command_failed} -> {:error, :version_mismatch}
      _ -> {:error, :source_unavailable}
    end
  end

  defp blob(git, root, sha, path) do
    ref = sha <> ":" <> path

    with {:ok, size} <- git_output(git, root, ["cat-file", "-s", ref], 128),
         {bytes, ""} when bytes in 1..@max_blob_bytes <- Integer.parse(String.trim(size)),
         {:ok, file} <- git_output(git, root, ["cat-file", "blob", ref], bytes),
         true <- String.valid?(file) and not String.contains?(file, <<0>>) do
      {:ok, file}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp excerpt(blob, line) do
    start_line = max(line - @radius, 1)

    lines =
      blob
      |> String.split("\n")
      |> Enum.slice((start_line - 1)..(line + @radius - 1))

    end_line = start_line + length(lines) - 1

    if end_line >= line do
      {:ok,
       %{
         "status" => "available",
         "start_line" => start_line,
         "end_line" => end_line,
         "lines" => Enum.map(lines, &Redaction.summary(&1, @max_line_bytes))
       }}
    else
      {:error, :source_unavailable}
    end
  end

  defp git_output(git, root, args, max_bytes) do
    port =
      Port.open({:spawn_executable, git}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-C", root, "-c", "protocol.allow=never" | args],
        env: [
          {~c"GIT_NO_REPLACE_OBJECTS", ~c"1"},
          {~c"GIT_NO_LAZY_FETCH", ~c"1"},
          {~c"GIT_TERMINAL_PROMPT", ~c"0"},
          {~c"GIT_OPTIONAL_LOCKS", ~c"0"}
        ]
      ])

    collect(port, <<>>, max_bytes, System.monotonic_time(:millisecond) + @timeout_ms)
  rescue
    ArgumentError -> {:error, :command_failed}
  end

  defp collect(port, output, limit, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, bytes}} when byte_size(bytes) + byte_size(output) <= limit ->
        collect(port, output <> bytes, limit, deadline)

      {^port, {:data, _}} ->
        close(port)
        {:error, :output_limit}

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, _}} ->
        {:error, :command_failed}
    after
      remaining ->
        close(port)
        {:error, :timed_out}
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
