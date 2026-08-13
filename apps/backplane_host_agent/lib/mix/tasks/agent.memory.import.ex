defmodule Mix.Tasks.Agent.Memory.Import do
  @shortdoc "Imports host-local Claude Code JSONL through the durable capture pipeline"

  use Mix.Task

  alias Backplane.HostAgent.{Config, Connector, MemoryProxy}
  alias Backplane.HostAgent.Memory.{CaptureSupervisor, CaptureUploader, Import}
  alias Backplane.HostAgent.Memory.Import.Protocol

  @switches [
    path: :string,
    root: :keep,
    allow_symlinks: :boolean,
    max_files: :integer,
    max_entries: :integer,
    max_bytes: :integer,
    max_depth: :integer
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    Application.put_env(:backplane_host_agent, :start_on_application, false)
    {:ok, _apps} = Application.ensure_all_started(:backplane_host_agent)

    {cli, extras} = OptionParser.parse!(args, strict: @switches)
    if extras != [], do: Mix.raise("unexpected arguments: #{Enum.join(extras, " ")}")

    path = Keyword.get(cli, :path) || Mix.raise("--path is required")
    roots = Keyword.get_values(cli, :root)
    if roots == [], do: Mix.raise("at least one --root is required")

    with {:ok, config} <- Config.load_default(),
         {:ok, connection} <- Connector.connect(config),
         :ok <- MemoryProxy.set_connection(connection, config),
         {:ok, _capture} <- start_capture(config, connection.host_id),
         runtime <- Application.fetch_env!(:backplane_host_agent, :capture_runtime),
         {:ok, result} <- Import.run(path, import_opts(cli, roots, runtime, connection)) do
      Mix.shell().info(
        "Import #{result.status}: #{result.imported_count} imported, " <>
          "#{result.duplicate_count} duplicate, #{result.rejected_count} rejected " <>
          "(batch #{result.batch_id})."
      )
    else
      {:error, reason} -> Mix.raise("memory import failed: #{inspect(reason)}")
    end
  end

  defp start_capture(%{capture: %{enabled: true} = capture}, host_id) do
    CaptureSupervisor.start_link(Map.merge(capture, %{host_id: host_id, agent_id: "claude_code"}))
    |> normalize_started()
  end

  defp start_capture(_config, _host_id), do: {:error, :capture_disabled}
  defp normalize_started({:error, {:already_started, pid}}), do: {:ok, pid}
  defp normalize_started(result), do: result

  defp import_opts(cli, roots, runtime, connection) do
    reporter = fn payload ->
      with :ok <- maybe_drain(payload, runtime, connection),
           :ok <- Protocol.report(connection.channel, payload) do
        :ok
      end
    end

    [
      approved_roots: roots,
      allow_symlinks: Keyword.get(cli, :allow_symlinks, false),
      max_files: Keyword.get(cli, :max_files, 1_000),
      max_entries: Keyword.get(cli, :max_entries, 100_000),
      max_bytes: Keyword.get(cli, :max_bytes, 256 * 1024 * 1024),
      max_depth: Keyword.get(cli, :max_depth, 12),
      host_id: connection.host_id,
      agent_id: runtime.agent_id || "claude_code",
      spool: runtime.spool,
      spool_module: runtime.spool_module,
      reporter: reporter
    ]
  end

  defp maybe_drain(%{"action" => "completed"}, runtime, connection) do
    drain(runtime, connection, 1_000)
  end

  defp maybe_drain(_payload, _runtime, _connection), do: :ok

  defp drain(_runtime, _connection, 0), do: {:error, :import_upload_limit_exceeded}

  defp drain(runtime, connection, remaining) do
    case CaptureUploader.drain_once(
           spool: runtime.spool,
           spool_module: runtime.spool_module,
           channel: connection.channel,
           host_id: connection.host_id
         ) do
      {:ok, %{"status" => "empty"}} -> :ok
      {:ok, _summary} -> drain(runtime, connection, remaining - 1)
      {:error, reason} -> {:error, {:import_upload_failed, reason}}
    end
  end
end
