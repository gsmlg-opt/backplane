defmodule Backplane.Proxy.Upstream do
  @moduledoc """
  GenServer managing a single upstream MCP server connection.

  Supports two transport types:
  - `:http` — stateless HTTP requests via Req
  - `:stdio` — persistent Port-based communication over stdin/stdout

  On startup, sends `initialize` then `tools/list` to discover upstream tools,
  registers them in the ToolRegistry with the configured prefix.
  """

  use GenServer
  require Logger

  alias Backplane.Registry.{Tool, ToolRegistry}

  @default_timeout 30_000
  @refresh_interval 300_000
  @health_ping_interval 60_000
  @max_consecutive_failures 3
  @initial_backoff_ms 1_000
  @max_backoff_ms 60_000

  # Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @doc """
  Forward a tool call to this upstream server.

  The optional `timeout` parameter overrides the default 30s GenServer call
  timeout. This is used by per-tool timeout configuration.
  """
  @spec forward(pid(), String.t(), map(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def forward(pid, tool_name, arguments, timeout \\ @default_timeout) do
    GenServer.call(pid, {:tools_call, tool_name, arguments}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, "Upstream timeout after #{timeout}ms"}
    :exit, reason -> {:error, "Upstream error: #{inspect(reason)}"}
  end

  @doc "Get the status of this upstream connection."
  @spec status(pid()) :: map()
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc "Trigger a tool refresh."
  @spec refresh(pid()) :: :ok
  def refresh(pid) do
    GenServer.cast(pid, :refresh)
  end

  # Server implementation

  @impl true
  def init(config) do
    state = %{
      name: config.name,
      prefix: config.prefix,
      transport: config.transport,
      config: config,
      tools: [],
      status: :connecting,
      port: nil,
      buffer: "",
      pending_requests: %{},
      next_id: 1,
      initialized: false,
      last_ping_at: nil,
      last_pong_at: nil,
      consecutive_ping_failures: 0,
      consecutive_call_failures: 0,
      reconnect_attempts: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_and_initialize(state) do
      {:ok, state} ->
        case discover_tools(state) do
          {:ok, state} ->
            schedule_refresh()
            schedule_health_ping()
            {:noreply, %{state | status: :connected, reconnect_attempts: 0}}

          {:error, reason, state} ->
            Logger.warning("Failed to discover tools",
              upstream: state.name,
              reason: inspect(reason)
            )

            schedule_reconnect(state.reconnect_attempts)

            {:noreply,
             %{state | status: :degraded, reconnect_attempts: state.reconnect_attempts + 1}}
        end

      {:error, reason, state} ->
        Logger.warning("Failed to connect to upstream",
          upstream: state.name,
          reason: inspect(reason)
        )

        schedule_reconnect(state.reconnect_attempts)

        {:noreply,
         %{state | status: :disconnected, reconnect_attempts: state.reconnect_attempts + 1}}
    end
  end

  @impl true
  def handle_call({:tools_call, tool_name, arguments}, _from, %{transport: "http"} = state) do
    result = http_tools_call(state, tool_name, arguments)
    state = track_call_result(state, result)
    {:reply, result, state}
  end

  def handle_call({:tools_call, tool_name, arguments}, from, %{transport: "stdio"} = state) do
    {id, state} = next_request_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => id,
      "params" => %{"name" => tool_name, "arguments" => arguments}
    }

    case send_stdio(state.port, request) do
      :ok ->
        state = %{state | pending_requests: Map.put(state.pending_requests, id, from)}
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, "Failed to send to upstream: #{inspect(reason)}"}, state}
    end
  end

  def handle_call(:status, _from, state) do
    info = %{
      name: state.name,
      prefix: state.prefix,
      transport: state.transport,
      status: state.status,
      tool_count: length(state.tools),
      last_ping_at: state.last_ping_at,
      last_pong_at: state.last_pong_at,
      consecutive_ping_failures: state.consecutive_ping_failures
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    case discover_tools(state) do
      {:ok, state} ->
        schedule_refresh()
        {:noreply, state}

      {:error, _reason, state} ->
        schedule_refresh()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    handle_cast(:refresh, state)
  end

  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(:health_ping, %{status: status} = state)
      when status in [:disconnected, :connecting] do
    # Don't ping if not connected, just reschedule
    schedule_health_ping()
    {:noreply, state}
  end

  def handle_info(:health_ping, state) do
    now = System.system_time(:second)
    state = %{state | last_ping_at: now}

    case send_ping(state) do
      :ok ->
        schedule_health_ping()

        {:noreply, %{state | last_pong_at: now, consecutive_ping_failures: 0, status: :connected}}

      {:error, reason} ->
        failures = state.consecutive_ping_failures + 1

        Logger.warning("Health ping failed",
          upstream: state.name,
          reason: inspect(reason),
          consecutive_failures: failures
        )

        new_status = if failures >= @max_consecutive_failures, do: :degraded, else: state.status
        schedule_health_ping()
        {:noreply, %{state | consecutive_ping_failures: failures, status: new_status}}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = handle_stdio_data(state, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Upstream stdio process exited",
      upstream: state.name,
      exit_status: status
    )

    ToolRegistry.deregister_upstream(state.prefix)
    schedule_reconnect(state.reconnect_attempts)

    {:noreply,
     %{
       state
       | status: :disconnected,
         port: nil,
         tools: [],
         reconnect_attempts: state.reconnect_attempts + 1
     }}
  end

  @impl true
  def terminate(_reason, state) do
    ToolRegistry.deregister_upstream(state.prefix)

    if state.port do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # HTTP Transport

  defp connect_and_initialize(%{transport: "http"} = state) do
    request =
      jsonrpc_request("initialize", %{
        "protocolVersion" => Backplane.protocol_version(),
        "clientInfo" => %{"name" => "backplane", "version" => Backplane.version()},
        "capabilities" => %{}
      })

    case http_request(state, request) do
      {:ok, %{"result" => _result}} ->
        {:ok, %{state | initialized: true}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp connect_and_initialize(%{transport: "stdio"} = state) do
    config = state.config

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, config[:args] || []},
      {:env, format_env(config[:env] || %{})}
    ]

    try do
      port = Port.open({:spawn_executable, find_executable(config.command)}, port_opts)

      state = %{state | port: port}

      request =
        jsonrpc_request("initialize", %{
          "protocolVersion" => Backplane.protocol_version(),
          "clientInfo" => %{"name" => "backplane", "version" => Backplane.version()},
          "capabilities" => %{}
        })

      case send_stdio_and_wait(state, request) do
        {:ok, _result, state} ->
          {:ok, %{state | initialized: true}}

        {:error, reason, state} ->
          {:error, reason, state}
      end
    rescue
      e -> {:error, Exception.message(e), state}
    end
  end

  defp discover_tools(%{transport: "http"} = state) do
    request = jsonrpc_request("tools/list", %{})

    case http_request(state, request) do
      {:ok, %{"result" => %{"tools" => tools}}} ->
        register_tools(state, tools)

      {:ok, _} ->
        {:error, "Unexpected response from tools/list", state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp discover_tools(%{transport: "stdio"} = state) do
    request = jsonrpc_request("tools/list", %{})

    case send_stdio_and_wait(state, request) do
      {:ok, %{"tools" => tools}, state} ->
        register_tools(state, tools)

      {:ok, _, state} ->
        {:error, "Unexpected response from tools/list", state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp register_tools(state, raw_tools) do
    # Deregister old tools first
    ToolRegistry.deregister_upstream(state.prefix)
    tool_timeouts = state.config[:tool_timeouts] || %{}

    tools =
      Enum.map(raw_tools, fn raw ->
        tool_name = raw["name"]
        timeout = Map.get(tool_timeouts, tool_name, @default_timeout)

        %Tool{
          name: tool_name,
          description: raw["description"] || "",
          input_schema: raw["inputSchema"] || %{},
          origin: {:upstream, state.prefix},
          timeout: timeout
        }
      end)

    ToolRegistry.register_upstream(state.prefix, self(), tools)

    {:ok, %{state | tools: tools}}
  end

  defp http_tools_call(state, tool_name, arguments) do
    request =
      jsonrpc_request("tools/call", %{
        "name" => tool_name,
        "arguments" => arguments
      })

    case http_request(state, request) do
      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, %{"error" => error}} ->
        {:error, error["message"] || "Unknown upstream error"}

      {:ok, body} ->
        {:error, "Malformed upstream response: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Upstream request failed: #{inspect(reason)}"}
    end
  end

  defp http_request(state, body) do
    config = state.config
    headers = Map.to_list(config[:headers] || %{})

    # Propagate request ID from Logger metadata for distributed tracing
    headers =
      case Logger.metadata()[:request_id] do
        nil -> headers
        req_id -> [{"x-request-id", req_id} | headers]
      end

    opts = [
      url: config.url,
      method: :post,
      json: body,
      headers: [{"content-type", "application/json"} | headers],
      receive_timeout: @default_timeout
    ]

    case Req.request(opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Stdio Transport helpers

  defp send_stdio(port, request) when is_port(port) do
    data = Jason.encode!(request) <> "\n"
    Port.command(port, data)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp send_stdio(nil, _request), do: {:error, :not_connected}

  defp send_stdio_and_wait(state, request) do
    case send_stdio(state.port, request) do
      :ok ->
        receive do
          {port, {:data, data}} when port == state.port ->
            case Jason.decode(data) do
              {:ok, %{"result" => result}} ->
                {:ok, result, state}

              {:ok, %{"error" => error}} ->
                {:error, error["message"], state}

              {:error, _} ->
                {:error, "Invalid JSON response", state}
            end
        after
          @default_timeout ->
            {:error, :timeout, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handle_stdio_data(state, data) do
    buffer = state.buffer <> data

    case String.split(buffer, "\n", parts: 2) do
      [complete, rest] ->
        state = %{state | buffer: ""} |> process_stdio_message(complete)
        # Recurse to handle any additional complete messages in the remainder
        handle_stdio_data(state, rest)

      [_incomplete] ->
        %{state | buffer: buffer}
    end
  end

  defp process_stdio_message(state, message) do
    case Jason.decode(message) do
      {:ok, %{"id" => id} = response} ->
        dispatch_stdio_response(state, id, response)

      _ ->
        state
    end
  end

  defp dispatch_stdio_response(state, id, response) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        state

      {from, pending} ->
        result = parse_jsonrpc_result(response)
        GenServer.reply(from, result)
        %{state | pending_requests: pending}
    end
  end

  defp parse_jsonrpc_result(%{"result" => result}), do: {:ok, result}
  defp parse_jsonrpc_result(%{"error" => error}), do: {:error, error["message"]}

  # Call failure tracking

  defp track_call_result(state, {:ok, _}) do
    %{state | consecutive_call_failures: 0, status: :connected}
  end

  defp track_call_result(state, {:error, _}) do
    failures = state.consecutive_call_failures + 1

    new_status =
      if failures >= @max_consecutive_failures, do: :degraded, else: state.status

    %{state | consecutive_call_failures: failures, status: new_status}
  end

  # Helpers

  defp jsonrpc_request(method, params) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "id" => System.unique_integer([:positive]),
      "params" => params
    }
  end

  defp next_request_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp schedule_reconnect(attempt) do
    base_delay = min(@initial_backoff_ms * Integer.pow(2, attempt), @max_backoff_ms)
    # Add jitter: 75-125% of base delay
    jitter = div(base_delay, 4)
    delay = base_delay - jitter + :rand.uniform(max(jitter * 2, 1))
    Process.send_after(self(), :reconnect, delay)
  end

  defp schedule_health_ping do
    Process.send_after(self(), :health_ping, @health_ping_interval)
  end

  defp send_ping(%{transport: "http"} = state) do
    request = jsonrpc_request("ping", %{})

    case http_request(state, request) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_ping(%{transport: "stdio", port: nil}), do: {:error, :not_connected}

  defp send_ping(%{transport: "stdio"} = state) do
    request = jsonrpc_request("ping", %{})

    case send_stdio(state.port, request) do
      :ok ->
        # For stdio, we just verify the send succeeded
        # Response will come async via handle_info
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> command
      path -> path
    end
  end

  defp format_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end
end
