defmodule Backplane.HostAgent.Diagnostics.Collectors.Process do
  @moduledoc "Samples a registered PID using host boot and process creation identity."

  alias Backplane.HostAgent.Diagnostics.Collectors.Probes

  @linux_boot "/proc/sys/kernel/random/boot_id"

  def boot_identity(%{platform: :linux, read: read}) do
    with {:ok, value} <- read.(@linux_boot, 128),
         boot <- String.trim(value),
         true <- Regex.match?(~r/\A[0-9a-f-]{36}\z/i, boot) do
      boot
    else
      _ -> nil
    end
  end

  def boot_identity(%{platform: :darwin, command: command}) do
    with {:ok, bytes} <- command.("sysctl", ["-n", "kern.boottime"]),
         [_, seconds, microseconds] <- Regex.run(~r/\{ sec = (\d+), usec = (\d+) \}/, bytes) do
      Probes.fingerprint({:darwin, seconds, microseconds})
    else
      _ -> nil
    end
  end

  def boot_identity(_env), do: nil

  def sample(pid, %{boot_id: boot} = env)
      when is_integer(pid) and pid in 1..2_147_483_647 and is_binary(boot) do
    case process_fields(pid, env) do
      {:ok, start, status, metrics} ->
        %{
          status: status,
          pid: pid,
          start: start,
          instance: Probes.fingerprint({boot, pid, start}),
          metrics: metrics
        }

      :absent ->
        %{status: :absent}

      :unavailable ->
        %{status: :unavailable}
    end
  end

  def sample(_pid, _env), do: %{status: :unavailable}

  defp process_fields(pid, %{platform: :linux, read: read}) do
    case read.("/proc/#{pid}/stat", 4_096) do
      {:ok, bytes} -> linux_fields(bytes, pid)
      {:error, :enoent} -> :absent
      _ -> :unavailable
    end
  end

  defp process_fields(pid, %{platform: :darwin, command: command}) do
    case command.("ps", [
           "-p",
           Integer.to_string(pid),
           "-o",
           "lstart=",
           "-o",
           "rss=",
           "-o",
           "time=",
           "-o",
           "state="
         ]) do
      {:ok, bytes} -> darwin_fields(bytes)
      {:error, {:exit, 1, true}} -> :absent
      _ -> :unavailable
    end
  end

  defp process_fields(_pid, _env), do: :unavailable

  defp linux_fields(bytes, pid) do
    with true <- String.starts_with?(bytes, "#{pid} ("),
         {finish, 1} <- List.last(:binary.matches(bytes, ")")),
         [state | _] = fields <-
           bytes
           |> binary_part(finish + 1, byte_size(bytes) - finish - 1)
           |> :binary.split([" ", "\n"], [:global, :trim_all]),
         start when is_integer(start) <- Probes.unsigned(Enum.at(fields, 19)) do
      metrics = %{
        "process_user_cpu_ticks" => Probes.unsigned(Enum.at(fields, 11)),
        "process_system_cpu_ticks" => Probes.unsigned(Enum.at(fields, 12)),
        "process_rss_pages" => Probes.unsigned(Enum.at(fields, 21))
      }

      {:ok, Integer.to_string(start), status(state), metrics}
    else
      _ -> :unavailable
    end
  end

  defp darwin_fields(bytes) do
    case String.split(bytes) do
      [day, month, date, time, year, rss, cpu, state] ->
        if Regex.match?(~r/\A\d\d:\d\d:\d\d\z/, time) do
          {:ok, Enum.join([day, month, date, time, year], " "), status(state),
           %{
             "process_rss_kib" => Probes.unsigned(rss),
             "process_cpu_centiseconds" => cpu_centiseconds(cpu)
           }}
        else
          :unavailable
        end

      _ ->
        :unavailable
    end
  end

  defp status("Z" <> _), do: :exited
  defp status("X" <> _), do: :exited
  defp status(_), do: :running

  defp cpu_centiseconds(cpu) do
    with [_ | _] = fields <- String.split(cpu, [":", "."]),
         [centis, seconds, minutes | hours] <-
           fields |> Enum.map(&Probes.unsigned/1) |> Enum.reverse(),
         true <-
           length(hours) <= 1 and Enum.all?([centis, seconds, minutes | hours], &is_integer/1) do
      centis + 100 * (seconds + 60 * minutes + 3_600 * List.first(hours, 0))
    else
      _ -> nil
    end
  end
end
