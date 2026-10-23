defmodule Backplane.AgentRuntime.Plugins.MCP do
  @moduledoc "Session-owned MCP connections using Backplane's shared protocol client."
  alias Backplane.McpProtocol.Client
  alias Backplane.AgentRuntime.Codex.PathGuard

  def start(config, opts) do
    key = {Keyword.fetch!(opts, :session), Keyword.fetch!(opts, :server)}
    client = {:via, Registry, {Backplane.AgentRuntime.PluginRegistry, {key, :client}}}
    transport_name = {:via, Registry, {Backplane.AgentRuntime.PluginRegistry, {key, :transport}}}

    with {:ok, transport} <- transport(config, opts),
         {:ok, supervisor} <-
           Client.start_link(
             name: client,
             transport_name: transport_name,
             transport: transport,
             client_info: %{"name" => "Backplane Plugin Runtime", "version" => "1.0.0"},
             protocol_version: :auto,
             timeout: Keyword.fetch!(opts, :timeout)
           ) do
      {:ok, %{supervisor: supervisor, client: client}}
    end
  end

  def tools(connection, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with :ok <- Client.await_ready(connection.client, timeout: timeout) do
      list_tools(connection.client, deadline, nil, MapSet.new(), [])
    end
  end

  defp list_tools(client, deadline, cursor, seen, pages) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         {:ok, response} <- Client.list_tools(client, timeout: remaining, cursor: cursor),
         result = Map.get(response, :result, Map.get(response, "result", response)),
         tools when is_list(tools) <- Map.get(result, "tools", Map.get(result, :tools)) do
      case Map.get(result, "nextCursor", Map.get(result, :nextCursor)) do
        nil ->
          {:ok, pages |> Enum.reverse() |> Enum.concat() |> Kernel.++(tools)}

        next when is_binary(next) and next != "" ->
          if MapSet.member?(seen, next) do
            {:error, :invalid_tool_cursor}
          else
            list_tools(client, deadline, next, MapSet.put(seen, next), [tools | pages])
          end

        _ ->
          {:error, :invalid_tool_cursor}
      end
    else
      _ -> {:error, :invalid_tool_catalog}
    end
  end

  def call(connection, name, arguments, timeout) do
    with {:ok, response} <- Client.call_tool(connection.client, name, arguments, timeout: timeout) do
      {:ok, Map.get(response, :result, Map.get(response, "result", response))}
    end
  end

  def stop(connection) do
    if Process.alive?(connection.supervisor), do: Supervisor.stop(connection.supervisor)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp transport(%{"type" => "stdio"} = config, opts) do
    root = Keyword.fetch!(opts, :root)

    command =
      if String.starts_with?(config["command"], "./"),
        do: Path.expand(config["command"], root),
        else: config["command"]

    cwd =
      case Map.get(config, "cwd") do
        nil -> root
        value -> Path.expand(value, root)
      end

    data_dir = Keyword.fetch!(opts, :data_dir)

    cwd_root =
      if cwd == data_dir or String.starts_with?(cwd, data_dir <> "/"), do: data_dir, else: root

    with {:ok, cwd} <- PathGuard.authorize(cwd_root, cwd),
         true <- File.dir?(cwd) do
      reserved = Map.take(Keyword.fetch!(opts, :env), ["PLUGIN_ROOT", "PLUGIN_DATA"])

      env =
        Keyword.fetch!(opts, :env)
        |> Map.merge(Map.get(config, "env", %{}))
        |> Map.merge(reserved)

      {:ok,
       {:stdio,
        [
          command: command,
          args: Map.get(config, "args", []),
          env: env,
          cwd: cwd
        ]}}
    else
      _ -> {:error, :invalid_working_directory}
    end
  end

  defp transport(%{"type" => "streamable-http"} = config, _opts),
    do:
      {:ok,
       {:streamable_http,
        [
          url: config["url"],
          headers: headers(config),
          http_options: [allowed_origin: config["url"]]
        ]}}

  defp transport(%{"type" => "sse"} = config, _opts) do
    uri = URI.parse(config["url"])
    origin = URI.to_string(%{uri | path: nil, query: nil, fragment: nil})
    path = (uri.path || "/sse") <> if(uri.query, do: "?" <> uri.query, else: "")

    {:ok,
     {:sse,
      [
        server: [base_url: origin, sse_path: path],
        headers: headers(config),
        http_options: [allowed_origin: config["url"]]
      ]}}
  end

  defp transport(_, _), do: {:error, :unsupported_transport}

  defp headers(config) do
    Map.get(config, "headers", %{})
    |> Map.new(fn {key, value} -> {String.downcase(key), value} end)
    |> Map.drop(
      ~w(content-type accept cache-control connection mcp-session-id mcp-protocol-version
      mcp-method mcp-resource-uri mcp-tool-name mcp-prompt-name)
    )
  end
end
