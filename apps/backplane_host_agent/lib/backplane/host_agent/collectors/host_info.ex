defmodule Backplane.HostAgent.Collectors.HostInfo do
  @moduledoc """
  Snapshots host identity: hostname, OS, non-local IP addresses and listening
  TCP ports. Always yields exactly one item.

  Listening ports come from `ss` on Linux and `lsof` on macOS, reduced to
  unique `{port, process}` pairs sorted by port then process so process or
  socket ordering never changes the fingerprint. A failed or unavailable
  listening scan reports `[]` with `complete: false` (unknown, not empty).

  `env[:hostname]` and `env[:ifaddrs]` optionally override
  `:inet.gethostname/0` and `:inet.getifaddrs/0` (used by tests).
  """

  @behaviour Backplane.HostAgent.Collectors.Collector

  import Bitwise

  @impl true
  def config_key, do: :host

  @impl true
  def collect(_config, %{runner: runner, os: os} = env) do
    {listening, complete} = listening(runner, os)

    [
      %{
        collector: "host",
        unit: "local",
        complete: complete,
        items: [
          %{
            "hostname" => hostname(env),
            "os" => os_name(runner),
            "addresses" => addresses(env),
            "listening" => listening
          }
        ]
      }
    ]
  end

  defp hostname(env) do
    {:ok, name} = Map.get_lazy(env, :hostname, &:inet.gethostname/0)
    to_string(name)
  end

  defp os_name(runner) do
    case runner.("uname", ["-sr"], []) do
      {:ok, out} -> String.trim(out)
      {:error, _reason} -> inspect(:os.type())
    end
  end

  defp addresses(env) do
    case Map.get_lazy(env, :ifaddrs, &:inet.getifaddrs/0) do
      {:ok, ifaces} ->
        for {_name, opts} <- ifaces,
            :loopback not in Keyword.get(opts, :flags, []),
            {:addr, addr} <- opts,
            routable?(addr),
            uniq: true,
            do: addr |> :inet.ntoa() |> to_string()

      _ ->
        []
    end
    |> Enum.sort()
  end

  defp routable?({127, _, _, _}), do: false
  defp routable?({169, 254, _, _}), do: false
  defp routable?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp routable?({a, _, _, _}) when a in 0..255, do: true
  defp routable?({w, _, _, _, _, _, _, _}), do: (w &&& 0xFFC0) != 0xFE80
  defp routable?(_), do: false

  defp listening(runner, :linux), do: scan(runner, "ss", ["-ltnpH"], &parse_ss/1)

  defp listening(runner, :darwin),
    do: scan(runner, "lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"], &parse_lsof/1)

  defp listening(_runner, _os), do: {[], false}

  defp scan(runner, cmd, args, parse) do
    case runner.(cmd, args, []) do
      {:ok, out} ->
        parsed = out |> String.split("\n", trim: true) |> parse.()

        entries =
          for({:ok, entry} <- parsed, do: entry)
          |> Enum.uniq()
          |> Enum.sort_by(&{&1["port"], &1["process"] || ""})

        {entries, Enum.all?(parsed, &match?({:ok, _}, &1))}

      {:error, _reason} ->
        {[], false}
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
