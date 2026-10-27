defmodule Backplane.McpProtocol.Transport.STDIO.Guardian do
  @moduledoc false
  @probe "backplane-mcp-stdio-guardian 1\n"
  @max_data 65_536

  def path,
    do: :backplane_mcp_protocol |> :code.priv_dir() |> to_string() |> Path.join("bin/backplane-mcp-stdio-guardian")

  def available(path) do
    with true <- :os.type() in [{:unix, :linux}, {:unix, :darwin}],
         true <- File.regular?(path),
         :ok <- probe(path) do
      :ok
    else
      _ -> {:error, {:verified_stdio_unavailable, %{reason: :guardian_missing_or_unsupported}}}
    end
  end

  defp probe(path) do
    port = Port.open({:spawn_executable, String.to_charlist(path)}, [:binary, :exit_status, args: ["--probe"]])
    probe_result(port, "", System.monotonic_time(:millisecond) + 1_000)
  rescue
    _ -> {:error, :probe_failed}
  end

  defp probe_result(port, data, deadline) do
    receive do
      {^port, {:data, chunk}} when byte_size(data) + byte_size(chunk) <= 128 ->
        probe_result(port, data <> chunk, deadline)

      {^port, {:exit_status, 0}} when data == @probe ->
        :ok

      {^port, {:exit_status, _}} ->
        {:error, :probe_failed}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        if Port.info(port), do: Port.close(port)
        {:error, :probe_timeout}
    end
  end

  def token, do: :crypto.strong_rand_bytes(16)
  def ack(token), do: <<2, token::binary-size(16)>>
  def data(data) when byte_size(data) <= @max_data, do: <<4, data::binary>>
  def close(token, nonce, timeout), do: <<6, token::binary-size(16), nonce::binary-size(16), timeout::unsigned-big-32>>

  def chunks(<<chunk::binary-size(@max_data), rest::binary>>), do: [data(chunk) | chunks(rest)]
  def chunks(<<>>), do: []
  def chunks(data), do: [data(data)]

  def decode(<<1, 1::16, token::binary-size(16)>>), do: {:hello, token}
  def decode(<<3, token::binary-size(16), pid::32>>), do: {:started, token, pid}
  def decode(<<5, data::binary>>) when byte_size(data) <= @max_data, do: {:data, data}
  def decode(<<9, pid::32, kind, status::32>>) when kind in [0, 1], do: {:target_exit, pid, status(kind, status)}
  def decode(<<8, code::32>>), do: {:error, code}

  def decode(<<7, token::binary-size(16), nonce::binary-size(16), pid::32, kind, status::32, reaped, pipes, term, kill>>)
      when kind in [0, 1] and reaped in [0, 1] and pipes in [0, 1] and term in [0, 1] and kill in [0, 1] do
    {:receipt, token, nonce,
     %{
       target_pid: pid,
       target_status: status(kind, status),
       reaped: reaped == 1,
       pipes_closed: pipes == 1,
       term_sent: term == 1,
       kill_sent: kill == 1
     }}
  end

  def decode(_), do: {:error, :invalid_guardian_packet}

  defp status(0, status), do: %{kind: :exit, code: status}
  defp status(1, status), do: %{kind: :signal, signal: status}

  def report(%{close_report: report}) when not is_nil(report), do: report

  def report(state) do
    receipt = state.guard_receipt
    child = if receipt && receipt.reaped, do: :confirmed, else: :uncertain
    pipes = if receipt && receipt.pipes_closed, do: :confirmed, else: :uncertain
    guardian = if state.guard_exit == 0, do: :confirmed, else: :uncertain

    resources = [
      resource(
        state,
        :direct_child,
        child,
        receipt && Map.take(receipt, [:target_pid, :target_status, :reaped]),
        if(child == :confirmed, do: nil, else: :missing_waitpid_receipt)
      ),
      resource(
        state,
        :local_pipes,
        pipes,
        %{closed: receipt && receipt.pipes_closed},
        if(pipes == :confirmed, do: nil, else: :missing_pipe_receipt)
      ),
      resource(
        state,
        :guardian,
        guardian,
        %{os_pid: state.guard_pid, exit_status: state.guard_exit, protocol_error: state.guard_error},
        if(guardian == :confirmed, do: nil, else: :missing_successful_helper_exit)
      )
    ]

    %{
      version: 1,
      close_id: state.close_id,
      activation_id: state.activation_id,
      transport: :stdio,
      phase: state.close_phase,
      outcome:
        if(state.close_phase == :closed,
          do: if(Enum.all?(resources, &(&1.outcome == :confirmed)), do: :confirmed, else: :unconfirmed),
          else: :pending
        ),
      resources: resources,
      remote: %{outcome: :unknown, session_delete: nil}
    }
  end

  defp resource(state, scope, outcome, evidence, error) do
    %{
      id: {state.activation_id, scope},
      scope: scope,
      outcome: outcome,
      evidence: evidence || %{target_pid: state.target_pid, target_status: state.target_status},
      error: if(error, do: %{reason: error})
    }
  end
end
