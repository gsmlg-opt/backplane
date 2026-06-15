defmodule BackplaneWeb.McpInspectorLive do
  @moduledoc """
  Interactive MCP inspector for probing MCP servers.
  Supports HTTP (Streamable HTTP) and stdio transports, plus an internal
  tab for testing managed services and upstream MCP tools via the registry.
  """
  use BackplaneWeb, :live_view

  alias Backplane.Settings.Credentials
  alias Backplane.Registry.Namespace
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Transport.McpHandler

  @json_rpc_version "2.0"
  # 10 MB buffer cap
  @max_buffer_size 10_000_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/mcp/inspector",
       # Transport: "http" | "stdio"
       transport: "http",
       # HTTP fields
       url: "",
       credential: "",
       auth_scheme: "none",
       credential_options: load_credential_options(),
       # Stdio fields
       command: "",
       args: "",
       env: "",
       # Connection state
       connected: false,
       loading: false,
       error: nil,
       server_info: nil,
       # Tools
       tools: [],
       expanded_tools: MapSet.new(),
       # Per-tool call state: %{tool_name => %{args: "...", result: ..., loading: bool}}
       tool_calls: %{},
       # Stdio port state
       port: nil,
       buffer: "",
       pending_requests: %{},
       next_id: 1,
       # Request log
       request_log: [],
       # Internal tab state
       sources: [],
       internal_source: "",
       internal_connected: false,
       internal_source_info: nil,
       internal_tools: [],
       internal_expanded_tools: MapSet.new(),
       internal_tool_calls: %{},
       internal_loading: false,
       internal_error: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :internal}} = socket) do
    {:noreply, load_sources(socket)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("update_config", params, socket) do
    transport = params["transport"] || socket.assigns.transport
    transport_changed = transport != socket.assigns.transport

    socket =
      if transport_changed do
        socket = maybe_close_port(socket)

        assign(socket,
          connected: false,
          server_info: nil,
          tools: [],
          expanded_tools: MapSet.new(),
          tool_calls: %{},
          error: nil,
          request_log: []
        )
      else
        socket
      end

    {:noreply,
     assign(socket,
       transport: transport,
       url: params["url"] || socket.assigns.url,
       auth_scheme: params["auth_scheme"] || socket.assigns.auth_scheme,
       credential: params["credential"] || socket.assigns.credential,
       command: params["command"] || socket.assigns.command,
       args: params["args"] || socket.assigns.args,
       env: params["env"] || socket.assigns.env
     )}
  end

  def handle_event("connect", _params, socket) do
    socket = assign(socket, loading: true, error: nil)

    case socket.assigns.transport do
      "http" -> handle_http_connect(socket)
      "stdio" -> handle_stdio_connect(socket)
    end
  end

  def handle_event("disconnect", _params, socket) do
    socket = maybe_close_port(socket)

    {:noreply,
     assign(socket,
       connected: false,
       server_info: nil,
       tools: [],
       expanded_tools: MapSet.new(),
       tool_calls: %{},
       error: nil
     )}
  end

  def handle_event("list_tools", _params, socket) do
    socket = assign(socket, loading: true, error: nil)

    case socket.assigns.transport do
      "http" -> handle_http_list_tools(socket)
      "stdio" -> handle_stdio_list_tools(socket)
    end
  end

  def handle_event("toggle_tool", %{"name" => name}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_tools, name) do
        MapSet.delete(socket.assigns.expanded_tools, name)
      else
        MapSet.put(socket.assigns.expanded_tools, name)
      end

    {:noreply, assign(socket, expanded_tools: expanded)}
  end

  def handle_event("expand_all", _params, socket) do
    all_names = Enum.map(socket.assigns.tools, & &1["name"]) |> MapSet.new()
    {:noreply, assign(socket, expanded_tools: all_names)}
  end

  def handle_event("collapse_all", _params, socket) do
    {:noreply, assign(socket, expanded_tools: MapSet.new())}
  end

  def handle_event("update_tool_args", %{"tool_name" => name, "tool_args" => args}, socket) do
    tool_calls =
      Map.update(
        socket.assigns.tool_calls,
        name,
        %{args: args, result: nil, loading: false},
        fn tc ->
          %{tc | args: args}
        end
      )

    {:noreply, assign(socket, tool_calls: tool_calls)}
  end

  def handle_event("call_tool", %{"tool_name" => name}, socket) do
    tc = Map.get(socket.assigns.tool_calls, name, %{args: "{}", result: nil, loading: false})

    case Jason.decode(tc.args) do
      {:ok, args} when is_map(args) ->
        tool_calls = Map.put(socket.assigns.tool_calls, name, %{tc | loading: true, result: nil})
        socket = assign(socket, tool_calls: tool_calls)

        case socket.assigns.transport do
          "http" -> handle_http_call_tool(socket, name, args)
          "stdio" -> handle_stdio_call_tool(socket, name, args)
        end

      {:ok, _} ->
        {:noreply, assign(socket, error: "Arguments must be a JSON object")}

      {:error, _} ->
        {:noreply, assign(socket, error: "Invalid JSON in arguments")}
    end
  end

  def handle_event("ping", _params, socket) do
    case socket.assigns.transport do
      "http" ->
        request = jsonrpc_request("ping", %{})
        socket = send_http_request(socket, request, fn _resp -> %{} end)
        {:noreply, socket}

      "stdio" ->
        request = jsonrpc_request("ping", %{})
        {id, socket} = next_request_id(socket)
        request = Map.put(request, "id", id)

        case send_stdio(socket.assigns.port, request) do
          :ok ->
            pending = Map.put(socket.assigns.pending_requests, id, {:ping, nil})
            log_entry = make_log_entry("ping", request, nil, :pending)

            {:noreply,
             assign(socket,
               pending_requests: pending,
               request_log: [log_entry | socket.assigns.request_log]
             )}

          {:error, reason} ->
            {:noreply, assign(socket, error: "Send failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("clear_log", _params, socket) do
    {:noreply, assign(socket, request_log: [], error: nil)}
  end

  # ── Internal tab events ──────────────────────────────────────────────────────

  def handle_event("update_internal_config", params, socket) do
    source = params["source"] || socket.assigns.internal_source
    source_changed = source != socket.assigns.internal_source

    socket =
      if source_changed do
        assign(socket,
          internal_connected: false,
          internal_source_info: nil,
          internal_tools: [],
          internal_expanded_tools: MapSet.new(),
          internal_tool_calls: %{},
          internal_error: nil
        )
      else
        socket
      end

    {:noreply, assign(socket, internal_source: source)}
  end

  def handle_event("internal_connect", _params, socket) do
    source_key = socket.assigns.internal_source

    if source_key == "" do
      {:noreply, assign(socket, internal_error: "Please select a source")}
    else
      source = Enum.find(socket.assigns.sources, &(&1.key == source_key))

      if source do
        {:noreply,
         assign(socket,
           internal_connected: true,
           internal_source_info: source,
           internal_tools: [],
           internal_expanded_tools: MapSet.new(),
           internal_tool_calls: %{},
           internal_error: nil
         )}
      else
        {:noreply, assign(socket, internal_error: "Source not found")}
      end
    end
  end

  def handle_event("internal_disconnect", _params, socket) do
    {:noreply,
     assign(socket,
       internal_connected: false,
       internal_source_info: nil,
       internal_tools: [],
       internal_expanded_tools: MapSet.new(),
       internal_tool_calls: %{},
       internal_error: nil
     )}
  end

  def handle_event("internal_list_tools", _params, socket) do
    source_key = socket.assigns.internal_source
    all_tools = safe_call(fn -> ToolRegistry.list_all() end, [])

    filtered =
      Enum.filter(all_tools, fn tool ->
        source_key_for_tool(tool) == source_key
      end)

    tool_calls =
      Map.new(filtered, fn t ->
        {t.name, %{args: tool_args_template_from_struct(t), result: nil, loading: false}}
      end)

    {:noreply,
     assign(socket,
       internal_tools: filtered,
       internal_tool_calls: tool_calls,
       internal_expanded_tools: MapSet.new(),
       internal_error: nil
     )}
  end

  def handle_event("toggle_internal_tool", %{"name" => name}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.internal_expanded_tools, name) do
        MapSet.delete(socket.assigns.internal_expanded_tools, name)
      else
        MapSet.put(socket.assigns.internal_expanded_tools, name)
      end

    {:noreply, assign(socket, internal_expanded_tools: expanded)}
  end

  def handle_event("expand_all_internal", _params, socket) do
    all_names = Enum.map(socket.assigns.internal_tools, & &1.name) |> MapSet.new()
    {:noreply, assign(socket, internal_expanded_tools: all_names)}
  end

  def handle_event("collapse_all_internal", _params, socket) do
    {:noreply, assign(socket, internal_expanded_tools: MapSet.new())}
  end

  def handle_event(
        "update_internal_tool_args",
        %{"tool_name" => name, "tool_args" => args},
        socket
      ) do
    tool_calls =
      Map.update(
        socket.assigns.internal_tool_calls,
        name,
        %{args: args, result: nil, loading: false},
        fn tc -> %{tc | args: args} end
      )

    {:noreply, assign(socket, internal_tool_calls: tool_calls)}
  end

  def handle_event("call_internal_tool", %{"tool_name" => name}, socket) do
    tc =
      Map.get(socket.assigns.internal_tool_calls, name, %{args: "{}", result: nil, loading: false})

    case Jason.decode(tc.args) do
      {:ok, args} when is_map(args) ->
        tool_calls =
          Map.put(socket.assigns.internal_tool_calls, name, %{tc | loading: true, result: nil})

        socket = assign(socket, internal_tool_calls: tool_calls, internal_error: nil)

        case McpHandler.dispatch_tool_call(name, args) do
          {:ok, result} ->
            tool_calls =
              Map.update!(socket.assigns.internal_tool_calls, name, fn tc ->
                %{tc | result: %{status: :ok, data: result}, loading: false}
              end)

            {:noreply, assign(socket, internal_tool_calls: tool_calls)}

          {:error, message} ->
            tool_calls =
              Map.update!(socket.assigns.internal_tool_calls, name, fn tc ->
                %{tc | result: %{status: :error, data: message}, loading: false}
              end)

            {:noreply, assign(socket, internal_tool_calls: tool_calls)}
        end

      {:ok, _} ->
        {:noreply, assign(socket, internal_error: "Arguments must be a JSON object")}

      {:error, _} ->
        {:noreply, assign(socket, internal_error: "Invalid JSON in arguments")}
    end
  end

  # ── Stdio Port messages ────────────────────────────────────────────────────

  @impl true
  def handle_info({port, {:data, data}}, %{assigns: %{port: port}} = socket) do
    {:noreply, handle_stdio_data(socket, data)}
  end

  def handle_info({port, {:exit_status, status}}, %{assigns: %{port: port}} = socket) do
    {:noreply,
     assign(socket,
       port: nil,
       buffer: "",
       connected: false,
       pending_requests: %{},
       error: "MCP process exited (status #{status})"
     )}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ── HTTP transport ─────────────────────────────────────────────────────────

  defp handle_http_connect(socket) do
    request =
      jsonrpc_request("initialize", %{
        "protocolVersion" => Backplane.MCP.Info.protocol_version(),
        "capabilities" => %{},
        "clientInfo" => %{"name" => "Backplane Inspector", "version" => "1.0.0"}
      })

    socket =
      send_http_request(socket, request, fn response ->
        server_info = get_in(response, ["result", "serverInfo"])
        capabilities = get_in(response, ["result", "capabilities"])
        %{server_info: %{info: server_info, capabilities: capabilities}, connected: true}
      end)

    {:noreply, socket}
  end

  defp handle_http_list_tools(socket) do
    request = jsonrpc_request("tools/list", %{})

    socket =
      send_http_request(socket, request, fn response ->
        tools = get_in(response, ["result", "tools"]) || []

        tool_calls =
          Map.new(tools, fn t ->
            {t["name"], %{args: tool_args_template(t), result: nil, loading: false}}
          end)

        %{tools: tools, tool_calls: tool_calls, expanded_tools: MapSet.new()}
      end)

    {:noreply, socket}
  end

  defp handle_http_call_tool(socket, name, args) do
    request = jsonrpc_request("tools/call", %{"name" => name, "arguments" => args})

    socket =
      send_http_request(socket, request, fn response ->
        result = response["result"] || response["error"]

        tool_calls =
          Map.update!(socket.assigns.tool_calls, name, fn tc ->
            %{tc | result: result, loading: false}
          end)

        %{tool_calls: tool_calls}
      end)

    {:noreply, socket}
  end

  defp send_http_request(socket, request, on_success) do
    url = String.trim(socket.assigns.url)

    if url == "" do
      assign(socket, error: "Please enter an MCP server URL", loading: false)
    else
      headers = build_http_headers(socket.assigns)
      request_json = Jason.encode!(request, pretty: true)

      case do_http_post(url, request, headers) do
        {:ok, response} ->
          response_json = Jason.encode!(response, pretty: true)

          log_entry =
            make_log_entry(
              request["method"],
              request_json,
              response_json,
              if(response["error"], do: :error, else: :ok)
            )

          updates = on_success.(response)

          socket
          |> assign(loading: false)
          |> assign(request_log: [log_entry | socket.assigns.request_log])
          |> assign(Map.to_list(updates))

        {:error, reason} ->
          log_entry = make_log_entry(request["method"], request_json, inspect(reason), :error)

          socket
          |> assign(
            loading: false,
            error: "Request failed: #{inspect(reason)}",
            request_log: [log_entry | socket.assigns.request_log]
          )
      end
    end
  end

  defp build_http_headers(assigns) do
    base = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]

    case {assigns.auth_scheme, assigns.credential} do
      {_, ""} ->
        base

      {"none", _} ->
        base

      {"bearer", cred_name} ->
        case Credentials.fetch(cred_name) do
          {:ok, token} -> base ++ [{"authorization", "Bearer #{token}"}]
          _ -> base
        end

      {"x_api_key", cred_name} ->
        case Credentials.fetch(cred_name) do
          {:ok, key} -> base ++ [{"x-api-key", key}]
          _ -> base
        end

      _ ->
        base
    end
  end

  defp do_http_post(url, body, headers) do
    req_headers = Map.new(headers)

    case Req.post(url, json: body, headers: req_headers, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_mcp_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Response is already decoded JSON (Req auto-decodes application/json)
  defp parse_mcp_response(%{} = map), do: {:ok, map}

  # Response is a binary — could be raw JSON or SSE format
  defp parse_mcp_response(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, map} ->
        {:ok, map}

      {:error, _} ->
        # Try parsing as SSE: extract data from "data: {...}" lines
        case extract_sse_data(bin) do
          {:ok, json_str} -> Jason.decode(json_str)
          :error -> {:error, "Could not parse response: #{String.slice(bin, 0, 200)}"}
        end
    end
  end

  defp parse_mcp_response(other), do: {:ok, other}

  # Extract JSON payload from SSE-formatted response.
  # Handles single and multi-line data fields.
  defp extract_sse_data(sse_text) do
    data_lines =
      sse_text
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn line ->
        line |> String.trim_leading("data:") |> String.trim()
      end)
      |> Enum.reject(&(&1 == ""))

    case data_lines do
      [] -> :error
      lines -> {:ok, Enum.join(lines, "")}
    end
  end

  # ── Stdio transport ────────────────────────────────────────────────────────

  defp handle_stdio_connect(socket) do
    command = String.trim(socket.assigns.command)

    if command == "" do
      {:noreply, assign(socket, error: "Please enter a command", loading: false)}
    else
      args = parse_args(socket.assigns.args)
      env = parse_env(socket.assigns.env)

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

        socket = assign(socket, port: port, buffer: "", pending_requests: %{}, next_id: 1)

        # Send initialize request
        request =
          jsonrpc_request("initialize", %{
            "protocolVersion" => Backplane.MCP.Info.protocol_version(),
            "capabilities" => %{},
            "clientInfo" => %{"name" => "Backplane Inspector", "version" => "1.0.0"}
          })

        {id, socket} = next_request_id(socket)
        request = Map.put(request, "id", id)

        case send_stdio(port, request) do
          :ok ->
            pending = Map.put(socket.assigns.pending_requests, id, {:initialize, nil})
            log_entry = make_log_entry("initialize", request, nil, :pending)

            {:noreply,
             assign(socket,
               pending_requests: pending,
               request_log: [log_entry | socket.assigns.request_log]
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket, error: "Failed to send: #{inspect(reason)}", loading: false)}
        end
      rescue
        e ->
          {:noreply,
           assign(socket, error: "Failed to start: #{Exception.message(e)}", loading: false)}
      end
    end
  end

  defp handle_stdio_list_tools(socket) do
    if socket.assigns.port == nil do
      {:noreply, assign(socket, error: "Not connected", loading: false)}
    else
      request = jsonrpc_request("tools/list", %{})
      {id, socket} = next_request_id(socket)
      request = Map.put(request, "id", id)

      case send_stdio(socket.assigns.port, request) do
        :ok ->
          pending = Map.put(socket.assigns.pending_requests, id, {:list_tools, nil})
          log_entry = make_log_entry("tools/list", request, nil, :pending)

          {:noreply,
           assign(socket,
             pending_requests: pending,
             request_log: [log_entry | socket.assigns.request_log]
           )}

        {:error, reason} ->
          {:noreply, assign(socket, error: "Send failed: #{inspect(reason)}", loading: false)}
      end
    end
  end

  defp handle_stdio_call_tool(socket, name, args) do
    if socket.assigns.port == nil do
      {:noreply, assign(socket, error: "Not connected")}
    else
      request = jsonrpc_request("tools/call", %{"name" => name, "arguments" => args})
      {id, socket} = next_request_id(socket)
      request = Map.put(request, "id", id)

      case send_stdio(socket.assigns.port, request) do
        :ok ->
          pending = Map.put(socket.assigns.pending_requests, id, {:call_tool, name})
          log_entry = make_log_entry("tools/call", request, nil, :pending)

          {:noreply,
           assign(socket,
             pending_requests: pending,
             request_log: [log_entry | socket.assigns.request_log]
           )}

        {:error, reason} ->
          tool_calls =
            Map.update!(socket.assigns.tool_calls, name, fn tc -> %{tc | loading: false} end)

          {:noreply,
           assign(socket, error: "Send failed: #{inspect(reason)}", tool_calls: tool_calls)}
      end
    end
  end

  defp handle_stdio_data(socket, data) do
    buffer = socket.assigns.buffer <> data

    if byte_size(buffer) > @max_buffer_size do
      assign(socket, buffer: "", error: "Buffer overflow — dropped")
    else
      split_and_process_stdio(socket, buffer)
    end
  end

  defp split_and_process_stdio(socket, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [complete, rest] ->
        socket = %{socket | assigns: %{socket.assigns | buffer: ""}}
        socket = process_stdio_message(socket, complete)
        split_and_process_stdio(socket, rest)

      [_incomplete] ->
        assign(socket, buffer: buffer)
    end
  end

  defp process_stdio_message(socket, message) when byte_size(message) == 0, do: socket

  defp process_stdio_message(socket, message) do
    case Jason.decode(message) do
      {:ok, %{"id" => id} = response} ->
        dispatch_stdio_response(socket, id, response)

      {:ok, _} ->
        socket

      {:error, _} ->
        assign(socket, error: "Failed to decode response")
    end
  end

  defp dispatch_stdio_response(socket, id, response) do
    case Map.pop(socket.assigns.pending_requests, id) do
      {nil, _} ->
        socket

      {{:initialize, _}, pending} ->
        response_json = Jason.encode!(response, pretty: true)

        log_entry =
          make_log_entry(
            "initialize",
            nil,
            response_json,
            if(response["error"], do: :error, else: :ok)
          )

        server_info =
          if response["result"] do
            %{
              info: get_in(response, ["result", "serverInfo"]),
              capabilities: get_in(response, ["result", "capabilities"])
            }
          end

        assign(socket,
          pending_requests: pending,
          loading: false,
          connected: response["error"] == nil,
          server_info: server_info,
          request_log: [log_entry | socket.assigns.request_log]
        )

      {{:list_tools, _}, pending} ->
        response_json = Jason.encode!(response, pretty: true)

        log_entry =
          make_log_entry(
            "tools/list",
            nil,
            response_json,
            if(response["error"], do: :error, else: :ok)
          )

        tools = get_in(response, ["result", "tools"]) || []

        tool_calls =
          Map.new(tools, fn t ->
            {t["name"], %{args: tool_args_template(t), result: nil, loading: false}}
          end)

        assign(socket,
          pending_requests: pending,
          loading: false,
          tools: tools,
          tool_calls: tool_calls,
          expanded_tools: MapSet.new(),
          request_log: [log_entry | socket.assigns.request_log]
        )

      {{:call_tool, tool_name}, pending} ->
        response_json = Jason.encode!(response, pretty: true)

        log_entry =
          make_log_entry(
            "tools/call (#{tool_name})",
            nil,
            response_json,
            if(response["error"], do: :error, else: :ok)
          )

        result = response["result"] || response["error"]

        tool_calls =
          Map.update!(socket.assigns.tool_calls, tool_name, fn tc ->
            %{tc | result: result, loading: false}
          end)

        assign(socket,
          pending_requests: pending,
          tool_calls: tool_calls,
          request_log: [log_entry | socket.assigns.request_log]
        )

      {{:ping, _}, pending} ->
        response_json = Jason.encode!(response, pretty: true)

        log_entry =
          make_log_entry("ping", nil, response_json, if(response["error"], do: :error, else: :ok))

        assign(socket,
          pending_requests: pending,
          request_log: [log_entry | socket.assigns.request_log]
        )
    end
  end

  defp send_stdio(port, request) when is_port(port) do
    data = Jason.encode!(request) <> "\n"
    Port.command(port, data)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp send_stdio(nil, _request), do: {:error, :not_connected}

  defp maybe_close_port(socket) do
    if socket.assigns.port do
      try do
        Port.close(socket.assigns.port)
      rescue
        _ -> :ok
      end
    end

    assign(socket,
      port: nil,
      buffer: "",
      pending_requests: %{},
      connected: false
    )
  end

  # ── Shared helpers ─────────────────────────────────────────────────────────

  defp load_credential_options do
    creds = safe_call(fn -> Credentials.list() end, [])

    [{"", "— None —"}] ++
      Enum.map(creds, fn c -> {c.name, "#{c.name} (#{c.kind})"} end)
  end

  defp jsonrpc_request(method, params) do
    %{
      "jsonrpc" => @json_rpc_version,
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }
  end

  defp next_request_id(socket) do
    id = socket.assigns.next_id
    {id, assign(socket, next_id: id + 1)}
  end

  defp make_log_entry(method, request, response, status) do
    %{
      method: method,
      request:
        if(is_binary(request), do: request, else: request && Jason.encode!(request, pretty: true)),
      response: response,
      status: status,
      at: DateTime.utc_now()
    }
  end

  defp tool_args_template(nil), do: "{}"

  defp tool_args_template(%{"inputSchema" => %{"properties" => props}}) when is_map(props) do
    template =
      Map.new(props, fn {key, schema} ->
        {key, schema_placeholder(schema)}
      end)

    Jason.encode!(template, pretty: true)
  end

  defp tool_args_template(_), do: "{}"

  defp schema_placeholder(%{"type" => "string"}), do: ""
  defp schema_placeholder(%{"type" => "number"}), do: 0
  defp schema_placeholder(%{"type" => "integer"}), do: 0
  defp schema_placeholder(%{"type" => "boolean"}), do: false
  defp schema_placeholder(%{"type" => "array"}), do: []
  defp schema_placeholder(%{"type" => "object"}), do: %{}
  defp schema_placeholder(_), do: nil

  defp parse_args(args_str) do
    args_str
    |> String.trim()
    |> case do
      "" -> []
      s -> String.split(s, ~r/\s+/)
    end
  end

  defp parse_env(env_str) do
    env_str
    |> String.trim()
    |> case do
      "" ->
        []

      s ->
        s
        |> String.split("\n")
        |> Enum.map(fn line ->
          case String.split(line, "=", parts: 2) do
            [k, v] -> {String.to_charlist(String.trim(k)), String.to_charlist(String.trim(v))}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> command
      path -> path
    end
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp format_time(datetime) do
    assigns = %{datetime: datetime}

    ~H"""
    <.local_time datetime={@datetime} format="time" />
    """
  end

  defp tool_expanded?(expanded_tools, name) do
    MapSet.member?(expanded_tools, name)
  end

  defp get_tool_call(tool_calls, name) do
    Map.get(tool_calls, name, %{args: "{}", result: nil, loading: false})
  end

  defp schema_type_label(%{"type" => type}), do: type
  defp schema_type_label(_), do: "any"

  defp required_properties(%{"inputSchema" => %{"required" => required}}) when is_list(required),
    do: required

  defp required_properties(_), do: []

  # ── Internal tab helpers ───────────────────────────────────────────────────

  defp load_sources(socket) do
    all_tools = safe_call(fn -> ToolRegistry.list_all() end, [])

    sources =
      all_tools
      |> Enum.group_by(&source_tuple_for_tool/1)
      |> Enum.map(fn {{type, prefix}, tools} ->
        %{type: type, prefix: prefix, tool_count: length(tools), key: "#{type}:#{prefix}"}
      end)
      |> Enum.sort_by(fn s -> {source_type_order(s.type), s.prefix} end)

    assign(socket, sources: sources)
  end

  defp source_type_order(:managed), do: 0
  defp source_type_order(:upstream), do: 1
  defp source_type_order(:native), do: 2

  defp source_tuple_for_tool(tool) do
    case tool.origin do
      {:managed, prefix} -> {:managed, prefix}
      {:upstream, prefix} -> {:upstream, Namespace.normalize_prefix(prefix)}
      :native -> {:native, "native"}
    end
  end

  defp source_key_for_tool(tool) do
    {type, prefix} = source_tuple_for_tool(tool)
    "#{type}:#{prefix}"
  end

  defp source_label(%{type: :managed, prefix: prefix}), do: "#{prefix}:: (managed)"
  defp source_label(%{type: :upstream, prefix: prefix}), do: "#{prefix}:: (upstream)"
  defp source_label(%{type: :native, prefix: prefix}), do: "#{prefix} (native)"

  defp source_type_badge(:managed), do: "info"
  defp source_type_badge(:upstream), do: "success"
  defp source_type_badge(:native), do: "warning"

  defp tool_args_template_from_struct(%{
         input_schema: %{"properties" => props, "required" => required}
       })
       when is_map(props) and is_list(required) do
    template =
      props
      |> Map.take(required)
      |> Map.new(fn {key, schema} -> {key, schema_placeholder(schema)} end)

    Jason.encode!(template, pretty: true)
  end

  defp tool_args_template_from_struct(%{input_schema: %{"properties" => props}})
       when is_map(props) do
    template =
      Map.new(props, fn {key, schema} ->
        {key, schema_placeholder(schema)}
      end)

    Jason.encode!(template, pretty: true)
  end

  defp tool_args_template_from_struct(_), do: "{}"

  defp internal_tool_required_properties(%{input_schema: %{"required" => required}})
       when is_list(required),
       do: required

  defp internal_tool_required_properties(_), do: []

  # ── Template ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">MCP Inspector</h1>
        <p class="mt-1 text-sm text-on-surface-variant">
          Test and probe MCP tools — connect to external servers or test internal registered tools.
        </p>
      </div>

      <%!-- Tab bar --%>
      <div class="flex gap-1 mb-6 border-b border-outline-variant">
        <.link
          navigate={~p"/admin/mcp/inspector"}
          class={[
            "px-4 py-2.5 text-sm font-medium transition-colors border-b-2 -mb-px",
            @live_action == :index && "border-primary text-primary",
            @live_action != :index && "border-transparent text-on-surface-variant hover:text-on-surface hover:border-outline"
          ]}
        >
          <.dm_mdi name="access-point-network" class="w-4 h-4 mr-1.5 inline-block align-text-bottom" />
          External
        </.link>
        <.link
          navigate={~p"/admin/mcp/inspector/internal"}
          class={[
            "px-4 py-2.5 text-sm font-medium transition-colors border-b-2 -mb-px",
            @live_action == :internal && "border-primary text-primary",
            @live_action != :internal && "border-transparent text-on-surface-variant hover:text-on-surface hover:border-outline"
          ]}
        >
          <.dm_mdi name="toolbox-outline" class="w-4 h-4 mr-1.5 inline-block align-text-bottom" />
          Internal
        </.link>
      </div>

      <%= case @live_action do %>
        <% :index -> %>
          <.render_external_tab {assigns} />
        <% :internal -> %>
          <.render_internal_tab {assigns} />
      <% end %>
    </div>
    """
  end

  # ── External tab (existing inspector) ──────────────────────────────────────

  defp render_external_tab(assigns) do
    ~H"""
      <.dm_card variant="bordered" class="mb-6">
        <:title>
          <div class="flex items-center gap-3">
            <span>Connection</span>
            <.dm_badge
              :if={@connected}
              variant="success"
              size="sm"
            >
              Connected
            </.dm_badge>
            <.dm_badge
              :if={!@connected}
              variant="ghost"
              size="sm"
            >
              Disconnected
            </.dm_badge>
          </div>
        </:title>
        <form phx-change="update_config" phx-submit="connect" class="space-y-4">
          <%!-- Transport selector --%>
          <div class="max-w-xs">
            <.dm_select
              id="inspector-transport"
              name="transport"
              label="Transport"
              options={[{"http", "HTTP (Streamable HTTP)"}, {"stdio", "Stdio (stdin/stdout)"}]}
              value={@transport}
            />
          </div>

          <%!-- HTTP fields --%>
          <div :if={@transport == "http"} class="space-y-4">
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div>
                <.dm_input
                  id="inspector-url"
                  name="url"
                  label="MCP Server URL"
                  value={@url}
                  placeholder="https://example.com/mcp"
                  phx-debounce="300"
                />
              </div>
              <div>
                <.dm_select
                  id="inspector-auth-scheme"
                  name="auth_scheme"
                  label="Auth Scheme"
                  options={[
                    {"none", "None"},
                    {"bearer", "Bearer Token"},
                    {"x_api_key", "X-API-Key"}
                  ]}
                  value={@auth_scheme}
                />
              </div>
            </div>
            <div :if={@auth_scheme != "none"} class="max-w-sm">
              <.dm_select
                id="inspector-credential"
                name="credential"
                label="Credential"
                options={@credential_options}
                value={@credential}
              />
            </div>
          </div>

          <%!-- Stdio fields --%>
          <div :if={@transport == "stdio"} class="space-y-4">
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div>
                <.dm_input
                  id="inspector-command"
                  name="command"
                  label="Command"
                  value={@command}
                  placeholder="npx"
                  phx-debounce="300"
                />
              </div>
              <div>
                <.dm_input
                  id="inspector-args"
                  name="args"
                  label="Arguments (space-separated)"
                  value={@args}
                  placeholder="-y @modelcontextprotocol/server-filesystem /tmp"
                  phx-debounce="300"
                />
              </div>
            </div>
            <div class="max-w-sm">
              <.dm_textarea
                id="inspector-env"
                name="env"
                label="Environment (KEY=VALUE per line)"
                value={@env}
                rows={3}
                class="font-mono text-xs"
                placeholder={"NODE_ENV=production\nAPI_KEY=xxx"}
                phx-debounce="300"
              />
            </div>
          </div>

          <%!-- Action buttons --%>
          <div class="flex flex-wrap gap-2 pt-1">
            <.dm_btn
              :if={!@connected}
              id="inspector-connect"
              size="sm"
              variant="primary"
              phx-click="connect"
              disabled={@loading}
            >
              <.dm_mdi name="power-plug" class="w-4 h-4 mr-1" />
              Initialize
            </.dm_btn>
            <.dm_btn
              :if={@connected}
              id="inspector-disconnect"
              size="sm"
              variant="outline"
              phx-click="disconnect"
            >
              <.dm_mdi name="power-plug-off" class="w-4 h-4 mr-1" />
              Disconnect
            </.dm_btn>
            <.dm_btn
              :if={@connected}
              id="inspector-list-tools"
              size="sm"
              variant="primary"
              phx-click="list_tools"
              disabled={@loading}
            >
              <.dm_mdi name="toolbox" class="w-4 h-4 mr-1" />
              List Tools
            </.dm_btn>
            <.dm_btn
              :if={@connected}
              id="inspector-ping"
              size="sm"
              phx-click="ping"
              disabled={@loading}
            >
              <.dm_mdi name="access-point-network" class="w-4 h-4 mr-1" />
              Ping
            </.dm_btn>
            <.dm_btn
              id="inspector-clear"
              size="sm"
              variant="outline"
              phx-click="clear_log"
            >
              <.dm_mdi name="delete-outline" class="w-4 h-4 mr-1" />
              Clear Log
            </.dm_btn>
          </div>

          <p :if={@loading} class="text-sm text-on-surface-variant flex items-center gap-2">
            <.dm_mdi name="loading" class="w-4 h-4 animate-spin" />
            Waiting for response…
          </p>
          <p :if={@error} class="text-sm text-error">{@error}</p>
        </form>
      </.dm_card>

      <%!-- Server info --%>
      <.dm_card :if={@server_info} variant="bordered" class="mb-6">
        <:title>Server Info</:title>
        <dl class="grid grid-cols-1 gap-x-6 gap-y-2 sm:grid-cols-3 text-sm">
          <div :if={@server_info.info}>
            <dt class="font-medium text-on-surface-variant">Name</dt>
            <dd>{@server_info.info["name"] || "—"}</dd>
          </div>
          <div :if={@server_info.info}>
            <dt class="font-medium text-on-surface-variant">Version</dt>
            <dd>{@server_info.info["version"] || "—"}</dd>
          </div>
          <div :if={@server_info.capabilities}>
            <dt class="font-medium text-on-surface-variant">Capabilities</dt>
            <dd class="font-mono text-xs break-all">
              {Map.keys(@server_info.capabilities || %{}) |> Enum.join(", ")}
            </dd>
          </div>
        </dl>
      </.dm_card>

      <%!-- Tools section --%>
      <div :if={@tools != []} class="mb-6">
        <div class="flex items-center justify-between mb-4">
          <div class="flex items-center gap-2">
            <h2 class="text-lg font-semibold">Tools</h2>
            <.dm_badge variant="ghost">{length(@tools)}</.dm_badge>
          </div>
          <div class="flex gap-2">
            <.dm_btn id="expand-all" size="sm" variant="outline" phx-click="expand_all">
              Expand All
            </.dm_btn>
            <.dm_btn id="collapse-all" size="sm" variant="outline" phx-click="collapse_all">
              Collapse All
            </.dm_btn>
          </div>
        </div>

        <div class="space-y-3">
          <div :for={tool <- @tools} class="border border-outline-variant rounded-lg overflow-hidden">
            <%!-- Tool header (always visible) --%>
            <div
              class="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-surface-container-high transition-colors select-none"
              phx-click="toggle_tool"
              phx-value-name={tool["name"]}
            >
              <.dm_mdi
                name={if tool_expanded?(@expanded_tools, tool["name"]), do: "chevron-down", else: "chevron-right"}
                class="w-5 h-5 shrink-0 text-on-surface-variant transition-transform"
              />
              <div class="flex-1 min-w-0">
                <span class="font-mono text-sm font-medium">{tool["name"]}</span>
                <p :if={tool["description"] && !tool_expanded?(@expanded_tools, tool["name"])} class="text-xs text-on-surface-variant mt-0.5 truncate">
                  {tool["description"]}
                </p>
              </div>
              <.dm_badge :if={tool["inputSchema"]["properties"]} variant="ghost" size="sm">
                {map_size(tool["inputSchema"]["properties"])} params
              </.dm_badge>
            </div>

            <%!-- Tool body (expanded) --%>
            <div :if={tool_expanded?(@expanded_tools, tool["name"])} class="border-t border-outline-variant">
              <%!-- Description --%>
              <div :if={tool["description"]} class="px-4 py-3 text-sm text-on-surface-variant bg-surface-container">
                {tool["description"]}
              </div>

              <%!-- Input schema parameters --%>
              <div :if={tool["inputSchema"]["properties"] && map_size(tool["inputSchema"]["properties"]) > 0} class="px-4 py-3 border-t border-outline-variant">
                <h4 class="text-xs font-semibold text-on-surface-variant uppercase tracking-wider mb-2">Parameters</h4>
                <div class="space-y-2">
                  <div
                    :for={{param_name, param_schema} <- tool["inputSchema"]["properties"] || %{}}
                    class="flex items-start gap-3 text-sm"
                  >
                    <div class="flex items-center gap-1.5 shrink-0 min-w-[140px]">
                      <code class="font-mono text-xs font-medium">{param_name}</code>
                      <.dm_badge
                        :if={param_name in required_properties(tool)}
                        variant="error"
                        size="sm"
                      >
                        req
                      </.dm_badge>
                    </div>
                    <.dm_badge variant="ghost" size="sm" class="shrink-0">
                      {schema_type_label(param_schema)}
                    </.dm_badge>
                    <span :if={param_schema["description"]} class="text-xs text-on-surface-variant">
                      {param_schema["description"]}
                    </span>
                  </div>
                </div>
              </div>

              <%!-- Tool call form --%>
              <div class="px-4 py-3 border-t border-outline-variant bg-surface-container">
                <h4 class="text-xs font-semibold text-on-surface-variant uppercase tracking-wider mb-2">Call Tool</h4>
                <form phx-change="update_tool_args" phx-submit="call_tool" class="space-y-3">
                  <input type="hidden" name="tool_name" value={tool["name"]} />
                  <.dm_textarea
                    id={"tool-args-#{tool["name"]}"}
                    name="tool_args"
                    value={get_tool_call(@tool_calls, tool["name"]).args}
                    rows={4}
                    class="font-mono text-xs"
                    placeholder="{}"
                  />
                  <.dm_btn
                    id={"tool-call-#{tool["name"]}"}
                    type="submit"
                    size="sm"
                    variant="primary"
                    disabled={get_tool_call(@tool_calls, tool["name"]).loading}
                  >
                    <.dm_mdi
                      :if={get_tool_call(@tool_calls, tool["name"]).loading}
                      name="loading"
                      class="w-4 h-4 animate-spin mr-1"
                    />
                    Call
                  </.dm_btn>
                </form>

                <%!-- Result --%>
                <div :if={get_tool_call(@tool_calls, tool["name"]).result} class="mt-3 border-t border-outline-variant pt-3">
                  <h5 class="text-xs font-medium text-on-surface-variant mb-1">Result</h5>
                  <pre class="overflow-x-auto rounded-md bg-surface-container-high p-3 text-xs font-mono max-h-64 overflow-y-auto"><code>{Jason.encode!(get_tool_call(@tool_calls, tool["name"]).result, pretty: true)}</code></pre>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Request log --%>
      <.dm_card variant="bordered">
        <:title>
          <div class="flex items-center gap-2">
            <span>Request Log</span>
            <.dm_badge :if={@request_log != []} variant="ghost">
              {length(@request_log)}
            </.dm_badge>
          </div>
        </:title>

        <div :if={@request_log == []} class="text-sm text-on-surface-variant">
          No requests sent yet. Connect to a server and start probing.
        </div>

        <div :if={@request_log != []} class="space-y-3 max-h-[calc(100vh-20rem)] overflow-y-auto">
          <div :for={entry <- @request_log} class="border border-outline-variant rounded-md overflow-hidden">
            <div class={[
              "flex items-center justify-between px-3 py-2 text-xs font-medium",
              entry.status == :ok && "bg-success/10 text-success",
              entry.status == :error && "bg-error/10 text-error",
              entry.status == :pending && "bg-warning/10 text-warning"
            ]}>
              <.dm_badge
                variant={case entry.status do
                  :ok -> "success"
                  :error -> "error"
                  :pending -> "warning"
                end}
                size="sm"
              >
                {entry.method}
              </.dm_badge>
              <span class="text-on-surface-variant">{format_time(entry.at)}</span>
            </div>
            <details :if={entry.request} class="text-xs">
              <summary class="px-3 py-1 cursor-pointer text-on-surface-variant hover:bg-surface-container-high">
                Request
              </summary>
              <pre class="overflow-x-auto bg-surface-container-high p-3 font-mono"><code>{entry.request}</code></pre>
            </details>
            <details :if={entry.response} open class="text-xs">
              <summary class="px-3 py-1 cursor-pointer text-on-surface-variant hover:bg-surface-container-high">
                Response
              </summary>
              <pre class="overflow-x-auto bg-surface-container-high p-3 font-mono max-h-64 overflow-y-auto"><code>{entry.response}</code></pre>
            </details>
          </div>
        </div>
      </.dm_card>
    """
  end

  # ── Internal tab ───────────────────────────────────────────────────────────

  defp render_internal_tab(assigns) do
    ~H"""
    <%!-- Connection panel --%>
    <.dm_card variant="bordered" class="mb-6">
      <:title>
        <div class="flex items-center gap-3">
          <span>Connection</span>
          <.dm_badge
            :if={@internal_connected}
            variant="success"
            size="sm"
          >
            Connected
          </.dm_badge>
          <.dm_badge
            :if={!@internal_connected}
            variant="ghost"
            size="sm"
          >
            Disconnected
          </.dm_badge>
        </div>
      </:title>
      <form phx-change="update_internal_config" phx-submit="internal_connect" class="space-y-4">
        <div class="max-w-md">
          <.dm_select
            id="internal-source-select"
            name="source"
            label="MCP Server"
            options={
              [{"", "— Select a source —"}] ++
              Enum.map(@sources, fn s -> {s.key, source_label(s)} end)
            }
            value={@internal_source}
          />
        </div>

        <%!-- Source info badges --%>
        <div :if={@sources != []} class="flex flex-wrap gap-1.5">
          <.dm_badge :for={source <- @sources} variant={source_type_badge(source.type)} size="sm">
            {source.prefix}:: ({source.tool_count})
          </.dm_badge>
        </div>

        <p :if={@sources == []} class="text-sm text-on-surface-variant">
          No tools registered. Enable managed services or configure upstream servers.
        </p>

        <%!-- Action buttons --%>
        <div class="flex flex-wrap gap-2 pt-1">
          <.dm_btn
            :if={!@internal_connected}
            id="internal-connect-btn"
            size="sm"
            variant="primary"
            phx-click="internal_connect"
            disabled={@internal_source == ""}
          >
            <.dm_mdi name="power-plug" class="w-4 h-4 mr-1" />
            Connect
          </.dm_btn>
          <.dm_btn
            :if={@internal_connected}
            id="internal-disconnect-btn"
            size="sm"
            variant="outline"
            phx-click="internal_disconnect"
          >
            <.dm_mdi name="power-plug-off" class="w-4 h-4 mr-1" />
            Disconnect
          </.dm_btn>
          <.dm_btn
            :if={@internal_connected}
            id="internal-list-tools-btn"
            size="sm"
            variant="primary"
            phx-click="internal_list_tools"
          >
            <.dm_mdi name="toolbox" class="w-4 h-4 mr-1" />
            List Tools
          </.dm_btn>
        </div>

        <p :if={@internal_error} class="text-sm text-error">{@internal_error}</p>
      </form>
    </.dm_card>

    <%!-- Source info --%>
    <.dm_card :if={@internal_source_info} variant="bordered" class="mb-6">
      <:title>Source Info</:title>
      <dl class="grid grid-cols-1 gap-x-6 gap-y-2 sm:grid-cols-3 text-sm">
        <div>
          <dt class="font-medium text-on-surface-variant">Prefix</dt>
          <dd class="font-mono">{@internal_source_info.prefix}::</dd>
        </div>
        <div>
          <dt class="font-medium text-on-surface-variant">Type</dt>
          <dd>{@internal_source_info.type}</dd>
        </div>
        <div>
          <dt class="font-medium text-on-surface-variant">Registered Tools</dt>
          <dd>{@internal_source_info.tool_count}</dd>
        </div>
      </dl>
    </.dm_card>

    <%!-- Tools section --%>
    <div :if={@internal_tools != []} class="mb-6">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-2">
          <h2 class="text-lg font-semibold">Tools</h2>
          <.dm_badge variant="ghost">{length(@internal_tools)}</.dm_badge>
        </div>
        <div class="flex gap-2">
          <.dm_btn id="internal-expand-all" size="sm" variant="outline" phx-click="expand_all_internal">
            Expand All
          </.dm_btn>
          <.dm_btn id="internal-collapse-all" size="sm" variant="outline" phx-click="collapse_all_internal">
            Collapse All
          </.dm_btn>
        </div>
      </div>

      <div class="space-y-3">
        <div :for={tool <- @internal_tools} class="border border-outline-variant rounded-lg overflow-hidden">
          <%!-- Tool header (always visible) --%>
          <div
            class="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-surface-container-high transition-colors select-none"
            phx-click="toggle_internal_tool"
            phx-value-name={tool.name}
          >
            <.dm_mdi
              name={if tool_expanded?(@internal_expanded_tools, tool.name), do: "chevron-down", else: "chevron-right"}
              class="w-5 h-5 shrink-0 text-on-surface-variant transition-transform"
            />
            <div class="flex-1 min-w-0">
              <span class="font-mono text-sm font-medium">{tool.name}</span>
              <p :if={tool.description && !tool_expanded?(@internal_expanded_tools, tool.name)} class="text-xs text-on-surface-variant mt-0.5 truncate">
                {tool.description}
              </p>
            </div>
            <.dm_badge :if={tool.input_schema["properties"]} variant="ghost" size="sm">
              {map_size(tool.input_schema["properties"])} params
            </.dm_badge>
          </div>

          <%!-- Tool body (expanded) --%>
          <div :if={tool_expanded?(@internal_expanded_tools, tool.name)} class="border-t border-outline-variant">
            <%!-- Description --%>
            <div :if={tool.description} class="px-4 py-3 text-sm text-on-surface-variant bg-surface-container">
              {tool.description}
            </div>

            <%!-- Input schema parameters --%>
            <div :if={tool.input_schema["properties"] && map_size(tool.input_schema["properties"]) > 0} class="px-4 py-3 border-t border-outline-variant">
              <h4 class="text-xs font-semibold text-on-surface-variant uppercase tracking-wider mb-2">Parameters</h4>
              <div class="space-y-2">
                <div
                  :for={{param_name, param_schema} <- tool.input_schema["properties"] || %{}}
                  class="flex items-start gap-3 text-sm"
                >
                  <div class="flex items-center gap-1.5 shrink-0 min-w-[140px]">
                    <code class="font-mono text-xs font-medium">{param_name}</code>
                    <.dm_badge
                      :if={param_name in internal_tool_required_properties(tool)}
                      variant="error"
                      size="sm"
                    >
                      req
                    </.dm_badge>
                  </div>
                  <.dm_badge variant="ghost" size="sm" class="shrink-0">
                    {schema_type_label(param_schema)}
                  </.dm_badge>
                  <span :if={param_schema["description"]} class="text-xs text-on-surface-variant">
                    {param_schema["description"]}
                  </span>
                </div>
              </div>
            </div>

            <%!-- Tool call form --%>
            <div class="px-4 py-3 border-t border-outline-variant bg-surface-container">
              <h4 class="text-xs font-semibold text-on-surface-variant uppercase tracking-wider mb-2">Call Tool</h4>
              <form phx-change="update_internal_tool_args" phx-submit="call_internal_tool" class="space-y-3">
                <input type="hidden" name="tool_name" value={tool.name} />
                <.dm_textarea
                  id={"internal-tool-args-#{tool.name}"}
                  name="tool_args"
                  value={get_tool_call(@internal_tool_calls, tool.name).args}
                  rows={4}
                  class="font-mono text-xs"
                  placeholder="{}"
                />
                <.dm_btn
                  id={"internal-tool-call-#{tool.name}"}
                  type="submit"
                  size="sm"
                  variant="primary"
                  disabled={get_tool_call(@internal_tool_calls, tool.name).loading}
                >
                  <.dm_mdi
                    :if={get_tool_call(@internal_tool_calls, tool.name).loading}
                    name="loading"
                    class="w-4 h-4 animate-spin mr-1"
                  />
                  Call
                </.dm_btn>
              </form>

              <%!-- Result --%>
              <% tc = get_tool_call(@internal_tool_calls, tool.name) %>
              <div :if={tc.result} class="mt-3 border-t border-outline-variant pt-3">
                <div class="flex items-center gap-2 mb-1">
                  <h5 class="text-xs font-medium text-on-surface-variant">Result</h5>
                  <.dm_badge variant={if tc.result.status == :ok, do: "success", else: "error"} size="sm">
                    {tc.result.status}
                  </.dm_badge>
                </div>
                <pre class="overflow-x-auto rounded-md bg-surface-container-high p-3 text-xs font-mono max-h-64 overflow-y-auto"><code>{format_internal_result(tc.result.data)}</code></pre>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_internal_result(data) when is_binary(data), do: data

  defp format_internal_result(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(data, pretty: true)
    end
  end
end
