defmodule Backplane.AgentRuntime.Plugins.Session do
  @moduledoc """
  Activates one immutable plugin installation for one run.

  Skills remain available when individual MCP servers fail. Connections belong
  to this process, never to the gateway's global upstream or tool registry.
  Credentials are supplied by the host in :env and are not part of the package.
  """
  use GenServer
  alias Backplane.AgentRuntime.{Error, ToolCatalog}
  alias Backplane.AgentRuntime.Plugins.{Backend, MCP}
  alias Backplane.PluginProtocol
  alias Backplane.AgentRuntime.Codex.PathGuard

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def snapshot(session), do: GenServer.call(session, :snapshot)
  def catalog(session, run_id), do: GenServer.call(session, {:catalog, run_id})
  def load_skill(session, run_id, path), do: GenServer.call(session, {:skill, run_id, path})
  def resource(session, run_id, path), do: GenServer.call(session, {:resource, run_id, path})

  def call_tool(session, run_id, name, arguments),
    do: GenServer.call(session, {:call, run_id, name, arguments}, :infinity)

  def stop(session), do: GenServer.stop(session)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    installation = Keyword.fetch!(opts, :installation)
    root_input = Path.expand(Map.fetch!(installation, :root))
    data_input = Path.expand(Map.fetch!(installation, :data_dir))
    run_id = Keyword.fetch!(opts, :run_id)

    with true <- Map.get(installation, :enabled, true),
         true <- is_binary(run_id) and run_id != "",
         {:ok, root} <- PathGuard.authorize(root_input, root_input),
         :ok <- File.mkdir_p(data_input),
         {:ok, data_dir} <- PathGuard.authorize(data_input, data_input),
         true <-
           root != data_dir and not String.starts_with?(data_dir, root <> "/") and
             not String.starts_with?(root, data_dir <> "/"),
         {:ok, package} <- PluginProtocol.load_directory(root),
         :ok <- verify_installation(root, installation) do
      state = %{
        run_id: run_id,
        installation: installation,
        root: root,
        data_dir: data_dir,
        package: package,
        connections: %{},
        tools: %{},
        components: %{},
        diagnostics: package.diagnostics,
        adapter: Keyword.get(opts, :mcp_adapter, MCP),
        timeout: Keyword.get(opts, :timeout, 5_000),
        bindings: Keyword.get(opts, :bindings, %{})
      }

      env =
        Keyword.get(opts, :env, %{})
        |> Map.merge(%{"PLUGIN_ROOT" => root, "PLUGIN_DATA" => data_dir})

      {:ok, activate(state, env)}
    else
      false -> {:stop, :invalid_plugin_session}
      {:error, reason} -> {:stop, {:plugin_load_failed, reason}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       run_id: state.run_id,
       plugin_id: state.installation.plugin_id,
       release_id: state.installation.release_id,
       artifact_digest: state.installation.artifact_digest,
       skills: skills(state),
       components: state.components,
       diagnostics: state.diagnostics
     }, state}
  end

  def handle_call({:catalog, run_id}, _from, %{run_id: run_id} = state) do
    {:reply, admit(state.tools, run_id), state}
  end

  def handle_call({:skill, run_id, path}, _from, %{run_id: run_id} = state) do
    found = Enum.find(skills(state), &(&1.path == path))
    {:reply, if(found, do: {:ok, found}, else: {:error, :not_found}), state}
  end

  def handle_call({:resource, run_id, path}, _from, %{run_id: run_id} = state) do
    {:reply, Map.fetch(state.package.files, path), state}
  end

  def handle_call({:call, run_id, name, args}, _from, %{run_id: run_id} = state) do
    case Map.fetch(state.tools, name) do
      {:ok, tool} ->
        connection = Map.fetch!(state.connections, tool.server)
        result = safely(fn -> state.adapter.call(connection, tool.name, args, state.timeout) end)
        {:reply, result, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, Error.new(:forbidden, "plugin session belongs to another run")}, state}

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    failed = for {name, conn} <- state.connections, conn.supervisor == pid, do: name
    components = Enum.reduce(failed, state.components, &Map.put(&2, &1, %{status: :unavailable}))
    tools = Map.reject(state.tools, fn {_key, tool} -> tool.server in failed end)
    {:noreply, %{state | components: components, tools: tools}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.update(status, :state, %{}, fn state ->
      Map.drop(state, [:bindings, :package, :connections, :tools])
    end)
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.connections, fn {_name, conn} ->
      safely(fn -> state.adapter.stop(conn) end)
    end)
  end

  defp skills(state) do
    Enum.map(state.package.skills, fn skill ->
      Map.merge(skill, %{
        plugin_id: state.installation.plugin_id,
        release_id: state.installation.release_id,
        plugin_root: state.root,
        data_dir: state.data_dir
      })
    end)
  end

  defp activate(state, env) do
    Enum.reduce(state.package.mcp_servers, state, fn {name, config}, acc ->
      opts = [
        session: self(),
        server: name,
        root: state.root,
        data_dir: state.data_dir,
        env: env,
        timeout: state.timeout
      ]

      result =
        safely(fn ->
          with {:ok, expanded} <- expand_config(config, env),
               expanded = bind(expanded, Map.get(acc.bindings, name, %{})),
               {:ok, connection} <- acc.adapter.start(expanded, opts) do
            prepared =
              safely(fn ->
                with {:ok, tools} when is_list(tools) <-
                       acc.adapter.tools(connection, acc.timeout),
                     entries = Map.new(tools, fn tool -> tool_entry(acc, name, tool) end),
                     true <- map_size(entries) == length(tools),
                     true <- Enum.all?(Map.keys(entries), &(not Map.has_key?(acc.tools, &1))),
                     {:ok, admitted} <- admit(entries, acc.run_id) do
                  {:ok, Map.take(entries, admitted.accepted)}
                else
                  _ -> {:error, :invalid_tool_catalog}
                end
              end)

            case prepared do
              {:ok, entries} ->
                {:ok, {connection, entries}}

              error ->
                safely(fn -> acc.adapter.stop(connection) end)
                error
            end
          end
        end)

      case result do
        {:ok, {connection, entries}} ->
          %{
            acc
            | connections: Map.put(acc.connections, name, connection),
              tools: Map.merge(acc.tools, entries),
              components:
                Map.put(acc.components, name, %{status: :ready, tools: map_size(entries)})
          }

        {:error, _reason} ->
          diagnostic = %{
            severity: :error,
            code: :mcp_unavailable,
            path: "mcp.json/" <> name,
            message: "MCP server could not be activated; other components remain available"
          }

          %{
            acc
            | components: Map.put(acc.components, name, %{status: :unavailable}),
              diagnostics: acc.diagnostics ++ [diagnostic]
          }
      end
    end)
  end

  defp admit(entries, run_id) do
    descriptors = entries |> Map.values() |> Enum.map(& &1.descriptor)

    authority = %{
      caller: "plugin-host",
      run_id: run_id,
      grants: Enum.map(descriptors, & &1.tool_name),
      tool_revisions: Map.new(descriptors, &{&1.tool_name, 1})
    }

    ToolCatalog.admit_batch(descriptors, authority: authority, run_id: run_id, mode: :quarantine)
  end

  defp tool_entry(state, server, %{"name" => tool_name} = tool)
       when is_binary(tool_name) and tool_name != "" do
    prefix =
      :crypto.hash(:sha256, state.installation.plugin_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    name = "plugin_" <> prefix <> "_" <> server <> "::" <> tool["name"]
    annotations = Map.get(tool, "annotations", %{})

    descriptor = %{
      tool_name: name,
      tool_revision: 1,
      description: Map.get(tool, "description", ""),
      schema: Map.get(tool, "inputSchema", %{"type" => "object", "properties" => %{}}),
      safety: %{
        read_only: annotations["readOnlyHint"] == true,
        retry_safe: annotations["idempotentHint"] == true,
        parallel_safe: false
      },
      backend: Backend,
      backend_context: %{session: self()}
    }

    {name, %{server: server, name: tool["name"], descriptor: descriptor}}
  end

  # The specification reserves exactly these two placeholders. Other strings
  # stay literal; credentials are separately bound by the host per server.
  defp expand_config(%{"type" => "stdio"} = config, env) do
    Enum.reduce_while(["args", "env", "cwd"], {:ok, config}, fn field, {:ok, acc} ->
      if Map.has_key?(config, field) do
        case expand(config[field], env) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp expand_config(config, _env), do: {:ok, config}

  defp expand(value, env) when is_binary(value) do
    {:ok,
     Regex.replace(~r/\$\{(PLUGIN_ROOT|PLUGIN_DATA)\}/, value, fn _, key ->
       Map.fetch!(env, key)
     end)}
  end

  defp expand(value, env) when is_map(value), do: expand_pairs(value, env, %{})

  defp expand(value, env) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, items} ->
      case expand(item, env) do
        {:ok, next} -> {:cont, {:ok, items ++ [next]}}
        error -> {:halt, error}
      end
    end)
  end

  defp expand(value, _env), do: {:ok, value}

  defp expand_pairs(value, env, acc) do
    Enum.reduce_while(value, {:ok, acc}, fn {key, item}, {:ok, result} ->
      case expand(item, env) do
        {:ok, expanded} -> {:cont, {:ok, Map.put(result, key, expanded)}}
        error -> {:halt, error}
      end
    end)
  end

  defp bind(config, bindings) do
    Enum.reduce(["env", "headers"], config, fn field, acc ->
      case Map.get(bindings, field) do
        nil ->
          acc

        values when is_map(values) ->
          existing = Map.get(acc, field, %{})

          {existing, values} =
            if field == "headers" do
              normalize = fn map ->
                Map.new(map, fn {key, value} -> {String.downcase(key), value} end)
              end

              {normalize.(existing), normalize.(values)}
            else
              {existing, values}
            end

          Map.put(acc, field, Map.merge(existing, values))
      end
    end)
  end

  defp verify_installation(root, %{content_digest: digest}) when is_binary(digest) do
    alias Backplane.PluginProtocol.Archive

    with {:ok, snapshot} <- Archive.read_directory_with_metadata(root),
         {:ok, bytes} <- Archive.pack(snapshot.files, modes: snapshot.modes),
         true <- Archive.digest(bytes) == digest do
      :ok
    else
      _ -> {:error, :installed_content_changed}
    end
  end

  defp verify_installation(_root, _installation), do: :ok

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :mcp_unavailable}
  catch
    :exit, _ -> {:error, :mcp_unavailable}
  end
end
