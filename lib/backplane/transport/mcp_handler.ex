defmodule Backplane.Transport.McpHandler do
  @moduledoc """
  JSON-RPC dispatcher for MCP protocol messages.

  Handles: initialize, tools/list, tools/call, resources/list, resources/read,
  prompts/list, prompts/get, completion/complete, logging/setLevel, ping.
  """

  import Plug.Conn

  require Logger

  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Proxy.Upstream
  alias Backplane.Registry.{InputValidator, ToolRegistry}
  alias Backplane.Repo
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Telemetry
  alias Backplane.Transport.SSE

  import Ecto.Query

  @server_name "backplane"

  defp server_capabilities do
    %{
      tools: %{listChanged: false},
      resources: %{listChanged: false},
      prompts: %{listChanged: false},
      completions: %{},
      logging: %{}
    }
  end

  defp initialize_result do
    %{
      protocolVersion: Backplane.protocol_version(),
      serverInfo: %{name: @server_name, version: Backplane.version()},
      capabilities: server_capabilities()
    }
  end

  @spec handle(Plug.Conn.t()) :: Plug.Conn.t()
  def handle(conn) do
    case conn.body_params do
      %{"_json" => batch} when is_list(batch) ->
        handle_batch(conn, batch)

      %{"jsonrpc" => "2.0", "method" => method, "id" => id} = params ->
        Telemetry.emit_mcp_request(method)
        dispatch(conn, method, id, params["params"])

      %{"jsonrpc" => "2.0", "method" => method} = params when is_map(params) ->
        # Notification (no id) — acknowledge but don't respond with result
        dispatch_notification(conn, method, params["params"])

      %{"method" => _method} ->
        # Missing jsonrpc field
        json_rpc_error(conn, nil, -32_600, "Invalid Request: missing jsonrpc field")

      _ ->
        json_rpc_error(conn, nil, -32_600, "Invalid Request")
    end
  end

  defp handle_batch(conn, []) do
    json_rpc_error(conn, nil, -32_600, "Invalid Request: empty batch")
  end

  defp handle_batch(conn, requests) do
    # Partition into requests needing responses vs notifications
    {to_dispatch, notifications_count} =
      Enum.reduce(requests, {[], 0}, fn request, {items, notif_count} ->
        case request do
          %{"jsonrpc" => "2.0", "method" => method, "id" => id} = params ->
            {[{:request, method, id, params["params"]} | items], notif_count}

          %{"jsonrpc" => "2.0", "method" => _method} ->
            {items, notif_count + 1}

          _ ->
            invalid = %{
              jsonrpc: "2.0",
              id: nil,
              error: %{code: -32_600, message: "Invalid Request"}
            }

            {[{:invalid, invalid} | items], notif_count}
        end
      end)

    to_dispatch = Enum.reverse(to_dispatch)
    _ = notifications_count

    # Process requests concurrently — each may hit a different upstream
    responses =
      to_dispatch
      |> Task.async_stream(
        fn
          {:request, method, id, params} ->
            Telemetry.emit_mcp_request(method)
            dispatch_single(method, id, params)

          {:invalid, response} ->
            response
        end,
        ordered: true,
        max_concurrency: System.schedulers_online()
      )
      |> Enum.map(fn {:ok, result} -> result end)

    case responses do
      [] ->
        # All notifications — just acknowledge
        send_resp(conn, 202, "")

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(responses))
    end
  end

  # Batch dispatch: returns a JSON-RPC response map (no conn)
  defp dispatch_single(method, id, params) do
    case compute_result(method, id, params) do
      {:result, result} -> %{jsonrpc: "2.0", id: id, result: result}
      {:error, code, message} -> %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
    end
  end

  defp compute_result("initialize", _id, _params) do
    {:result, initialize_result()}
  end

  defp compute_result("tools/list", _id, _params) do
    tools =
      ToolRegistry.list_all()
      |> Enum.map(fn tool ->
        %{name: tool.name, description: tool.description, inputSchema: tool.input_schema}
      end)

    {:result, %{tools: tools}}
  end

  defp compute_result("tools/call", _id, %{"name" => name} = params)
       when is_binary(name) and name != "" do
    arguments = params["arguments"] || %{}

    case validate_tool_args(name, arguments) do
      :ok ->
        case dispatch_tool_call(name, arguments) do
          {:ok, result} ->
            {:result, %{content: [%{type: "text", text: format_result(result)}]}}

          {:error, message} ->
            {:result, %{content: [%{type: "text", text: to_string(message)}], isError: true}}
        end

      {:error, reason} ->
        {:error, -32_602, "Invalid params: #{reason}"}
    end
  end

  defp compute_result("tools/call", _id, _params) do
    {:error, -32_602, "Invalid params: 'name' is required"}
  end

  defp compute_result("resources/list", _id, params) do
    cursor = if is_map(params), do: params["cursor"]
    {resources, next_cursor} = list_resources(cursor)
    result = %{resources: resources}
    result = if next_cursor, do: Map.put(result, :nextCursor, next_cursor), else: result
    {:result, result}
  end

  defp compute_result("resources/read", _id, %{"uri" => uri}) when is_binary(uri) do
    case read_resource(uri) do
      {:ok, contents} -> {:result, %{contents: contents}}
      {:error, reason} -> {:error, -32_602, "Resource not found: #{reason}"}
    end
  end

  defp compute_result("resources/read", _id, _params) do
    {:error, -32_602, "Invalid params: 'uri' is required"}
  end

  defp compute_result("prompts/list", _id, _params), do: {:result, %{prompts: list_prompts()}}

  defp compute_result("prompts/get", _id, %{"name" => name}) when is_binary(name) do
    case get_prompt(name) do
      {:ok, prompt} -> {:result, prompt}
      {:error, reason} -> {:error, -32_602, "Prompt not found: #{reason}"}
    end
  end

  defp compute_result("prompts/get", _id, _params) do
    {:error, -32_602, "Invalid params: 'name' is required"}
  end

  defp compute_result("completion/complete", _id, %{"ref" => ref, "argument" => argument})
       when is_map(ref) and is_map(argument) do
    completions = compute_completions(ref, argument)
    {:result, %{completion: %{values: completions, hasMore: false, total: length(completions)}}}
  end

  defp compute_result("completion/complete", _id, _params) do
    {:error, -32_602, "Invalid params: 'ref' and 'argument' are required"}
  end

  defp compute_result("logging/setLevel", _id, %{"level" => level})
       when level in ~w(debug info notice warning error critical alert emergency) do
    Logger.configure(level: String.to_existing_atom(level))
    Logger.info("MCP client set log level to #{level}")
    {:result, %{}}
  end

  defp compute_result("logging/setLevel", _id, _params) do
    {:error, -32_602,
     "Invalid params: 'level' must be one of: debug, info, notice, warning, error, critical, alert, emergency"}
  end

  defp compute_result("ping", _id, _params), do: {:result, %{}}

  defp compute_result(_method, _id, _params), do: {:error, -32_601, "Method not found"}

  defp dispatch(conn, "initialize", id, params) do
    client_version = get_in(params || %{}, ["protocolVersion"])

    if client_version && client_version != Backplane.protocol_version() do
      Logger.warning(
        "Client requested unsupported protocol version: #{client_version} (server supports #{Backplane.protocol_version()})"
      )
    end

    session_id = generate_session_id()

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> json_rpc_result(id, initialize_result())
  end

  defp dispatch(conn, "tools/list", id, params) do
    {:result, %{tools: tools} = result} = compute_result("tools/list", id, params)
    etag = tools_etag(tools)
    client_etag = get_req_header(conn, "if-none-match")

    if client_etag == [etag] do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_header("etag", etag)
      |> json_rpc_result(id, result)
    end
  end

  defp dispatch(conn, "tools/call", id, %{"name" => name} = params)
       when is_binary(name) and name != "" do
    arguments = params["arguments"] || %{}

    case validate_tool_args(name, arguments) do
      :ok -> dispatch_validated_tool_call(conn, id, name, arguments)
      {:error, reason} -> json_rpc_error(conn, id, -32_602, "Invalid params: #{reason}")
    end
  end

  # All remaining methods delegate to compute_result to avoid duplication
  defp dispatch(conn, method, id, params) do
    case compute_result(method, id, params) do
      {:result, result} -> json_rpc_result(conn, id, result)
      {:error, code, message} -> json_rpc_error(conn, id, code, message)
    end
  end

  defp dispatch_notification(conn, "notifications/initialized", _params) do
    # Client acknowledges initialization — no action needed for stateless server
    send_resp(conn, 202, "")
  end

  defp dispatch_notification(conn, "notifications/cancelled", _params) do
    # Client requests cancellation — stateless per-request, so just acknowledge
    send_resp(conn, 202, "")
  end

  defp dispatch_notification(conn, _method, _params) do
    send_resp(conn, 202, "")
  end

  defp dispatch_validated_tool_call(conn, id, name, arguments) do
    if SSE.streaming_requested?(conn) do
      dispatch_tool_call_sse(conn, id, name, arguments)
    else
      dispatch_tool_call_json(conn, id, name, arguments)
    end
  end

  defp dispatch_tool_call_json(conn, id, name, arguments) do
    case dispatch_tool_call(name, arguments) do
      {:ok, result} ->
        json_rpc_result(conn, id, %{
          content: [%{type: "text", text: format_result(result)}]
        })

      {:error, message} ->
        json_rpc_result(conn, id, %{
          content: [%{type: "text", text: to_string(message)}],
          isError: true
        })
    end
  end

  defp dispatch_tool_call_sse(conn, id, name, arguments) do
    start_time = System.monotonic_time()
    Telemetry.emit_sse_start(name)
    conn = SSE.start_stream(conn)

    conn =
      case dispatch_tool_call(name, arguments) do
        {:ok, result} ->
          SSE.send_event(conn, id, %{
            content: [%{type: "text", text: format_result(result)}]
          })

        {:error, message} ->
          SSE.send_event(conn, id, %{
            content: [%{type: "text", text: to_string(message)}],
            isError: true
          })
      end

    duration = System.monotonic_time() - start_time
    Telemetry.emit_sse_stop(name, duration)
    conn
  end

  defp validate_tool_args(name, arguments) do
    case ToolRegistry.lookup(name) do
      %{input_schema: schema} when is_map(schema) ->
        InputValidator.validate(arguments, schema)

      _ ->
        :ok
    end
  end

  defp dispatch_tool_call(name, args) do
    Telemetry.span_tool_call(name, fn ->
      name |> ToolRegistry.resolve() |> execute_tool(args)
    end)
  end

  defp execute_tool({:native, module, handler}, args) do
    call_args = if handler, do: Map.put(args, "_handler", to_string(handler)), else: args
    module.call(call_args)
  rescue
    e ->
      Logger.error(
        "Native tool crash in #{inspect(module)}/#{inspect(handler)}: #{Exception.message(e)}"
      )

      {:error, "Internal error: #{Exception.message(e)}"}
  end

  defp execute_tool({:upstream, upstream_pid, original_tool_name, timeout}, args) do
    Upstream.forward(upstream_pid, original_tool_name, args, timeout)
  end

  defp execute_tool(:not_found, _args) do
    {:error, "Unknown tool"}
  end

  # Resources: doc chunks as MCP resources

  @page_size 100

  defp list_resources(cursor) do
    query =
      DocChunk
      |> select([c], %{
        project_id: c.project_id,
        source_path: c.source_path,
        chunk_type: c.chunk_type,
        id: c.id
      })
      |> order_by([c], asc: c.id)

    query = if cursor, do: where(query, [c], c.id > ^decode_cursor(cursor)), else: query

    chunks =
      query
      |> limit(^(@page_size + 1))
      |> Repo.all()

    {page, has_more} =
      if length(chunks) > @page_size do
        {Enum.take(chunks, @page_size), true}
      else
        {chunks, false}
      end

    resources =
      Enum.map(page, fn chunk ->
        %{
          uri: resource_uri(chunk.project_id, chunk.id),
          name: "#{chunk.project_id}/#{chunk.source_path}",
          description: "#{chunk.chunk_type} from #{chunk.source_path}",
          mimeType: "text/plain"
        }
      end)

    next_cursor =
      if has_more do
        last = List.last(page)
        encode_cursor(last.id)
      end

    {resources, next_cursor}
  end

  defp encode_cursor(id), do: Base.url_encode64(to_string(id), padding: false)

  defp decode_cursor(cursor) do
    with {:ok, id_str} <- Base.url_decode64(cursor, padding: false),
         {id, ""} <- Integer.parse(id_str) do
      id
    else
      _ -> 0
    end
  end

  defp read_resource(uri) do
    case parse_resource_uri(uri) do
      {:ok, chunk_id} ->
        case Repo.get(DocChunk, chunk_id) do
          nil -> {:error, "not found"}
          chunk -> {:ok, [%{uri: uri, mimeType: "text/plain", text: chunk.content}]}
        end

      :error ->
        {:error, "invalid URI format"}
    end
  end

  defp resource_uri(project_id, chunk_id) do
    "backplane://docs/#{project_id}/#{chunk_id}"
  end

  defp parse_resource_uri("backplane://docs/" <> rest) do
    with [_project_id, chunk_id_str] <- String.split(rest, "/", parts: 2),
         {chunk_id, ""} <- Integer.parse(chunk_id_str) do
      {:ok, chunk_id}
    else
      _ -> :error
    end
  end

  defp parse_resource_uri(_), do: :error

  # Prompts: skills as MCP prompts

  defp list_prompts do
    SkillsRegistry.list()
    |> Enum.map(fn skill ->
      %{
        name: skill.name,
        description: skill.description,
        arguments: build_prompt_arguments(skill)
      }
    end)
  end

  defp get_prompt(name) do
    skills = SkillsRegistry.list()

    case Enum.find(skills, &(&1.name == name)) do
      nil ->
        {:error, "not found"}

      skill ->
        {:ok,
         %{
           description: skill.description,
           messages: [
             %{
               role: "user",
               content: %{type: "text", text: skill.content || ""}
             }
           ]
         }}
    end
  end

  defp build_prompt_arguments(skill) do
    tools = skill[:tools] || []

    Enum.map(tools, fn tool ->
      %{name: tool, description: "Tool required: #{tool}", required: false}
    end)
  end

  # Completion: provide auto-complete values for tool/prompt arguments
  defp compute_completions(
         %{"type" => "ref/tool", "name" => tool_name},
         %{"name" => arg_name} = arg
       ) do
    value = arg["value"] || ""
    complete_tool_argument(tool_name, arg_name, value)
  end

  defp compute_completions(
         %{"type" => "ref/prompt", "name" => prompt_name},
         %{"name" => _} = arg
       ) do
    value = arg["value"] || ""
    complete_prompt_argument(prompt_name, value)
  end

  defp compute_completions(_ref, _argument), do: []

  defp complete_tool_argument(tool_name, arg_name, prefix) do
    case {tool_name, arg_name} do
      {_, "project_id"} ->
        DocChunk
        |> select([c], c.project_id)
        |> distinct(true)
        |> limit(100)
        |> Repo.all()
        |> filter_by_prefix(prefix)

      {_, "repo"} ->
        Project
        |> select([p], p.repo)
        |> limit(100)
        |> Repo.all()
        |> filter_by_prefix(prefix)

      {_, "skill_id"} ->
        SkillsRegistry.list()
        |> Enum.map(& &1.id)
        |> filter_by_prefix(prefix)

      {_, "tool_name"} ->
        ToolRegistry.list_all()
        |> Enum.map(& &1.name)
        |> filter_by_prefix(prefix)

      _ ->
        []
    end
  end

  defp complete_prompt_argument(_prompt_name, _prefix), do: []

  defp filter_by_prefix(values, ""), do: Enum.take(values, 20)

  defp filter_by_prefix(values, prefix) do
    values
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.take(20)
  end

  defp tools_etag(tools) do
    hash = :erlang.phash2(tools)
    "\"bp-tools-#{hash}\""
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp format_result(result) when is_binary(result), do: result

  defp format_result(result) do
    case Jason.encode(result) do
      {:ok, json} -> json
      {:error, _} -> inspect(result)
    end
  end

  defp json_rpc_result(conn, id, result) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        result: result
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp json_rpc_error(conn, id, code, message) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        error: %{code: code, message: message}
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end
end
