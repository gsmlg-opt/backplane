defmodule Backplane.Proxy.Upstream do
  @moduledoc """
  GenServer managing a single upstream MCP server connection.

  Supports three transport types:
  - `"http"` — stateless HTTP requests via Req (Streamable HTTP)
  - `"stdio"` — persistent Port-based communication over stdin/stdout
  - `"sse"` — persistent SSE GET connection with POST for requests (legacy MCP SSE)

  On startup, sends `initialize` then `tools/list` to discover upstream tools,
  registers them in the ToolRegistry with the configured prefix.
  """

  use GenServer
  require Logger

  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.{Tool, ToolRegistry}

  @default_timeout 30_000
  @refresh_interval 300_000
  @health_ping_interval 60_000
  @max_consecutive_failures 3
  # 10 MB — drop buffer and log if a misbehaving upstream streams without newlines
  @max_buffer_size 10_000_000
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
      reconnect_attempts: 0,
      pending_ping_id: nil,
      tool_timeout: config[:timeout] || @default_timeout,
      refresh_interval: config[:refresh_interval],
      # SSE transport fields
      sse_ref: nil,
      sse_endpoint: nil,
      sse_retry_ms: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_and_initialize(state) do
      {:ok, state} ->
        case discover_tools(state) do
          {:ok, state} ->
            schedule_refresh(state)
            schedule_health_ping()
            new_state = %{state | status: :connected, reconnect_attempts: 0}
            PubSubBroadcaster.broadcast_upstream(state.prefix, :connected, %{name: state.name})
            {:noreply, new_state}

          {:error, reason, state} ->
            Logger.warning("Failed to discover tools",
              upstream: state.name,
              reason: inspect(reason)
            )

            schedule_reconnect(state.reconnect_attempts)

            new_state = %{
              state
              | status: :degraded,
                reconnect_attempts: state.reconnect_attempts + 1
            }

            PubSubBroadcaster.broadcast_upstream(state.prefix, :degraded, %{
              name: state.name,
              reason: reason
            })

            {:noreply, new_state}
        end

      {:error, reason, state} ->
        Logger.warning("Failed to connect to upstream",
          upstream: state.name,
          reason: inspect(reason)
        )

        schedule_reconnect(state.reconnect_attempts)

        new_state = %{
          state
          | status: :disconnected,
            reconnect_attempts: state.reconnect_attempts + 1
        }

        PubSubBroadcaster.broadcast_upstream(state.prefix, :disconnected, %{
          name: state.name,
          reason: reason
        })

        {:noreply, new_state}
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

  def handle_call({:tools_call, _tool_name, _arguments}, _from, %{transport: "sse", sse_endpoint: nil} = state) do
    {:reply, {:error, "SSE endpoint not yet discovered"}, state}
  end

  def handle_call({:tools_call, tool_name, arguments}, from, %{transport: "sse"} = state) do
    {id, state} = next_request_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => id,
      "params" => %{"name" => tool_name, "arguments" => arguments}
    }

    case sse_post(state, request) do
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
      consecutive_ping_failures: state.consecutive_ping_failures,
      post_url_known: is_binary(state.sse_endpoint)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    case discover_tools(state) do
      {:ok, state} ->
        schedule_refresh(state)
        {:noreply, %{state | reconnect_attempts: 0}}

      {:error, _reason, state} ->
        schedule_refresh(state)
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

  def handle_info(:health_ping, %{transport: "http"} = state) do
    now = System.system_time(:second)
    state = %{state | last_ping_at: now}

    case send_ping(state) do
      :ok ->
        schedule_health_ping()

        {:noreply, %{state | last_pong_at: now, consecutive_ping_failures: 0, status: :connected}}

      {:error, reason} ->
        handle_ping_failure(state, reason)
    end
  end

  def handle_info(:health_ping, %{transport: "stdio"} = state) do
    now = System.system_time(:second)
    state = %{state | last_ping_at: now}

    # If the previous ping never got a response, count as failure
    state =
      if state.pending_ping_id != nil do
        failures = state.consecutive_ping_failures + 1
        new_status = if failures >= @max_consecutive_failures, do: :degraded, else: state.status
        %{state | consecutive_ping_failures: failures, status: new_status, pending_ping_id: nil}
      else
        state
      end

    {id, state} = next_request_id(state)
    state = %{state | pending_ping_id: id}

    case send_ping(state) do
      :ok ->
        schedule_health_ping()
        {:noreply, state}

      {:error, reason} ->
        state = %{state | pending_ping_id: nil}
        handle_ping_failure(state, reason)
    end
  end

  def handle_info(:health_ping, %{transport: "sse"} = state) do
    now = System.system_time(:second)
    state = %{state | last_ping_at: now}

    # If the previous ping never got a response, count as failure
    state =
      if state.pending_ping_id != nil do
        failures = state.consecutive_ping_failures + 1
        new_status = if failures >= @max_consecutive_failures, do: :degraded, else: state.status
        %{state | consecutive_ping_failures: failures, status: new_status, pending_ping_id: nil}
      else
        state
      end

    {id, state} = next_request_id(state)
    state = %{state | pending_ping_id: id}

    request = %{
      "jsonrpc" => "2.0",
      "method" => "ping",
      "id" => id,
      "params" => %{}
    }

    case sse_post(state, request) do
      :ok ->
        schedule_health_ping()
        {:noreply, state}

      {:error, reason} ->
        state = %{state | pending_ping_id: nil}
        handle_ping_failure(state, reason)
    end
  end

  # SSE event handlers
  def handle_info({:sse_event, ref, event}, %{sse_ref: ref} = state) when not is_nil(ref) do
    handle_sse_event(state, event)
  end

  def handle_info({:sse_closed, ref, reason}, %{sse_ref: ref} = state) when not is_nil(ref) do
    Logger.warning("SSE connection closed", upstream: state.name, reason: inspect(reason))

    # Reply to all pending requests
    for {_id, from} <- state.pending_requests do
      GenServer.reply(from, {:error, :disconnected})
    end

    ToolRegistry.deregister_upstream(state.prefix)

    # Use server-supplied retry or standard backoff
    case state.sse_retry_ms do
      ms when is_integer(ms) and ms > 0 ->
        Process.send_after(self(), :reconnect, ms)

      _ ->
        schedule_reconnect(state.reconnect_attempts)
    end

    PubSubBroadcaster.broadcast_upstream(state.prefix, :disconnected, %{
      name: state.name,
      reason: "SSE connection closed: #{inspect(reason)}"
    })

    {:noreply,
     %{
       state
       | status: :disconnected,
         sse_ref: nil,
         sse_endpoint: nil,
         tools: [],
         pending_requests: %{},
         pending_ping_id: nil,
         reconnect_attempts: state.reconnect_attempts + 1
     }}
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

    # Reply to all pending callers so they don't hang until GenServer.call timeout
    for {_id, from} <- state.pending_requests do
      GenServer.reply(from, {:error, "upstream process exited (status #{status})"})
    end

    ToolRegistry.deregister_upstream(state.prefix)
    schedule_reconnect(state.reconnect_attempts)

    PubSubBroadcaster.broadcast_upstream(state.prefix, :disconnected, %{
      name: state.name,
      reason: "process exited (status #{status})"
    })

    {:noreply,
     %{
       state
       | status: :disconnected,
         port: nil,
         tools: [],
         pending_requests: %{},
         pending_ping_id: nil,
         reconnect_attempts: state.reconnect_attempts + 1
     }}
  end

  def handle_info(msg, state) do
    Logger.debug("Upstream #{state.name} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Reply to all pending callers so they don't hang
    for {_id, from} <- state.pending_requests do
      GenServer.reply(from, {:error, "upstream terminated"})
    end

    ToolRegistry.deregister_upstream(state.prefix)

    # Close SSE connection
    if state.sse_ref do
      Backplane.Proxy.SSEClient.close(state.sse_ref)
    end

    if state.port do
      try do
        Port.close(state.port)
      rescue
        e ->
          Logger.debug("Port.close failed during terminate: #{Exception.message(e)}")
      end
    end

    :ok
  end

  defp handle_ping_failure(state, reason) do
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
      e ->
        Logger.warning("Stdio initialization failed for #{state.name}: #{Exception.message(e)}")
        {:error, Exception.message(e), state}
    end
  end

  defp connect_and_initialize(%{transport: "sse"} = state) do
    config = state.config

    # Build headers for SSE GET connection
    base_headers = Map.to_list(config[:headers] || %{})

    # Inject auth headers
    headers =
      case Backplane.Proxy.AuthInjector.inject(
             base_headers,
             config[:auth_scheme],
             config[:auth_header_name],
             config[:credential]
           ) do
        {:ok, h} -> h
        # Connect anyway, auth failure will surface on POST
        {:error, _reason} -> base_headers
      end

    # Open SSE connection
    {:ok, ref} = Backplane.Proxy.SSEClient.connect(config.url, headers, self())
    state = %{state | sse_ref: ref}

    # Wait for the endpoint event
    receive do
      {:sse_event, ^ref, %{event: "endpoint", data: endpoint_url}} ->
        # Resolve endpoint URL (may be relative)
        post_url = resolve_endpoint_url(config.url, endpoint_url)
        state = %{state | sse_endpoint: post_url}

        # Now send initialize via POST to the discovered endpoint
        request =
          jsonrpc_request("initialize", %{
            "protocolVersion" => Backplane.protocol_version(),
            "clientInfo" => %{"name" => "backplane", "version" => Backplane.version()},
            "capabilities" => %{}
          })

        case sse_post_and_wait(state, request) do
          {:ok, _result, state} ->
            {:ok, %{state | initialized: true}}

          {:error, reason, state} ->
            {:error, reason, state}
        end

      {:sse_closed, ^ref, reason} ->
        {:error, "SSE connection closed: #{inspect(reason)}", %{state | sse_ref: nil}}
    after
      @default_timeout ->
        Backplane.Proxy.SSEClient.close(ref)
        {:error, :timeout, %{state | sse_ref: nil}}
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

  defp discover_tools(%{transport: "sse"} = state) do
    request = jsonrpc_request("tools/list", %{})

    case sse_post_and_wait(state, request) do
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
    default_timeout = state.tool_timeout

    tools =
      Enum.map(raw_tools, fn raw ->
        tool_name = raw["name"]
        timeout = Map.get(tool_timeouts, tool_name, default_timeout)

        %Tool{
          name: tool_name,
          description: raw["description"] || "",
          input_schema: raw["inputSchema"] || %{},
          origin: {:upstream, state.prefix},
          timeout: timeout
        }
      end)

    ToolRegistry.register_upstream(state.prefix, self(), tools)

    PubSubBroadcaster.broadcast_upstream(state.prefix, :tools_refreshed, %{
      name: state.name,
      tool_count: length(tools)
    })

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
    headers = build_request_headers(config)

    opts = [
      url: config.url,
      method: :post,
      json: body,
      headers: [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"}
        | headers
      ],
      receive_timeout: config[:timeout] || @default_timeout,
      decode_body: false
    ]

    case Req.request(opts) do
      {:ok, %{status: 200, headers: resp_headers, body: resp_body}} ->
        decode_http_response(resp_headers, resp_body)

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    {:auth_error, reason} -> {:error, reason}
  end

  defp build_request_headers(config) do
    base_headers = Map.to_list(config[:headers] || %{})

    base_headers =
      case Backplane.Proxy.AuthInjector.inject(
             base_headers,
             config[:auth_scheme],
             config[:auth_header_name],
             config[:credential]
           ) do
        {:ok, h} -> h
        {:error, reason} -> throw({:auth_error, reason})
      end

    case Logger.metadata()[:request_id] do
      nil -> base_headers
      req_id -> [{"x-request-id", req_id} | base_headers]
    end
  end

  defp decode_http_response(resp_headers, resp_body) do
    content_type = get_content_type(resp_headers)

    if String.contains?(content_type, "text/event-stream") do
      parse_sse_response(resp_body)
    else
      case Jason.decode(resp_body) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, "Unexpected non-object JSON response"}
        {:error, _} -> {:error, "Invalid JSON response"}
      end
    end
  end

  defp parse_sse_response(body) when is_binary(body) do
    {events, _rest} = Backplane.Proxy.SSEParser.parse(body, "")

    case Enum.find(events, &(&1.event == "message")) do
      %{data: data} ->
        case Jason.decode(data) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:ok, _} -> {:error, "Unexpected non-object in SSE data"}
          {:error, _} -> {:error, "Invalid JSON in SSE data"}
        end

      nil ->
        {:error, "No message event in SSE response"}
    end
  end

  defp get_content_type(headers) when is_map(headers) do
    case headers["content-type"] do
      [ct | _] -> ct
      _ -> ""
    end
  end

  defp get_content_type(headers) when is_list(headers) do
    Enum.find_value(headers, "", fn
      {k, v} when is_binary(k) -> if String.downcase(k) == "content-type", do: v
      _ -> nil
    end)
  end

  # Stdio Transport helpers

  defp send_stdio(port, request) when is_port(port) do
    data = Jason.encode!(request) <> "\n"
    Port.command(port, data)
    :ok
  rescue
    e ->
      Logger.debug("Stdio send failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
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

    if byte_size(buffer) > @max_buffer_size do
      Logger.warning("Stdio buffer exceeded #{@max_buffer_size} bytes, dropping",
        upstream: state.name
      )

      %{state | buffer: ""}
    else
      split_and_process(state, buffer)
    end
  end

  defp split_and_process(state, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [complete, rest] ->
        state = %{state | buffer: ""} |> process_stdio_message(complete)
        handle_stdio_data(state, rest)

      [_incomplete] ->
        %{state | buffer: buffer}
    end
  end

  defp process_stdio_message(state, message) when byte_size(message) == 0, do: state

  defp process_stdio_message(state, message) do
    case Jason.decode(message) do
      {:ok, %{"id" => id} = response} ->
        dispatch_stdio_response(state, id, response)

      {:ok, decoded} ->
        Logger.debug("Upstream #{state.prefix}: received message without id: #{inspect(decoded)}")
        state

      {:error, _} ->
        Logger.warning(
          "Upstream #{state.prefix}: failed to decode stdio message: #{String.slice(message, 0, 200)}"
        )

        state
    end
  end

  defp dispatch_stdio_response(%{pending_ping_id: ping_id} = state, id, _response)
       when id == ping_id and not is_nil(ping_id) do
    now = System.system_time(:second)

    %{
      state
      | pending_ping_id: nil,
        last_pong_at: now,
        consecutive_ping_failures: 0,
        status: :connected
    }
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

  defp schedule_refresh(%{refresh_interval: interval}) when is_integer(interval) do
    Process.send_after(self(), :refresh, interval)
  end

  defp schedule_refresh(_state) do
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
    # Use the pending_ping_id so the async response can be matched
    request = %{
      "jsonrpc" => "2.0",
      "method" => "ping",
      "id" => state.pending_ping_id,
      "params" => %{}
    }

    case send_stdio(state.port, request) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # SSE Transport helpers

  defp sse_post(state, request) do
    config = state.config
    base_headers = Map.to_list(config[:headers] || %{})

    headers =
      case Backplane.Proxy.AuthInjector.inject(
             base_headers,
             config[:auth_scheme],
             config[:auth_header_name],
             config[:credential]
           ) do
        {:ok, h} -> h
        {:error, reason} -> throw({:auth_error, reason})
      end

    opts = [
      url: state.sse_endpoint,
      method: :post,
      json: request,
      headers: [{"content-type", "application/json"} | headers],
      receive_timeout: @default_timeout,
      decode_body: false
    ]

    case Req.request(opts) do
      {:ok, %{status: status}} when status in [200, 202] -> :ok
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  catch
    {:auth_error, reason} -> {:error, reason}
  end

  defp sse_post_and_wait(state, request) do
    id = request["id"]

    config = state.config
    base_headers = Map.to_list(config[:headers] || %{})

    headers =
      case Backplane.Proxy.AuthInjector.inject(
             base_headers,
             config[:auth_scheme],
             config[:auth_header_name],
             config[:credential]
           ) do
        {:ok, h} -> h
        {:error, reason} -> throw({:auth_error, reason})
      end

    opts = [
      url: state.sse_endpoint,
      method: :post,
      json: request,
      headers: [{"content-type", "application/json"} | headers],
      receive_timeout: @default_timeout,
      decode_body: false
    ]

    case Req.request(opts) do
      {:ok, %{status: status}} when status in [200, 202] ->
        # Wait for matching response on SSE stream
        sse_wait_for_response(state, id)

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}", state}

      {:error, reason} ->
        {:error, inspect(reason), state}
    end
  catch
    {:auth_error, reason} -> {:error, reason, state}
  end

  defp sse_wait_for_response(state, id, depth \\ 0)

  defp sse_wait_for_response(state, _id, depth) when depth > 20 do
    {:error, "Too many non-matching SSE events", state}
  end

  defp sse_wait_for_response(state, id, depth) do
    ref = state.sse_ref

    receive do
      {:sse_event, ^ref, %{event: "message", data: data} = event} ->
        state = maybe_update_retry(state, event)
        dispatch_sse_wait_result(state, id, data, depth)

      {:sse_event, ^ref, event} ->
        state = maybe_update_retry(state, event)
        sse_wait_for_response(state, id, depth + 1)

      {:sse_closed, ^ref, reason} ->
        {:error, "SSE closed: #{inspect(reason)}", state}
    after
      @default_timeout ->
        {:error, :timeout, state}
    end
  end

  defp dispatch_sse_wait_result(state, id, data, depth) do
    case Jason.decode(data) do
      {:ok, %{"id" => ^id, "result" => result}} ->
        {:ok, result, state}

      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, error["message"] || "Unknown error", state}

      {:ok, _other} ->
        sse_wait_for_response(state, id, depth + 1)

      {:error, _} ->
        {:error, "Invalid JSON in SSE data", state}
    end
  end

  defp maybe_update_retry(state, %{retry: retry}) when is_integer(retry) and retry > 0 do
    %{state | sse_retry_ms: retry}
  end

  defp maybe_update_retry(state, _event), do: state

  defp handle_sse_event(state, %{event: "message", data: data} = event) do
    # Check for retry field
    state =
      if is_integer(event.retry) and event.retry > 0,
        do: %{state | sse_retry_ms: event.retry},
        else: state

    case Jason.decode(data) do
      {:ok, %{"id" => id} = response} ->
        state = dispatch_sse_response(state, id, response)
        {:noreply, state}

      {:ok, notification} ->
        Logger.debug("Upstream #{state.prefix}: SSE notification: #{inspect(notification)}")
        {:noreply, state}

      {:error, _} ->
        Logger.warning("Upstream #{state.prefix}: invalid JSON in SSE message")
        {:noreply, state}
    end
  end

  defp handle_sse_event(state, event) do
    # Handle retry on any event type
    state =
      if is_integer(event.retry) and event.retry > 0,
        do: %{state | sse_retry_ms: event.retry},
        else: state

    {:noreply, state}
  end

  defp dispatch_sse_response(%{pending_ping_id: ping_id} = state, id, _response)
       when id == ping_id and not is_nil(ping_id) do
    now = System.system_time(:second)

    %{
      state
      | pending_ping_id: nil,
        last_pong_at: now,
        consecutive_ping_failures: 0,
        status: :connected
    }
  end

  defp dispatch_sse_response(state, id, response) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        state

      {from, pending} ->
        result = parse_jsonrpc_result(response)
        GenServer.reply(from, result)
        state = track_call_result(%{state | pending_requests: pending}, result)
        state
    end
  end

  defp resolve_endpoint_url(sse_url, endpoint_url) do
    if String.starts_with?(endpoint_url, "http") do
      endpoint_url
    else
      base = URI.parse(sse_url)
      endpoint = URI.parse(endpoint_url)
      URI.to_string(%{base | path: endpoint.path, query: endpoint.query, fragment: nil})
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
