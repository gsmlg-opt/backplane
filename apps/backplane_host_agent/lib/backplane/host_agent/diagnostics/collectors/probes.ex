defmodule Backplane.HostAgent.Diagnostics.Collectors.Probes do
  @moduledoc false

  @command_ms 400
  @command_bytes 16 * 1024

  def platform do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :darwin
      _ -> :unsupported
    end
  end

  def read(path, maximum) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case :file.read(file, maximum + 1) do
          {:ok, bytes} when byte_size(bytes) <= maximum -> {:ok, bytes}
          {:ok, _} -> {:error, :too_large}
          :eof -> {:ok, ""}
          {:error, _} = error -> error
        end
      after
        File.close(file)
      end
    end
  end

  def command(program, arguments) do
    case System.find_executable(program) do
      nil ->
        {:error, :not_found}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: arguments,
            env: [{~c"LC_ALL", ~c"C"}, {~c"TZ", ~c"UTC"}]
          ])

        receive_output(port, System.monotonic_time(:millisecond) + @command_ms, 0, [])
    end
  rescue
    _error in [ErlangError, ArgumentError] -> {:error, :spawn_failed}
  end

  def fingerprint(value) do
    <<short::binary-size(16), _::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))

    Base.encode16(short, case: :lower)
  end

  def unsigned(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number in 0..9_007_199_254_740_991 -> number
      _ -> nil
    end
  end

  def unsigned(_), do: nil

  defp receive_output(port, deadline, size, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      terminate(port, :timeout)
    else
      receive do
        {^port, {:data, part}} when size + byte_size(part) <= @command_bytes ->
          receive_output(port, deadline, size + byte_size(part), [part | acc])

        {^port, {:data, _}} ->
          terminate(port, :too_large)

        {^port, {:exit_status, 0}} ->
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

        {^port, {:exit_status, status}} ->
          empty? = acc |> IO.iodata_to_binary() |> String.trim() == ""
          {:error, {:exit, status, empty?}}
      after
        remaining -> terminate(port, :timeout)
      end
    end
  end

  defp terminate(port, reason) do
    with {:os_pid, pid} <- Port.info(port, :os_pid),
         kill when is_binary(kill) <- System.find_executable("kill") do
      System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    try do
      Port.close(port)
    rescue
      _error in ArgumentError -> :ok
    end

    drop_port_messages(port)
    {:error, reason}
  end

  defp drop_port_messages(port) do
    receive do
      {^port, _} -> drop_port_messages(port)
    after
      0 -> :ok
    end
  end
end
