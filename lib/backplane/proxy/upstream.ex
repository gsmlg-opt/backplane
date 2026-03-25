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

  # Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @doc "Forward a tool call to this upstream server."
  def forward(pid, tool_name, arguments) do
    GenServer.call(pid, {:tools_call, tool_name, arguments}, @default_timeout)
  catch
    :exit, {:timeout, _} -> {:error, "Upstream timeout after #{@default_timeout}ms"}
    :exit, reason -> {:error, "Upstream error: #{inspect(reason)}"}
  end

  @doc "Get the status of this upstream connection."
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc "Trigger a tool refresh."
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
      initialized: false
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
            {:noreply, %{state | status: :connected}}

          {:error, reason, state} ->
            Logger.warning("Failed to discover tools from #{state.name}: #{inspect(reason)}")
            schedule_reconnect()
            {:noreply, %{state | status: :degraded}}
        end

      {:error, reason, state} ->
        Logger.warning("Failed to connect to upstream #{state.name}: #{inspect(reason)}")
        schedule_reconnect()
        {:noreply, %{state | status: :disconnected}}
    end
  end

  @impl true
  def handle_call({:tools_call, tool_name, arguments}, _from, %{transport: "http"} = state) do
    result = http_tools_call(state, tool_name, arguments)
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
      tool_count: length(state.tools)
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

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = handle_stdio_data(state, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Upstream #{state.name} stdio process exited with status #{status}")
    ToolRegistry.deregister_upstream(state.prefix)
    schedule_reconnect()
    {:noreply, %{state | status: :disconnected, port: nil, tools: []}}
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
        "protocolVersion" => "2025-03-26",
        "clientInfo" => %{"name" => "backplane", "version" => "0.1.0"},
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
          "protocolVersion" => "2025-03-26",
          "clientInfo" => %{"name" => "backplane", "version" => "0.1.0"},
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

    tools =
      Enum.map(raw_tools, fn raw ->
        %Tool{
          name: raw["name"],
          description: raw["description"] || "",
          input_schema: raw["inputSchema"] || %{},
          origin: {:upstream, state.prefix}
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

      {:error, reason} ->
        {:error, "Upstream request failed: #{inspect(reason)}"}
    end
  end

  defp http_request(state, body) do
    config = state.config
    headers = Map.to_list(config[:headers] || %{})

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
        %{state | buffer: rest} |> process_stdio_message(complete)

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

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, 5_000)
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
