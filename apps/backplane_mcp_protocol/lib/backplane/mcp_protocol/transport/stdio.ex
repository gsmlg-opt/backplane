defmodule Backplane.McpProtocol.Transport.STDIO do
  @moduledoc """
  A transport implementation that uses standard input/output.

  > ## Notes {: .info}
  >
  > For initialization and setup, check our [Installation & Setup](./installation.html) and
  > the [Transport options](./transport_options.html) guides for reference.
  """

  @behaviour Backplane.McpProtocol.Transport
  @behaviour Backplane.McpProtocol.Transport.Behaviour

  use GenServer
  use Backplane.McpProtocol.Logging

  import Peri

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Telemetry
  alias Backplane.McpProtocol.Transport.Behaviour, as: Transport
  alias Backplane.McpProtocol.Transport.RequestContext
  alias Backplane.McpProtocol.Transport.STDIO.Guardian

  @type t :: GenServer.server()

  # Functional transport state
  @type stdio_state :: %{buffer: binary()}

  @impl Backplane.McpProtocol.Transport
  @spec transport_init(keyword()) :: {:ok, stdio_state()} | {:error, term()}
  def transport_init(_opts \\ []) do
    {:ok, %{buffer: ""}}
  end

  @impl Backplane.McpProtocol.Transport
  @spec parse(binary() | map(), stdio_state()) ::
          {:ok, [map()], stdio_state()} | {:error, term()}
  def parse(raw, state) when is_binary(raw) do
    data = state.buffer <> raw
    {lines, rest} = split_complete_lines(data)

    case decode_lines(lines) do
      {:ok, messages} ->
        {:ok, messages, %{state | buffer: rest}}

      {:error, _} = error ->
        error
    end
  end

  @impl Backplane.McpProtocol.Transport
  @spec encode(map(), stdio_state()) :: {:ok, binary(), stdio_state()} | {:error, term()}
  def encode(message, state) when is_map(message) do
    {:ok, JSON.encode!(message) <> "\n", state}
  rescue
    e ->
      {:error, {:encode_error, Exception.message(e)}}
  end

  @impl Backplane.McpProtocol.Transport
  @spec extract_metadata(term(), stdio_state()) :: map()
  def extract_metadata(_raw_input, _state) do
    %{transport: :stdio}
  end

  defp split_complete_lines(data) do
    case String.split(data, "\n", trim: false) do
      [] ->
        {[], ""}

      parts ->
        {complete, [rest]} = Enum.split(parts, -1)
        {Enum.reject(complete, &(&1 == "")), rest}
    end
  end

  defp decode_lines(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case JSON.decode(line) do
        {:ok, %{} = message} -> {:cont, {:ok, [message | acc]}}
        {:ok, _} -> {:halt, {:error, :invalid_message}}
        {:error, _} -> {:halt, {:error, :invalid_json}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  @type params_t :: Enumerable.t(option)

  @typedoc """
  The options for the STDIO transport.

  - `:command` - The command to run, it will be searched in the system's PATH.
  - `:args` - The arguments to pass to the command, as a list of strings.
  - `:env` - The extra environment variables to set for the command, as a map.
  - `:cwd` - The working directory for the command.
  - `:client` - The client to send the messages to, respecting the `GenServer` "Name Registration" section

  And any other `GenServer` init option.
  """
  @type option ::
          {:command, Path.t()}
          | {:args, list(String.t()) | nil}
          | {:env, map() | nil}
          | {:cwd, Path.t() | nil}
          | {:client, GenServer.server()}
          | GenServer.option()

  defschema(:options_schema, %{
    cleanup: {:any, {:default, :best_effort}},
    guardian_path: {:string, {:default, nil}},
    activation_id: {:any, {:default, nil}},
    one_shot: {:boolean, {:default, false}},
    name: {{:custom, &Backplane.McpProtocol.genserver_name/1}, {:default, __MODULE__}},
    client: {:required, Backplane.McpProtocol.get_schema(:process_name)},
    command: {:required, :string},
    args: {{:list, :string}, {:default, nil}},
    env: {:map, {:default, nil}},
    cwd: {:string, {:default, nil}}
  })

  @win32_default_env [
    "APPDATA",
    "HOMEDRIVE",
    "HOMEPATH",
    "LOCALAPPDATA",
    "PATH",
    "PROCESSOR_ARCHITECTURE",
    "SYSTEMDRIVE",
    "SYSTEMROOT",
    "TEMP",
    "USERNAME",
    "USERPROFILE"
  ]
  @unix_default_env ["HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER"]

  @impl Transport
  @spec start_link(params_t) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = options_schema!(opts)

    with :ok <- validate_cleanup(opts) do
      GenServer.start_link(__MODULE__, Map.new(opts), name: opts[:name])
    end
  end

  @impl Transport
  def send_message(pid \\ __MODULE__, message, opts) when is_binary(message) do
    # Request contexts carry HTTP-only routing fields. STDIO deliberately sends
    # only the encoded JSON-RPC body, which already contains protocol metadata.
    _request_context = Keyword.get(opts, :request_context)
    GenServer.call(pid, {:send, message}, Keyword.get(opts, :timeout, 5000))
  end

  @impl Transport
  def open_stream(pid \\ __MODULE__, message, opts) when is_binary(message) and is_list(opts) do
    context = Keyword.get(opts, :request_context)
    subscription_id = Keyword.get(opts, :subscription_id)

    with %RequestContext{era: :modern, method: "subscriptions/listen"} <- context,
         true <- is_binary(subscription_id) or is_integer(subscription_id),
         :ok <- send_message(pid, message, opts) do
      {:ok, %{transport: :stdio, subscription_id: subscription_id}}
    else
      false -> {:error, :invalid_subscription_id}
      %RequestContext{} -> {:error, :unsupported_stream}
      nil -> {:error, :missing_request_context}
      {:error, _reason} = error -> error
      _invalid -> {:error, :unsupported_stream}
    end
  end

  @impl Transport
  def close_stream(pid \\ __MODULE__, stream, opts)

  def close_stream(pid, %{transport: :stdio, subscription_id: subscription_id}, opts) when is_list(opts) do
    reason = Keyword.get(opts, :reason, "subscription closed")

    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => subscription_id, "reason" => reason}
    }

    send_message(pid, JSON.encode!(notification) <> "\n", opts)
  rescue
    _exception -> {:error, :encode_error}
  end

  def close_stream(_pid, _stream, _opts), do: {:error, :invalid_stream}

  @impl Transport
  def shutdown(pid \\ __MODULE__) do
    GenServer.cast(pid, :close_port)
  end

  @impl Transport
  def close(pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    if is_integer(timeout) and timeout in 1..4_294_967_295 do
      GenServer.call(pid, {:close, opts}, timeout + 100)
    else
      {:error, Error.protocol(:invalid_params, %{reason: :invalid_cleanup_timeout})}
    end
  catch
    :exit, _ -> {:error, Error.transport(:cleanup_report_unavailable)}
  end

  @impl Transport
  def cleanup_status(pid) do
    GenServer.call(pid, :cleanup_status)
  catch
    :exit, _ -> {:error, Error.transport(:cleanup_report_unavailable)}
  end

  defp validate_cleanup(opts) do
    case opts[:cleanup] do
      :best_effort -> :ok
      :verified -> Guardian.available(opts[:guardian_path] || Guardian.path())
      _ -> {:error, Error.protocol(:invalid_params, %{reason: :invalid_stdio_cleanup_mode})}
    end
  end

  @impl Transport
  def supported_protocol_versions, do: :all

  # credo:disable-for-next-line Credo.Check.Design.TagTODO
  # TODO(upstream): gsmlg-opt/backplane#78
  @impl GenServer
  def format_status(status) do
    Map.update!(status, :state, fn state ->
      Enum.reduce([:env, :guard_token, :close_nonce], state, &Map.replace(&2, &1, :redacted))
    end)
  end

  @impl GenServer
  def init(%{} = opts) do
    if opts.cleanup == :verified, do: Process.flag(:trap_exit, true)

    state =
      Map.merge(opts, %{
        port: nil,
        ref: nil,
        guard_token: Guardian.token(),
        guard_pid: nil,
        target_pid: nil,
        target_status: nil,
        guard_receipt: nil,
        guard_exit: nil,
        startup_timer: nil,
        close_timer: nil,
        close_deadline: nil,
        close_nonce: nil,
        close_id: nil,
        close_phase: :active,
        close_waiters: [],
        sealed: false,
        close_report: nil,
        guardian_started: false,
        guardian_acked: false,
        close_sent: false,
        guard_error: nil
      })

    state = %{state | activation_id: state.activation_id || make_ref()}

    metadata = %{
      transport: :stdio,
      command: opts.command,
      args: opts.args,
      client: opts.client
    }

    Telemetry.execute(
      Telemetry.event_transport_init(),
      %{system_time: System.system_time()},
      metadata
    )

    {:ok, state, {:continue, :spawn}}
  end

  @impl GenServer
  def handle_continue(:spawn, %{cleanup: :verified} = state) do
    case System.find_executable(state.command) do
      nil ->
        {:stop, {:error, "Command not found: #{state.command}"}, state}

      cmd ->
        helper = state.guardian_path || Guardian.path()
        token = Base.encode16(state.guard_token, case: :lower)
        opts = [:binary, :exit_status, {:packet, 4}, args: ["--token", token, "--", cmd | state.args || []]]

        opts =
          if state.env, do: opts ++ [env: normalize_env_for_erlang(Map.merge(get_default_env(), state.env))], else: opts

        opts = if state.cwd, do: opts ++ [cd: state.cwd], else: opts
        port = Port.open({:spawn_executable, String.to_charlist(helper)}, opts)
        {:os_pid, pid} = Port.info(port, :os_pid)
        timer = Process.send_after(self(), :guardian_startup_timeout, 5_000)
        {:noreply, %{state | port: port, ref: Port.monitor(port), guard_pid: pid, startup_timer: timer}}
    end
  end

  def handle_continue(:spawn, state) do
    if cmd = System.find_executable(state.command) do
      port = spawn_port(cmd, state)
      ref = Port.monitor(port)

      GenServer.cast(state.client, :negotiate)
      {:noreply, %{state | port: port, ref: ref}}
    else
      {:stop, {:error, "Command not found: #{state.command}"}, state}
    end
  end

  @impl GenServer
  def handle_call(:cleanup_status, _from, state), do: {:reply, {:ok, Guardian.report(state)}, state}

  def handle_call({:close, _opts}, _from, %{close_phase: :closed} = state),
    do: {:reply, {:ok, Guardian.report(state)}, state}

  def handle_call({:close, _opts}, from, %{close_phase: :closing} = state),
    do: {:noreply, %{state | close_waiters: [from | state.close_waiters]}}

  def handle_call({:close, opts}, from, %{cleanup: :verified} = state),
    do: {:noreply, begin_guard_close(state, opts, from)}

  def handle_call({:close, opts}, _from, state) do
    if is_port(state.port) and Port.info(state.port), do: Port.close(state.port)
    state = %{state | sealed: true, close_phase: :closed, close_id: Keyword.get(opts, :close_id) || make_ref()}
    {:reply, {:ok, Guardian.report(state)}, state}
  end

  def handle_call({:send, _}, _from, %{sealed: true} = state), do: {:reply, {:error, :closing}, state}

  def handle_call({:send, _}, _from, %{cleanup: :verified, guardian_started: false} = state),
    do: {:reply, {:error, :port_not_connected}, state}

  def handle_call({:send, message}, _from, %{cleanup: :verified} = state) do
    result =
      Enum.reduce_while(Guardian.chunks(message), :ok, fn packet, _ ->
        if Port.command(state.port, packet, [:nosuspend]), do: {:cont, :ok}, else: {:halt, {:error, :port_backpressure}}
      end)

    {:reply, result, state}
  rescue
    _ -> {:reply, {:error, :port_not_connected}, state}
  end

  def handle_call({:send, message}, _, %{port: port} = state) when is_port(port) do
    metadata = %{
      transport: :stdio,
      message_size: byte_size(message),
      command: state.command
    }

    Telemetry.execute(
      Telemetry.event_transport_send(),
      %{system_time: System.system_time()},
      metadata
    )

    Port.command(port, message)
    {:reply, :ok, state}
  end

  def handle_call({:send, message}, _, state) do
    Telemetry.execute(
      Telemetry.event_transport_error(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        error: :port_not_connected,
        message_size: byte_size(message)
      }
    )

    {:reply, {:error, :port_not_connected}, state}
  end

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{cleanup: :verified, port: port} = state) do
    {:noreply, handle_guard_packet(Guardian.decode(packet), state)}
  end

  def handle_info({port, {:exit_status, status}}, %{cleanup: :verified, port: port} = state) do
    state = %{state | guard_exit: status, sealed: true}
    state = if state.close_phase == :active, do: begin_guard_close(state, [], nil), else: state
    {:noreply, finish_guard_close(state)}
  end

  def handle_info(:guardian_startup_timeout, %{cleanup: :verified, guardian_started: false} = state) do
    {:noreply, begin_guard_close(%{state | guard_error: :startup_timeout}, [], nil)}
  end

  def handle_info(:guardian_startup_timeout, state), do: {:noreply, state}

  def handle_info(:guardian_close_deadline, %{cleanup: :verified, close_phase: :closing} = state) do
    # Port teardown releases our handle but cannot replace the lost exit receipt.
    if is_port(state.port) and Port.info(state.port), do: Port.close(state.port)
    {:noreply, finish_guard_close(state)}
  end

  def handle_info(:guardian_close_retry, %{cleanup: :verified, close_phase: :closing} = state),
    do: {:noreply, send_guard_close(state)}

  def handle_info({:DOWN, ref, :port, port, _reason}, %{cleanup: :verified, port: port, ref: ref} = state) do
    state = %{state | sealed: true}
    {:noreply, if(state.close_phase == :active, do: begin_guard_close(state, [], nil), else: state)}
  end

  def handle_info({port, :closed}, %{cleanup: :verified, port: port} = state), do: {:noreply, state}
  def handle_info({:EXIT, port, _reason}, %{cleanup: :verified, port: port} = state), do: {:noreply, state}
  def handle_info(:guardian_close_retry, state), do: {:noreply, state}

  def handle_info({port, _event}, %{port: port, close_phase: :closed} = state), do: {:noreply, state}
  def handle_info({:DOWN, ref, :port, _port, _}, %{ref: ref, close_phase: :closed} = state), do: {:noreply, state}
  def handle_info({:EXIT, port, _}, %{port: port, close_phase: :closed} = state), do: {:noreply, state}

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logging.transport_event("stdio_received", String.slice(data, 0, 100))

    Telemetry.execute(
      Telemetry.event_transport_receive(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        message_size: byte_size(data)
      }
    )

    GenServer.cast(state.client, {:response, data})
    {:noreply, state}
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    Logging.transport_event(
      "stdio_closed",
      "Connection closed, transport will restart",
      level: :warning
    )

    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        reason: :normal
      }
    )

    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logging.transport_event("stdio_exit", %{status: status}, level: :warning)

    Telemetry.execute(
      Telemetry.event_transport_error(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        error: :exit_status,
        status: status
      }
    )

    {:stop, status, state}
  end

  def handle_info({:DOWN, ref, :port, port, reason}, %{ref: ref, port: port} = state) do
    Logging.transport_event("stdio_down", %{reason: reason}, level: :error)

    Telemetry.execute(
      Telemetry.event_transport_error(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        error: :port_down,
        reason: reason
      }
    )

    {:stop, reason, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logging.transport_event("stdio_exit", %{reason: reason}, level: :error)

    Telemetry.execute(
      Telemetry.event_transport_error(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        error: :port_exit,
        reason: reason
      }
    )

    {:stop, reason, state}
  end

  @impl GenServer
  def handle_cast(:close_port, %{cleanup: :verified} = state) do
    {:noreply, if(state.close_phase == :active, do: begin_guard_close(state, [], nil), else: state)}
  end

  def handle_cast(:close_port, %{port: port} = state) do
    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        reason: :client_closed
      }
    )

    Port.close(port)
    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    if state.cleanup == :verified and is_port(state.port) and Port.info(state.port), do: Port.close(state.port)

    Telemetry.execute(
      Telemetry.event_transport_terminate(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        reason: reason
      }
    )

    :ok
  end

  defp handle_guard_packet({:hello, token}, %{guard_token: token, guardian_acked: false} = state) do
    if Port.command(state.port, Guardian.ack(token), [:nosuspend]),
      do: %{state | guardian_acked: true},
      else: begin_guard_close(%{state | guard_error: :startup_backpressure}, [], nil)
  end

  defp handle_guard_packet({:started, token, pid}, %{guard_token: token, guardian_acked: true} = state) do
    if state.startup_timer, do: Process.cancel_timer(state.startup_timer)
    if not state.sealed, do: GenServer.cast(state.client, :negotiate)
    %{state | guardian_started: true, target_pid: pid}
  end

  defp handle_guard_packet({:data, data}, %{guardian_acked: true} = state) do
    if state.close_phase == :active, do: GenServer.cast(state.client, {:response, data})
    state
  end

  defp handle_guard_packet({:target_exit, pid, status}, state) do
    %{state | target_pid: state.target_pid || pid, target_status: status, sealed: true}
  end

  defp handle_guard_packet(
         {:receipt, token, nonce, receipt},
         %{guard_token: token, close_nonce: nonce, close_phase: :closing} = state
       ) do
    if is_nil(state.target_pid) or receipt.target_pid == state.target_pid do
      state = %{state | guard_receipt: receipt, target_pid: receipt.target_pid, target_status: receipt.target_status}
      if is_nil(state.guard_exit), do: state, else: finish_guard_close(state)
    else
      %{state | guard_error: :target_identity_mismatch}
    end
  end

  defp handle_guard_packet(_invalid, state) do
    if state.close_phase == :active,
      do: begin_guard_close(%{state | guard_error: :invalid_guardian_packet}, [], nil),
      else: state
  end

  defp begin_guard_close(%{close_phase: :active} = state, opts, from) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    timer = Process.send_after(self(), :guardian_close_deadline, timeout)

    state = %{
      state
      | sealed: true,
        close_phase: :closing,
        close_id: Keyword.get(opts, :close_id) || make_ref(),
        close_nonce: Guardian.token(),
        close_deadline: System.monotonic_time(:millisecond) + timeout,
        close_timer: timer,
        close_waiters: if(from, do: [from], else: [])
    }

    if is_nil(state.guard_exit), do: send_guard_close(state), else: finish_guard_close(state)
  end

  defp begin_guard_close(state, _opts, _from), do: state

  defp send_guard_close(%{close_sent: true} = state), do: state

  defp send_guard_close(state) do
    remaining = max(state.close_deadline - System.monotonic_time(:millisecond), 0)

    if remaining > 0 and is_port(state.port) and Port.info(state.port) do
      packet = Guardian.close(state.guard_token, state.close_nonce, remaining)

      if Port.command(state.port, packet, [:nosuspend]) do
        %{state | close_sent: true}
      else
        Process.send_after(self(), :guardian_close_retry, min(remaining, 10))
        state
      end
    else
      state
    end
  rescue
    _ -> %{state | guard_error: :close_delivery_unknown}
  end

  defp finish_guard_close(%{close_phase: :closed} = state), do: state

  defp finish_guard_close(state) do
    if state.close_timer, do: Process.cancel_timer(state.close_timer)
    state = %{state | close_phase: :closed}
    report = Guardian.report(state)
    Enum.each(state.close_waiters, &GenServer.reply(&1, {:ok, report}))
    %{state | close_waiters: [], close_report: report}
  end

  defp spawn_port(cmd, state) do
    default_env = get_default_env()

    env =
      if is_nil(state.env), do: default_env, else: Map.merge(default_env, state.env)

    env = normalize_env_for_erlang(env)

    # As per erlang docs, :hide only affects Windows and gets ignored anywhere else.
    # https://www.erlang.org/doc/apps/erts/erlang#open_port/2
    opts =
      [:hide, :binary]
      |> then(&if is_nil(state.args), do: &1, else: Enum.concat(&1, args: state.args))
      |> then(&if is_nil(state.env), do: &1, else: Enum.concat(&1, env: env))
      |> then(&if is_nil(state.cwd), do: &1, else: Enum.concat(&1, cd: state.cwd))
      |> then(&if :os.type() == {:win32, :nt}, do: [{:hide, true} | &1], else: &1)

    Port.open({:spawn_executable, cmd}, opts)
  end

  defp get_default_env do
    default_env =
      if :os.type() == {:win32, :nt}, do: @win32_default_env, else: @unix_default_env

    System.get_env()
    |> Enum.filter(fn {k, _} -> Enum.member?(default_env, k) end)
    # remove functions, for security risks
    |> Enum.reject(fn {_, v} -> String.starts_with?(v, "()") end)
    |> Map.new()
  end

  defp normalize_env_for_erlang(%{} = env) do
    env
    |> Map.new(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    |> Enum.to_list()
  end
end
