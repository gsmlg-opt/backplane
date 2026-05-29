defmodule Backplane.HostAgent.McpManager do
  @moduledoc """
  Manages MCP server processes that run on the host agent.

  Supports two transports:
  - **stdio**: Opens an Erlang Port that communicates via stdin/stdout JSON-RPC.
  - **http**: Connects to an HTTP MCP endpoint for tool discovery and calls.

  The manager maintains a registry of running servers, their discovered tools,
  and routes `tools/call` requests to the correct server by prefix.
  """

  use GenServer

  require Logger

  @call_timeout 30_000
  @max_retries 3
  @retry_delays [1_000, 5_000, 30_000]
  @max_buffer_size 10_000_000
  @mcp_protocol_version "2025-11-25"
  @agent_version "0.1.0"

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Reconcile desired MCP server configs with current running state."
  @spec reconcile([map()]) :: :ok
  def reconcile(desired_servers) do
    GenServer.call(__MODULE__, {:reconcile, desired_servers}, @call_timeout)
  end

  @doc "List all tools from all running MCP servers."
  @spec list_tools() :: [map()]
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc "Call a tool by its full name (prefix::tool_name)."
  @spec call_tool(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call_tool(name, args) do
    GenServer.call(__MODULE__, {:call_tool, name, args}, @call_timeout)
  end

  @doc "Get the current status of all managed servers."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{servers: %{}}}
  end

  @impl true
  def handle_call({:reconcile, desired_servers}, _from, state) do
    state = do_reconcile(state, desired_servers)
    {:reply, :ok, state}
  end

  def handle_call(:list_tools, _from, state) do
    tools =
      state.servers
      |> Enum.filter(fn {_id, s} -> s.status == :running end)
      |> Enum.flat_map(fn {_id, s} -> s.tools end)

    {:reply, tools, state}
  end

  def handle_call({:call_tool, name, args}, _from, state) do
    result = do_call_tool(state, name, args)
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    summary =
      Map.new(state.servers, fn {id, s} ->
        {id,
         %{
           name: s.config["name"] || s.config[:name],
           prefix: s.config["prefix"] || s.config[:prefix],
           transport: s.config["transport"] || s.config[:transport],
           status: s.status,
           tool_count: length(s.tools),
           retries: s.retries
         }}
      end)

    {:reply, summary, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case find_server_by_port(state, port) do
      {id, server} ->
        {server, state} = handle_port_data(server, data, id, state)
        {:noreply, put_in(state, [:servers, id], server)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, exit_status}}, state) when is_port(port) do
    case find_server_by_port(state, port) do
      {id, server} ->
        Logger.warning("MCP server #{server_name(server)} exited with status #{exit_status}")
        server = %{server | port: nil, status: :stopped}
        server = maybe_retry(server, id)
        {:noreply, put_in(state, [:servers, id], server)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_start, id}, state) do
    case Map.get(state.servers, id) do
      %{status: :retrying} = server ->
        server = start_server(server)
        {:noreply, put_in(state, [:servers, id], server)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.servers, fn {_id, server} -> stop_server(server) end)
  end

  # ── Reconciliation ─────────────────────────────────────────────────────────

  defp do_reconcile(state, desired_servers) do
    desired_by_id =
      desired_servers
      |> Enum.filter(&server_enabled?/1)
      |> Map.new(&{server_id(&1), &1})

    current_ids = Map.keys(state.servers)
    desired_ids = Map.keys(desired_by_id)

    # Stop removed servers
    to_remove = current_ids -- desired_ids

    state =
      Enum.reduce(to_remove, state, fn id, acc ->
        server = acc.servers[id]
        stop_server(server)
        Logger.info("MCP server #{server_name(server)} stopped (removed)")
        %{acc | servers: Map.delete(acc.servers, id)}
      end)

    # Start new or update existing servers
    Enum.reduce(desired_by_id, state, fn {id, config}, acc ->
      case Map.get(acc.servers, id) do
        nil ->
          # New server
          server = new_server(config) |> start_server()
          Logger.info("MCP server #{server_name(server)} started")
          put_in(acc, [:servers, id], server)

        existing ->
          if config_changed?(existing.config, config) do
            # Config changed — restart
            stop_server(existing)
            server = new_server(config) |> start_server()
            Logger.info("MCP server #{server_name(server)} restarted (config changed)")
            put_in(acc, [:servers, id], server)
          else
            # No change
            acc
          end
      end
    end)
  end

  # ── Server lifecycle ────────────────────────────────────────────────────────

  defp new_server(config) do
    %{
      config: config,
      transport: field(config, :transport),
      port: nil,
      status: :stopped,
      tools: [],
      buffer: "",
      pending: %{},
      next_id: 1,
      retries: 0
    }
  end

  defp start_server(%{transport: "stdio"} = server) do
    command = field(server.config, :command)
    args = field(server.config, :args) || []
    env = build_env(field(server.config, :env))

    try do
      executable = find_executable(command)

      port_opts = [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, args},
        {:env, env}
      ]

      port = Port.open({:spawn_executable, executable}, port_opts)

      server = %{server | port: port, status: :starting, buffer: "", pending: %{}, next_id: 1}

      # Send initialize
      {id, server} = next_id(server)
      request = init_request(id)
      send_to_port(port, request)

      pending = Map.put(server.pending, id, :initialize)
      %{server | pending: pending}
    rescue
      e ->
        Logger.error("Failed to start MCP server #{server_name(server)}: #{Exception.message(e)}")
        %{server | status: :error}
    end
  end

  defp start_server(%{transport: "http"} = server) do
    url = field(server.config, :url)

    if url && url != "" do
      request = init_request(System.unique_integer([:positive]))

      case http_post(url, request) do
        {:ok, response} ->
          server = process_init_response(server, response)
          # Discover tools
          discover_http_tools(server, url)

        {:error, reason} ->
          Logger.error("Failed to connect to HTTP MCP server #{server_name(server)}: #{inspect(reason)}")
          %{server | status: :error}
      end
    else
      Logger.error("HTTP MCP server #{server_name(server)} has no URL")
      %{server | status: :error}
    end
  end

  defp start_server(server) do
    Logger.error("Unknown transport for MCP server #{server_name(server)}: #{server.transport}")
    %{server | status: :error}
  end

  defp stop_server(%{port: port} = _server) when is_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp stop_server(_server), do: :ok

  defp maybe_retry(%{retries: retries} = server, id) when retries < @max_retries do
    delay = Enum.at(@retry_delays, retries, List.last(@retry_delays))
    Logger.info("Retrying MCP server #{server_name(server)} in #{delay}ms (attempt #{retries + 1}/#{@max_retries})")
    Process.send_after(self(), {:retry_start, id}, delay)
    %{server | retries: retries + 1, status: :retrying}
  end

  defp maybe_retry(server, _id) do
    Logger.error("MCP server #{server_name(server)} failed after #{@max_retries} retries")
    %{server | status: :failed}
  end

  # ── Stdio I/O ───────────────────────────────────────────────────────────────

  defp handle_port_data(server, data, id, state) do
    buffer = server.buffer <> data

    if byte_size(buffer) > @max_buffer_size do
      Logger.warning("MCP server #{server_name(server)} buffer overflow, dropping")
      {%{server | buffer: ""}, state}
    else
      process_buffer(%{server | buffer: buffer}, id, state)
    end
  end

  defp process_buffer(server, id, state) do
    case String.split(server.buffer, "\n", parts: 2) do
      [complete, rest] ->
        server = %{server | buffer: rest}
        server = process_line(server, String.trim(complete))
        process_buffer(server, id, state)

      [_incomplete] ->
        {server, state}
    end
  end

  defp process_line(server, ""), do: server

  defp process_line(server, line) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = response} ->
        dispatch_response(server, id, response)

      {:ok, _notification} ->
        # Notifications (no id) — ignore for now
        server

      {:error, _} ->
        Logger.debug("MCP server #{server_name(server)}: non-JSON line: #{String.slice(line, 0, 100)}")
        server
    end
  end

  defp dispatch_response(server, id, response) do
    case Map.pop(server.pending, id) do
      {nil, _} ->
        server

      {:initialize, pending} ->
        server = %{server | pending: pending}
        server = process_init_response(server, response)

        # Now discover tools
        {tid, server} = next_id(server)
        request = tools_list_request(tid)
        send_to_port(server.port, request)
        %{server | pending: Map.put(server.pending, tid, :tools_list)}

      {:tools_list, pending} ->
        server = %{server | pending: pending}
        process_tools_response(server, response)

      {:call_tool, pending} ->
        %{server | pending: pending, last_call_result: response}
    end
  end

  defp process_init_response(server, response) do
    if response["error"] do
      Logger.error("MCP server #{server_name(server)} initialize failed: #{inspect(response["error"])}")
      %{server | status: :error}
    else
      %{server | status: :running}
    end
  end

  defp process_tools_response(server, response) do
    if response["error"] do
      Logger.warning("MCP server #{server_name(server)} tools/list failed: #{inspect(response["error"])}")
      server
    else
      raw_tools = get_in(response, ["result", "tools"]) || []
      prefix = field(server.config, :prefix)

      tools =
        Enum.map(raw_tools, fn tool ->
          prefixed_name = "#{prefix}::#{tool["name"]}"

          %{
            "name" => prefixed_name,
            "original_name" => tool["name"],
            "description" => tool["description"],
            "inputSchema" => tool["inputSchema"],
            "outputSchema" => tool["outputSchema"],
            "annotations" => tool["annotations"],
            "icon" => tool["icon"]
          }
        end)

      Logger.info("MCP server #{server_name(server)} discovered #{length(tools)} tools")
      %{server | tools: tools, status: :running}
    end
  end

  defp send_to_port(port, request) when is_port(port) do
    data = Jason.encode!(request) <> "\n"
    Port.command(port, data)
  rescue
    e -> Logger.error("Failed to send to MCP port: #{Exception.message(e)}")
  end

  defp send_to_port(nil, _request), do: :ok

  # ── HTTP transport ──────────────────────────────────────────────────────────

  defp discover_http_tools(server, url) do
    request = tools_list_request(System.unique_integer([:positive]))

    case http_post(url, request) do
      {:ok, response} ->
        process_tools_response(server, response)

      {:error, reason} ->
        Logger.warning("MCP server #{server_name(server)} tools/list failed: #{inspect(reason)}")
        server
    end
  end

  defp http_post(url, body) do
    headers = %{"content-type" => "application/json", "accept" => "application/json, text/event-stream"}

    case Req.post(url, json: body, headers: headers, receive_timeout: @call_timeout) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_http_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_http_response(%{} = map), do: {:ok, map}

  defp parse_http_response(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, _} = ok -> ok
      {:error, _} -> parse_sse_response(bin)
    end
  end

  defp parse_http_response(other), do: {:ok, other}

  defp parse_sse_response(text) do
    data_lines =
      text
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&(&1 |> String.trim_leading("data:") |> String.trim()))
      |> Enum.reject(&(&1 == ""))

    case data_lines do
      [] -> {:error, "Could not parse SSE response"}
      lines -> Jason.decode(Enum.join(lines, ""))
    end
  end

  # ── Tool call routing ───────────────────────────────────────────────────────

  defp do_call_tool(state, name, args) do
    case find_server_for_tool(state, name) do
      {_id, %{transport: "stdio", port: port} = server} when is_port(port) ->
        call_stdio_tool(server, name, args)

      {_id, %{transport: "http"} = server} ->
        call_http_tool(server, name, args)

      {_id, _server} ->
        {:error, "MCP server for #{name} is not running"}

      nil ->
        {:error, "No MCP server handles tool #{name}"}
    end
  end

  defp call_stdio_tool(server, name, args) do
    # Find original tool name (without prefix)
    original_name = original_tool_name(server, name)
    {id, server} = next_id(server)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => original_name, "arguments" => args}
    }

    send_to_port(server.port, request)

    # For stdio, we can't synchronously wait. We'll use a receive pattern
    # to wait for the response from the port.
    receive_stdio_response(server.port, id, @call_timeout)
  end

  defp call_http_tool(server, name, args) do
    url = field(server.config, :url)
    original_name = original_tool_name(server, name)

    request = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{"name" => original_name, "arguments" => args}
    }

    case http_post(url, request) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_stdio_response(port, request_id, timeout) do
    # Collect data from port until we get a complete JSON-RPC response
    # with the matching request ID
    collect_stdio_response(port, request_id, "", timeout, System.monotonic_time(:millisecond))
  end

  defp collect_stdio_response(port, request_id, buffer, timeout, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    remaining = max(timeout - elapsed, 0)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          buffer = buffer <> data

          case try_extract_response(buffer, request_id) do
            {:ok, response, _rest} ->
              result = response["result"] || response["error"]

              if response["error"] do
                {:error, result}
              else
                {:ok, result}
              end

            :incomplete ->
              collect_stdio_response(port, request_id, buffer, timeout, start_time)
          end

        {^port, {:exit_status, status}} ->
          {:error, "MCP server exited with status #{status}"}
      after
        remaining ->
          {:error, :timeout}
      end
    end
  end

  defp try_extract_response(buffer, request_id) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        case Jason.decode(String.trim(line)) do
          {:ok, %{"id" => ^request_id} = response} ->
            {:ok, response, rest}

          {:ok, _other} ->
            # Not our response, keep looking
            try_extract_response(rest, request_id)

          {:error, _} ->
            try_extract_response(rest, request_id)
        end

      [_incomplete] ->
        :incomplete
    end
  end

  defp find_server_for_tool(state, tool_name) do
    Enum.find(state.servers, fn {_id, server} ->
      server.status == :running &&
        Enum.any?(server.tools, &(&1["name"] == tool_name))
    end)
  end

  defp original_tool_name(server, name) do
    case Enum.find(server.tools, &(&1["name"] == name)) do
      %{"original_name" => original} -> original
      _ -> name
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp init_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @mcp_protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "backplane-host-agent", "version" => @agent_version}
      }
    }
  end

  defp tools_list_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/list",
      "params" => %{}
    }
  end

  defp next_id(server) do
    id = server.next_id
    {id, %{server | next_id: id + 1}}
  end

  defp field(map, key) do
    Map.get(map, key, Map.get(map, to_string(key)))
  end

  defp server_id(config), do: field(config, :id) || field(config, :name)
  defp server_name(%{config: config}), do: field(config, :name) || field(config, :prefix) || "unknown"
  defp server_enabled?(config), do: field(config, :enabled) != false

  defp config_changed?(old, new) do
    # Compare the fields that matter for server identity
    fields = [:transport, :command, :args, :env, :url, :prefix]

    Enum.any?(fields, fn f ->
      field(old, f) != field(new, f)
    end)
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> command
      path -> path
    end
  end

  defp find_server_by_port(state, port) do
    Enum.find(state.servers, fn {_id, s} -> s.port == port end)
  end

  defp build_env(nil), do: []
  defp build_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end
  defp build_env(env) when is_list(env), do: env
  defp build_env(_), do: []
end
