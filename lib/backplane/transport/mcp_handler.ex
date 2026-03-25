defmodule Backplane.Transport.McpHandler do
  @moduledoc """
  JSON-RPC dispatcher for MCP protocol messages.

  Handles: initialize, tools/list, tools/call, ping.
  """

  import Plug.Conn

  alias Backplane.Docs.DocChunk
  alias Backplane.Proxy.Upstream
  alias Backplane.Registry.{InputValidator, ToolRegistry}
  alias Backplane.Repo
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Telemetry
  alias Backplane.Transport.SSE

  import Ecto.Query

  @protocol_version "2025-03-26"
  @server_name "backplane"
  @server_version "0.1.0"

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
    responses =
      Enum.reduce(requests, [], fn request, acc ->
        case request do
          %{"jsonrpc" => "2.0", "method" => method, "id" => id} = params ->
            Telemetry.emit_mcp_request(method)
            result = dispatch_single(method, id, params["params"])
            [result | acc]

          %{"jsonrpc" => "2.0", "method" => _method} ->
            # Notification in batch — no response
            acc

          _ ->
            [
              %{jsonrpc: "2.0", id: nil, error: %{code: -32_600, message: "Invalid Request"}}
              | acc
            ]
        end
      end)
      |> Enum.reverse()

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
    {:result,
     %{
       protocolVersion: @protocol_version,
       serverInfo: %{name: @server_name, version: @server_version},
       capabilities: %{
         tools: %{listChanged: true},
         resources: %{listChanged: false},
         prompts: %{},
         completions: %{},
         logging: %{}
       }
     }}
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
    {:result, %{}}
  end

  defp compute_result("logging/setLevel", _id, _params) do
    {:error, -32_602,
     "Invalid params: 'level' must be one of: debug, info, notice, warning, error, critical, alert, emergency"}
  end

  defp compute_result("ping", _id, _params), do: {:result, %{}}

  defp compute_result(_method, _id, _params), do: {:error, -32_601, "Method not found"}

  defp dispatch(conn, "initialize", id, _params) do
    session_id = generate_session_id()

    result = %{
      protocolVersion: @protocol_version,
      serverInfo: %{
        name: @server_name,
        version: @server_version
      },
      capabilities: %{
        tools: %{listChanged: true},
        resources: %{},
        prompts: %{},
        completions: %{},
        logging: %{}
      }
    }

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> json_rpc_result(id, result)
  end

  defp dispatch(conn, "tools/list", id, _params) do
    tools =
      ToolRegistry.list_all()
      |> Enum.map(fn tool ->
        %{
          name: tool.name,
          description: tool.description,
          inputSchema: tool.input_schema
        }
      end)

    etag = tools_etag(tools)
    client_etag = get_req_header(conn, "if-none-match")

    if client_etag == [etag] do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_header("etag", etag)
      |> json_rpc_result(id, %{tools: tools})
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

  defp dispatch(conn, "tools/call", id, %{}) do
    json_rpc_error(conn, id, -32_602, "Invalid params: 'name' is required")
  end

  defp dispatch(conn, "tools/call", id, _params) do
    json_rpc_error(conn, id, -32_602, "Invalid params: 'params' object is required")
  end

  defp dispatch(conn, "resources/list", id, params) do
    cursor = if is_map(params), do: params["cursor"]
    {resources, next_cursor} = list_resources(cursor)
    result = %{resources: resources}
    result = if next_cursor, do: Map.put(result, :nextCursor, next_cursor), else: result
    json_rpc_result(conn, id, result)
  end

  defp dispatch(conn, "resources/read", id, %{"uri" => uri}) when is_binary(uri) do
    case read_resource(uri) do
      {:ok, contents} ->
        json_rpc_result(conn, id, %{contents: contents})

      {:error, reason} ->
        json_rpc_error(conn, id, -32_602, "Resource not found: #{reason}")
    end
  end

  defp dispatch(conn, "resources/read", id, _params) do
    json_rpc_error(conn, id, -32_602, "Invalid params: 'uri' is required")
  end

  defp dispatch(conn, "prompts/list", id, _params) do
    prompts = list_prompts()
    json_rpc_result(conn, id, %{prompts: prompts})
  end

  defp dispatch(conn, "prompts/get", id, %{"name" => name}) when is_binary(name) do
    case get_prompt(name) do
      {:ok, prompt} ->
        json_rpc_result(conn, id, prompt)

      {:error, reason} ->
        json_rpc_error(conn, id, -32_602, "Prompt not found: #{reason}")
    end
  end

  defp dispatch(conn, "prompts/get", id, _params) do
    json_rpc_error(conn, id, -32_602, "Invalid params: 'name' is required")
  end

  defp dispatch(conn, "completion/complete", id, %{"ref" => ref, "argument" => argument})
       when is_map(ref) and is_map(argument) do
    completions = compute_completions(ref, argument)

    json_rpc_result(conn, id, %{
      completion: %{values: completions, hasMore: false, total: length(completions)}
    })
  end

  defp dispatch(conn, "completion/complete", id, _params) do
    json_rpc_error(conn, id, -32_602, "Invalid params: 'ref' and 'argument' are required")
  end

  defp dispatch(conn, "logging/setLevel", id, %{"level" => level})
       when level in ~w(debug info notice warning error critical alert emergency) do
    json_rpc_result(conn, id, %{})
  end

  defp dispatch(conn, "logging/setLevel", id, _params) do
    json_rpc_error(
      conn,
      id,
      -32_602,
      "Invalid params: 'level' must be one of: debug, info, notice, warning, error, critical, alert, emergency"
    )
  end

  defp dispatch(conn, "ping", id, _params) do
    json_rpc_result(conn, id, %{})
  end

  defp dispatch(conn, _method, id, _params) do
    json_rpc_error(conn, id, -32_601, "Method not found")
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
    case Base.url_decode64(cursor, padding: false) do
      {:ok, id_str} -> String.to_integer(id_str)
      :error -> 0
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
    case String.split(rest, "/", parts: 2) do
      [_project_id, chunk_id] -> {:ok, chunk_id}
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
         %{"name" => _arg_name} = arg
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
        |> Repo.all()
        |> filter_by_prefix(prefix)

      {_, "repo"} ->
        Backplane.Docs.Project
        |> select([p], p.repo)
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
  defp format_result(result), do: Jason.encode!(result)

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
