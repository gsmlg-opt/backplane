defmodule Backplane.HostAgent.Collectors.HostInfo do
  @moduledoc """
  Snapshots host identity: hostname, OS, IPv4 addresses and listening TCP
  ports. Yields exactly one item, or nothing when the listening scan fails.

  Listening ports come from `ss` on Linux and `lsof` on macOS, reduced to
  unique `{port, process}` pairs sorted by port then process so process or
  socket ordering never changes the fingerprint. Ephemeral ports (>= 32768 on
  Linux, >= 49152 on macOS) are dropped as churn. A failed listening scan
  yields no snapshot (unknown, not empty); `lsof` exiting 1 with no output means
  no listeners. On other platforms the item has no `"listening"` key.

  Addresses are IPv4 only (IPv6 privacy addresses rotate), from interfaces other
  than loopback and virtual ones (docker, bridges, veth, tunnels, AWDL).

  `env[:hostname]` and `env[:ifaddrs]` optionally override
  `:inet.gethostname/0` and `:inet.getifaddrs/0` (used by tests).
  """

  @behaviour Backplane.HostAgent.Collectors.Collector

  alias Backplane.HostAgent.Collectors.Collector

  @virtual_prefixes ~w(lo docker br- veth utun bridge vmnet awdl llw)

  @impl true
  def config_key, do: :host

  @impl true
  def collect(_config, %{runner: runner, os: os} = env) do
    case listening(runner, os) do
      :error ->
        []

      result ->
        {extra, complete} =
          case result do
            {:ok, entries, complete} -> {%{"listening" => entries}, complete}
            :unsupported -> {%{}, true}
          end

        item =
          Map.merge(
            %{
              "hostname" => hostname(env),
              "os" => os_name(runner),
              "addresses" => addresses(env)
            },
            extra
          )

        [%{collector: "host", unit: "local", complete: complete, items: [item]}]
    end
  end

  defp hostname(env) do
    {:ok, name} = Map.get_lazy(env, :hostname, &:inet.gethostname/0)
    name |> to_string() |> Collector.sanitize()
  end

  defp os_name(runner) do
    case runner.("uname", ["-sr"], []) do
      {:ok, out} -> out |> Collector.sanitize() |> String.trim()
      {:error, _reason} -> inspect(:os.type())
    end
  end

  defp addresses(env) do
    case Map.get_lazy(env, :ifaddrs, &:inet.getifaddrs/0) do
      {:ok, ifaces} ->
        for {name, opts} <- ifaces,
            physical?(to_string(name)),
            :loopback not in Keyword.get(opts, :flags, []),
            {:addr, {_, _, _, _} = addr} <- opts,
            routable?(addr),
            uniq: true,
            do: addr |> :inet.ntoa() |> to_string()

      _ ->
        []
    end
    |> Enum.sort()
  end

  defp physical?(name), do: not String.starts_with?(name, @virtual_prefixes)

  defp routable?({127, _, _, _}), do: false
  defp routable?({169, 254, _, _}), do: false
  defp routable?({0, _, _, _}), do: false
  defp routable?(_addr), do: true

  defp listening(runner, :linux), do: scan(runner, "ss", ["-ltnpH"], &parse_ss/1, 32_768)

  defp listening(runner, :darwin),
    do: scan(runner, "lsof", ["-w", "-nP", "-iTCP", "-sTCP:LISTEN"], &parse_lsof/1, 49_152)

  defp listening(_runner, _os), do: :unsupported

  defp scan(runner, cmd, args, parse, ephemeral) do
    case runner.(cmd, args, output_on_error: true) do
      {:ok, out} ->
        parsed = out |> Collector.sanitize() |> String.split("\n", trim: true) |> parse.()

        entries =
          for({:ok, entry} <- parsed, entry["port"] < ephemeral, do: entry)
          |> Enum.uniq()
          |> Enum.sort_by(&{&1["port"], &1["process"] || ""})

        {:ok, entries, Enum.all?(parsed, &match?({:ok, _}, &1))}

      # lsof exits 1 when nothing matches
      {:error, {:exit, 1, out}} when cmd == "lsof" ->
        if String.trim(out) == "", do: {:ok, [], true}, else: :error

      {:error, _reason} ->
        :error
    end
  end

  defp parse_ss(lines), do: Enum.map(lines, &parse_ss_line/1)

  defp parse_ss_line(line) do
    with [_state, _recvq, _sendq, local | rest] <- String.split(line),
         {:ok, port} <- port(local) do
      {:ok, %{"port" => port, "process" => ss_process(Enum.join(rest, " "))}}
    else
      _ -> :error
    end
  end

  defp ss_process(rest) do
    case Regex.run(~r/users:\(\("([^"]*)"/, rest) do
      [_, name] -> name
      nil -> nil
    end
  end

  defp parse_lsof(lines) do
    lines
    |> Enum.reject(&String.starts_with?(&1, "COMMAND"))
    |> Enum.map(&parse_lsof_line/1)
  end

  defp parse_lsof_line(line) do
    with [command | _] = tokens <- String.split(line),
         [name, "(LISTEN)"] <- Enum.take(tokens, -2),
         {:ok, port} <- port(name) do
      {:ok, %{"port" => port, "process" => command}}
    else
      _ -> :error
    end
  end

  defp port(address) do
    with [_, digits] <- Regex.run(~r/:(\d+)$/, address),
         {port, ""} <- Integer.parse(digits) do
      {:ok, port}
    else
      _ -> :error
    end
  end
end
