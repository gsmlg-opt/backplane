defmodule Backplane.AgentRuntime.Plugins.MCP do
  @moduledoc "Session-owned MCP connections using Backplane's shared protocol client."
  alias Backplane.McpProtocol.Client
  alias Backplane.AgentRuntime.Error
  alias Backplane.McpProtocol.Transport.STDIO.Guardian
  alias Backplane.AgentRuntime.Codex.PathGuard

  def start(config, opts) do
    activation_id =
      Keyword.get_lazy(opts, :activation_id, fn ->
        Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      end)

    key = {Keyword.fetch!(opts, :session), Keyword.fetch!(opts, :server)}
    client = {:via, Registry, {Backplane.AgentRuntime.PluginRegistry, {key, :client}}}
    transport_name = {:via, Registry, {Backplane.AgentRuntime.PluginRegistry, {key, :transport}}}

    with {:ok, transport} <- transport(config, opts),
         {:ok, supervisor} <-
           Client.start_link(
             name: client,
             one_shot: true,
             activation_id: activation_id,
             transport_name: transport_name,
             transport: transport,
             client_info: %{"name" => "Backplane Plugin Runtime", "version" => "1.0.0"},
             protocol_version: :auto,
             timeout: Keyword.fetch!(opts, :timeout)
           ) do
      {:ok,
       %{
         supervisor: supervisor,
         client: client,
         transport: transport_name,
         activation_id: activation_id,
         transport_kind: elem(transport, 0)
       }}
    end
  end

  def tools(connection, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with :ok <- Client.await_ready(connection.client, timeout: timeout) do
      list_tools(connection.client, deadline, nil, %{}, [])
    end
  end

  @spec list_tools(GenServer.server(), number(), String.t() | nil, map(), [list()]) ::
          {:ok, list()} | {:error, :invalid_tool_cursor | :invalid_tool_catalog}
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
          if Map.has_key?(seen, next) do
            {:error, :invalid_tool_cursor}
          else
            list_tools(client, deadline, next, Map.put(seen, next, true), [tools | pages])
          end

        _ ->
          {:error, :invalid_tool_cursor}
      end
    else
      _ -> {:error, :invalid_tool_catalog}
    end
  end

  def call(connection, name, arguments, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, handle} <-
           Client.start_tool_call(connection.client, name, arguments,
             timeout: timeout,
             registration_timeout: timeout
           ),
         {:ok, response} <-
           Client.await_tool_call(handle, max(0, deadline - System.monotonic_time(:millisecond))) do
      {:ok, Map.get(response, :result, Map.get(response, "result", response))}
    end
  end

  @doc "Observe the connection's typed local cleanup evidence within one finite budget."
  def close(connection, opts \\ []) do
    with {:ok, report} <- Client.close_connection(connection.supervisor, opts),
         true <- valid_close_report?(report) do
      {:ok, report}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, Error.new(:unknown_outcome, "invalid MCP connection cleanup report")}
    end
  catch
    :exit, _ ->
      {:error, Error.new(:unknown_outcome, "MCP connection cleanup could not be observed")}
  end

  def stop(connection) do
    result = close(connection)

    if confirmed_close?(result, connection.activation_id),
      do: :ok,
      else: {:error, Error.new(:unknown_outcome, "MCP connection cleanup is unconfirmed")}
  end

  @doc false
  def confirmed_close?({:ok, report}, activation_id) do
    valid_close_report?(report) and report.activation_id == activation_id and
      report.outcome == :confirmed and
      match?({:ok, %{phase: :closed, outcome: :confirmed}}, report.transport) and
      elem(report.transport, 1).activation_id == report.activation_id and
      elem(report.transport, 1).close_id == report.close_id and
      confirmed_resources?(elem(report.transport, 1).resources) and
      match?({:ok, %{outcome: :confirmed}}, report.client_workers) and
      confirmed_resources?(elem(report.client_workers, 1).resources) and
      report.supervisor.outcome == :confirmed and report.supervisor.evidence[:down] == true
  end

  def confirmed_close?(_, _), do: false

  defp valid_close_report?(%{
         version: 1,
         close_id: close_id,
         activation_id: activation_id,
         outcome: outcome,
         transport: transport,
         client_workers: workers,
         supervisor: %{outcome: supervisor_outcome, evidence: evidence, error: _}
       }) do
    (is_nil(close_id) or identifier?(close_id)) and
      (is_nil(activation_id) or identifier?(activation_id)) and
      outcome in [:confirmed, :unconfirmed] and valid_transport?(transport) and
      valid_workers?(workers) and supervisor_outcome in [:confirmed, :uncertain, :unconfirmed] and
      is_map(evidence)
  end

  defp valid_close_report?(_), do: false

  defp valid_transport?(
         {:ok,
          %{
            version: 1,
            close_id: close_id,
            activation_id: activation_id,
            transport: transport,
            phase: phase,
            outcome: outcome,
            resources: resources,
            remote: %{outcome: :unknown, session_delete: _}
          }}
       ) do
    identifier?(close_id) and identifier?(activation_id) and
      transport in [:stdio, :sse, :streamable_http] and
      phase in [:closing, :closed] and outcome in [:pending, :confirmed, :unconfirmed] and
      valid_resources?(resources)
  end

  defp valid_transport?({:error, %Backplane.McpProtocol.MCP.Error{}}), do: true
  defp valid_transport?(_), do: false

  defp valid_workers?({:ok, %{outcome: outcome, resources: resources}}),
    do: outcome in [:confirmed, :unconfirmed] and valid_resources?(resources)

  defp valid_workers?({:error, _}), do: true
  defp valid_workers?(_), do: false

  defp valid_resources?(resources) when is_list(resources),
    do:
      Enum.all?(resources, fn
        %{id: id, scope: _, outcome: outcome, evidence: evidence, error: _} ->
          resource_id?(id) and outcome in [:pending, :confirmed, :failed, :uncertain] and
            is_map(evidence)

        _ ->
          false
      end)

  defp valid_resources?(_), do: false

  defp identifier?(value),
    do: (is_binary(value) and byte_size(value) in 1..1024) or is_reference(value)

  defp resource_id?(value) when is_binary(value), do: identifier?(value)

  defp resource_id?({activation, id}),
    do: identifier?(activation) and (identifier?(id) or is_atom(id))

  defp resource_id?(_), do: false
  defp confirmed_resources?(resources), do: Enum.all?(resources, &(&1.outcome == :confirmed))

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
         true <- File.dir?(cwd),
         :ok <- Guardian.available(Keyword.get(opts, :guardian_path, Guardian.path())) do
      reserved = Map.take(Keyword.fetch!(opts, :env), ["PLUGIN_ROOT", "PLUGIN_DATA"])

      env =
        Keyword.fetch!(opts, :env)
        |> Map.merge(Map.get(config, "env", %{}))
        |> Map.merge(reserved)

      {:ok,
       {:stdio,
        [
          cleanup: :verified,
          command: command,
          args: Map.get(config, "args", []),
          env: env,
          cwd: cwd
        ] ++ Keyword.take(opts, [:guardian_path])}}
    else
      {:error, {:verified_stdio_unavailable, _}} ->
        {:error,
         Error.new(:unsupported_capability, "verified plugin stdio guardian is unavailable",
           details: %{allocation: :not_started, reason: :guardian_missing_or_unsupported}
         )}

      _ ->
        {:error, :invalid_working_directory}
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
