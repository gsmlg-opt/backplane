defmodule Mix.Tasks.Memory.Replay.BrowserQualify do
  @shortdoc "Qualify the Memory V2 replay UI in headless Chrome"

  @moduledoc """
  Seeds a disposable exact-partition replay with more than one page of events,
  drives the routed admin LiveView through Chrome DevTools Protocol, and writes
  a content-free JSON qualification report.

  This task is intentionally restricted to `MIX_ENV=test`.
  """

  use Mix.Task

  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Projections.Rebuild

  @requirements ["app.config"]
  @event_count 121

  @impl Mix.Task
  def run(args) do
    if Mix.env() != :test, do: Mix.raise("memory.replay.browser_qualify requires MIX_ENV=test")

    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [report: :string, browser: :string])

    if rest != [] or invalid != [], do: Mix.raise("invalid arguments")

    report_path = Keyword.get(opts, :report, "memory-v2-replay-browser.json")
    admin_port = free_port()
    debugging_port = free_port()
    configure_admin_endpoint(admin_port)

    {:ok, _apps} = Application.ensure_all_started(:backplane_admin)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :manual)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Backplane.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, {:shared, self()})

    try do
      qualify!(opts, report_path, admin_port, debugging_port)
    after
      Ecto.Adapters.SQL.Sandbox.checkin(Backplane.Repo)
    end

    Mix.shell().info("Replay browser qualification passed: #{report_path}")
  end

  defp qualify!(opts, report_path, admin_port, debugging_port) do
    run_id = Ecto.UUID.generate()
    partition = partition(run_id)
    session_id = "browser-qualification-#{run_id}"

    seed!(partition, session_id, 1..@event_count)
    assert_rebuild!(partition.host_id, session_id)

    url =
      "http://127.0.0.1:#{admin_port}/memory/replay?" <>
        URI.encode_query(%{
          "host" => partition.host_id,
          "client" => partition.client_id,
          "scope" => partition.scope,
          "namespace" => partition.namespace,
          "session" => session_id
        })

    script = Application.app_dir(:backplane_memory, "priv/browser/replay_qualification.mjs")
    browser = Keyword.get(opts, :browser, "")
    File.mkdir_p!(Path.dirname(report_path))

    port =
      Port.open(
        {:spawn_executable, System.find_executable("node") || Mix.raise("node not found")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [script, url, report_path, Integer.to_string(debugging_port), browser]
        ]
      )

    await_browser!(port, "", partition, session_id)
  end

  defp await_browser!(port, output, partition, session_id) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data
        Mix.shell().info(String.trim_trailing(data))

        if String.contains?(output, "READY_FOR_PUBSUB") do
          seed!(partition, session_id, 122..122)
          result = assert_rebuild!(partition.host_id, session_id)

          Phoenix.PubSub.broadcast(
            Backplane.PubSub,
            "memory:v2:replay",
            {:memory_replay_updated,
             %{"session_id" => session_id, "input_revision" => result.input_revision}}
          )

          await_exit!(port, String.replace(output, "READY_FOR_PUBSUB", "", global: false))
        else
          await_browser!(port, output, partition, session_id)
        end

      {^port, {:exit_status, status}} ->
        Mix.raise(
          "browser qualification exited before PubSub check with status #{status}: #{output}"
        )
    after
      60_000 -> Mix.raise("browser qualification timed out before PubSub check")
    end
  end

  defp await_exit!(port, output) do
    receive do
      {^port, {:data, data}} ->
        Mix.shell().info(String.trim_trailing(data))
        await_exit!(port, output <> data)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        Mix.raise("browser qualification failed with status #{status}: #{output}")
    after
      60_000 -> Mix.raise("browser qualification timed out after PubSub check")
    end
  end

  defp configure_admin_endpoint(port) do
    current = Application.get_env(:backplane_admin, Backplane.Admin.Endpoint, [])

    Application.put_env(
      :backplane_admin,
      Backplane.Admin.Endpoint,
      Keyword.merge(current, server: true, http: [ip: {127, 0, 0, 1}, port: port])
    )
  end

  defp seed!(partition, session_id, range) do
    Enum.each(range, fn sequence ->
      event_type =
        if rem(sequence, 2) == 1,
          do: "agent.prompt.submitted",
          else: "conversation.agent_message"

      source =
        if rem(sequence, 2) == 1,
          do: %{"prompt" => "qualification event #{sequence}"},
          else: %{"message" => "qualification event #{sequence}"}

      attrs =
        Map.merge(partition, %{
          id: Ecto.UUID.generate(),
          stream_id: "capture:#{partition.host_id}:#{session_id}",
          session_id: session_id,
          sequence: sequence,
          source_sequence: sequence,
          event_type: event_type,
          occurred_at: DateTime.add(~U[2026-08-12 00:00:00.000000Z], sequence),
          idempotency_key: "#{session_id}:#{sequence}",
          payload: %{"source" => source},
          payload_hash: "sha256:browser-qualification:#{sequence}",
          schema_version: 1
        })

      case Store.append_tagged(attrs) do
        {:ok, {:inserted, _event}} -> :ok
        other -> Mix.raise("failed to seed replay event #{sequence}: #{inspect(other)}")
      end
    end)
  end

  defp assert_rebuild!(host_id, session_id) do
    case Rebuild.session(host_id, session_id) do
      {:ok, result} -> result
      other -> Mix.raise("failed to rebuild replay: #{inspect(other)}")
    end
  end

  defp partition(run_id) do
    %{
      host_id: "browser-host-#{run_id}",
      client_id: "browser-client",
      scope: "browser-qualification",
      namespace: "private"
    }
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
