defmodule Backplane.MCP.Dispatch do
  @moduledoc """
  Executes Backplane's transport-independent MCP application operations.

  Results use JSON-ready string keys. Expected application failures are
  returned as semantic errors so each protocol transport can choose its own
  wire error codes and status behavior.
  """

  require Logger

  alias Backplane.Clients
  alias Backplane.MCP.{Info, ObservabilityContext, ToolAccessEvent}
  alias Backplane.McpProtocol.Protocol
  alias Backplane.Proxy.Upstream
  alias Backplane.Registry.{InputValidator, PromptRegistry, Tool, ToolRegistry}
  alias Backplane.Skills.Registry, as: SkillsRegistry
  alias Backplane.Observability
  alias Backplane.Telemetry

  @type context :: %{
          required(:protocol_version) => String.t(),
          required(:scopes) => [String.t()],
          required(:auth) => map(),
          required(:client) => term(),
          optional(:observability) => ObservabilityContext.t()
        }

  @type error_reason ::
          :invalid_params
          | :not_found
          | :method_not_found
          | :insufficient_scope
          | :internal_error

  @type error :: {:error, error_reason(), String.t()}
  @type result :: {:ok, map()} | error()

  @doc "Executes one application-level MCP request."
  @spec execute(String.t(), map() | nil, context()) :: result()
  def execute(method, params, context) do
    with :ok <- validate_context(context) do
      do_execute(method, params, context)
    end
  rescue
    exception ->
      Logger.warning("MCP application dispatch failed",
        method: method,
        failure: failure_category(exception)
      )

      internal_error()
  catch
    kind, reason ->
      Logger.warning("MCP application dispatch failed",
        method: method,
        failure: failure_category({kind, reason})
      )

      internal_error()
  end

  @doc "Returns the registered tools visible to this request context."
  @spec visible_tools(context()) :: [Tool.t()] | error()
  def visible_tools(context) when is_map(context) do
    with :ok <- validate_context(context) do
      ToolRegistry.list_all()
      |> Enum.reject(&management_tool?(&1.name))
      |> Clients.filter_tools(context.scopes)
    end
  end

  def visible_tools(_context), do: internal_error()

  @doc "Executes a raw tool call without transport-level scope or argument validation."
  @spec call_tool(String.t(), map(), map(), ObservabilityContext.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def call_tool(name, args, auth \\ %{}, observability \\ nil)
      when is_binary(name) and is_map(auth) do
    case {Observability.mcp_write?(), observability} do
      {true, %{}} ->
        ToolAccessEvent.span(name, args, observability, fn tool_context ->
          observability = Map.put(observability, :tool_context, tool_context)
          name |> ToolRegistry.resolve() |> execute_tool(name, args, auth, observability)
        end)

      _legacy ->
        call_legacy_tool(name, args, auth)
    end
  end

  defp call_legacy_tool(name, args, auth) do
    Telemetry.span_tool_call(name, args, fn ->
      case name |> ToolRegistry.resolve() |> execute_tool(name, args, auth, nil) do
        {:ok, result, _meta} -> {:ok, result}
        {:error, reason, _meta} -> {:error, reason}
      end
    end)
  end

  @doc false
  @spec validate_tool_call(map() | nil, context()) :: :ok | error()
  def validate_tool_call(params, context) do
    with :ok <- validate_context(context) do
      validate_tool_call_params(params, context.scopes)
    end
  end

  defp validate_tool_call_params(%{"name" => name} = params, scopes)
       when is_binary(name) and name != "" do
    if Clients.scope_matches?(scopes, name) do
      case validate_tool_args(name, params["arguments"] || %{}) do
        :ok -> :ok
        {:error, reason} -> {:error, :invalid_params, "Invalid params: #{reason}"}
      end
    else
      {:error, :insufficient_scope, "Tool '#{name}' is not in scope for this client"}
    end
  end

  defp validate_tool_call_params(_params, _scopes),
    do: {:error, :invalid_params, "Invalid params: 'name' is required"}

  defp do_execute("tools/list", _params, context) do
    tools = context |> visible_tools() |> Enum.map(&tool_to_json(&1, context.protocol_version))
    {:ok, %{"tools" => tools}}
  end

  defp do_execute("tools/call", params, context) do
    with :ok <- validate_tool_call(params, context) do
      execute_validated_tool_call(params, context)
    end
  end

  defp do_execute("resources/list", _params, context) do
    {:ok, %{"resources" => list_resources(context.auth)}}
  end

  defp do_execute("resources/templates/list", _params, context) do
    {:ok,
     %{
       "resourceTemplates" => list_resource_templates(context.auth)
     }}
  end

  defp do_execute("resources/read", %{"uri" => uri}, context) when is_binary(uri) do
    read_resource(uri, context.auth)
  end

  defp do_execute("resources/read", _params, _context),
    do: {:error, :invalid_params, "Invalid params: 'uri' is required"}

  defp do_execute("prompts/list", _params, context) do
    {:ok, %{"prompts" => list_prompts(context.auth)}}
  end

  defp do_execute("prompts/get", params, context) do
    get_prompt(params || %{}, context.auth)
  end

  defp do_execute("completion/complete", %{"ref" => ref, "argument" => argument}, _context)
       when is_map(ref) and is_map(argument) do
    completions = compute_completions(ref, argument)

    {:ok,
     %{
       "completion" => %{
         "values" => completions,
         "hasMore" => false,
         "total" => length(completions)
       }
     }}
  end

  defp do_execute("completion/complete", _params, _context),
    do: {:error, :invalid_params, "Invalid params: 'ref' and 'argument' are required"}

  defp do_execute(_method, _params, _context),
    do: {:error, :method_not_found, "Method not found"}

  defp execute_validated_tool_call(%{"name" => name} = params, context) do
    arguments = params["arguments"] || %{}
    Backplane.PubSubBroadcaster.broadcast_tools_call(:dispatched, %{tool: name})

    observability = observability_with_client(context)

    case call_tool(name, arguments, context.auth, observability) do
      {:ok, result} ->
        maybe_log_skill_load(context.client, name, result, observability)
        Backplane.PubSubBroadcaster.broadcast_tools_call(:completed, %{tool: name})
        {:ok, build_tool_call_result(name, result)}

      {:error, message} ->
        Backplane.PubSubBroadcaster.broadcast_tools_call(:failed, %{
          tool: name,
          reason: message
        })

        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => format_error(message)}],
           "isError" => true
         }}
    end
  end

  defp validate_tool_args(name, arguments) do
    case ToolRegistry.lookup(name) do
      %{input_schema: schema} when is_map(schema) -> InputValidator.validate(arguments, schema)
      _other -> :ok
    end
  end

  defp validate_context(%{
         protocol_version: protocol_version,
         scopes: scopes,
         auth: auth,
         client: _client
       })
       when is_binary(protocol_version) and is_list(scopes) and is_map(auth) do
    if Enum.all?(scopes, &is_binary/1), do: :ok, else: internal_error()
  end

  defp validate_context(_context), do: internal_error()

  defp execute_tool({:native, module, handler}, name, args, _auth, _observability) do
    call_args = if handler, do: Map.put(args, "_handler", to_string(handler)), else: args
    meta = base_meta("native", name, nil)

    case module.call(call_args) do
      {:ok, result} -> {:ok, result, meta}
      {:error, reason} -> {:error, reason, meta}
      result -> {:ok, result, meta}
    end
  rescue
    exception ->
      Logger.error("Native tool crashed",
        tool: name,
        module: inspect(module),
        handler: inspect(handler),
        failure: failure_category(exception)
      )

      {:error, "Tool #{name} failed: #{Exception.message(exception)}",
       base_meta("native", name, nil)}
  end

  defp execute_tool(
         {:upstream, upstream_pid, original_tool_name, timeout},
         name,
         args,
         _auth,
         observability
       ) do
    upstream_prefix = upstream_prefix(name)

    case upstream_cache_ttl(name) do
      nil ->
        forward_upstream(
          upstream_pid,
          original_tool_name,
          name,
          args,
          timeout,
          upstream_prefix,
          "bypass",
          observability
        )

      ttl_ms ->
        key = Backplane.Cache.KeyBuilder.upstream(upstream_prefix, name, args)

        case Backplane.Cache.get(key) do
          {:ok, cached} ->
            {:ok, cached,
             base_meta("upstream", name, timeout,
               original_tool_name: original_tool_name,
               cache_status: "hit",
               upstream_prefix: upstream_prefix,
               upstream_pid: upstream_pid
             )}

          :miss ->
            case forward_upstream(
                   upstream_pid,
                   original_tool_name,
                   name,
                   args,
                   timeout,
                   upstream_prefix,
                   "miss",
                   observability
                 ) do
              {:ok, result, meta} ->
                Backplane.Cache.put(key, result, ttl_ms)
                {:ok, result, meta}

              other ->
                other
            end
        end
    end
  end

  defp execute_tool({:managed, handler}, name, args, auth, _observability)
       when is_function(handler, 2) do
    meta = base_meta("managed", name, nil)

    case managed_tool_result(handler.(args, auth), name) do
      {:ok, result} -> {:ok, result, meta}
      {:error, reason} -> {:error, reason, meta}
    end
  rescue
    exception ->
      {:error, "Managed tool #{name} failed: #{Exception.message(exception)}",
       base_meta("managed", name, nil)}
  end

  defp execute_tool({:managed, handler}, name, args, _auth, _observability)
       when is_function(handler, 1) do
    meta = base_meta("managed", name, nil)

    case managed_tool_result(handler.(args), name) do
      {:ok, result} -> {:ok, result, meta}
      {:error, reason} -> {:error, reason, meta}
    end
  rescue
    exception ->
      {:error, "Managed tool #{name} failed: #{Exception.message(exception)}",
       base_meta("managed", name, nil)}
  end

  defp execute_tool(:not_found, name, _args, _auth, _observability) do
    {:error, "Unknown tool: #{name}. Use tools/list to see available tools.",
     base_meta("unknown", name, nil)}
  end

  defp managed_tool_result({:ok, result}, _name), do: {:ok, result}

  defp managed_tool_result({:error, %{message: message}}, name),
    do: {:error, "Managed tool #{name} failed: #{message}"}

  defp managed_tool_result({:error, reason}, name) when is_binary(reason),
    do: {:error, "Managed tool #{name} failed: #{reason}"}

  defp managed_tool_result({:error, reason}, name),
    do: {:error, "Managed tool #{name} failed: #{inspect(reason)}"}

  defp forward_upstream(
         upstream_pid,
         original_tool_name,
         name,
         args,
         timeout,
         upstream_prefix,
         cache_status,
         observability
       ) do
    meta =
      base_meta("upstream", name, timeout,
        original_tool_name: original_tool_name,
        cache_status: cache_status,
        upstream_prefix: upstream_prefix,
        upstream_pid: upstream_pid
      )

    result =
      if observability && Map.get(observability, :tool_context) do
        Upstream.forward(
          upstream_pid,
          original_tool_name,
          args,
          timeout,
          %{
            context: observability.tool_context,
            tool_event_id: observability.mcp_request_id
          }
        )
      else
        Upstream.forward(upstream_pid, original_tool_name, args, timeout)
      end

    case result do
      {:ok, result, upstream_meta} ->
        {:ok, result, Map.merge(meta, upstream_meta)}

      {:ok, result} ->
        {:ok, result, enrich_upstream_meta(meta, upstream_pid)}

      {:error, reason, upstream_meta} ->
        Logger.warning("Upstream tool call failed",
          tool: name,
          original_tool: original_tool_name,
          failure: failure_category(reason)
        )

        {:error, "Tool #{name} failed: #{reason}", Map.merge(meta, upstream_meta)}

      {:error, reason} ->
        Logger.warning("Upstream tool call failed",
          tool: name,
          original_tool: original_tool_name,
          failure: failure_category(reason)
        )

        {:error, "Tool #{name} failed: #{reason}", enrich_upstream_meta(meta, upstream_pid)}
    end
  end

  defp base_meta(execution_kind, name, timeout, extra \\ []) do
    {namespace, _} =
      case String.split(name, "::", parts: 2) do
        [ns, _rest] -> {ns, name}
        _other -> {name, name}
      end

    [
      execution_kind: execution_kind,
      tool_namespace: namespace,
      timeout_ms: timeout
    ]
    |> Keyword.merge(extra)
    |> Enum.into(%{})
  end

  defp enrich_upstream_meta(meta, upstream_pid) do
    case Upstream.status(upstream_pid) do
      %{name: name, prefix: prefix, transport: transport, negotiated_version: version} ->
        Map.merge(meta, %{
          upstream_name: name,
          upstream_prefix: prefix,
          upstream_transport: transport,
          upstream_protocol_version: version,
          attempt_count: 1
        })

      _ ->
        Map.put(meta, :attempt_count, 1)
    end
  end

  defp upstream_prefix(namespaced_name) do
    case String.split(namespaced_name, "::", parts: 2) do
      [prefix, _name] -> prefix
      _other -> namespaced_name
    end
  end

  defp upstream_cache_ttl(tool_name) do
    prefix = upstream_prefix(tool_name)
    upstreams = Application.get_env(:backplane, :upstreams, [])

    case Enum.find(upstreams, fn upstream ->
           upstream[:prefix] == prefix or upstream["prefix"] == prefix
         end) do
      nil ->
        nil

      upstream ->
        cache_ttl = upstream[:cache_ttl] || upstream["cache_ttl"]
        cache_tools = upstream[:cache_tools] || upstream["cache_tools"]

        cond do
          is_nil(cache_ttl) -> nil
          is_nil(cache_tools) -> parse_ttl(cache_ttl)
          tool_name in cache_tools -> parse_ttl(cache_ttl)
          true -> nil
        end
    end
  end

  defp parse_ttl(ttl) when is_integer(ttl), do: ttl

  defp parse_ttl(ttl) when is_binary(ttl) do
    case Backplane.Utils.parse_interval(ttl) do
      {:ok, seconds} -> seconds * 1_000
      :error -> nil
    end
  end

  defp parse_ttl(_ttl), do: nil

  defp maybe_log_skill_load(client, "skill::load", result, observability) when is_map(result) do
    case result[:name] || result["name"] do
      skill_name when is_binary(skill_name) ->
        result
        |> skill_load_attrs(client, skill_name, observability)
        |> Backplane.Audit.log_skill_load()

      _other ->
        :ok
    end
  end

  defp maybe_log_skill_load(_client, _name, _result, _observability), do: :ok

  defp skill_load_attrs(result, client, skill_name, observability) do
    %{
      skill_name: skill_name,
      loaded_deps: result[:loaded_deps] || result["loaded_deps"] || []
    }
    |> maybe_put_client(client)
    |> maybe_put_observability(observability)
  end

  defp maybe_put_observability(attrs, observability) do
    Map.merge(attrs, %{
      request_id: get_in(observability, [:context, :request_id]),
      trace_id: get_in(observability, [:context, :trace_id]),
      mcp_request_id: get_in(observability, [:mcp_request_id])
    })
  end

  defp observability_with_client(%{observability: observability, client: client})
       when is_map(observability) do
    Map.put(observability, :client, client)
  end

  defp observability_with_client(_context), do: nil

  defp maybe_put_client(attrs, %{id: id, name: name}) do
    attrs
    |> Map.put(:client_id, id)
    |> Map.put(:client_name, name)
  end

  defp maybe_put_client(attrs, _client), do: attrs

  defp list_resources(auth) do
    service = memory_service()

    resources =
      if Code.ensure_loaded?(service) and function_exported?(service, :resources, 1),
        do: apply(service, :resources, [auth]),
        else: []

    Enum.map(resources, fn resource ->
      %{
        "uri" => resource.uri,
        "name" => resource.name,
        "description" => resource.description,
        "mimeType" => resource.mime_type
      }
    end)
  end

  defp list_resource_templates(auth) do
    service = memory_service()

    templates =
      if Code.ensure_loaded?(service) and function_exported?(service, :resource_templates, 1),
        do: apply(service, :resource_templates, [auth]),
        else: []

    Enum.map(templates, fn template ->
      %{
        "uriTemplate" => template.uri_template,
        "name" => template.name,
        "description" => template.description,
        "mimeType" => template.mime_type
      }
    end)
  end

  defp read_resource(uri, auth) do
    service = memory_service()

    result =
      if Code.ensure_loaded?(service) and function_exported?(service, :read_resource, 2),
        do: apply(service, :read_resource, [uri, auth]),
        else: {:error, :not_found}

    case result do
      {:ok, text} ->
        {:ok,
         %{
           "contents" => [
             %{"uri" => uri, "mimeType" => "application/json", "text" => text}
           ]
         }}

      {:error, :not_found} ->
        {:error, :not_found, "Resource not found: #{uri}"}

      {:error, _reason} ->
        {:error, :not_found, "Resource unavailable"}
    end
  end

  defp memory_service,
    do: Application.get_env(:backplane_mcp, :memory_service, Backplane.Memory.Service)

  defp list_prompts(auth) do
    managed = PromptRegistry.list()
    reserved_names = MapSet.new(managed, & &1.name)

    skills =
      SkillsRegistry.list()
      |> Enum.reject(&MapSet.member?(reserved_names, &1.name))
      |> Enum.map(fn skill ->
        %{
          "name" => skill.name,
          "description" => skill.description,
          "arguments" => build_prompt_arguments(skill)
        }
      end)

    managed_prompts =
      managed
      |> Enum.filter(&managed_prompt_authorized?(&1, auth))
      |> Enum.map(&json_keys(&1.descriptor))

    Enum.sort_by(skills ++ managed_prompts, & &1["name"])
  end

  defp get_prompt(%{"name" => name} = params, auth) when is_binary(name) and name != "" do
    case PromptRegistry.lookup(name) do
      nil -> get_skill_prompt(name)
      entry -> get_managed_prompt(entry, params["arguments"] || %{}, auth)
    end
  end

  defp get_prompt(_params, _auth),
    do: {:error, :invalid_params, "Invalid params: 'name' is required"}

  defp get_skill_prompt(name) do
    case Enum.find(SkillsRegistry.list(), &(&1.name == name)) do
      nil ->
        {:error, :not_found, "Prompt not found: not found"}

      skill ->
        case SkillsRegistry.fetch(skill.id) do
          {:ok, full_skill} ->
            {:ok,
             %{
               "description" => full_skill.description,
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => %{"type" => "text", "text" => full_skill.content || ""}
                 }
               ]
             }}

          {:error, :not_found} ->
            {:error, :not_found, "Prompt not found: not found"}
        end
    end
  end

  defp get_managed_prompt(entry, arguments, auth) when is_map(arguments) do
    if managed_prompt_authorized?(entry, auth) do
      case invoke_managed_prompt(entry, arguments, auth) do
        {:ok, prompt} ->
          {:ok, json_keys(prompt)}

        {:error, :invalid_arguments} ->
          {:error, :invalid_params, "Invalid params"}

        {:error, reason} when reason in [:not_found, :unauthorized] ->
          {:error, :not_found, "Prompt not found: not found"}

        {:error, _reason} ->
          log_managed_prompt_failure(entry)
          internal_error()

        :internal_error ->
          log_managed_prompt_failure(entry)
          internal_error()
      end
    else
      {:error, :not_found, "Prompt not found: not found"}
    end
  end

  defp get_managed_prompt(_entry, _arguments, _auth),
    do: {:error, :invalid_params, "Invalid params: 'arguments' must be an object"}

  defp invoke_managed_prompt(entry, arguments, auth) do
    entry.service.get_prompt(entry.name, arguments, auth)
  rescue
    _exception -> :internal_error
  catch
    _kind, _reason -> :internal_error
  end

  defp log_managed_prompt_failure(entry) do
    Logger.warning("Managed prompt failed",
      prompt_name: entry.name,
      prompt_service: inspect(entry.service)
    )
  end

  defp managed_prompt_authorized?(entry, %{kind: kind, client_id: client_id, scopes: scopes})
       when kind in [:oauth, :client_token] and is_binary(client_id) and client_id != "" and
              is_list(scopes) do
    entry.permission in scopes or "*" in scopes or "#{entry.prefix}::*" in scopes or
      entry.scope_target in scopes
  end

  defp managed_prompt_authorized?(_entry, %{kind: kind}) when kind in [:open, :legacy],
    do: true

  defp managed_prompt_authorized?(_entry, _auth), do: false

  defp build_prompt_arguments(skill) do
    Enum.map(skill[:tools] || [], fn tool ->
      %{"name" => tool, "description" => "Tool required: #{tool}", "required" => false}
    end)
  end

  defp compute_completions(
         %{"type" => "ref/tool", "name" => tool_name},
         %{"name" => arg_name} = argument
       ) do
    complete_tool_argument(tool_name, arg_name, argument["value"] || "")
  end

  defp compute_completions(
         %{"type" => "ref/prompt", "name" => prompt_name},
         %{"name" => _arg_name} = argument
       ) do
    complete_prompt_argument(prompt_name, argument["value"] || "")
  end

  defp compute_completions(_ref, _argument), do: []

  defp complete_tool_argument(_tool_name, "skill_id", prefix) do
    SkillsRegistry.list()
    |> Enum.map(& &1.id)
    |> filter_by_prefix(prefix)
  rescue
    _exception -> []
  end

  defp complete_tool_argument(_tool_name, "tool_name", prefix) do
    ToolRegistry.list_all()
    |> Enum.map(& &1.name)
    |> filter_by_prefix(prefix)
  rescue
    _exception -> []
  end

  defp complete_tool_argument(_tool_name, _arg_name, _prefix), do: []
  defp complete_prompt_argument(_prompt_name, _prefix), do: []
  defp filter_by_prefix(values, ""), do: Enum.take(values, 20)

  defp filter_by_prefix(values, prefix) do
    values
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.take(20)
  end

  defp management_tool?(name) when is_binary(name) do
    String.starts_with?(name, "admin::") or String.starts_with?(name, "hub::")
  end

  defp tool_to_json(tool, version) do
    base = %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => json_keys(tool.input_schema)
    }

    base =
      if supports_since?(version, "2025-03-26") and tool.annotations,
        do: Map.put(base, "annotations", json_keys(tool.annotations)),
        else: base

    base =
      if supports_since?(version, "2025-06-18") and tool.output_schema,
        do: Map.put(base, "outputSchema", json_keys(tool.output_schema)),
        else: base

    base =
      if Protocol.legacy?(version) and Info.version_gte?(version, "2025-11-25") and tool.icon,
        do: Map.put(base, "icon", json_keys(tool.icon)),
        else: base

    if Protocol.modern?(version) do
      base
      |> then(&if tool.title, do: Map.put(&1, "title", tool.title), else: &1)
      |> then(&if tool.icons, do: Map.put(&1, "icons", json_keys(tool.icons)), else: &1)
      |> then(&if tool.meta, do: Map.put(&1, "_meta", json_keys(tool.meta)), else: &1)
    else
      base
    end
  end

  defp supports_since?(version, threshold) do
    Protocol.modern?(version) or Info.version_gte?(version, threshold)
  end

  defp build_tool_call_result(result_name, result) do
    content = if is_map(result), do: result["content"] || result[:content]

    if is_list(content) do
      base = %{"content" => json_keys(content)}

      base =
        case fetch_key(result, "structuredContent", :structuredContent) do
          {:ok, structured_content} ->
            Map.put(base, "structuredContent", json_keys(structured_content))

          :error ->
            base
        end

      case fetch_key(result, "isError", :isError) do
        {:ok, true} -> Map.put(base, "isError", true)
        _other -> base
      end
    else
      tool = ToolRegistry.lookup(result_name)
      base = %{"content" => [%{"type" => "text", "text" => format_result(result)}]}

      if tool && tool.output_schema && is_map(result),
        do: Map.put(base, "structuredContent", json_keys(result)),
        else: base
    end
  end

  defp fetch_key(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, atom_key)
    end
  end

  defp format_result(result) when is_binary(result), do: result

  defp format_result(result) do
    case Jason.encode(result) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(result)
    end
  end

  defp format_error(message) when is_binary(message), do: message
  defp format_error(message), do: inspect(message)

  defp json_keys(value) when is_list(value), do: Enum.map(value, &json_keys/1)

  defp json_keys(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_keys(nested)} end)
  end

  defp json_keys(value), do: value

  defp internal_error, do: {:error, :internal_error, "Internal error"}
  defp failure_category(%module{}), do: inspect(module)
  defp failure_category(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_category(_reason), do: "runtime_failure"
end
