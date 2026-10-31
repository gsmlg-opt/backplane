# Manual real OpenClaw acceptance, deliberately outside ExUnit discovery.
# MIX_ENV=test BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL=1 \
# MIX_TEST_PARTITION=_openclawlive_<12-to-32-random-lowercase-hex-digits> \
# OPENCLAW_NODE=/absolute/path/to/node24 \
# OPENCLAW_RUNTIME=/absolute/path/to/node_modules/openclaw \
# mix run --no-start test/openclaw_memory_live_acceptance.exs
# OPENROUTER_API_KEY is environment-only. Never uses user service ports.
# OPENCLAW_LIVE_DIAGNOSTIC=capture|overlap|capture_and_overlap runs only the
# selected unchanged oracles and cleanup; its result never qualifies a release.

defmodule Backplane.OpenClawLiveAcceptance do
  import Ecto.Query
  Code.require_file("support/hermes_semantic_oracle.exs", __DIR__)
  Code.require_file("support/openclaw_capture_barrier.exs", __DIR__)
  Code.require_file("support/openclaw_owned_process.exs", __DIR__)
  alias Backplane.{Repo, Settings}
  alias Backplane.HostAgent.{Config, MemoryProxy, MemoryRouter, Worker}
  alias Backplane.HostAgent.Memory.Access
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Backplane.Memory.Projections.{ProjectedSession, RepairFrontier, State}
  alias Backplane.Memory.Sources.{Entry, Mutation, RequestEvidence}
  alias Backplane.Memory.Sources.Source, as: NativeSource
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}

  @timeout 120_000
  @resource_key {__MODULE__, :resources}
  @result_key {__MODULE__, :results}

  defmodule Error do
    defexception [:code, diagnostics: %{}, message: "OpenClaw acceptance gate failed"]
  end

  def main do
    Process.flag(:trap_exit, true)
    Process.put(@resource_key, %{pids: [], apps: [], node: nil, suspended: nil})
    Process.put(@result_key, [])
    Logger.configure(level: :emergency)

    try do
      guard_environment!()
      prepare_database!()
      start_gateway!()
      fixture = prepare_fixture!()
      put_resource(:host_id, fixture.host.id)
      put_resource(:base_url, fixture.base_url)
      start_worker!(fixture.config)
      ready!(fixture.base_url)
      prepare_node_fixture!(fixture)
      start_node!()
      boot = node!("boot")

      gate("T01_real_loader_registry", fn ->
        assert!(
          boot["version"] == "2026.10.7" and get_in(boot, ["loader", "actualPackage"]) == true,
          "OpenClaw_boot_result_missing"
        )

        registry = get_in(boot, ["loader", "registry"])

        assert!(
          registry["ok"] == true and get_in(registry, ["plugin", "id"]) == "backplane-memory",
          "real_plugin_registry_missing"
        )

        declared = get_in(registry, ["declared", "tools"]) || []

        assert!(
          Enum.sort(declared) ==
            Enum.sort(
              ~w(backplane_memory_search backplane_memory_get backplane_memory_save backplane_memory_correct backplane_memory_withdraw backplane_memory_forget backplane_memory_status)
            ),
          "declared_plugin_tools_wrong"
        )

        assert!(
          get_in(registry, ["grants", "hooks", "allowConversationAccess", "effective"]) == true,
          "real_conversation_grant_missing"
        )

        %{
          version: boot["version"],
          loader: %{
            actual_package: true,
            registry_ready: registry["ok"],
            declared_tools: declared,
            conversation_grant: true
          },
          real_http: true,
          real_websocket: true
        }
      end)

      packaging_scenario!()

      if resource(:diagnostic),
        do: run_diagnostics!(fixture),
        else: run_scenarios!(fixture)
    rescue
      error in Error ->
        record("startup", "failed", %{code: error.code, diagnostics: error.diagnostics})

      error ->
        record("startup", "failed", %{
          code: "exception:#{inspect(error.__struct__)}",
          frames: exception_frames(__STACKTRACE__)
        })
    catch
      kind, _ -> record("startup", "failed", %{code: "caught:#{kind}"})
    after
      cleanup()
    end

    results = Process.get(@result_key) |> Enum.reverse()

    passed =
      Enum.all?(
        results,
        &(&1.status == "passed" or
            (&1.gate == "T13_real_model_semantics" and &1.status == "not_run" and
               resource(:mode) == "deterministic"))
      )

    report =
      %{
        kind: "openclaw_live_acceptance",
        status: if(passed, do: "passed", else: "failed"),
        deterministic_results: Enum.reject(results, &(&1.gate == "T13_real_model_semantics")),
        real_model_results: Enum.filter(results, &(&1.gate == "T13_real_model_semantics")),
        real_model:
          if(resource(:mode) == "deterministic" or resource(:diagnostic),
            do: %{
              status: "not_run",
              reason:
                if(resource(:diagnostic),
                  do: "diagnostic_only",
                  else: "not_requested_by_deterministic_scope"
                )
            },
            else: %{
              status:
                (Enum.find(results, &(&1.gate == "T13_real_model_semantics")) ||
                   %{status: "blocked"}).status
            }
          ),
        mode: resource(:mode),
        node_version: resource(:node_version),
        production_installation_verified: false,
        database: resource(:database),
        cleanup: resource(:cleanup)
      }

    report =
      if resource(:diagnostic) do
        Map.merge(report, %{
          kind: "openclaw_live_diagnostic",
          status: if(passed, do: "diagnostic_passed", else: "diagnostic_failed"),
          diagnostic_only: true,
          diagnostic: resource(:diagnostic),
          qualification: "not_qualified"
        })
      else
        report
      end

    IO.puts(Jason.encode!(report))

    if not passed, do: System.halt(1)
  end

  defmodule FaultProxy do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts),
      do:
        forward(
          Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason)),
          opts
        )

    def forward(%Plug.Conn{halted: true} = conn, _opts), do: conn

    def forward(conn, opts) do
      owner = Keyword.fetch!(opts, :owner)
      state = Agent.get(owner, & &1)

      mutation? =
        String.contains?(conn.request_path, "/capture/v1/hooks/") or
          String.ends_with?(conn.request_path, "/source_mutate") or
          String.ends_with?(conn.request_path, "/source_reconcile")

      Agent.update(
        owner,
        &%{
          &1
          | requests: &1.requests + 1,
            calls: Enum.take([%{path: conn.request_path, args: conn.body_params} | &1.calls], 512)
        }
      )

      if state.mode == :unreceived and mutation? do
        Plug.Conn.send_resp(
          conn,
          503,
          Jason.encode!(%{ok: false, error: "canonical_unavailable"})
        )
      else
        case Req.post(state.target <> conn.request_path,
               json: conn.body_params,
               retry: false,
               receive_timeout: 20_000
             ) do
          {:ok, response} ->
            Agent.update(owner, fn value ->
              payloads =
                if mutation?,
                  do: [
                    %{path: conn.request_path, payload: conn.body_params, status: response.status}
                    | value.payloads
                  ],
                  else: value.payloads

              %{value | payloads: Enum.take(payloads, 256)}
            end)

            {status, body} =
              if state.mode == :lost_ack and mutation? and response.status in [200, 202],
                do: {503, %{"ok" => false, "error" => "canonical_unavailable"}},
                else: {response.status, response.body}

            body =
              if state.mode == :old_host and
                   String.ends_with?(conn.request_path, "/source_capabilities"),
                 do:
                   update_in(body, ["result"], fn result ->
                     result
                     |> Map.update!(
                       "contracts",
                       &Enum.reject(&1, fn x -> String.starts_with?(x, "openclaw_") end)
                     )
                     |> Map.update!(
                       "negotiated",
                       &Enum.reject(&1, fn x -> String.starts_with?(x, "openclaw_") end)
                     )
                   end),
                 else: body

            body =
              if state.mode == :capture_mismatch and
                   String.ends_with?(conn.request_path, "/source_capabilities"),
                 do:
                   put_in(
                     body,
                     ["result", "capture_binding_fingerprint"],
                     String.duplicate("b", 64)
                   ),
                 else: body

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(status, Jason.encode!(body))

          _ ->
            Plug.Conn.send_resp(
              conn,
              503,
              Jason.encode!(%{ok: false, error: "canonical_unavailable"})
            )
        end
      end
    end
  end

  defp find_node! do
    path = System.get_env("OPENCLAW_NODE") || System.find_executable("node")
    assert!(is_binary(path) and File.exists?(path), "BLOCKED_ENV:Node24_executable_missing")
    {version, 0} = System.cmd(path, ["--version"], stderr_to_stdout: true)
    assert!(String.trim(version) == "v24.22.1", "BLOCKED_ENV:requires_Node24")
    put_resource(:node_version, String.trim(version))
    path
  end

  defp ready!(base_url, previous \\ nil) do
    wait!(
      fn ->
        connection = live_connection(previous)

        if connection do
          case Req.post(base_url <> "/memory/main/call/source_capabilities",
                 json: %{integration: "openclaw"},
                 retry: false,
                 receive_timeout: 2_000
               ) do
            {:ok,
             %{
               status: 200,
               body: %{"ok" => true, "result" => %{"ready" => true, "capture_ready" => true}}
             }} ->
              live_connection(previous) == connection

            _ ->
              false
          end
        else
          false
        end
      end,
      "host_OpenClaw_source_capture_negotiation_unready",
      25_000
    )
  end

  defp prepare_node_fixture!(fixture) do
    {:ok, proxy_state} =
      Agent.start_link(fn ->
        %{mode: :normal, target: fixture.base_url, requests: 0, payloads: [], calls: []}
      end)

    remember_pid(proxy_state)

    {:ok, proxy} =
      Gaoxy.HTTP.start_link(plug: {FaultProxy, owner: proxy_state}, ip: {127, 0, 0, 1}, port: 0)

    remember_pid(proxy)
    %{local: {:ok, {{127, 0, 0, 1}, port}}} = Gaoxy.info(proxy, :http)
    assert!(port not in [4220, 4221, 4222], "reserved_proxy_port")
    put_resource(:proxy_state, proxy_state)
    status = Access.status()
    package_home = Path.join(resource(:root), "package-home")
    File.mkdir!(package_home)

    {:ok, installed} =
      Backplane.HostAgent.PluginInstaller.install("memory", "openclaw", %{
        home_dir: package_home,
        source_root: Path.expand("../integrations/memory", __DIR__)
      })

    put_resource(:installed_package, installed["target_path"])
    path = Path.join(resource(:root), "openclaw-fixture.json")

    File.write!(
      path,
      Jason.encode!(%{
        root: Path.join(resource(:root), "openclaw"),
        host_url: "http://127.0.0.1:#{port}",
        package_path: installed["target_path"],
        agent_id: "main",
        access_id: status.default_access_id,
        marker: fixture.marker,
        token_budget: 1000,
        timeout_ms: 5000
      })
    )

    File.chmod!(path, 0o600)
    put_resource(:node_fixture_path, path)
  end

  defp proxy_mode(mode), do: Agent.update(resource(:proxy_state), &%{&1 | mode: mode})

  defp start_node! do
    script = Path.expand("support/openclaw_runtime_acceptance.mjs", __DIR__)
    assert!(File.exists?(script), "BLOCKED_ENV:OpenClaw_runtime_harness_missing")

    env = [
      {~c"OPENCLAW_LIVE_FIXTURE", String.to_charlist(resource(:node_fixture_path))},
      {~c"OPENROUTER_API_KEY", false},
      {~c"BACKPLANE_MEMORY_URL", false},
      {~c"BACKPLANE_MEMORY_AGENT_ID", false},
      {~c"BACKPLANE_MEMORY_ACCESS_ID", false}
    ]

    port =
      Port.open({:spawn_executable, resource(:node_executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 65_536},
        {:env, env},
        {:args, [script]}
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    put_resource(:node, %{port: port, os_pid: pid})
  end

  defp node!(op, args \\ %{}) do
    %{port: port} = resource(:node)
    id = Ecto.UUID.generate()
    true = Port.command(port, Jason.encode!(Map.merge(args, %{id: id, op: op})) <> "\n")
    await_node!(port, id, op, System.monotonic_time(:millisecond) + @timeout, "")
  end

  defp await_node!(port, id, op, deadline, partial) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, {:noeol, bytes}}} ->
        assert!(
          byte_size(partial) + byte_size(bytes) <= 8_388_608,
          "node_protocol_line_too_large"
        )

        await_node!(port, id, op, deadline, partial <> bytes)

      {^port, {:data, {:eol, bytes}}} ->
        case Jason.decode(partial <> bytes) do
          {:ok, %{"id" => ^id, "ok" => true, "result" => result}} ->
            result

          {:ok, %{"id" => ^id, "ok" => false, "error" => error}} ->
            fail!(
              "node:" <> to_string(error["code"]),
              Map.take(
                error,
                ~w(code message operation stage reason failure_class gateway_code gateway_message
                gateway_details request_sent retryable admission_attempts pre_admission_rejections)
              )
            )

          _ ->
            await_node!(port, id, op, deadline, "")
        end

      {^port, {:exit_status, status}} ->
        put_resource(:node, nil)
        fail!("node_peer_exited:#{status}")

      {:EXIT, _pid, _reason} ->
        await_node!(port, id, op, deadline, partial)
    after
      remaining -> fail!("node_protocol_timeout:#{op}")
    end
  end

  defp stop_node! do
    case resource(:node) do
      nil ->
        :ok

      %{port: port} ->
        node!("stop")

        receive do
          {^port, {:exit_status, 0}} ->
            put_resource(:node, nil)

          {^port, {:exit_status, _}} ->
            put_resource(:node, nil)
            fail!("node_shutdown_failed")
        after
          15_000 -> fail!("node_shutdown_timeout")
        end
    end
  end

  defp capture_scenario!(fixture) do
    first_input = %{
      prompt: "My durable deployment status color is amber. Fixture #{fixture.marker}",
      responseText: "I guessed cobalt as your deployment status color."
    }

    first = node!("turn", first_input)
    put_resource(:first_turn, first)
    gate("T02_real_context_identity", fn -> verify_turn_identity!(fixture, first) end)

    second_input = %{
      prompt: "Correction: amber is correct. Cobalt was your mistake, not my preference.",
      responseText: ""
    }

    second = node!("turn", second_input)

    third_input = %{
      prompt: "My durable deployment status color is amber. Fixture #{fixture.marker}",
      responseText: "Acknowledged: amber is your deployment status color."
    }

    third = node!("turn", third_input)
    fourth_input = %{prompt: "Unrelated chat: the weather today is cloudy.", responseText: ""}
    fourth = node!("turn", fourth_input)

    gate("T03_turn_delta", fn ->
      verify_turns!(
        fixture,
        [first, second, third, fourth],
        [first_input, second_input, third_input, fourth_input]
      )
    end)

    first
  end

  defp run_diagnostics!(fixture) do
    if resource(:diagnostic) in ["capture", "capture_and_overlap"] do
      capture_scenario!(fixture)
      node!("reset")
    end

    if resource(:diagnostic) in ["overlap", "capture_and_overlap"],
      do: concurrent_identity_scenario!(fixture)
  end

  defp run_scenarios!(fixture) do
    first = capture_scenario!(fixture)
    node!("reset")
    session_id = first["sessionId"]

    projected =
      gate("T12_canonical_capture_projection", fn ->
        projection = verify_projection!(fixture, session_id)
        summary = verify_async_summary!(fixture.host.id, session_id)

        processing =
          if resource(:mode) == "full" and fixture.model_available,
            do: verify_processing!(fixture.host.id, session_id, fixture),
            else: %{extraction: "not_requested_by_deterministic_scope"}

        put_resource(:processing, processing)

        Map.merge(projection, %{
          summary_id: summary.id,
          async_source_links:
            Repo.aggregate(
              from(link in SourceEvent, where: link.summary_id == ^summary.id),
              :count
            ),
          processing: processing
        })
      end)

    if resource(:mode) == "deterministic" do
      record("T13_real_model_semantics", "not_run", %{
        reason: "not_requested_by_deterministic_scope"
      })
    else
      if projected and fixture.model_available do
        gate("T13_real_model_semantics", fn ->
          processing = resource(:processing)

          verify_derived_current_facts!(
            processing.memory_ids,
            Repo.get!(Summary, processing.summary_id)
          )
        end)
      else
        blocked("T13_real_model_semantics", "BLOCKED_ENV:real_model_or_capture_unavailable")
      end
    end

    concurrent_identity_scenario!(fixture)
    replay_scenario!(fixture)
    native_scenarios!(fixture)
    privacy_recall_scenarios!(fixture)
    recovery_scenarios!(fixture)
    negotiation_scenarios!(fixture)

    flush_scenarios!(fixture)
    audience_scenarios!(fixture)
  end

  defp concurrent_identity_scenario!(fixture) do
    gate("T02_concurrent_invocation_identity", fn ->
      inputs =
        for agent <- ~w(main shared) do
          %{
            agentId: agent,
            sessionKey: "agent:#{agent}:qualification-overlap-#{fixture.marker}",
            prompt: "Concurrent transient fixture #{fixture.marker}: input for #{agent} only."
          }
        end

      result =
        node!("concurrent_turns", %{
          turns: inputs,
          responseText: "Concurrent fixture acknowledged."
        })

      turns = result["turns"] || []
      overlap = result["overlap"] || %{}

      unless overlap["held_until_both"] == true and overlap["model_requests"] == 2 and
               length(overlap["arrivals"] || []) == 2 and is_binary(overlap["releasedAt"]) do
        fail!("actual_model_request_overlap_not_proven", %{
          overlap: overlap,
          turns: capture_turn_diagnostics(turns, result)
        })
      end

      assert!(
        length(turns) == 2 and Enum.sort(Enum.map(turns, & &1["agentId"])) == ~w(main shared) and
          length(Enum.uniq_by(turns, & &1["sessionId"])) == 2 and
          length(Enum.uniq_by(turns, & &1["runId"])) == 2,
        "concurrent_session_or_run_identity_collapsed"
      )

      events =
        Enum.flat_map(turns, fn turn ->
          expected = Enum.find(inputs, &(&1.agentId == turn["agentId"]))
          session = turn["sessionId"]
          run = turn["runId"]

          assert!(
            is_binary(session) and is_binary(run) and turn["sessionKey"] == expected.sessionKey and
              turn["prompt"] == expected.prompt,
            "concurrent_public_identity_mismatch"
          )

          query =
            from(e in Event,
              where:
                e.host_id == ^fixture.host.id and
                  fragment("?->'source'->>'run_id'", e.payload) == ^run and
                  e.event_type in ["conversation.user_message", "conversation.agent_message"]
            )

          wait!(fn -> Repo.aggregate(query, :count) == 2 end, "concurrent_capture_not_canonical")
          captured = Repo.all(query)

          assert!(
            Enum.all?(captured, &(&1.agent_id == expected.agentId and &1.session_id == session)) and
              Enum.count(captured, &(&1.role == "user" and &1.content == expected.prompt)) == 1 and
              Enum.count(
                captured,
                &(&1.role == "assistant" and &1.content == "Concurrent fixture acknowledged.")
              ) == 1,
            "concurrent_capture_crossed_invocation"
          )

          captured
        end)

      contexts = node!("snapshot")["actualContext"] || []

      for turn <- turns, hook <- ~w(before_prompt_build agent_end) do
        context = Enum.find(contexts, &(&1["hook"] == hook and &1["runId"] == turn["runId"]))

        assert!(
          is_map(context) and context["agentId"] == turn["agentId"] and
            context["sessionId"] == turn["sessionId"] and
            context["sessionKey"] == turn["sessionKey"],
          "concurrent_real_hook_context_crossed_invocation"
        )
      end

      assert!(
        length(Enum.uniq_by(events, &get_in(&1.payload, ["source", "profile_id"]))) == 2 and
          length(Enum.uniq_by(events, &Map.take(&1, [:memory_space_id, :scope, :namespace]))) == 1,
        "concurrent_source_namespaces_or_authorized_sharing_wrong"
      )

      %{
        actual_overlapping_model_requests: overlap["model_requests"],
        barrier_held_until_both: true,
        agents: Enum.map(turns, & &1["agentId"]),
        distinct_sessions_and_runs: true,
        exact_original_inputs: true,
        distinct_source_namespaces_same_authorized_partition: true
      }
    end)
  end

  defp verify_turn_identity!(fixture, turn) do
    assert!(
      is_binary(turn["sessionId"]) and is_binary(turn["runId"]) and turn["agentId"] == "main",
      "actual_OpenClaw_identity_missing"
    )

    session = turn["sessionId"]
    run = turn["runId"]

    context =
      Enum.find(
        turn["actualContext"] || [],
        &(&1["hook"] == "before_prompt_build" and &1["runId"] == run)
      )

    assert!(
      is_map(context) and context["current"] == true and context["sandboxed"] == false and
        get_in(context, ["memoryAudience", "kind"]) == "owner-private" and
        context["sessionId"] == session,
      "real_owner_private_audience_missing"
    )

    wait!(
      fn ->
        Repo.exists?(
          from(e in Event,
            where:
              e.host_id == ^fixture.host.id and e.session_id == ^session and
                fragment("?->'source'->>'run_id'", e.payload) == ^run and e.role == "user"
          )
        )
      end,
      "actual_OpenClaw_capture_missing"
    )

    events =
      Repo.all(
        from(e in Event, where: e.host_id == ^fixture.host.id and e.session_id == ^session)
      )

    assert!(
      Enum.all?(
        events,
        &(&1.integration == "openclaw" and &1.agent_id == "main" and &1.session_id == session)
      ),
      "canonical_OpenClaw_identity_changed"
    )

    if is_nil(resource(:native_profile_id)) do
      user =
        Enum.find(
          events,
          &(&1.role == "user" and get_in(&1.payload, ["source", "run_id"]) == run)
        )

      profile = user && get_in(user.payload, ["source", "profile_id"])
      assert!(is_binary(profile), "primary_native_source_profile_missing")
      put_resource(:native_profile_id, profile)
    end

    %{session_id: session, run_id: run, captured_events: length(events)}
  end

  defp verify_turns!(fixture, turns, inputs) do
    session = hd(turns)["sessionId"]
    runs = Enum.map(turns, & &1["runId"])

    assert!(
      length(Enum.uniq(runs)) == 4 and Enum.all?(turns, &(&1["sessionId"] == session)),
      "turn_session_or_run_mapping_wrong"
    )

    wait!(
      fn ->
        Repo.aggregate(
          from(e in Event,
            where:
              e.host_id == ^fixture.host.id and e.session_id == ^session and
                e.event_type == "conversation.user_message"
          ),
          :count
        ) == 4
      end,
      "turn_delta_user_count_wrong"
    )

    # Public chat final/history do not await asynchronous agent_end capture or
    # canonical host delivery. Observe both before asserting absence of records.
    initial = node!("snapshot")
    pending_after_chat = not Backplane.OpenClawCaptureBarrier.settled?(initial, turns)

    assistant_count_after_chat =
      Repo.aggregate(
        from(e in Event,
          where:
            e.host_id == ^fixture.host.id and e.session_id == ^session and e.role == "assistant"
        ),
        :count
      )

    wait!(
      fn -> Backplane.OpenClawCaptureBarrier.settled?(node!("snapshot"), turns) end,
      "turn_capture_completion_unconfirmed"
    )

    events =
      Repo.all(
        from(e in Event,
          where:
            e.host_id == ^fixture.host.id and e.session_id == ^session and
              e.event_type in ["conversation.user_message", "conversation.agent_message"]
        )
      )

    assert!(Enum.count(events, &(&1.role == "user")) == 4, "cumulative_history_duplicated")

    unless Enum.count(events, &(&1.role == "assistant")) == 2 do
      fail!("empty_assistant_fabricated_or_lost_messages", %{
        captured_roles: Enum.frequencies_by(events, & &1.role),
        turns: capture_turn_diagnostics(turns, node!("snapshot"))
      })
    end

    assert!(
      Enum.all?(events, &(get_in(&1.payload, ["source", "run_id"]) in runs)),
      "cross_turn_source_identity"
    )

    for {turn, input} <- Enum.zip(turns, inputs) do
      actual =
        events
        |> Enum.filter(&(get_in(&1.payload, ["source", "run_id"]) == turn["runId"]))
        |> Enum.map(&{&1.role, &1.content})
        |> Enum.sort()

      expected =
        [{"user", input.prompt}] ++
          if(input.responseText == "", do: [], else: [{"assistant", input.responseText}])

      assert!(actual == Enum.sort(expected), "turn_original_content_or_occurrence_changed")
    end

    %{
      user_occurrences: 4,
      assistant_occurrences: 2,
      real_session: session,
      real_runs: runs,
      capture_pending_after_chat: pending_after_chat,
      assistant_occurrences_after_chat: assistant_count_after_chat,
      exact_turns_completed_and_canonical_acknowledged: true,
      exact_original_content: true
    }
  end

  # Only identities, roles, equality hashes and fixed authority classifications
  # leave the isolated runtime on a failed turn-integrity gate.
  defp capture_turn_diagnostics(turns, snapshot) do
    Enum.map(turns, fn turn ->
      run = turn["runId"]

      %{
        identity: Map.take(turn, ~w(agentId sessionId sessionKey runId)),
        terminal_state: get_in(turn, ["terminal", "payload", "state"]),
        hooks:
          snapshot
          |> Map.get("actualContext", [])
          |> Enum.filter(&(is_binary(run) and &1["runId"] == run))
          |> Enum.map(
            &Map.take(
              &1,
              ~w(hook observedAt current audienceCode delayMs toolAuthority messageBoundary)
            )
          ),
        journal_turns:
          snapshot
          |> get_in(["journal", "turns"])
          |> List.wrap()
          |> Enum.filter(fn row ->
            case Jason.decode(row["identity"] || "") do
              {:ok, [_, _, ^run]} when is_binary(run) -> true
              _ -> false
            end
          end)
          |> Enum.map(fn row ->
            %{
              completed: row["completed"],
              fence: Map.take(row["payload"] || %{}, ~w(history_count history_hash prompt_hash))
            }
          end),
        deliveries:
          snapshot
          |> get_in(["journal", "deliveries"])
          |> List.wrap()
          |> Enum.filter(&(is_binary(run) and get_in(&1, ["payload", "run_id"]) == run))
          |> Enum.map(fn row ->
            %{
              state: row["state"],
              source: Map.take(row["payload"] || %{}, ~w(role occurrence_id message_index))
            }
          end)
      }
    end)
  end

  defp verify_projection!(fixture, session) do
    wait!(
      fn ->
        match?(
          %ProjectedSession{status: status} when status in ["completed", "stopped"],
          Repo.get_by(ProjectedSession, host_id: fixture.host.id, session_id: session)
        )
      end,
      "canonical_session_projection_incomplete"
    )

    projected = Repo.get_by!(ProjectedSession, host_id: fixture.host.id, session_id: session)

    wait!(
      fn ->
        frontier = Repo.get_by(RepairFrontier, host_id: fixture.host.id, session_id: session)

        (frontier && frontier.completed_generation == frontier.requested_generation) and
          frontier.completed_revision == projected.input_revision
      end,
      "projection_frontier_unsettled"
    )

    states =
      Repo.all(
        from(s in State,
          where:
            s.subject_id == ^projected.subject_id and
              s.projector in ["observations", "session", "activity", "replay"]
        )
      )

    assert!(
      length(states) == 4 and
        Enum.all?(
          states,
          &(&1.status == "complete" and &1.input_revision == projected.input_revision)
        ),
      "projection_revision_lineage_wrong"
    )

    %{
      real_session: session,
      input_revision: projected.input_revision,
      projection_states: length(states)
    }
  end

  defp replay_scenario!(fixture) do
    gate("T05_immutable_replay", fn ->
      snapshot = node!("snapshot")

      row =
        Enum.find(
          get_in(snapshot, ["journal", "deliveries"]),
          &(&1["path"] == "/capture/v1/hooks/openclaw/message")
        )

      assert!(is_map(row), "captured_journal_message_missing")
      id = row["event_id"]
      wait!(fn -> not is_nil(Repo.get(Event, id)) end, "original_capture_not_canonical")
      first = Repo.get!(Event, id)

      {:ok, replay} =
        Req.post(fixture.base_url <> row["path"], json: row["payload"], retry: false)

      assert!(replay.status == 202, "immutable_capture_replay_refused")
      changed = Map.put(row["payload"], "content", "Changed immutable fixture occurrence")
      content = changed["content"]

      changed =
        put_in(changed, ["completeness"], %{
          "truncated" => false,
          "coverage" => "full",
          "original_length" => String.length(content),
          "original_sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)
        })

      {:ok, conflict} = Req.post(fixture.base_url <> row["path"], json: changed, retry: false)

      assert!(
        conflict.status == 400 and conflict.body["error"] == "capture identity collision",
        "changed_immutable_capture_not_conflicted"
      )

      assert!(
        Repo.get!(Event, id).payload_hash == first.payload_hash,
        "immutable_replay_changed_canonical_event"
      )

      same_text =
        Repo.all(
          from(e in Event,
            where:
              e.host_id == ^fixture.host.id and e.content == ^first.content and
                e.event_type == "conversation.user_message"
          )
        )

      assert!(
        length(same_text) == 2 and length(Enum.uniq_by(same_text, & &1.id)) == 2,
        "distinct_equal_text_occurrences_collapsed"
      )

      %{
        duplicate_receipt: true,
        changed_payload_conflict: true,
        distinct_equal_text_occurrences: 2
      }
    end)
  end

  defp call_tool!(name, args) do
    prompt = "Execute the requested qualification operation."

    node!("turn", %{
      prompt: prompt,
      tools: [%{name: name, args: args}],
      responseText: "Qualification operation complete."
    })
  end

  defp canonical_provider_entry!(fixture, content) do
    wait!(
      fn ->
        provider_entries(fixture.host.id)
        |> Enum.any?(&(&1.active and Repo.get!(Memory, &1.memory_id).content == content))
      end,
      "provider_tool_source_not_committed"
    )

    Enum.find(
      provider_entries(fixture.host.id),
      &(&1.active and Repo.get!(Memory, &1.memory_id).content == content)
    )
  end

  defp provider_entries(host),
    do:
      Repo.all(
        from(e in Entry,
          join: s in NativeSource,
          on: s.id == e.source_id,
          where: s.host_id == ^host and s.integration == "openclaw" and s.target == "provider"
        )
      )

  defp native_scenarios!(fixture) do
    old = "Fixture #{fixture.marker}: native memory qualification target is willow."
    current = "Fixture #{fixture.marker}: native memory qualification target is cedar."

    gate("T09_native_lifecycle", fn ->
      node!("native", %{path: "MEMORY.md", content: old})
      node!("turn", %{prompt: "Inspect fixture native state.", responseText: "Acknowledged."})

      wait!(
        fn -> Enum.any?(native_entries(fixture.host.id), & &1.active) end,
        "native_source_not_committed"
      )

      [original] = native_entries(fixture.host.id)
      put_resource(:native_original, original)
      call_tool!("backplane_memory_save", %{content: old, fact_key: "independent-willow"})
      provider = canonical_provider_entry!(fixture, old)

      assert!(
        provider.memory_id == original.memory_id,
        "independent_source_canonical_identity_diverged"
      )

      put_resource(:provider_independent, provider)
      node!("native", %{path: "MEMORY.md", content: current})

      turn =
        node!("turn", %{prompt: "Inspect corrected native state.", responseText: "Acknowledged."})

      put_resource(:native_recall_turn, turn)

      wait!(
        fn ->
          Enum.any?(
            native_entries(fixture.host.id),
            &(&1.id == original.id and &1.revision > original.revision and
                &1.memory_id != original.memory_id)
          )
        end,
        "native_revision_identity_not_stable"
      )

      [corrected] = native_entries(fixture.host.id)
      put_resource(:native_corrected, corrected)

      node!("restart")

      restarted =
        node!("turn", %{
          prompt: "Inspect unchanged native source after actual gateway restart.",
          responseText: "Acknowledged."
        })

      run = restarted["runId"]

      query =
        from(e in Event,
          where:
            e.host_id == ^fixture.host.id and
              fragment("?->'source'->>'run_id'", e.payload) == ^run and e.role == "user"
        )

      wait!(fn -> Repo.exists?(query) end, "post_restart_native_capture_missing")
      restarted_event = Repo.one!(query)

      assert!(
        get_in(restarted_event.payload, ["source", "profile_id"]) == resource(:native_profile_id),
        "unchanged_workspace_source_namespace_changed_after_restart"
      )

      [after_restart] = native_entries(fixture.host.id)

      assert!(
        Map.take(after_restart, [:id, :entry_id, :revision, :memory_id, :active]) ==
          Map.take(corrected, [:id, :entry_id, :revision, :memory_id, :active]),
        "unchanged_native_source_identity_changed_after_restart"
      )

      %{
        stable_entry_id: original.entry_id,
        add_edit: true,
        unchanged_workspace_restart_identity: true,
        old_support_survives_native_replacement:
          Repo.get!(Memory, original.memory_id).effective_support
      }
    end)

    gate("T10_incomplete_reconciliation", fn ->
      [before] = native_entries(fixture.host.id)
      node!("native", %{path: "USER.md", content: String.duplicate("x", 300_000)})

      node!("turn", %{
        prompt: "Inspect oversized native source refusal.",
        responseText: "Acknowledged."
      })

      [after_entry] = native_entries(fixture.host.id)

      assert!(
        after_entry.revision == before.revision and after_entry.active and
          after_entry.memory_id == before.memory_id,
        "failed_snapshot_withdrew_existing_source"
      )

      snapshot = node!("snapshot")

      assert!(
        Enum.any?(snapshot["diagnostics"], &String.contains?(&1, "native_inventory_unsupported")),
        "oversized_snapshot_not_diagnosed"
      )

      node!("native", %{path: "USER.md", content: ""})
      [mutation] = Repo.all(from(m in Mutation, where: m.id == ^before.mutation_id))

      {:ok, source} =
        Backplane.Memory.Sources.Source |> Repo.get(before.source_id) |> then(&{:ok, &1})

      args = %{
        "protocol" => "memory_sources.v1",
        "event_id" => Ecto.UUID.generate(),
        "source" => %{
          "integration" => source.integration,
          "installation_id" => source.installation_id,
          "profile_id" => source.profile_id,
          "target" => source.target
        },
        "entry_id" => before.entry_id,
        "revision" => 1,
        "operation" => "upsert",
        "content" => old,
        "type" => "semantic",
        "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "provenance" =>
          Map.merge(mutation.provenance, %{
            "document_sha256" => Base.encode16(:crypto.hash(:sha256, old), case: :lower),
            "document_revision" => Base.encode16(:crypto.hash(:sha256, old), case: :lower)
          })
      }

      {:ok, response} =
        Req.post(fixture.base_url <> "/memory/main/call/source_mutate", json: args, retry: false)

      assert!(response.status == 200, "late_source_revision_not_accepted_for_ordering")
      event_id = args["event_id"]

      wait!(
        fn -> match?(%Mutation{outcome: "stale"}, Repo.get(Mutation, event_id)) end,
        "late_source_revision_not_stale"
      )

      assert!(
        hd(native_entries(fixture.host.id)).memory_id == before.memory_id,
        "late_revision_replaced_current_head"
      )

      %{oversize_snapshot_preserved_head: true, late_revision_stale: true}
    end)

    gate("T11_source_support_and_global_forget", fn ->
      original = resource(:native_original)
      provider = resource(:provider_independent)
      corrected = resource(:native_corrected)

      assert!(
        Repo.get!(Memory, original.memory_id).effective_support,
        "independent_support_lost_on_native_replace"
      )

      call_tool!("backplane_memory_withdraw", %{entry_id: provider.entry_id})

      wait!(
        fn -> not Repo.get!(Memory, original.memory_id).effective_support end,
        "sole_provider_withdrawal_retained_current_support"
      )

      call_tool!("backplane_memory_forget", %{id: corrected.memory_id, confirm_global: true})

      wait!(
        fn -> not is_nil(Repo.get!(Memory, corrected.memory_id).deleted_at) end,
        "global_forget_not_durable"
      )

      node!("native", %{path: "MEMORY.md", content: current <> "\n"})

      node!("turn", %{
        prompt: "Inspect globally forgotten source after revision.",
        responseText: "Acknowledged."
      })

      wait!(
        fn -> Enum.all?(native_entries(fixture.host.id), &(!&1.active and &1.suppressed)) end,
        "reconciliation_revived_global_forget"
      )

      node!("native", %{path: "MEMORY.md", content: ""})
      node!("turn", %{prompt: "Inspect empty native state.", responseText: "Acknowledged."})
      node!("native", %{path: "MEMORY.md", content: nil})

      node!("turn", %{prompt: "Inspect confirmed native deletion.", responseText: "Acknowledged."})

      assert!(
        Enum.all?(native_entries(fixture.host.id), &(!&1.active)),
        "confirmed_native_delete_retained_support"
      )

      %{
        independent_support_survives: true,
        sole_source_withdrawn: true,
        global_forget_suppresses_later_reconcile: true,
        empty_and_confirmed_delete: true
      }
    end)
  end

  defp privacy_recall_scenarios!(fixture) do
    gate("T04_capture_privacy_and_projection", fn ->
      raw = "Fixture #{fixture.marker}: API_KEY=synthetic-private-qualification-value"
      turn = node!("turn", %{prompt: raw, responseText: "Acknowledged."})
      run = turn["runId"]

      wait!(
        fn ->
          Repo.exists?(
            from(e in Event,
              where:
                e.host_id == ^fixture.host.id and
                  fragment("?->'source'->>'run_id'", e.payload) == ^run and e.role == "user"
            )
          )
        end,
        "redacted_capture_missing"
      )

      events =
        Repo.all(
          from(e in Event,
            where:
              e.host_id == ^fixture.host.id and
                fragment("?->'source'->>'run_id'", e.payload) == ^run
          )
        )

      assert!(
        not Enum.any?(
          events,
          &(Jason.encode!(&1.payload) =~ "synthetic-private-qualification-value")
        ),
        "sensitive_fixture_value_egressed_to_canonical"
      )

      all = Repo.all(from(e in Event, where: e.host_id == ^fixture.host.id and e.role == "user"))

      assert!(
        not Enum.any?(all, &(&1.content =~ "Backplane memory reference data")),
        "model_only_recall_recaptured_as_user_evidence"
      )

      %{
        egress_redaction: true,
        original_roles_preserved: true,
        model_only_context_not_recaptured: true
      }
    end)

    gate("T14_interactive_provider_tools", fn ->
      old = "Fixture #{fixture.marker}: provider-owned qualification fruit is plum."
      corrected = "Fixture #{fixture.marker}: provider-owned qualification fruit is pear."
      call_tool!("backplane_memory_save", %{content: old})
      initial = canonical_provider_entry!(fixture, old)
      call_tool!("backplane_memory_correct", %{entry_id: initial.entry_id, content: corrected})
      current = canonical_provider_entry!(fixture, corrected)

      assert!(
        current.entry_id == initial.entry_id and current.memory_id != initial.memory_id,
        "provider_correction_identity_wrong"
      )

      get = call_tool!("backplane_memory_get", %{id: current.memory_id})

      assert!(
        Jason.encode!(get["toolResults"]) =~ current.memory_id,
        "exact_get_tool_not_executed"
      )

      native = resource(:native_original)

      refused =
        call_tool!("backplane_memory_correct", %{
          entry_id: native.entry_id,
          content: "Must not rewrite native ownership"
        })

      assert!(
        Jason.encode!(refused["toolResults"]) =~ "native_file_owned",
        "native_file_ownership_not_enforced"
      )

      put_resource(:interactive_entry, current)

      %{
        save_committed: true,
        corrected_same_provider_entry: true,
        exact_get: true,
        native_rewrite_refused: true
      }
    end)

    gate("T16_recall_budgets_and_current_state", fn ->
      entry = resource(:interactive_entry)

      turn =
        node!("turn", %{
          prompt: "What is the provider-owned qualification fruit for Fixture #{fixture.marker}?",
          responseText: "Acknowledged."
        })

      model = last_user_text(turn)
      assert!(model =~ "pear", "relevant_current_recall_missing")

      block =
        case String.split(model, "Backplane memory reference data", parts: 2) do
          [_prefix, block] -> "Backplane memory reference data" <> block
          _ -> fail!("automatic_recall_context_missing")
        end

      reference = block |> String.split("\n\n", parts: 2) |> hd()
      assert!(byte_size(reference) <= 1000, "final_reference_context_budget_exceeded")

      assert!(
        not String.contains?(model, "native memory qualification target is cedar"),
        "forgotten_native_source_in_current_prompt"
      )

      captures =
        Enum.filter(
          get_in(turn, ["journal", "deliveries"]),
          &String.starts_with?(&1["path"], "/capture/v1/hooks/")
        )

      assert!(captures != [], "recall_scenario_did_not_capture")

      {:ok, result} =
        Req.post(fixture.base_url <> "/memory/main/call/recall",
          json: %{query: "provider-owned qualification fruit", token_budget: 1000, limit: 20},
          retry: false,
          receive_timeout: 20_000
        )

      rows = get_in(result.body, ["result", "results"]) || []
      row = Enum.find(rows, &((&1["canonical_id"] || &1["id"]) == entry.memory_id))
      assert!(is_map(row) and row["source_refs"] != [], "recall_provenance_missing")

      assert!(
        Enum.all?(rows, &(&1["effective_support"] == true and &1["relevance_accepted"] == true)),
        "ineligible_recall_released"
      )

      irrelevant =
        node!("turn", %{
          prompt: "Unrelated question about quasiperiodic neutrino tomography 7f2a90.",
          responseText: "Acknowledged."
        })

      assert!(
        not (last_user_text(irrelevant) =~ "Backplane memory reference data"),
        "irrelevant_query_injected_memory"
      )

      %{
        relevant_current_record: entry.memory_id,
        provenance_present: true,
        unrelated_zero_injection: true,
        token_budget: 1000
      }
    end)
  end

  defp last_user_text(turn) do
    turn["finalPrompt"]
    |> Enum.reverse()
    |> Enum.find(&(&1["role"] == "user"))
    |> case do
      %{"content" => content} when is_binary(content) ->
        content

      %{"content" => content} when is_list(content) ->
        Enum.map_join(content, "\n", &Map.get(&1, "text", ""))

      _ ->
        ""
    end
  end

  defp negotiation_scenarios!(fixture) do
    gate("T07_negotiation_refusal", fn ->
      try do
        for mode <- [:old_host, :capture_mismatch] do
          proxy_mode(mode)

          turn =
            node!("turn", %{
              prompt: "Inspect incompatible negotiated #{mode} capability.",
              responseText: "Acknowledged."
            })

          run = turn["runId"]

          assert!(
            not Repo.exists?(
              from(e in Event,
                where:
                  e.host_id == ^fixture.host.id and
                    fragment("?->'source'->>'run_id'", e.payload) == ^run
              )
            ),
            "incompatible_capture_capability_admitted"
          )

          assert!(
            Enum.any?(
              turn["diagnostics"],
              &(String.contains?(&1, "unsupported_capability") or
                  String.contains?(&1, "capture_binding_mismatch"))
            ),
            "incompatible_capability_diagnostic_missing"
          )
        end

        %{
          old_host_refused: true,
          incompatible_capture_binding_refused: true,
          fault_injected_negotiation: true
        }
      after
        proxy_mode(:normal)
      end
    end)
  end

  defp flush_scenarios!(fixture) do
    gate("T15_real_provider_flush", fn ->
      persistence = node!("flush", %{mode: "save"})
      assert!(persistence["flushObserved"] == true, "real_precompaction_flush_not_invoked")
      state = flush_state(persistence)
      assert!(state["kind"] == "succeeded", "successful_provider_flush_not_recorded")
      content = "Fixture #{fixture.marker}: provider flush fact."
      entry = canonical_provider_entry!(fixture, content)
      mutation = Repo.get!(Mutation, entry.mutation_id)

      assert!(
        mutation.provenance["role"] == "assistant" and
          mutation.provenance["write_origin"] == "openclaw.provider",
        "flush_provider_write_origin_wrong"
      )

      maintenance = Enum.filter(persistence["actualContext"], &(&1["trigger"] == "memory"))
      assert!(maintenance != [], "trusted_memory_trigger_not_observed")
      runs = Enum.map(maintenance, & &1["runId"]) |> Enum.uniq()

      assert!(
        not Repo.exists?(
          from(e in Event,
            where:
              e.host_id == ^fixture.host.id and e.role == "user" and
                fragment("?->'source'->>'run_id'", e.payload) in ^runs
          )
        ),
        "maintenance_flush_recaptured_as_user_evidence"
      )

      before = Repo.aggregate(Mutation, :count)
      lookup = node!("flush", %{mode: "lookup"})

      assert!(
        lookup["flushObserved"] == true and flush_state(lookup)["kind"] == "failed",
        "lookup_only_flush_claimed_persistence"
      )

      assert!(Repo.aggregate(Mutation, :count) == before, "lookup_flush_created_source_mutation")
      noop = node!("flush", %{mode: "noop"})

      assert!(
        noop["flushObserved"] == true and flush_state(noop)["kind"] == "succeeded",
        "legitimate_noop_flush_not_completed"
      )

      assert!(Repo.aggregate(Mutation, :count) == before, "noop_flush_created_source_mutation")
      denied = node!("flush", %{mode: "denied"})

      assert!(
        denied["flushObserved"] == false and Repo.aggregate(Mutation, :count) == before,
        "denied_flush_dispatched_or_persisted"
      )

      node!("restart", %{flush: false, denyTools: []})

      %{
        actual_precompaction: true,
        trigger: persistence["trigger"],
        persistence_canonical_id: entry.memory_id,
        persistence_succeeded: true,
        lookup_without_persistence_failed: true,
        legitimate_noop_succeeded: true,
        denied_skipped: true,
        maintenance_user_capture_absent: true,
        compaction_blocking_not_claimed: true
      }
    end)
  end

  defp flush_state(result) do
    session =
      Enum.find(result["runtimeSessions"] || [], &(&1["sessionKey"] == result["sessionKey"]))

    if session, do: session["memoryFlush"] || %{}, else: %{}
  end

  defp audience_scenarios!(fixture) do
    gate("T08_audience_and_permission_enforcement", fn ->
      for grant <- [false, "missing"] do
        before = Repo.aggregate(Event, :count)
        node!("restart", %{conversationAccess: grant})

        denied =
          node!("turn", %{
            prompt: "Conversation permission is absent or explicitly denied.",
            responseText: "Acknowledged."
          })

        assert!(
          Repo.aggregate(Event, :count) == before,
          "missing_conversation_grant_captured_content"
        )

        assert!(
          Enum.any?(denied["diagnostics"], &String.contains?(&1, "conversation_access_required")),
          "missing_conversation_grant_not_diagnosed"
        )
      end

      node!("restart", %{conversationAccess: true})

      other =
        node!("turn", %{
          agentId: "other",
          prompt: "Unbound agent must not access owner-private memory.",
          responseText: "Acknowledged."
        })

      assert!(
        not Repo.exists?(
          from(e in Event, where: e.host_id == ^fixture.host.id and e.agent_id == "other")
        ),
        "unbound_other_agent_captured"
      )

      assert!(
        Enum.any?(other["diagnostics"], &String.contains?(&1, "audience_binding_unavailable")),
        "unbound_agent_not_diagnosed"
      )

      conversation =
        node!("turn", %{
          caller: "conversation",
          sessionKey: "agent:main:qualification-conversation",
          prompt: "Conversation-scoped caller must not access owner-private memory.",
          responseText: "Acknowledged."
        })

      context =
        Enum.find(
          conversation["actualContext"],
          &(&1["hook"] == "before_prompt_build" and &1["runId"] == conversation["runId"])
        )

      assert!(
        get_in(context, ["memoryAudience", "kind"]) == "conversation" and
          context["current"] == true,
        "real_conversation_audience_not_observed"
      )

      run = conversation["runId"]

      assert!(
        not Repo.exists?(
          from(e in Event,
            where:
              e.host_id == ^fixture.host.id and
                fragment("?->'source'->>'run_id'", e.payload) == ^run
          )
        ),
        "conversation_audience_captured_into_owner_private"
      )

      assert!(
        Enum.any?(
          conversation["diagnostics"],
          &String.contains?(&1, "unsupported_memory_audience")
        ),
        "conversation_audience_refusal_not_diagnosed"
      )

      shared =
        node!("turn", %{
          agentId: "shared",
          prompt: "Explicitly configured owner-agent sharing uses the existing grant.",
          responseText: "Acknowledged."
        })

      run = shared["runId"]

      wait!(
        fn ->
          Repo.exists?(
            from(e in Event,
              where:
                e.host_id == ^fixture.host.id and e.agent_id == "shared" and
                  fragment("?->'source'->>'run_id'", e.payload) == ^run
            )
          )
        end,
        "intentional_same_access_sharing_failed"
      )

      shared_event =
        Repo.one!(
          from(e in Event,
            where:
              e.host_id == ^fixture.host.id and e.agent_id == "shared" and e.role == "user" and
                fragment("?->'source'->>'run_id'", e.payload) == ^run
          )
        )

      original_event =
        Repo.one!(
          from(e in Event,
            where: e.host_id == ^fixture.host.id and e.role == "user",
            order_by: [asc: e.inserted_at],
            limit: 1
          )
        )

      assert!(
        Map.take(shared_event, [:memory_space_id, :scope, :namespace]) ==
          Map.take(original_event, [:memory_space_id, :scope, :namespace]),
        "explicit_shared_agent_changed_partition"
      )

      node!("restart", %{
        denyTools:
          ~w(backplane_memory_search backplane_memory_get backplane_memory_save backplane_memory_correct backplane_memory_withdraw)
      })

      state = Agent.get(resource(:proxy_state), & &1.requests)

      denied_tools =
        node!("turn", %{
          prompt: "All memory tools denied by host policy.",
          responseText: "Acknowledged."
        })

      calls = Agent.get(resource(:proxy_state), &Enum.take(&1.calls, &1.requests - state))

      assert!(
        not Enum.any?(
          calls,
          &(String.ends_with?(&1.path, "/recall") or String.ends_with?(&1.path, "/get") or
              get_in(&1.args, ["run_id"]) == denied_tools["runId"])
        ),
        "tool_policy_denial_egressed_memory"
      )

      node!("restart", %{denyTools: []})

      before_disabled = node!("snapshot")
      node!("restart", %{enabled: false})

      disabled =
        node!("turn", %{
          prompt: "Disabled provider must perform no memory work.",
          responseText: "Acknowledged."
        })

      assert!(
        length(get_in(disabled, ["journal", "deliveries"])) ==
          length(get_in(before_disabled, ["journal", "deliveries"])),
        "disabled_provider_admitted_work"
      )

      node!("restart", %{enabled: true})

      %{
        missing_conversation_grant_refused: true,
        unbound_agent_refused: true,
        tool_policy_zero_egress: true,
        owner_private_real_caller: true,
        real_conversation_caller_refused: true,
        explicit_same_grant_sharing_verified: true,
        disabled_provider_preserved_journal_without_new_work: true
      }
    end)

    gate("T08_binding_revocation", fn ->
      access = Access.status()
      entry = Enum.find(access.accesses, &(&1.access_id == access.default_access_id))
      actor = %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()}

      {:ok, _} =
        Backplane.MemorySpaces.revoke_host_access(
          actor,
          entry.access_id,
          entry.authority_version,
          "owned OpenClaw qualification revocation"
        )

      turn =
        node!("turn", %{
          prompt: "Revoked binding must not admit this occurrence.",
          responseText: "Acknowledged."
        })

      run = turn["runId"]

      assert!(
        not Repo.exists?(
          from(e in Event,
            where:
              e.host_id == ^fixture.host.id and
                fragment("?->'source'->>'run_id'", e.payload) == ^run
          )
        ),
        "revoked_binding_capture_admitted"
      )

      assert!(
        not Enum.any?(get_in(turn, ["journal", "deliveries"]), &(&1["payload"]["run_id"] == run)),
        "revoked_binding_durably_admitted_new_capture"
      )

      %{revoked_default_access: entry.access_id, new_capture_refused: true}
    end)
  end

  defp packaging_scenario! do
    gate("T18_installed_package_parity", fn ->
      source = Path.expand("../integrations/memory/openclaw", __DIR__)
      copied = Path.join(resource(:root), "openclaw/extension")

      files =
        ~w(plugin.mjs contract.mjs journal.mjs client.mjs context.mjs service.mjs rollout.mjs package.json openclaw.plugin.json plugin.yaml)

      for file <- files,
          do:
            assert!(
              File.read!(Path.join(source, file)) == File.read!(Path.join(copied, file)),
              "installed_package_bytes_differ:#{file}"
            )

      %{
        files_verified: length(files),
        actual_installer: true,
        real_runtime_loaded_copied_package: true,
        node_version: resource(:node_version)
      }
    end)
  end

  defp native_entries(host) do
    profile = resource(:native_profile_id)
    assert!(is_binary(profile), "primary_native_source_profile_missing")

    Repo.all(
      from(e in Entry,
        join: s in NativeSource,
        on: s.id == e.source_id,
        where:
          s.host_id == ^host and s.integration == "openclaw" and s.target == "memory" and
            s.profile_id == ^profile
      )
    )
  end

  defp recovery_scenarios!(fixture) do
    gate("T06_failure_recovery", fn ->
      try do
        proxy_mode(:unreceived)

        pending =
          recovery_step!("t06_unreceived_send", fn ->
            node!("turn", %{
              prompt: "Fixture #{fixture.marker}: recover exact unreceived occurrence.",
              responseText: "Acknowledged."
            })
          end)

        before = recovery_step!("t06_snapshot_before_crash", fn -> node!("snapshot") end)
        recovery_step!("t06_abrupt_restart", fn -> node!("restart", %{abrupt: true}) end)
        proxy_mode(:normal)
        ready!(fixture.base_url)

        recovery_step!("t06_abrupt_restart_settlement", fn ->
          node!("turn", %{prompt: "Inspect recovery settlement.", responseText: "Acknowledged."})
        end)

        verify_turn_identity!(fixture, pending)
        proxy_mode(:lost_ack)

        lost =
          recovery_step!("t06_lost_ack_send", fn ->
            node!("turn", %{
              prompt: "Fixture #{fixture.marker}: accepted despite response loss.",
              responseText: "Acknowledged."
            })
          end)

        proxy_mode(:normal)
        previous = live_connection(nil)

        recovery_step!("t06_host_restart", fn ->
          stop_worker!()
          start_worker!(fixture.config)
          ready!(fixture.base_url, previous)
        end)

        recovery_step!("t06_plugin_restart_after_host", fn -> node!("restart") end)

        recovery_step!("t06_host_restart_settlement", fn ->
          node!("turn", %{
            prompt: "Inspect host restart settlement.",
            responseText: "Acknowledged."
          })
        end)

        verify_turn_identity!(fixture, lost)

        after_restart =
          recovery_step!("t06_snapshot_after_restart", fn -> node!("snapshot") end)

        frozen = fn row -> Map.take(row, ~w(event_id path payload digest sequence binding)) end

        recovered =
          Map.new(get_in(after_restart, ["journal", "deliveries"]), &{&1["event_id"], &1})

        for row <- get_in(before, ["journal", "deliveries"]),
            do:
              assert!(
                frozen.(row) == frozen.(recovered[row["event_id"]]),
                "restart_mutated_frozen_delivery"
              )

        lost_run = lost["runId"]

        wait!(
          fn ->
            Repo.aggregate(
              from(e in Event,
                where:
                  e.host_id == ^fixture.host.id and
                    fragment("?->'source'->>'run_id'", e.payload) == ^lost_run
              ),
              :count
            ) == 2
          end,
          "lost_ack_effect_count_wrong"
        )

        recovery_step!("t06_plugin_reload", fn -> node!("reload") end)

        recovery_step!("t06_reload_settlement", fn ->
          node!("turn", %{
            prompt: "Inspect actual plugin reload recovery.",
            responseText: "Acknowledged."
          })
        end)

        %{
          unreceived: true,
          lost_ack: true,
          plugin_restart: true,
          host_restart: true,
          immutable_payloads_survived_crash: true,
          same_event_one_effect: true,
          actual_public_plugin_reload: true,
          retained_snapshot: is_map(before)
        }
      after
        proxy_mode(:normal)
      end
    end)
  end

  defp recovery_step!(scenario, fun) do
    result = fun.()

    IO.puts(
      Jason.encode!(%{
        kind: "openclaw_recovery_checkpoint",
        scenario: scenario,
        status: "passed"
      })
    )

    result
  rescue
    error in Error ->
      reraise %{error | diagnostics: Map.put(error.diagnostics, "scenario", scenario)},
              __STACKTRACE__
  catch
    kind, reason ->
      fail!("recovery_step_#{kind}", %{
        scenario: scenario,
        failure: safe_exit_diagnostic(reason),
        stack:
          Enum.map(__STACKTRACE__, fn {module, function, arity, location} ->
            %{
              module: inspect(module),
              function: Atom.to_string(function),
              arity: if(is_integer(arity), do: arity, else: length(arity)),
              file: location |> Keyword.get(:file, ~c"unknown") |> to_string() |> Path.basename(),
              line: Keyword.get(location, :line)
            }
          end)
      })
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

  defp safe_exit_diagnostic({reason, {module, function, args}})
       when is_atom(reason) and is_atom(module) and is_atom(function) and is_list(args) do
    target = List.first(args)

    %{
      reason: Atom.to_string(reason),
      module: inspect(module),
      function: Atom.to_string(function),
      arity: length(args),
      target_alive: is_pid(target) and Process.alive?(target),
      target_role:
        cond do
          target == resource(:worker) -> "worker"
          target in (resource(:host_pids) || []) -> "host_runtime_child"
          true -> "other"
        end
    }
  end

  defp safe_exit_diagnostic(reason) when is_atom(reason), do: %{reason: Atom.to_string(reason)}
  defp safe_exit_diagnostic(_), do: %{reason: "unclassified"}

  defp guard_environment! do
    assert!(Mix.env() == :test, "BLOCKED_ENV:requires_MIX_ENV_test")

    assert!(
      System.get_env("BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL") in ["1", "true"],
      "BLOCKED_ENV:requires_real_pool_flag"
    )

    mode = System.get_env("OPENCLAW_LIVE_MODE", "full")
    assert!(mode in ["full", "deterministic"], "BLOCKED_ENV:invalid_live_mode")
    put_resource(:mode, mode)
    diagnostic = System.get_env("OPENCLAW_LIVE_DIAGNOSTIC")

    assert!(
      is_nil(diagnostic) or diagnostic in ["capture", "overlap", "capture_and_overlap"],
      "BLOCKED_ENV:invalid_live_diagnostic"
    )

    put_resource(:diagnostic, diagnostic)
    partition = System.get_env("MIX_TEST_PARTITION", "")

    assert!(
      Regex.match?(~r/\A_openclawlive_[0-9a-f]{12,32}\z/, partition),
      "BLOCKED_ENV:requires_unique_openclawlive_partition"
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
        "backplane-openclaw-live-" <> String.replace_prefix(partition, "_openclawlive_", "")
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
    put_resource(:marker, String.replace_prefix(partition, "_openclawlive_", ""))
    put_resource(:node_executable, find_node!())
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
    name = "openclaw-live-" <> marker
    scope = "openclaw_live_" <> marker
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
    key = if resource(:mode) == "full", do: System.get_env("OPENROUTER_API_KEY", ""), else: ""

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

      model_name = System.get_env("OPENCLAW_LIVE_MODEL", "openai/gpt-4.1-mini")

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

  defp verify_async_summary!(host_id, session_id) do
    # A freshly closed session waits for gap grace; enqueue the real existing sweep.
    Process.sleep(1_100)
    {:ok, sweep} = Backplane.Memory.Workers.FallbackSweepWorker.new(%{}) |> Styx.insert()

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

    summary
  end

  defp verify_processing!(host_id, session_id, fixture) do
    # A freshly closed session waits for gap grace; enqueue the real existing sweep.
    Process.sleep(1_100)
    {:ok, sweep} = Backplane.Memory.Workers.FallbackSweepWorker.new(%{}) |> Styx.insert()

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
      memory_ids: memory_ids,
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
          synthetic_content: String.slice(memory.content, 0, 4_096),
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
                event.event_type in ["conversation.user_message", "agent.prompt.submitted"] and
                fragment(
                  "? #>> '{source,input_provenance,kind}' = 'external_user'",
                  event.payload
                )
          )
        )

      assert!(confirmed, "derived_fact_established_without_actual_user_confirmation")
    end
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
    %{
      access: Map.take(Access.status(), [:negotiated, :blocked, :global_fenced]),
      events: Repo.aggregate(from(e in Event, where: e.host_id == ^resource(:host_id)), :count),
      source_mutations: Repo.aggregate(Mutation, :count)
    }
  rescue
    _ -> %{unavailable: true}
  catch
    _, _ -> %{unavailable: true}
  end

  defp record(name, status, details) do
    item = %{gate: name, status: status, details: details}
    Process.put(@result_key, [item | Process.get(@result_key, [])])
    IO.puts(Jason.encode!(Map.put(item, :kind, "openclaw_live_gate")))
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
    node_stopped = safe_cleanup(fn -> stop_node!() end)

    node_stopped =
      if not node_stopped and not is_nil(resource(:node)) do
        %{port: port, os_pid: pid} = resource(:node)
        # Only this exact owned child PID can be terminated. Never match process names.
        safe_cleanup(fn ->
          System.cmd("/bin/kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)

          receive do
            {^port, {:exit_status, _}} -> put_resource(:node, nil)
          after
            5_000 -> fail!("owned_node_termination_unconfirmed")
          end
        end)
      else
        node_stopped
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
      resumed and node_stopped and pids_stopped and apps_stopped and
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
      node_stopped: node_stopped,
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

  defp stop_pid!(pid) when is_pid(pid), do: Backplane.OpenClawOwnedProcess.stop(pid)

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

Backplane.OpenClawLiveAcceptance.main()
