defmodule Backplane.HostAgent.Collectors.Services do
  @moduledoc """
  Snapshots system services: running systemd units on Linux, loaded launchd
  jobs on macOS. Other platforms yield nothing.

  launchd PIDs and exit statuses are volatile and never reported;
  `com.apple.*` jobs are dropped as OS noise.
  """

  @behaviour Backplane.HostAgent.Collectors.Collector

  @systemctl_args ~w(list-units --type=service --state=running --no-legend --plain --no-pager)

  @impl true
  def config_key, do: :services

  @impl true
  def collect(_config, %{runner: runner, os: :linux}) do
    snapshot(runner, "systemctl", @systemctl_args, "systemd", &parse_systemd/1)
  end

  def collect(_config, %{runner: runner, os: :darwin}) do
    snapshot(runner, "launchctl", ["list"], "launchd", &parse_launchd/1)
  end

  def collect(_config, _env), do: []

  defp snapshot(runner, cmd, args, collector, parse) do
    case runner.(cmd, args, []) do
      {:ok, out} ->
        parsed = out |> String.split("\n", trim: true) |> parse.()

        [
          %{
            collector: collector,
            unit: "local",
            complete: Enum.all?(parsed, &match?({:ok, _}, &1)),
            items: for({:ok, item} <- parsed, do: item)
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp parse_systemd(lines), do: Enum.map(lines, &parse_systemd_line/1)

  defp parse_systemd_line(line) do
    case String.split(line, ~r/\s+/, parts: 5, trim: true) do
      [name, _load, _active, _sub, description] ->
        {:ok, %{"name" => name, "description" => String.trim(description)}}

      [name, _load, _active, _sub] ->
        {:ok, %{"name" => name, "description" => ""}}

      _ ->
        :error
    end
  end

  defp parse_launchd(lines) do
    lines
    |> Enum.reject(&String.starts_with?(&1, "PID"))
    |> Enum.map(&parse_launchd_line/1)
    |> Enum.reject(&match?({:ok, %{"label" => "com.apple." <> _}}, &1))
  end

  defp parse_launchd_line(line) do
    case String.split(line, ~r/\s+/, parts: 3, trim: true) do
      [_pid, _status, label] -> {:ok, %{"label" => String.trim(label)}}
      _ -> :error
    end
  end
end
