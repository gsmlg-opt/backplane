defmodule Backplane.HostAgent.Diagnostics.Collectors.Service do
  @moduledoc "Reports lifecycle state from an explicitly configured service identity."

  alias Backplane.HostAgent.Diagnostics.Collectors.Probes

  @systemd_properties ~w(LoadState ActiveState MainPID NRestarts ExecMainStatus ExecMainCode Result InvocationID)
  @container_format "{{.Id}} {{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}} {{.RestartCount}} {{.State.StartedAt}}"

  def parse(%{"manager" => manager, "name" => name}) when manager in ~w(systemd launchd docker) do
    if valid_name?(manager, name), do: %{manager: manager, name: name}
  end

  def parse(_), do: nil

  def capabilities(:linux), do: ~w(systemd docker)
  def capabilities(:darwin), do: ~w(launchd docker)
  def capabilities(_), do: []

  def sample(%{manager: "systemd", name: name}, %{platform: :linux, command: command}) do
    args = [
      "show",
      "--no-pager",
      "--property=" <> Enum.join(@systemd_properties, ","),
      "--",
      name
    ]

    case command.("systemctl", args) do
      {:ok, bytes} -> parse_systemd(bytes)
      _ -> unavailable("systemd", "probe_unavailable")
    end
  end

  def sample(%{manager: "launchd", name: name}, %{platform: :darwin, command: command}) do
    case command.("launchctl", ["list", name]) do
      {:ok, bytes} -> parse_launchd(bytes, name)
      _ -> unavailable("launchd", "probe_unavailable")
    end
  end

  def sample(%{manager: "docker", name: name}, %{
        platform: platform,
        docker_socket: path,
        command: command
      })
      when platform in [:linux, :darwin] and is_binary(path) do
    args = [
      "--host",
      "unix://" <> path,
      "inspect",
      "--type",
      "container",
      "--format",
      @container_format,
      "--",
      name
    ]

    case command.("docker", args) do
      {:ok, bytes} -> parse_docker(bytes)
      _ -> unavailable("docker", "probe_unavailable")
    end
  end

  def sample(%{manager: "docker"}, %{platform: platform}) when platform in [:linux, :darwin],
    do: unavailable("docker", "socket_unconfigured")

  def sample(%{manager: manager}, _env), do: unavailable(manager, "unsupported_platform")

  defp valid_name?(manager, name) when is_binary(name) and byte_size(name) in 1..192 do
    case manager do
      "systemd" -> Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.@-]*\.service\z/, name)
      _ -> Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/, name)
    end
  end

  defp valid_name?(_, _), do: false

  defp parse_systemd(bytes) do
    fields =
      for line <- String.split(bytes, "\n"),
          [key, value] <- [String.split(line, "=", parts: 2)],
          key in @systemd_properties,
          into: %{},
          do: {key, value}

    with "loaded" <- fields["LoadState"],
         status
         when status in ~w(active inactive failed activating deactivating reloading maintenance) <-
           fields["ActiveState"] do
      %{
        manager: "systemd",
        status: status,
        pid: positive(fields["MainPID"]),
        restarts: Probes.unsigned(fields["NRestarts"]),
        exit_status: systemd_exit_status(fields),
        invocation: checked_token(fields["InvocationID"], 32),
        exit_reason: if(fields["Result"] == "oom-kill", do: "oom_kill")
      }
    else
      _ -> unavailable("systemd", "service_unavailable")
    end
  end

  defp systemd_exit_status(%{"ExecMainCode" => code, "ExecMainStatus" => status})
       when code in ["1", "2", "3"],
       do: Probes.unsigned(status)

  defp systemd_exit_status(_), do: nil

  defp parse_launchd(bytes, name) do
    reported = launchd_field(bytes, ~r/^\s*"Label"\s*=\s*"([a-zA-Z0-9_.-]+)";?\s*$/m)

    if reported == name do
      pid = launchd_field(bytes, ~r/^\s*"PID"\s*=\s*(\d+);?\s*$/m) |> positive()
      last_exit = launchd_field(bytes, ~r/^\s*"LastExitStatus"\s*=\s*(-?\d+);?\s*$/m)

      %{
        manager: "launchd",
        status: if(pid, do: "active", else: "inactive"),
        pid: pid,
        restarts: nil,
        invocation: nil,
        exit_status: parse_launchd_status(last_exit),
        exit_reason: nil
      }
    else
      unavailable("launchd", "service_unavailable")
    end
  end

  defp launchd_field(bytes, pattern) do
    case Regex.run(pattern, bytes) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp parse_launchd_status("-" <> signal) do
    case Probes.unsigned(signal) do
      value when is_integer(value) -> -value
      _ -> nil
    end
  end

  defp parse_launchd_status(value), do: Probes.unsigned(value)

  defp parse_docker(bytes) do
    case String.split(bytes) do
      [id, status, exit_code, killed, restarts, started]
      when status in ~w(created running paused restarting removing exited dead) and
             killed in ~w(true false) ->
        with value when is_binary(value) <- checked_token(id, 64),
             {:ok, datetime, _} <- DateTime.from_iso8601(started) do
          %{
            manager: "docker",
            status: docker_status(status),
            pid: nil,
            restarts: Probes.unsigned(restarts),
            exit_status: if(status in ~w(exited dead), do: Probes.unsigned(exit_code)),
            invocation: Probes.fingerprint({value, datetime}),
            exit_reason: if(killed == "true", do: "oom_kill")
          }
        else
          _ -> unavailable("docker", "invalid_evidence")
        end

      _ ->
        unavailable("docker", "invalid_evidence")
    end
  end

  defp docker_status("running"), do: "active"
  defp docker_status(status), do: status

  defp positive(text) do
    case Probes.unsigned(text) do
      value when value in 1..2_147_483_647 -> value
      _ -> nil
    end
  end

  defp checked_token(value, size)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= size do
    if Regex.match?(~r/\A[0-9a-f]+\z/i, value), do: value
  end

  defp checked_token(_, _), do: nil

  defp unavailable(manager, reason),
    do: %{manager: manager, status: "unavailable", reason: reason}
end
