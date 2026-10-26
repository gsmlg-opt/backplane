defmodule Backplane.AgentRuntime.Tools.LocalCommand.Pty do
  @moduledoc false
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Tools.LocalCommand.Procfs

  @frame_max 65_536

  def options(opts) do
    case Keyword.get(opts, :pty, false) do
      false -> {:ok, nil}
      true -> enabled_options(opts)
      _ -> {:error, Error.new(:validation, "pty must be a boolean")}
    end
  end

  def capabilities(nil), do: %{}

  def capabilities(config),
    do: %{
      pty: %{
        verified: true,
        platforms: [{:unix, :linux}],
        rows: config.rows,
        columns: config.columns
      }
    }

  defp enabled_options(opts) do
    path =
      Keyword.get(
        opts,
        :pty_helper_path,
        Application.app_dir(:backplane_agent_runtime, "priv/bin/backplane-local-command-pty")
      )

    rows = Keyword.get(opts, :terminal_rows, 24)
    columns = Keyword.get(opts, :terminal_columns, 80)

    cond do
      not (is_integer(rows) and rows in 1..1000 and is_integer(columns) and columns in 1..1000) ->
        {:error, Error.new(:validation, "PTY dimensions must be integers in 1..1000")}

      not (is_binary(path) and Path.type(path) == :absolute and File.regular?(path)) ->
        unavailable("PTY helper is unavailable; run mix backplane.pty.build")

      true ->
        case probe(path) do
          :ok -> {:ok, %{path: path, rows: rows, columns: columns}}
          _ -> unavailable("PTY helper capability probe failed")
        end
    end
  end

  defp unavailable(message), do: {:error, Error.new(:unsupported_capability, message)}

  defp probe(path) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, ["--probe"]}
      ])

    probe_result(port, "", System.monotonic_time(:millisecond) + 1000)
  rescue
    _ -> :error
  end

  defp probe_result(port, bytes, deadline) do
    receive do
      {^port, {:data, data}} when byte_size(bytes) + byte_size(data) <= 64 ->
        probe_result(port, bytes <> data, deadline)

      {^port, {:exit_status, 0}} ->
        if(bytes == "BACKPLANE_PTY 1\n", do: :ok, else: :error)

      {^port, {:exit_status, _}} ->
        :error
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        close(port)
        :error
    end
  end

  def open(config, request, token, environment, timeout) do
    terminal = Map.get(request, :terminal) || %{rows: config.rows, columns: config.columns}
    owner = Base.url_encode64(request.owner_run_id, padding: false)

    args =
      [
        "--run",
        token,
        owner,
        to_string(Map.get(request, :incarnation, 1)),
        to_string(Map.get(request, :session_id) || 0),
        to_string(terminal.rows),
        to_string(terminal.columns),
        to_string(max(1, timeout - 100)),
        to_string(request.output_limit),
        request.executable
      ] ++ request.arguments

    {:ok,
     Port.open({:spawn_executable, config.path}, [
       :binary,
       :use_stdio,
       :exit_status,
       :hide,
       {:packet, 4},
       {:args, args},
       {:env, environment},
       {:cd, request.workspace}
     ])}
  rescue
    error in ErlangError ->
      {:error,
       Error.new(:execution_failure, "PTY helper could not be started",
         details: %{reason: error.original}
       )}

    ArgumentError ->
      {:error, Error.new(:validation, "PTY helper launch arguments are invalid")}
  end

  def ready(<<"R", evidence::binary>>, token, broker, request) do
    with ["1", ^token, b, bs, g, gs, c, cs, sid, rows, columns, owner, incarnation, session] <-
           String.split(evidence, " "),
         {^broker, ""} <- Integer.parse(b),
         {guardian, ""} <- Integer.parse(g),
         {child, ""} <- Integer.parse(c),
         {^child, ""} <- Integer.parse(sid),
         {:ok, %{start: b_start}} <- Procfs.exact_identity(broker),
         {:ok, %{parent: ^broker, start: g_start}} <- Procfs.exact_identity(guardian),
         {:ok, %{parent: ^guardian, group: ^child, session: ^child, start: c_start}} <-
           Procfs.exact_identity(child),
         true <- [bs, gs, cs] == Enum.map([b_start, g_start, c_start], &to_string/1),
         true <- owner == Base.url_encode64(request.owner_run_id, padding: false),
         true <- incarnation == to_string(Map.get(request, :incarnation, 1)),
         true <- session == to_string(Map.get(request, :session_id) || 0),
         true <-
           rows == to_string(request.terminal.rows) and
             columns == to_string(request.terminal.columns) do
      {:ok,
       %{
         evidence: evidence,
         token: token,
         broker: broker,
         guardian: guardian,
         child: child,
         session: child
       }}
    else
      _ -> {:error, Error.new(:unknown_outcome, "PTY launch identity could not be verified")}
    end
  end

  def ready(_, _, _, _),
    do: {:error, Error.new(:unknown_outcome, "PTY readiness frame is malformed")}

  def proof(<<"F", payload::binary>>, identity) do
    case String.split(payload, "|") do
      [evidence, exit, status, master, dispatch, guardian, reason]
      when evidence == identity.evidence ->
        with {exit_status, ""} <- Integer.parse(exit),
             true <- dispatch in ["dispatched", "never_started", "unknown"] do
          {:ok,
           %{
             evidence: evidence,
             exit_status: exit_status,
             confirmed?:
               status == "confirmed" and master == "closed" and guardian == "reaped" and
                 reason == "none",
             dispatch: dispatch,
             reason: reason
           }}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def write(port, bytes), do: write_chunks(port, bytes)
  defp write_chunks(_port, ""), do: true

  defp write_chunks(port, bytes) do
    size = min(byte_size(bytes), @frame_max - 1)
    <<chunk::binary-size(^size), rest::binary>> = bytes
    Port.command(port, <<"I", chunk::binary>>, [:nosuspend]) and write_chunks(port, rest)
  end

  def acknowledge(port, token), do: Port.command(port, "A" <> token, [:nosuspend])

  def cancel(port) do
    Port.command(port, "C", [:nosuspend])
  rescue
    ArgumentError -> false
  end

  def close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Text-only API: incomplete suffixes remain invisible until the next frame.
  def project(bytes, final?), do: project(bytes, final?, [])
  defp project("", _final?, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp project(<<codepoint::utf8, rest::binary>>, final?, acc),
    do: project(rest, final?, [<<codepoint::utf8>> | acc])

  defp project(bytes, false, acc) when byte_size(bytes) < 4 do
    if incomplete?(bytes),
      do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), bytes},
      else: replace_byte(bytes, false, acc)
  end

  defp project(bytes, true, acc) when byte_size(bytes) < 4 do
    if incomplete?(bytes),
      do: {IO.iodata_to_binary(Enum.reverse(["�" | acc])), ""},
      else: replace_byte(bytes, true, acc)
  end

  defp project(bytes, final?, acc), do: replace_byte(bytes, final?, acc)
  defp replace_byte(<<_bad, rest::binary>>, final?, acc), do: project(rest, final?, ["�" | acc])

  defp incomplete?(bytes) do
    case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
      {:incomplete, "", ^bytes} -> true
      _ -> false
    end
  end
end
