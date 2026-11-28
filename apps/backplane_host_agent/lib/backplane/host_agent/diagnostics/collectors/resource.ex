defmodule Backplane.HostAgent.Diagnostics.Collectors.Resource do
  @moduledoc "Collects inexpensive, explicitly scoped resource measurements."

  alias Backplane.HostAgent.Diagnostics.Collectors.Probes

  @units %{
    "process_user_cpu_ticks" => "ticks",
    "process_system_cpu_ticks" => "ticks",
    "process_rss_pages" => "pages",
    "process_rss_kib" => "KiB",
    "process_cpu_centiseconds" => "cs",
    "process_fd_table_slots" => "slots",
    "host_memory_total_bytes" => "bytes",
    "host_memory_available_bytes" => "bytes",
    "host_runnable_tasks" => "tasks",
    "host_cpu_total_ticks" => "ticks",
    "host_cpu_idle_ticks" => "ticks",
    "disk_blocks_total_kib" => "KiB",
    "disk_blocks_available_kib" => "KiB"
  }

  def sample(process, disk_path, env) do
    values =
      host(env)
      |> Map.merge(Map.get(process, :metrics, %{}))
      |> Map.merge(fd_table(process, env))
      |> Map.merge(disk(disk_path, env))

    measurements =
      for {name, value} <- Enum.sort(values), not is_nil(value) do
        measurement = %{"name" => name, "value" => value}

        case Map.fetch(@units, name) do
          {:ok, unit} -> Map.put(measurement, "unit", unit)
          :error -> measurement
        end
      end

    missing =
      for {name, nil} <- Enum.sort(values),
          do: %{"kind" => "measurement_unavailable", "reference" => name}

    %{measurements: measurements, unavailable: missing}
  end

  defp host(%{platform: :linux, read: read}) do
    memory =
      case read.("/proc/meminfo", 8_192) do
        {:ok, data} ->
          %{
            "host_memory_total_bytes" => proc_kib(data, "MemTotal"),
            "host_memory_available_bytes" => proc_kib(data, "MemAvailable")
          }

        _ ->
          %{"host_memory_total_bytes" => nil, "host_memory_available_bytes" => nil}
      end

    {load, runnable} =
      case read.("/proc/loadavg", 1_024) do
        {:ok, data} ->
          case String.split(data) do
            [load, _, _, tasks, _] ->
              {checked_decimal(load),
               tasks |> String.split("/", parts: 2) |> List.first() |> Probes.unsigned()}

            _ ->
              {nil, nil}
          end

        _ ->
          {nil, nil}
      end

    memory
    |> Map.merge(%{"host_load_average_1m" => load, "host_runnable_tasks" => runnable})
    |> Map.merge(cpu_ticks(read))
  end

  defp host(%{platform: :darwin, command: command}) do
    total =
      case command.("sysctl", ["-n", "hw.memsize"]) do
        {:ok, data} -> Probes.unsigned(data)
        _ -> nil
      end

    load =
      case command.("sysctl", ["-n", "vm.loadavg"]) do
        {:ok, data} -> data |> String.split() |> Enum.at(1) |> checked_decimal()
        _ -> nil
      end

    %{
      "host_memory_total_bytes" => total,
      "host_load_average_1m" => load,
      "host_memory_available_bytes" => nil,
      "host_runnable_tasks" => nil
    }
  end

  defp host(_env),
    do: %{
      "host_memory_total_bytes" => nil,
      "host_load_average_1m" => nil,
      "host_runnable_tasks" => nil
    }

  defp cpu_ticks(read) do
    with {:ok, data} <- read.("/proc/stat", 32_768),
         ["cpu" | values] <- data |> :binary.split("\n") |> List.first() |> String.split(),
         [_, _, _, idle, _, _, _, _] = times <-
           values |> Enum.take(8) |> Enum.map(&Probes.unsigned/1),
         true <- Enum.all?(times, &is_integer/1),
         total when total <= 9_007_199_254_740_991 <- Enum.sum(times) do
      %{"host_cpu_total_ticks" => total, "host_cpu_idle_ticks" => idle}
    else
      _ -> %{"host_cpu_total_ticks" => nil, "host_cpu_idle_ticks" => nil}
    end
  end

  defp proc_kib(data, name) do
    case Regex.run(~r/^#{name}:\s+(\d+) kB$/m, data) do
      [_, digits] ->
        case Probes.unsigned(digits) do
          value when is_integer(value) and value <= 8_796_093_022_207 -> value * 1_024
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fd_table(%{pid: pid}, %{platform: :linux, read: read}) do
    slots =
      with {:ok, bytes} <- read.("/proc/#{pid}/status", 4_096),
           [_, value] <- Regex.run(~r/^FDSize:\s+(\d+)$/m, bytes) do
        Probes.unsigned(value)
      else
        _ -> nil
      end

    %{"process_fd_table_slots" => slots}
  end

  defp fd_table(%{pid: _}, _env), do: %{"process_fd_table_slots" => nil}
  defp fd_table(_process, _env), do: %{}

  defp disk(nil, _env), do: %{}

  defp disk(path, %{platform: platform, command: command}) when platform in [:linux, :darwin] do
    default = %{"disk_blocks_total_kib" => nil, "disk_blocks_available_kib" => nil}
    args = if platform == :linux, do: ["-Pk", "--", path], else: ["-Pk", path]

    case command.("df", args) do
      {:ok, data} ->
        case String.split(data, "\n", trim: true) do
          [_header, line] -> disk_fields(line, default)
          _ -> default
        end

      _ ->
        default
    end
  end

  defp disk(_, _env), do: %{"disk_blocks_total_kib" => nil, "disk_blocks_available_kib" => nil}

  defp disk_fields(line, default) do
    case Regex.run(~r/\s+(\d+)\s+\d+\s+(\d+)\s+\d+%\s+/, line) do
      [_, total, available] ->
        %{
          "disk_blocks_total_kib" => Probes.unsigned(total),
          "disk_blocks_available_kib" => Probes.unsigned(available)
        }

      _ ->
        default
    end
  end

  defp checked_decimal(value) when is_binary(value) and byte_size(value) <= 32 do
    if Regex.match?(~r/\A\d+\.\d+\z/, value), do: value
  end

  defp checked_decimal(_), do: nil
end
