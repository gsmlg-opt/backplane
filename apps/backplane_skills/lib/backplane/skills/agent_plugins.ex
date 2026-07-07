defmodule Backplane.Skills.AgentPlugins do
  @moduledoc """
  Client helpers for host-agent packaged plugin management.
  """

  alias Backplane.Skills.AgentManage

  @default_http_port 4222
  @receive_timeout 5_000
  @plugin_call_timeout 30_000

  @doc "Supported packaged host-agent plugins known to the admin UI."
  def packaged_plugins do
    [
      %{
        "plugin" => "memory",
        "name" => "Backplane Memory",
        "runtimes" => ["hermes", "openclaw"]
      }
    ]
  end

  @doc "Returns the host-agent local MCP endpoint for plugin management."
  def endpoint(entry) do
    case http_port(entry) do
      port when is_integer(port) and port > 0 ->
        with {:ok, host} <- http_host(entry) do
          {:ok, "http://#{host}:#{port}/memory/#{entry.host.id}/mcp"}
        end

      0 ->
        {:error, :http_disabled}

      _port ->
        {:error, :http_unavailable}
    end
  end

  @doc "Lists plugin install status from the host agent."
  def list(entry) do
    case call_tool(entry, "host_agent::list_plugins", %{}) do
      {:ok, %{"plugins" => plugins}} when is_list(plugins) -> {:ok, plugins}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Installs or updates a plugin on the host agent."
  def install(entry, params) when is_map(params) do
    call_tool(entry, "host_agent::install_plugin", plugin_args(params))
  end

  @doc "Removes a plugin from the host agent."
  def remove(entry, params) when is_map(params) do
    call_tool(entry, "host_agent::remove_plugin", plugin_args(params))
  end

  defp call_tool(%{status: :online, host: %{id: host_id}} = entry, tool_name, arguments)
       when is_binary(host_id) do
    case AgentManage.call_local_tool(host_id, tool_name, arguments, plugin_call_timeout()) do
      {:error, :not_connected} -> call_tool_http(entry, tool_name, arguments)
      result -> result
    end
  end

  defp call_tool(entry, tool_name, arguments), do: call_tool_http(entry, tool_name, arguments)

  defp call_tool_http(entry, tool_name, arguments) do
    with {:ok, url} <- endpoint(entry),
         {:ok, response} <- post_json_rpc(url, tool_name, arguments) do
      decode_json_rpc_response(response)
    end
  end

  defp post_json_rpc(url, tool_name, arguments) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => arguments}
    }

    request_opts =
      [
        json: body,
        receive_timeout: @receive_timeout,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:backplane_skills, :host_agent_plugin_req_options, []))

    case Req.post(url, request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json_rpc_response(%{"result" => %{"isError" => false, "content" => content}}) do
    content
    |> List.wrap()
    |> Enum.find_value(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> decode_text_result(text)
      _item -> nil
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :empty_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_json_rpc_response(%{"result" => %{"isError" => true, "content" => content}}) do
    {:error, text_content(content)}
  end

  defp decode_json_rpc_response(%{"error" => %{"message" => message}}), do: {:error, message}
  defp decode_json_rpc_response(%{"result" => result}), do: {:ok, result}
  defp decode_json_rpc_response(other), do: {:error, {:unexpected_response, other}}

  defp decode_text_result(text) do
    case Jason.decode(text) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:ok, text}
    end
  end

  defp text_content(content) do
    content
    |> List.wrap()
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      item -> inspect(item)
    end)
    |> Enum.join("\n")
  end

  defp plugin_args(params) do
    %{
      "plugin" => params["plugin"] || params[:plugin] || "memory",
      "runtime" => params["runtime"] || params[:runtime] || "hermes"
    }
    |> maybe_put_string("target_path", params["target_path"] || params[:target_path])
    |> maybe_put_bool("force", params["force"] || params[:force])
  end

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, _key, ""), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_bool(map, _key, nil), do: map
  defp maybe_put_bool(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp maybe_put_bool(map, key, "true"), do: Map.put(map, key, true)
  defp maybe_put_bool(map, key, "false"), do: Map.put(map, key, false)
  defp maybe_put_bool(map, _key, _value), do: map

  defp http_host(entry) do
    bind = entry |> agent_config() |> get_value("http_bind") |> blank_to_nil()

    case bind do
      nil -> {:ok, "127.0.0.1"}
      "0.0.0.0" -> connect_host(entry)
      "::" -> connect_host(entry)
      host when is_binary(host) -> {:ok, host}
      _host -> {:error, :http_unavailable}
    end
  end

  defp connect_host(%{connect_ip: ip}) when is_binary(ip) and ip != "", do: {:ok, ip}
  defp connect_host(_entry), do: {:error, :connect_ip_unavailable}

  defp http_port(entry) do
    entry
    |> agent_config()
    |> get_value("http_port")
    |> parse_port()
    |> case do
      nil -> @default_http_port
      port -> port
    end
  end

  defp agent_config(%{config: %{"agent" => agent}}) when is_map(agent), do: agent
  defp agent_config(%{config: config}) when is_map(config), do: config
  defp agent_config(_entry), do: %{}

  defp get_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp blank_to_nil(value) when value in ["", nil], do: nil
  defp blank_to_nil(value), do: value

  defp parse_port(port) when is_integer(port), do: port

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {value, ""} -> value
      _other -> nil
    end
  end

  defp parse_port(_port), do: nil

  defp plugin_call_timeout do
    Application.get_env(:backplane_skills, :host_agent_plugin_call_timeout, @plugin_call_timeout)
  end
end
