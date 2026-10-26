# Manual live acceptance, deliberately outside ExUnit discovery.
#
# In the supported development shell, with PostgreSQL already available:
#   MIX_ENV=test BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL=1 \
#   MIX_TEST_PARTITION=_hermeslive_<12-to-32-random-lowercase-hex-digits> \
#   HERMES_PYTHON=/absolute/path/to/the/real/hermes/venv/bin/python \
#   mix run --no-start test/hermes_memory_live_acceptance.exs
#
# OPENROUTER_API_KEY is read only from the environment. The optional
# HERMES_LIVE_MODEL defaults to openai/gpt-4.1-mini. This script creates, migrates,
# and drops ONLY its newly created partition database; an existing DB is refused.
# It never reads user gateway/agent ports, writes credentials to files, or uses
# an inference/transport adapter. Required failures remain red in the final JSON.

defmodule Backplane.HermesLiveAcceptance do
  import Ecto.Query

  Code.require_file("support/hermes_semantic_oracle.exs", __DIR__)

  alias Backplane.{Repo, Settings}
  alias Backplane.HostAgent.{Channel, Config, MemoryProxy, MemoryRouter, Worker}
  alias Backplane.HostAgent.Memory.Access
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Backplane.Memory.Projections.{ProjectedSession, RepairFrontier, State}
  alias Backplane.Memory.Sources.{Entry, Mutation, RequestEvidence}
  alias Backplane.Memory.Sources.Source, as: NativeSource
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}

  @timeout 90_000
  @resource_key {__MODULE__, :resources}
  @result_key {__MODULE__, :results}
  @semantic_diagnostics_key {__MODULE__, :synthetic_semantic_diagnostics}

  defmodule Error do
    defexception [:code, diagnostics: %{}, message: "Hermes acceptance gate failed"]
  end

  def main do
    Process.flag(:trap_exit, true)
    Process.put(@resource_key, %{pids: [], apps: [], python: nil, suspended: nil})
    Process.put(@result_key, [])
    Process.put(@semantic_diagnostics_key, [])
    Logger.configure(level: :emergency)

    try do
      guard_environment!()
      prepare_database!()
      start_gateway!()
      fixture = prepare_fixture!()
      put_resource(:host_id, fixture.host.id)
      put_resource(:base_url, fixture.base_url)
      start_worker!(fixture.config)
      start_python!(fixture)
      boot = python!("boot")

      gate("authenticated_negotiation", fn ->
        ready!(fixture.base_url)

        %{
          real_http: true,
          real_websocket: true,
          default_capture_binding: true,
          hermes_runtime: boot["runtime"]
        }
      end)

      # Native/capture/restart cases are independent of LLM availability.
      native_ok =
        gate("native_sources", fn ->
          python!("settle")
          added = python!("native_add")
          original_id = added["canonical_id"]
          assert_sources!(fixture.host.id, boot["identities"], original_id, 2)
          python!("native_replace")
          assert_sources!(fixture.host.id, boot["identities"], original_id, 1)
          gate("native_replacement_context", fn -> python!("replacement_context") end)
          python!("native_withdraw")
          assert_sources!(fixture.host.id, boot["identities"], original_id, 1)
          gate("native_withdrawal_context", fn -> python!("withdrawn_context") end)
          corrected = python!("native_correct")
          assert_sources!(fixture.host.id, boot["identities"], corrected["canonical_id"], 1)
          replay = python!("immutable_replay")

          assert!(
            Repo.aggregate(from(m in Mutation, where: m.id == ^replay["event_id"]), :count) == 1,
            "immutable_replay_created_duplicate_mutation"
          )

          assert!(
            Repo.get!(Memory, original_id).effective_support == false,
            "old_native_value_retained_support"
          )

          Map.take(replay, ["duplicate_receipt", "conflict_rejected"])
        end)

      if native_ok do
        gate("native_only_context", fn -> python!("context") end)
      else
        blocked("native_only_context", "native_sources")
      end

      if System.get_env("HERMES_LIVE_BOUNDARY_ONLY") == "1" do
        gate("boundary_delivery_diagnostics", fn ->
          %{provider: python!("diagnostic_delivery"), host: host_diagnostics()}
        end)
      else
        gate("socket_outage_and_provider_process_restart", fn ->
          worker = resource(:worker)
          previous = live_connection(nil)
          assert!(not is_nil(previous), "outage_initial_connection_not_live")
          :ok = :sys.suspend(worker)
          put_resource(:suspended, worker)

          try do
            :ok = Channel.retire_socket(previous.socket)
            pending = python!("outage_pending")
            stop_python!()
            start_python!(fixture)
            python!("boot")
            :ok = :sys.resume(worker)
            put_resource(:suspended, nil)
            ready!(fixture.base_url, previous)
            restart = python!("verify_restart")
            Map.merge(pending, Map.take(restart, ["immutable_deliveries_preserved"]))
          after
            resume_owned_worker()
          end
        end)

        gate("full_owned_host_restart", fn ->
          before = python!("snapshot")
          previous = live_connection(nil)
          assert!(not is_nil(previous), "restart_initial_connection_not_live")
          stop_python!()
          stop_worker!()
          start_worker!(fixture.config)
          ready!(fixture.base_url, previous)
          start_python!(fixture)
          python!("boot")
          python!("verify_restart")
          Map.put(before, "same_host_databases", true)
        end)

        gate("hermes_required_checkpoint_failure_blocks_compression", fn ->
          python!("required_checkpoint_failure")
        end)

        captured =
          gate("canonical_capture_and_projection", fn ->
            capture = python!("capture")
            verify_capture!(fixture.host.id, capture)
          end)

        if captured do
          if fixture.model_available do
            gate("real_async_summary_extraction_and_embedding", fn ->
              verify_processing!(fixture.host.id, "hermes-live-#{fixture.marker}-a", fixture)
            end)
          else
            blocked(
              "real_async_summary_extraction_and_embedding",
              "BLOCKED_ENV:OPENROUTER_API_KEY_missing"
            )
          end

          gate("current_context_after_capture", fn -> python!("context") end)
        else
          blocked(
            "real_async_summary_extraction_and_embedding",
            "canonical_capture_and_projection"
          )

          blocked("current_context_after_capture", "canonical_capture_and_projection")
        end

        if native_ok do
          gate("intentional_global_forget", fn ->
            forgotten = python!("forget")
            id = forgotten["canonical_id"]
            assert!(not is_nil(Repo.get!(Memory, id).deleted_at), "global_forget_not_durable")
            current = Backplane.Memory.CurrentContext.query(Memory)

            assert!(
              Repo.aggregate(from(m in current, where: m.id == ^id), :count) == 0,
              "global_forget_left_current_support"
            )

            forgotten
          end)

          gate("complete_final_fixture_state", fn ->
            verify_final_state!(fixture, boot["identities"], python!("final_state"))
          end)
        else
          blocked("intentional_global_forget", "native_sources")
          blocked("complete_final_fixture_state", "native_sources")
        end
      end
    rescue
      error in Error ->
        record("startup", "failed", %{code: error.code, diagnostics: error.diagnostics})

      error ->
        record("startup", "failed", %{
          code: "exception:#{inspect(error.__struct__)}",
          frames: exception_frames(__STACKTRACE__)
        })
    catch
      kind, _reason -> record("startup", "failed", %{code: "caught:#{kind}"})
    after
      cleanup()
    end

    results = Process.get(@result_key) |> Enum.reverse()
    passed = Enum.all?(results, &(&1.status == "passed"))
    boundary_only = System.get_env("HERMES_LIVE_BOUNDARY_ONLY") == "1"
    semantic_diagnostic_only = System.get_env("HERMES_LIVE_SYNTHETIC_SEMANTIC_DIAGNOSTICS") == "1"

    IO.puts(
      Jason.encode!(%{
        kind: "hermes_live_acceptance",
        status:
          cond do
            not passed -> "failed"
            boundary_only or semantic_diagnostic_only -> "diagnostic_complete"
            true -> "passed"
          end,
        evidence:
          cond do
            semantic_diagnostic_only -> "synthetic_hermes_semantic_diagnostic_only"
            boundary_only -> "owned_fixture_actual_http_websocket_boundary_diagnosis"
            true -> "owned_fixture_actual_http_websocket_committed_repo_async_styx"
          end,
        production_installation_verified: false,
        boundary_diagnosis_only: boundary_only,
        synthetic_semantic_diagnostic_only: semantic_diagnostic_only,
        synthetic_semantic_diagnostics: Enum.reverse(Process.get(@semantic_diagnostics_key)),
        results: results,
        database: resource(:database),
        cleanup: resource(:cleanup)
      })
    )

    if not passed, do: System.halt(1)
  end

  # Never format exception terms or stack arguments: startup can handle credentials.
  defp exception_frames(stacktrace) do
    stacktrace
    |> Enum.take(8)
    |> Enum.flat_map(fn
      {module, function, _arity_or_arguments, location}
      when is_atom(module) and is_atom(function) and is_list(location) ->
        [%{module: inspect(module), function: Atom.to_string(function), line: location[:line]}]

      _ ->
        []
    end)
  end

  defp guard_environment! do
    assert!(Mix.env() == :test, "BLOCKED_ENV:requires_MIX_ENV_test")

    assert!(
      System.get_env("BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL") in ["1", "true"],
      "BLOCKED_ENV:requires_real_pool_flag"
    )

    partition = System.get_env("MIX_TEST_PARTITION", "")

    assert!(
      Regex.match?(~r/\A_hermeslive_[0-9a-f]{12,32}\z/, partition),
      "BLOCKED_ENV:requires_unique_hermeslive_partition"
    )

    database = "backplane_test" <> partition
    config = Application.fetch_env!(:backplane_system, Repo)

    assert!(
      config[:database] == database and config[:pool] == DBConnection.ConnectionPool,
      "BLOCKED_ENV:repo_isolation_configuration_mismatch"
    )

    assert!(is_nil(config[:url]), "BLOCKED_ENV:database_URL_override_refused")
    assert!(is_nil(Process.whereis(Repo)), "BLOCKED_ENV:requires_mix_run_no_start")

    assert!(
      Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM) ==
        Backplane.Memory.LLM,
      "BLOCKED_ENV:inference_adapter_refused"
    )

    assert!(
      Application.get_env(:backplane_memory, :llm_req_options, []) == [],
      "BLOCKED_ENV:inference_request_adapter_refused"
    )

    root =
      Path.join(
        System.tmp_dir!(),
        "backplane-hermes-live-" <> String.replace_prefix(partition, "_hermeslive_", "")
      )

    assert!(File.mkdir(root) == :ok, "BLOCKED_ENV:fixture_directory_already_exists")
    File.chmod!(root, 0o700)
    put_resource(:root, root)
    put_resource(:database, database)

    put_resource(
      :repo_config,
      Keyword.put(config, :show_sensitive_data_on_connection_error, false)
    )

    Application.put_env(:backplane_system, Repo, resource(:repo_config))
    put_resource(:marker, String.replace_prefix(partition, "_hermeslive_", ""))
    put_resource(:python_executable, find_python!(root))
  end

  defp find_python!(root) do
    candidates =
      case System.get_env("HERMES_PYTHON") do
        nil ->
          [Path.expand("~/.hermes/hermes-agent/.venv/bin/python")] ++
            Path.wildcard(Path.expand("~/.hermes/installs/*/environments/*/venv/bin/python"))

        path ->
          [Path.expand(path)]
      end

    runtime_home = Path.join(root, "runtime-home")
    File.mkdir!(runtime_home)

    Enum.find(candidates, fn path ->
      if File.exists?(path) do
        {_ignored, status} =
          System.cmd(
            path,
            [
              "-B",
              "-c",
              "from agent.memory_provider import MemoryProvider; from agent.memory_manager import redact_for_egress; assert callable(redact_for_egress)"
            ],
            env: [
              {"HERMES_HOME", runtime_home},
              {"OPENROUTER_API_KEY", nil},
              {"PYTHONDONTWRITEBYTECODE", "1"}
            ],
            stderr_to_stdout: true
          )

        status == 0
      else
        false
      end
    end) ||
      fail!("BLOCKED_ENV:real_Hermes_interpreter_or_public_API_unavailable_set_HERMES_PYTHON")
  end

  defp prepare_database! do
    {:ok, apps} = Application.ensure_all_started(:ecto_sql)
    remember_apps(apps)

    case Ecto.Adapters.Postgres.storage_up(resource(:repo_config)) do
      :ok -> put_resource(:database_created, true)
      {:error, :already_up} -> fail!("BLOCKED_ENV:existing_database_refused")
      _ -> fail!("BLOCKED_ENV:cannot_create_owned_database")
    end

    path = Application.app_dir(:backplane_system, "priv/repo/migrations")

    {:ok, _migrations, apps} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        Ecto.Migrator.run(repo, path, :up, all: true, log: false, log_migrations_sql: false)
      end)

    remember_apps(apps)
  end

  defp start_gateway! do
    styx = Application.fetch_env!(:backplane, Styx)

    Application.put_env(
      :backplane,
      Styx,
      Keyword.merge(styx, testing: :disabled, queues: [memory: 3], plugins: [])
    )

    Application.put_env(:backplane, :llm_route_loader_enabled, true)
    Application.put_env(:backplane_memory, :projection_repair_enabled, true)
    endpoint = Application.fetch_env!(:backplane_api, Backplane.Api.Endpoint)

    endpoint =
      endpoint
      |> Keyword.put(:server, true)
      |> Keyword.update!(:http, &Keyword.merge(&1, ip: {127, 0, 0, 1}, port: 0))

    Application.put_env(:backplane_api, Backplane.Api.Endpoint, endpoint)
    {:ok, apps} = Application.ensure_all_started(:backplane_api)
    remember_apps(apps)
    {:ok, apps} = Application.ensure_all_started(:backplane_host_agent)
    remember_apps(apps)

    {:ok, {{127, 0, 0, 1}, port}} =
      Gaoxy.PhoenixAdapter.server_info(Backplane.Api.Endpoint, :http)

    assert!(port not in [4220, 4221, 4222], "reserved_gateway_port")
    put_resource(:gateway_port, port)
    Application.put_env(:backplane_memory, :llm_proxy_url, "http://127.0.0.1:#{port}")
    {:ok, _} = Settings.fetch_many(["memory.pipeline.enabled"])

    assert!(
      Repo.aggregate(Backplane.Skills.Host, :count) == 0 and
        Repo.aggregate(Backplane.LLM.Provider, :count) == 0 and
        Repo.aggregate(Backplane.Clients.Client, :count) == 0,
      "nonempty_database_refused"
    )
  end

  defp prepare_fixture! do
    marker = resource(:marker)
    name = "hermes-live-" <> marker
    scope = "hermes_live_" <> marker
    root = resource(:root)

    {:ok, host, _auth_token, token} =
      Backplane.Skills.Hosts.create_agent_with_token(%{"name" => name, "memory_scope" => scope})

    model = configure_model!(name)

    for key <- ~w(services.memory.enabled memory.pipeline.enabled
      memory.session_summary.enabled memory.recall.enabled
      memory.host_sync.enabled),
        do: :ok = Settings.set(key, true)

    for key <- ~w(memory.window_summaries.enabled memory.procedure_extraction.enabled
      memory.relation_classifier.enabled memory.lesson_auto_extract memory.crystals_enabled
      memory.crystal_session_enabled),
        do: :ok = Settings.set(key, false)

    :ok = Settings.set("memory.fact_extraction.enabled", model.available)
    :ok = Settings.set("memory.event_gap_grace_seconds", 1)
    :ok = Settings.set("monitor.api_usage.enabled", false)

    config = %Config{
      host_id: host.id,
      machine_name: name,
      token: token,
      hub_url: "http://127.0.0.1:#{resource(:gateway_port)}",
      socket_url:
        "ws://127.0.0.1:#{resource(:gateway_port)}/host-agent/socket/websocket?host_id=" <>
          URI.encode_www_form(host.id),
      work_dir: root,
      manifest_path: Path.join(root, "manifest.json"),
      targets: [],
      interval_ms: 250,
      http_bind: "127.0.0.1",
      http_port: 0,
      telemetry: %{enabled: false},
      memory: %{
        enabled: true,
        db_path: Path.join(root, "commands.db"),
        bound_scope: scope,
        local_ttl_days: 90,
        sync_interval_ms: 250,
        sync_batch_size: 50,
        max_attempts: 5,
        tombstone_relearn: :block,
        host_sync: %{enabled: false},
        import_profiles: %{}
      },
      capture: %{enabled: true, db_path: Path.join(root, "capture.db"), upload_interval_ms: 250}
    }

    {:ok, http} = Gaoxy.HTTP.start_link(plug: {MemoryRouter, []}, ip: {127, 0, 0, 1}, port: 0)
    remember_pid(http)
    %{local: {:ok, {{127, 0, 0, 1}, port}}} = Gaoxy.info(http, :http)
    assert!(port not in [4220, 4221, 4222], "reserved_host_port")
    home = Path.join(root, "profiles")
    File.mkdir!(home)

    %{
      marker: marker,
      host: host,
      config: config,
      base_url: "http://127.0.0.1:#{port}",
      home: home,
      model_available: model.available,
      embedding_model: model.embedding_model
    }
  end

  defp configure_model!(name) do
    key = System.get_env("OPENROUTER_API_KEY", "")

    if String.trim(key) == "" do
      %{available: false, embedding_model: nil}
    else
      credential = name <> "-upstream"
      {:ok, _} = Backplane.Settings.Credentials.store(credential, key, "llm")
      {:ok, provider} = Backplane.LLM.Provider.create(%{name: name, credential: credential})

      {:ok, api} =
        Backplane.LLM.ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "https://openrouter.ai/api/v1",
          native_protocols: [:openai_chat_completions],
          model_discovery_enabled: false
        })

      model_name = System.get_env("HERMES_LIVE_MODEL", "openai/gpt-4.1-mini")

      {:ok, model} =
        Backplane.LLM.ProviderModel.create(%{
          provider_id: provider.id,
          model: model_name,
          source: :manual
        })

      {:ok, _} =
        Backplane.LLM.ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: api.id
        })

      {:ok, %{provider: ep, model: em}} =
        Backplane.Embedding.create_provider_with_model(%{
          "name" => name,
          "credential" => credential,
          "base_url" => "https://openrouter.ai/api/v1",
          "enabled" => true,
          "model" => "openai/text-embedding-3-large",
          "model_enabled" => true,
          "metadata" => Jason.encode!(%{dimensions: 2560})
        })

      embedding_model = Backplane.Embedding.model_id(%{em | provider: ep})

      {:ok, _client, resource_token} =
        Backplane.Clients.issue_client(%{
          "name" => name <> "-processor",
          "scopes" => ["*"]
        })

      resource_credential = name <> "-resource"

      {:ok, _} =
        Backplane.Settings.Credentials.store(resource_credential, resource_token, "service")

      :ok = Settings.set("memory.proxy_credential", resource_credential)
      :ok = Settings.set("memory.llm_model", name <> "/" <> model_name)
      :ok = Settings.set("memory.embed_model", embedding_model)

      wait!(
        fn ->
          Map.has_key?(
            Relayixir.Config.UpstreamConfig.list_upstreams(),
            Backplane.LLM.RouteLoader.upstream_name(api.id)
          )
        end,
        "BLOCKED_ENV:fixture_LLM_route_not_loaded",
        10_000
      )

      %{available: true, embedding_model: embedding_model}
    end
  end

  defp start_worker!(config) do
    {:ok, worker} = Worker.start_link(config: config, connect?: true, sync_on_start?: false)
    remember_pid(worker)
    put_resource(:worker, worker)

    wait!(
      fn -> is_pid(GenServer.call(worker, :status).channel) end,
      "host_websocket_join_failed",
      20_000
    )

    state = GenServer.call(worker, :status)

    pids =
      Enum.map(
        [
          :capture_supervisor,
          :memory_supervisor,
          :trace_supervisor,
          :http_supervisor,
          :edge_syncer
        ],
        &Map.get(state, &1)
      )
      |> Enum.filter(&is_pid/1)

    Enum.each(pids, &remember_pid/1)
    put_resource(:host_pids, pids)
  end

  defp stop_worker! do
    resume_owned_worker()
    stop_pid!(resource(:worker))
    Enum.each(resource(:host_pids) || [], &stop_pid!/1)

    assert!(
      Enum.all?(resource(:host_pids) || [], &(not Process.alive?(&1))),
      "host_store_shutdown_incomplete"
    )

    put_resource(:worker, nil)
  end

  defp ready!(base_url, previous \\ nil) do
    wait!(
      fn ->
        case live_connection(previous) do
          nil ->
            false

          snapshot ->
            case Req.post(base_url <> "/memory/hermes/call/source_capabilities",
                   json: %{},
                   retry: false,
                   receive_timeout: 2_000
                 ) do
              {:ok,
               %{
                 status: 200,
                 body: %{"ok" => true, "result" => %{"ready" => true, "capture_ready" => true}}
               }} ->
                live_connection(previous) == snapshot

              _ ->
                false
            end
        end
      end,
      "host_source_capture_negotiation_unready",
      20_000
    )
  end

  defp live_connection(previous) do
    state = GenServer.call(resource(:worker), :status)

    case Access.status() do
      %{generation: generation} when is_integer(generation) ->
        snapshot = %{channel: state.channel, socket: state.socket, generation: generation}

        fresh =
          is_nil(previous) or
            (snapshot.channel != previous.channel and snapshot.socket != previous.socket and
               snapshot.generation != previous.generation)

        if fresh and is_pid(snapshot.channel) and Process.alive?(snapshot.channel) and
             is_pid(snapshot.socket) and Process.alive?(snapshot.socket) and
             Phoenix.SocketClient.connected?(snapshot.socket) and
             MemoryProxy.channel() == snapshot.channel,
           do: snapshot

      _ ->
        nil
    end
  catch
    :exit, _ -> nil
  end

  defp start_python!(fixture) do
    script = Path.expand("../integrations/memory/tests/hermes_http_acceptance.py", __DIR__)

    env = [
      {~c"OPENROUTER_API_KEY", false},
      {~c"BACKPLANE_MEMORY_URL", false},
      {~c"BACKPLANE_MEMORY_AGENT_ID", false},
      {~c"BACKPLANE_MEMORY_ACCESS_ID", false},
      {~c"HERMES_HOME", String.to_charlist(Path.join(resource(:root), "runtime-home"))},
      {~c"PYTHONDONTWRITEBYTECODE", ~c"1"}
    ]

    port =
      Port.open({:spawn_executable, resource(:python_executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 65_536},
        {:env, env},
        {:args,
         [
           "-B",
           script,
           "--home",
           fixture.home,
           "--base-url",
           fixture.base_url,
           "--marker",
           fixture.marker,
           "--timeout",
           "30"
         ]}
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    put_resource(:python, %{port: port, os_pid: pid})
  end

  defp python!(operation) do
    %{port: port} = resource(:python)
    true = Port.command(port, Jason.encode!(%{op: operation}) <> "\n")
    await_python!(port, operation, System.monotonic_time(:millisecond) + @timeout, "")
  end

  defp await_python!(port, operation, deadline, partial) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, {:noeol, bytes}}} ->
        assert!(
          byte_size(partial) + byte_size(bytes) <= 262_144,
          "python_protocol_line_too_large"
        )

        await_python!(port, operation, deadline, partial <> bytes)

      {^port, {:data, {:eol, bytes}}} ->
        case Jason.decode(partial <> bytes) do
          {:ok, %{"kind" => "reply", "op" => ^operation, "ok" => true, "result" => result}} ->
            result

          {:ok, %{"kind" => "reply", "op" => ^operation, "ok" => false, "code" => code} = reply} ->
            fail!(code, Map.get(reply, "diagnostics", %{}))

          _ ->
            await_python!(port, operation, deadline, "")
        end

      {^port, {:exit_status, status}} ->
        put_resource(:python, nil)
        fail!("python_peer_exited:#{status}")

      {:EXIT, _pid, _reason} ->
        await_python!(port, operation, deadline, partial)
    after
      remaining -> fail!("python_protocol_timeout:#{operation}")
    end
  end

  defp stop_python! do
    case resource(:python) do
      nil ->
        :ok

      %{port: port} ->
        python!("shutdown")

        receive do
          {^port, {:exit_status, 0}} ->
            put_resource(:python, nil)

          {^port, {:exit_status, _}} ->
            put_resource(:python, nil)
            fail!("python_shutdown_failed")
        after
          10_000 -> fail!("python_shutdown_timeout")
        end
    end
  end

  defp assert_sources!(host_id, identities, memory_id, expected) do
    sources =
      Repo.all(from(s in NativeSource, where: s.host_id == ^host_id and s.target == "memory"))

    for label <- ["a", "b"] do
      identity = identities[label]

      assert!(
        Enum.any?(
          sources,
          &(&1.installation_id == identity["installation_id"] and
              &1.profile_id == identity["profile_id"])
        ),
        "independent_source_namespace_missing"
      )
    end

    source_ids = Enum.map(sources, & &1.id)

    entries =
      Repo.all(
        from(e in Entry,
          where: e.source_id in ^source_ids and e.memory_id == ^memory_id and e.active
        )
      )

    assert!(length(entries) == expected, "canonical_source_membership_count_wrong")

    for entry <- entries do
      mutation = Repo.get!(Mutation, entry.mutation_id)

      assert!(
        mutation.revision == entry.revision and mutation.source_id == entry.source_id and
          mutation.memory_id == memory_id and mutation.outcome == "applied",
        "source_revision_lineage_wrong"
      )
    end
  end

  defp verify_capture!(host_id, capture) do
    ids = capture["event_ids"]
    events = Repo.all(from(e in Event, where: e.host_id == ^host_id and e.id in ^ids))
    assert!(length(ids) > 0 and length(events) == length(ids), "canonical_capture_rows_missing")

    message_events =
      Enum.filter(
        events,
        &(&1.event_type in ["conversation.user_message", "conversation.agent_message"])
      )

    uids =
      Enum.map(message_events, fn event ->
        get_in(event.payload, ["source", "message_uid"])
      end)

    assert!(
      MapSet.new(uids) == MapSet.new(capture["message_uids"]) and
        length(message_events) == capture["direct_messages"],
      "canonical_message_occurrence_identity_wrong"
    )

    assert!(
      Enum.count(message_events, &(&1.event_type == "conversation.user_message")) == 4 and
        Enum.count(message_events, &(&1.event_type == "conversation.agent_message")) == 2,
      "canonical_conversation_roles_wrong"
    )

    session_id = capture["session_id"]

    wait!(
      fn ->
        case Repo.get_by(ProjectedSession, host_id: host_id, session_id: session_id) do
          %ProjectedSession{status: status} when status in ["completed", "stopped"] -> true
          _ -> false
        end
      end,
      "canonical_session_projection_incomplete"
    )

    session = Repo.get_by!(ProjectedSession, host_id: host_id, session_id: session_id)
    frontier = Repo.get_by!(RepairFrontier, host_id: host_id, session_id: session_id)

    assert!(
      frontier.completed_generation == frontier.requested_generation and
        frontier.completed_revision == session.input_revision,
      "projection_frontier_unsettled"
    )

    states =
      Repo.all(
        from(s in State,
          where:
            s.subject_id == ^session.subject_id and
              s.projector in ["observations", "session", "activity", "replay"]
        )
      )

    assert!(
      length(states) == 4 and
        Enum.all?(
          states,
          &(&1.status == "complete" and
              &1.input_revision == session.input_revision)
        ),
      "projection_revision_lineage_wrong"
    )

    %{
      events: length(events),
      projection_states: length(states),
      input_revision: session.input_revision
    }
  end

  defp verify_processing!(host_id, session_id, fixture) do
    put_resource(:processing_session_id, session_id)
    # A freshly closed session waits for gap grace; enqueue the real existing sweep.
    Process.sleep(1_100)
    {:ok, sweep} = Backplane.Memory.Workers.FallbackSweepWorker.new(%{}) |> Styx.insert()
    put_resource(:processing_sweep_id, sweep.id)

    wait!(
      fn -> Repo.get!(Styx.Job, sweep.id).state == "completed" end,
      "background_sweep_incomplete"
    )

    session = Repo.get_by!(ProjectedSession, host_id: host_id, session_id: session_id)

    wait!(
      fn ->
        Repo.exists?(
          from(s in Summary,
            where:
              s.host_id == ^host_id and s.session_id == ^session_id and
                s.input_revision == ^session.input_revision and is_nil(s.superseded_at)
          )
        )
      end,
      "background_summary_missing"
    )

    summary =
      Repo.one!(
        from(s in Summary,
          where:
            s.host_id == ^host_id and s.session_id == ^session_id and
              s.input_revision == ^session.input_revision and is_nil(s.superseded_at)
        )
      )

    sources = Repo.all(from(s in SourceEvent, where: s.summary_id == ^summary.id))

    assert!(
      sources != [] and
        Enum.all?(sources, &(&1.host_id == host_id and &1.session_id == session_id)),
      "summary_event_lineage_missing"
    )

    wait!(
      fn ->
        Repo.exists?(
          from(s in State,
            where:
              s.subject_id == ^session.subject_id and s.projector == "episodic" and
                s.input_revision == ^summary.input_revision and s.status == "complete"
          )
        )
      end,
      "real_model_extraction_incomplete"
    )

    evidence = Repo.all(from(e in Evidence, where: e.source_summary_id == ^summary.id))
    assert!(evidence != [], "derived_summary_evidence_missing")
    memory_ids = Enum.map(evidence, & &1.memory_id) |> Enum.uniq()

    requests =
      Repo.all(
        from(r in RememberRequest,
          where:
            r.memory_id in ^memory_ids and
              r.idempotency_scope == "memory-worker:episodic"
        )
      )

    assert!(
      requests != [] and
        Enum.all?(requests, &(&1.origin == "derived" and &1.independent_support == false)),
      "backend_derived_request_provenance_wrong"
    )

    request_ids = Enum.map(requests, & &1.id)

    assert!(
      Repo.aggregate(from(e in RequestEvidence, where: e.request_id in ^request_ids), :count) >=
        length(requests),
      "backend_derived_request_evidence_missing"
    )

    derived_context = verify_derived_current_facts!(memory_ids, summary)

    wait!(
      fn ->
        Repo.exists?(
          from(m in Memory,
            where:
              m.id in ^memory_ids and not is_nil(m.embedding) and
                m.embedding_model == ^fixture.embedding_model
          )
        )
      end,
      "real_embedding_lineage_missing"
    )

    jobs = Repo.all(from(j in Styx.Job, where: j.state == "completed" and j.queue == "memory"))

    assert!(
      Enum.any?(jobs, &String.ends_with?(&1.worker, ".SummaryWorker")) and
        Enum.any?(jobs, &String.ends_with?(&1.worker, ".EpisodicWorker")),
      "completed_async_processing_jobs_missing"
    )

    %{
      summary_id: summary.id,
      derived_memories: length(memory_ids),
      derived_requests: length(requests),
      derived_current_facts: derived_context,
      real_llm: true,
      real_embedding: true,
      async_queue: true
    }
  end

  defp verify_derived_current_facts!(memory_ids, summary) do
    # Inspect only records with actual extraction evidence from this summary.
    # A native record in provider context alone cannot satisfy this gate.
    current = Backplane.Memory.CurrentContext.query(Memory)

    memories =
      Repo.all(
        from(m in current,
          where:
            m.id in ^memory_ids and m.memory_space_id == ^summary.memory_space_id and
              m.host_id == ^summary.host_id and m.scope == ^summary.scope and
              m.namespace == ^summary.namespace
        )
      )

    Enum.each(
      memories,
      &capture_synthetic_semantic_diagnostic(&1, summary.host_id, summary.session_id)
    )

    corrections =
      Enum.filter(memories, fn memory ->
        Regex.match?(~r/\bamber\b/i, memory.content) and
          Regex.match?(~r/\b(deployment|status|colou?r|preference)\b/i, memory.content) and
          Backplane.HermesSemanticOracle.corrected_preference?(memory.content)
      end)

    assert!(corrections != [], "derived_current_user_correction_missing")

    for memory <- memories do
      verify_current_policy!(memory, summary.host_id, summary.session_id)
    end

    %{
      correction_bearing_records: length(corrections),
      current_records: length(memories),
      assistant_guess_not_promoted: true,
      support_and_trust_checked: true
    }
  end

  defp verify_current_policy!(memory, host_id, session_id) do
    capture_synthetic_semantic_diagnostic(memory, host_id, session_id)
    policy = Backplane.Memory.CurrentContext.metadata(memory)

    assert!(
      policy["effective_support"] == true and policy["support_complete"] == true and
        policy["trust"] in ["candidate_inference", "established_fact"],
      "derived_current_support_or_trust_untruthful"
    )

    case Backplane.HermesSemanticOracle.check(memory.content, policy["trust"]) do
      :ok ->
        :ok

      {:error, code} ->
        fail!(code, %{
          memory_id: memory.id,
          synthetic_content: synthetic_text(memory.content, 4_096),
          trust: policy["trust"]
        })
    end

    if policy["trust"] == "established_fact" do
      confirmed =
        Repo.exists?(
          from(e in Evidence,
            join: event in Event,
            on: e.source_event_id == event.id,
            where:
              e.memory_id == ^memory.id and e.evidence_kind == "confirms" and
                e.support_score > 0.0 and event.host_id == ^host_id and
                event.session_id == ^session_id and
                event.event_type in ["conversation.user_message", "agent.prompt.submitted"]
          )
        )

      assert!(confirmed, "derived_fact_established_without_actual_user_confirmation")
    end
  end

  # Retain bounded lineage before semantic assertions, including in normal runs,
  # so cleanup cannot erase a failure's evidence. The ownership guard limits this
  # observer to the newly created synthetic fixture; it records no provider
  # bodies, credentials, arbitrary metadata, or operator memory records.
  defp capture_synthetic_semantic_diagnostic(memory, host_id, session_id) do
    captured = Process.get(@semantic_diagnostics_key, [])

    if semantic_diagnostic_allowed?(memory, host_id, session_id) and length(captured) < 32 and
         not Enum.any?(captured, &(&1[:memory_id] == memory.id)) do
      diagnostic = synthetic_semantic_diagnostic(memory, host_id, session_id)

      if diagnostic do
        Process.put(@semantic_diagnostics_key, [diagnostic | captured])
      end
    end
  end

  defp semantic_diagnostic_allowed?(memory, host_id, session_id) do
    marker = resource(:marker)

    resource(:database_created) == true and is_binary(marker) and
      resource(:database) == "backplane_test_hermeslive_" <> marker and
      host_id == resource(:host_id) and memory.host_id == host_id and
      session_id == "hermes-live-#{marker}-a" and memory.scope == "hermes_live_" <> marker and
      memory.namespace == "private"
  end

  defp synthetic_semantic_diagnostic(memory, host_id, session_id) do
    owned_partition =
      Repo.exists?(
        from(s in NativeSource,
          where:
            s.host_id == ^host_id and s.memory_space_id == ^memory.memory_space_id and
              s.scope == ^memory.scope and s.namespace == ^memory.namespace
        )
      )

    if owned_partition do
      summaries =
        Repo.all(
          from(s in Summary,
            join: e in Evidence,
            on: e.source_summary_id == s.id,
            where:
              e.memory_id == ^memory.id and s.host_id == ^host_id and
                s.session_id == ^session_id and s.memory_space_id == ^memory.memory_space_id and
                s.scope == ^memory.scope and s.namespace == ^memory.namespace,
            distinct: true,
            order_by: [s.id],
            limit: 8
          )
        )

      if summaries != [] do
        synthetic_semantic_provenance(memory, summaries, host_id, session_id)
      end
    end
  rescue
    error ->
      %{
        kind: "synthetic_hermes_semantic_diagnostic",
        diagnostic_only: true,
        diagnostic_status: "unavailable",
        memory_id: memory.id,
        exception_type: inspect(error.__struct__)
      }
  catch
    kind, _ ->
      %{
        kind: "synthetic_hermes_semantic_diagnostic",
        diagnostic_only: true,
        diagnostic_status: "unavailable",
        memory_id: memory.id,
        caught: kind
      }
  end

  defp synthetic_semantic_provenance(memory, summaries, host_id, session_id) do
    summary_ids = Enum.map(summaries, & &1.id)
    requests = Repo.all(from(r in RememberRequest, where: r.memory_id == ^memory.id, limit: 32))
    request_ids = Enum.map(requests, & &1.id)
    evidence_query = from(e in Evidence, where: e.memory_id == ^memory.id)
    evidence = Repo.all(from(e in evidence_query, order_by: e.id, limit: 32))
    links_query = from(l in RequestEvidence, where: l.request_id in ^request_ids)
    links = Repo.all(from(l in links_query, order_by: [l.request_id, l.evidence_id], limit: 64))
    sources_query = from(s in SourceEvent, where: s.summary_id in ^summary_ids)
    sources = Repo.all(from(s in sources_query, order_by: [s.summary_id, s.event_id], limit: 64))

    events_query =
      from(e in Event,
        join: s in SourceEvent,
        on: s.event_id == e.id,
        where:
          s.summary_id in ^summary_ids and s.host_id == ^host_id and s.session_id == ^session_id and
            e.host_id == ^host_id and e.session_id == ^session_id and
            e.memory_space_id == ^memory.memory_space_id and e.scope == ^memory.scope and
            e.namespace == ^memory.namespace,
        distinct: true
      )

    events = Repo.all(from(e in events_query, order_by: [e.source_sequence, e.id], limit: 32))

    %{
      kind: "synthetic_hermes_semantic_diagnostic",
      diagnostic_only: true,
      diagnostic_status: "captured",
      memory_id: memory.id,
      host_id: host_id,
      session_id: session_id,
      partition: Map.take(memory, [:memory_space_id, :scope, :namespace]),
      memory: %{
        content: synthetic_text(memory.content, 4_096),
        lifecycle_state: memory.lifecycle_state,
        policy:
          memory
          |> Backplane.Memory.CurrentContext.metadata()
          |> Map.update!("source_refs", &Enum.take(&1, 16))
      },
      summaries:
        Enum.map(summaries, fn summary ->
          summary
          |> Map.take([
            :id,
            :host_id,
            :session_id,
            :input_revision,
            :output_revision,
            :source_complete
          ])
          |> Map.put(:content, synthetic_text(summary.content, 16_384))
          |> Map.put(:superseded, not is_nil(summary.superseded_at))
        end),
      requests:
        Enum.map(requests, &Map.take(&1, [:id, :memory_id, :origin, :independent_support])),
      evidence:
        Enum.map(evidence, fn row ->
          Map.take(row, [
            :id,
            :memory_id,
            :source_event_id,
            :source_summary_id,
            :source_request_id,
            :source_observation_id,
            :source_crystal_id,
            :source_mutation_id,
            :source_session_id,
            :session_id,
            :host_id,
            :evidence_kind,
            :support_score
          ])
        end),
      request_evidence: Enum.map(links, &Map.take(&1, [:request_id, :evidence_id])),
      summary_event_links:
        Enum.map(sources, &Map.take(&1, [:summary_id, :event_id, :host_id, :session_id])),
      ordered_events:
        Enum.map(events, fn event ->
          event
          |> Map.take([:id, :host_id, :session_id, :event_type, :role, :source_sequence])
          |> Map.put(:content, synthetic_text(event.content, 4_096))
          |> Map.put(:message_uid, get_in(event.payload, ["source", "message_uid"]))
          |> Map.put(:source_revision, get_in(event.payload, ["source", "source_revision"]))
        end),
      row_counts: %{
        requests:
          Repo.aggregate(from(r in RememberRequest, where: r.memory_id == ^memory.id), :count),
        evidence: Repo.aggregate(evidence_query, :count),
        request_evidence: Repo.aggregate(links_query, :count),
        summary_event_links: Repo.aggregate(sources_query, :count),
        events: Repo.aggregate(events_query, :count)
      },
      limits: %{
        records: 32,
        summaries: 8,
        requests: 32,
        evidence: 32,
        links: 64,
        events: 32,
        source_refs: 16
      }
    }
  end

  defp synthetic_text(nil, _limit), do: nil

  defp synthetic_text(text, limit) when is_binary(text) do
    excerpt = String.slice(text, 0, limit)

    %{
      text: excerpt,
      original_bytes: byte_size(text),
      original_characters: String.length(text),
      truncated: excerpt != text,
      sha256: Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    }
  end

  defp verify_final_state!(fixture, identities, final) do
    host_id = fixture.host.id
    session_id = "hermes-live-#{fixture.marker}-a"
    sources = Repo.all(from(s in NativeSource, where: s.host_id == ^host_id))

    identity = fn source ->
      {source.installation_id, source.profile_id, source.target}
    end

    expected_sources =
      for label <- ["a", "b"], target <- ["memory", "user"], into: MapSet.new() do
        {identities[label]["installation_id"], identities[label]["profile_id"], target}
      end

    assert!(
      length(sources) == 4 and MapSet.new(sources, identity) == expected_sources and
        Enum.all?(sources, &(&1.integration == "hermes")),
      "final_source_namespace_set_wrong"
    )

    [partition] =
      sources |> Enum.map(&Map.take(&1, [:memory_space_id, :scope, :namespace])) |> Enum.uniq()

    source_ids = Enum.map(sources, & &1.id)
    by_source = Map.new(sources, &{&1.id, &1})
    entries = Repo.all(from(e in Entry, where: e.source_id in ^source_ids))
    heads = final["heads"]
    hashes = final["content_sha256"]
    original_id = final["original_id"]
    forgotten_id = final["forgotten_id"]
    outage_id = final["outage_id"]

    # A's amber entry was withdrawn, A's outage entry stays active, and B's
    # locally present amber entry is canonically suppressed by global forget.
    expected_heads =
      MapSet.new([
        {"a", hashes["current"], false},
        {"a", hashes["outage"], true},
        {"b", hashes["current"], true}
      ])

    assert!(
      length(heads) == 3 and
        MapSet.new(heads, &{&1["profile"], &1["content_sha256"], &1["active"]}) == expected_heads,
      "final_local_source_heads_wrong"
    )

    expected_keys =
      MapSet.new(heads, fn head ->
        source = head["source"]
        {{source["installation_id"], source["profile_id"], source["target"]}, head["entry_id"]}
      end)

    assert!(
      length(entries) == length(heads) and
        MapSet.new(entries, &{identity.(by_source[&1.source_id]), &1.entry_id}) == expected_keys,
      "final_canonical_source_head_set_wrong"
    )

    for entry <- entries do
      source = by_source[entry.source_id]
      head = Enum.find(heads, &(&1["entry_id"] == entry.entry_id))
      mutation = Repo.get!(Mutation, entry.mutation_id)
      forgotten = head["content_sha256"] == hashes["current"]
      expected_id = if forgotten, do: forgotten_id, else: outage_id

      assert!(
        source.target == "memory" and entry.memory_id == expected_id and
          entry.active == not forgotten and entry.suppressed == forgotten and
          entry.revision >= head["revision"] and mutation.revision == entry.revision and
          mutation.source_id == source.id and mutation.entry_id == entry.entry_id and
          mutation.memory_id == expected_id and
          mutation.outcome in if(forgotten, do: ["applied", "suppressed"], else: ["applied"]),
        "final_source_membership_or_suppression_wrong"
      )
    end

    assert!(not is_nil(Repo.get!(Memory, forgotten_id).deleted_at), "final_forget_not_durable")

    assert!(
      Repo.get!(Memory, original_id).effective_support == false,
      "final_old_native_supported"
    )

    current = Backplane.Memory.CurrentContext.query(Memory)

    memories =
      Repo.all(
        from(m in current,
          where:
            m.memory_space_id == ^partition.memory_space_id and m.scope == ^partition.scope and
              m.namespace == ^partition.namespace
        )
      )

    current_ids = MapSet.new(memories, & &1.id)

    assert!(
      MapSet.member?(current_ids, outage_id) and
        not MapSet.member?(current_ids, original_id) and
        not MapSet.member?(current_ids, forgotten_id),
      "final_current_native_set_wrong"
    )

    # Enumerate the whole owned partition. Independent conversation-derived
    # amber (or unrelated chat) may remain, but every non-native row needs an
    # actual current summary, real event lineage and its governing request edge.
    for memory <- memories do
      assert!(memory.host_id == host_id, "final_current_host_wrong")
      verify_current_policy!(memory, host_id, session_id)
      policy = Backplane.Memory.CurrentContext.metadata(memory)

      expected_refs =
        entries
        |> Enum.filter(&(&1.memory_id == memory.id and &1.active and not &1.suppressed))
        |> MapSet.new(fn entry ->
          {identity.(by_source[entry.source_id]), entry.entry_id, entry.revision,
           entry.mutation_id}
        end)

      actual_refs =
        MapSet.new(policy["source_refs"], fn ref ->
          source = ref["source"]

          {{source["installation_id"], source["profile_id"], source["target"]}, ref["entry_id"],
           ref["source_revision"], ref["event_id"]}
        end)

      assert!(
        actual_refs == expected_refs and Enum.all?(policy["source_refs"], &(&1["active"] == true)),
        "final_context_source_memberships_wrong"
      )

      if memory.id != outage_id do
        governed =
          Repo.exists?(
            from(r in RememberRequest,
              join: edge in RequestEvidence,
              on: edge.request_id == r.id,
              join: evidence in Evidence,
              on: edge.evidence_id == evidence.id and evidence.memory_id == r.memory_id,
              join: summary in Summary,
              on: evidence.source_summary_id == summary.id,
              join: session in ProjectedSession,
              on: session.host_id == summary.host_id and session.session_id == summary.session_id,
              join: source in SourceEvent,
              on: source.summary_id == summary.id,
              join: event in Event,
              on: source.event_id == event.id,
              where:
                r.memory_id == ^memory.id and r.origin == "derived" and
                  r.independent_support == false and
                  r.idempotency_scope == "memory-worker:episodic" and
                  evidence.evidence_kind == "derives" and evidence.support_score > 0.0 and
                  summary.host_id == ^host_id and summary.session_id == ^session_id and
                  summary.memory_space_id == ^partition.memory_space_id and
                  summary.scope == ^partition.scope and summary.namespace == ^partition.namespace and
                  is_nil(summary.superseded_at) and
                  summary.input_revision == session.input_revision and
                  source.host_id == ^host_id and source.session_id == ^session_id and
                  event.host_id == ^host_id and event.session_id == ^session_id and
                  event.event_type in ["conversation.user_message", "conversation.agent_message"]
            )
          )

        assert!(
          governed and policy["independent_support"] == true,
          "unexplained_final_current_record"
        )
      end
    end

    for label <- ["a", "b"] do
      delivery = final["delivery"][label]

      assert!(
        delivery["canonical_committed"] > 0 and
          Enum.all?(
            ~w(local_pending host_accepted rejected capture_deferred pending_reconciliation),
            &(delivery[&1] == 0)
          ),
        "final_provider_delivery_unsettled"
      )
    end

    %{
      source_heads: length(entries),
      active_native_memberships: Enum.count(entries, & &1.active),
      suppressed_native_memberships: Enum.count(entries, & &1.suppressed),
      current_records: length(memories),
      governed_conversation_records: Enum.count(memories, &(&1.id != outage_id)),
      current_ids: Enum.sort(MapSet.to_list(current_ids)),
      provider_delivery: final["delivery"]
    }
  end

  defp gate(name, fun) do
    try do
      record(name, "passed", fun.())
      true
    rescue
      error in Error ->
        record(name, "failed", %{
          code: error.code,
          diagnostics: error.diagnostics,
          host: host_diagnostics()
        })

        false

      error in Ecto.QueryError ->
        record(name, "failed", %{
          code: "exception:Ecto.QueryError",
          message: Exception.message(error)
        })

        false

      error ->
        record(name, "failed", %{code: "exception:#{inspect(error.__struct__)}"})
        false
    catch
      kind, _reason ->
        record(name, "failed", %{code: "caught:#{kind}"})
        false
    end
  end

  defp blocked(name, prerequisite), do: record(name, "blocked", %{prerequisite: prerequisite})

  defp host_diagnostics do
    alias Backplane.HostAgent.Memory.{Access, Store}

    store = Application.get_env(:backplane_host_agent, :memory_store, Store)
    access = Access.status()

    {:ok, %{rows: rows}} =
      Store.query(
        store,
        "SELECT command_id,op,state,attempts,last_error,ack_result,json_extract(payload,'$.arguments.phase') AS phase FROM memory_outbox ORDER BY seq DESC LIMIT 32"
      )

    commands =
      Enum.map(rows, fn row ->
        ack = if is_binary(row["ack_result"]), do: Jason.decode!(row["ack_result"]), else: %{}

        %{
          command_id: row["command_id"],
          operation:
            diagnostic_enum(row["op"], ~w(remember forget source_mutate source_reconcile)),
          state: diagnostic_enum(row["state"], ~w(pending inflight retry_wait done dead_letter)),
          phase: diagnostic_enum(row["phase"], ~w(begin page commit)),
          attempts: row["attempts"],
          error_code: diagnostic_error(row["last_error"]),
          ack_status: diagnostic_enum(ack["status"], ~w(pending committed rejected)),
          ack_outcome:
            diagnostic_enum(ack["outcome"], ~w(applied unchanged stale suppressed withdrawn))
        }
      end)

    canonical =
      Repo.all(
        from(r in Backplane.Memory.SharedCommands.Receipt,
          where: r.host_id == ^resource(:host_id),
          order_by: [desc: r.inserted_at],
          limit: 32,
          select: %{
            command_id: r.command_id,
            operation: r.operation,
            status: r.status,
            error_code: r.error_code
          }
        )
      )
      |> Enum.map(fn row ->
        %{
          row
          | operation:
              diagnostic_enum(row.operation, ~w(remember forget source_mutate source_reconcile)),
            status: diagnostic_enum(row.status, ~w(committed rejected)),
            error_code: diagnostic_error(row.error_code)
        }
      end)

    capture =
      case Application.get_env(:backplane_host_agent, :capture_runtime) do
        %{spool: spool} ->
          Backplane.HostAgent.Memory.Spool.Turso.stats(spool)
          |> Map.take([
            :pending_depth,
            :retry_count,
            :dead_letter_count,
            :captured_count,
            :rejected_count
          ])

        _ ->
          %{unavailable: true}
      end

    %{
      commands: commands,
      canonical_receipts: canonical,
      capture: capture,
      processing: processing_diagnostics(),
      access: Map.take(access, [:negotiated, :blocked, :global_fenced]),
      access_entries:
        Enum.map(access.accesses, fn entry ->
          %{
            access_id: entry.access_id,
            authority_version: entry.authority_version,
            status: diagnostic_enum(entry.status, ~w(active paused fenced)),
            fence_reason: diagnostic_error(entry.fence_reason)
          }
        end)
    }
  rescue
    error -> %{diagnostic_unavailable: true, exception_type: inspect(error.__struct__)}
  catch
    kind, _ -> %{diagnostic_unavailable: true, caught: kind}
  end

  defp processing_diagnostics do
    host_id = resource(:host_id)
    session_id = resource(:processing_session_id)

    session =
      if is_binary(session_id),
        do: Repo.get_by(ProjectedSession, host_id: host_id, session_id: session_id)

    if session do
      summaries =
        Repo.all(
          from(s in Summary,
            where: s.host_id == ^host_id and s.session_id == ^session_id,
            order_by: [desc: s.inserted_at],
            limit: 16,
            select: %{id: s.id, input_revision: s.input_revision, superseded_at: s.superseded_at}
          )
        )

      summary_ids = Enum.map(summaries, & &1.id)
      sweep_id = resource(:processing_sweep_id) || 0

      states =
        Repo.all(
          from(s in State,
            where: s.subject_id == ^session.subject_id,
            order_by: s.projector,
            limit: 16
          )
        )

      jobs =
        Repo.all(
          from(j in Styx.Job,
            where:
              j.id == ^sweep_id or fragment("?->>'summary_id'", j.args) in ^summary_ids or
                (fragment("?->>'host_id'", j.args) == ^host_id and
                   fragment("?->>'session_id'", j.args) == ^session_id),
            order_by: [desc: j.id],
            limit: 32
          )
        )

      %{
        pipeline_enabled: Backplane.Memory.Config.pipeline_enabled?(),
        fact_extraction_enabled: Backplane.Memory.Config.fact_extraction_enabled?(),
        model_configured: is_binary(Settings.get("memory.llm_model")),
        current_summary_count:
          Enum.count(
            summaries,
            &(&1.input_revision == session.input_revision and is_nil(&1.superseded_at))
          ),
        stages:
          Enum.map(states, fn state ->
            %{
              projector:
                diagnostic_enum(state.projector, ~w(summary episodic procedural graph crystal)),
              status:
                diagnostic_enum(
                  state.status,
                  Backplane.Memory.Projections.ProcessingState.statuses()
                ),
              attempt_count: state.attempt_count,
              current_revision: state.input_revision == session.input_revision,
              error: processing_error_class(state.last_error)
            }
          end),
        jobs:
          Enum.map(jobs, fn job ->
            %{
              worker:
                diagnostic_enum(
                  List.last(String.split(job.worker, ".")),
                  ~w(FallbackSweepWorker SummaryWorker EpisodicWorker CrystalWorker EmbedWorker StageResumeWorker)
                ),
              state:
                diagnostic_enum(
                  job.state,
                  ~w(available scheduled executing retryable completed cancelled discarded suspended)
                ),
              attempt: job.attempt,
              max_attempts: job.max_attempts,
              errors: Enum.map(job.errors, &processing_error_class(&1["error"]))
            }
          end)
      }
    else
      %{session_available: false}
    end
  rescue
    error -> %{diagnostic_unavailable: true, exception_type: inspect(error.__struct__)}
  end

  defp processing_error_class(nil), do: nil

  defp processing_error_class(value) when is_binary(value) do
    known =
      ~w(processing_failed disabled no_model fact_model_unavailable invalid_fact_response
      invalid_fact_selection invalid_fact_candidate invalid_fact_citation invalid_fact_attribution
      invalid_fact_assertion invalid_fact_correction fact_semantics_unverified fact_sources_incomplete
      fact_source_partition_mismatch fact_sources_too_large fact_assertion_units_too_large
      fact_request_too_large source_fact_contract_unavailable stale_fact_sources stale_input_revision
      incomplete_partition invalid_arguments source_provenance_mismatch proxy_credential_unavailable)

    cond do
      value in known ->
        %{class: value}

      match = Regex.run(~r/\{:llm_status,\s*(\d{3})\}/, value) ->
        %{class: "llm_status", status: String.to_integer(Enum.at(match, 1))}

      code = Enum.find(known, &String.contains?(value, ":" <> &1)) ->
        %{class: code}

      true ->
        %{class: "unclassified_processing_error"}
    end
  end

  defp processing_error_class(_value), do: %{class: "unclassified_processing_error"}

  defp diagnostic_enum(nil, _allowed), do: nil

  defp diagnostic_enum(value, allowed),
    do: if(value in allowed, do: value, else: "unclassified_status")

  defp diagnostic_error(value), do: diagnostic_enum(value, ~w(unauthorized forbidden access_denied
    authority_changed partition_mismatch invalid_protocol invalid_request idempotency_conflict
    not_found invalid_ack transport_failure delivery_exhausted storage_unavailable source_revision_conflict
    source_binding_mismatch capture_binding_mismatch memory_access_revoked memory_access_denied
    memory_scope_mismatch memory_sources_unavailable capture_unavailable not_negotiated))

  defp record(name, status, details) do
    item = %{gate: name, status: status, details: details}
    Process.put(@result_key, [item | Process.get(@result_key, [])])
    IO.puts(Jason.encode!(Map.put(item, :kind, "hermes_live_gate")))
  end

  defp wait!(fun, code, timeout \\ @timeout) do
    wait_until!(fun, code, System.monotonic_time(:millisecond) + timeout)
  end

  defp wait_until!(fun, code, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        fail!(code)

      true ->
        Process.sleep(100)
        wait_until!(fun, code, deadline)
    end
  end

  defp cleanup do
    resumed = safe_cleanup(fn -> resume_owned_worker() end)
    python_stopped = safe_cleanup(fn -> stop_python!() end)

    python_stopped =
      if not python_stopped and not is_nil(resource(:python)) do
        %{port: port, os_pid: pid} = resource(:python)
        # Only this exact owned child PID can be terminated. Never match process names.
        safe_cleanup(fn ->
          System.cmd("/bin/kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)

          receive do
            {^port, {:exit_status, _}} -> put_resource(:python, nil)
          after
            5_000 -> fail!("owned_python_termination_unconfirmed")
          end
        end)
      else
        python_stopped
      end

    pids_stopped =
      Enum.map(resource(:pids) || [], &safe_cleanup(fn -> stop_pid!(&1) end)) |> Enum.all?()

    apps_stopped =
      Enum.map(resource(:apps) || [], fn app ->
        safe_cleanup(fn ->
          case Application.stop(app) do
            :ok -> :ok
            {:error, {:not_started, ^app}} -> :ok
            _ -> fail!("application_shutdown_failed")
          end
        end)
      end)
      |> Enum.all?()

    stopped =
      resumed and python_stopped and pids_stopped and apps_stopped and
        is_nil(Process.whereis(Repo))

    dropped =
      if resource(:database_created) == true and stopped do
        safe_cleanup(fn ->
          assert!(
            Ecto.Adapters.Postgres.storage_down(resource(:repo_config)) == :ok,
            "owned_database_drop_failed"
          )
        end)
      else
        resource(:database_created) != true
      end

    removed =
      if is_binary(resource(:root)) and stopped,
        do:
          safe_cleanup(fn ->
            assert!(
              match?({:ok, _}, File.rm_rf(resource(:root))) and not File.exists?(resource(:root)),
              "owned_temporary_directory_removal_failed"
            )
          end),
        else: is_nil(resource(:root))

    result = %{
      python_stopped: python_stopped,
      owned_processes_stopped: stopped,
      owned_database_dropped: dropped,
      temporary_directory_removed: removed
    }

    put_resource(:cleanup, result)

    record(
      "owned_resource_cleanup",
      if(stopped and dropped and removed, do: "passed", else: "failed"),
      result
    )
  end

  defp safe_cleanup(fun) do
    try do
      fun.()
      true
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp resume_owned_worker do
    case resource(:suspended) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :sys.resume(pid)
        put_resource(:suspended, nil)

      _ ->
        :ok
    end
  end

  defp stop_pid!(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      GenServer.stop(pid, :normal, 10_000)
      assert!(not Process.alive?(pid), "owned_process_shutdown_incomplete")
    end

    :ok
  end

  defp stop_pid!(_), do: :ok

  defp resource(key), do: Process.get(@resource_key, %{})[key]

  defp put_resource(key, value),
    do: Process.put(@resource_key, Map.put(Process.get(@resource_key), key, value))

  defp remember_pid(pid), do: put_resource(:pids, [pid | resource(:pids)])

  defp remember_apps(apps),
    do: put_resource(:apps, Enum.uniq(Enum.reverse(apps) ++ resource(:apps)))

  defp assert!(condition, code), do: if(condition, do: :ok, else: fail!(code))
  defp fail!(code, diagnostics \\ %{}), do: raise(Error, code: code, diagnostics: diagnostics)
end

Backplane.HermesLiveAcceptance.main()
