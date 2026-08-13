defmodule Backplane.Memory.CompatibilityTest do
  use Backplane.Memory.DataCase, async: true

  @memory_api Enum.sort([
                {:count, 0},
                {:count, 1},
                {:forget, 1},
                {:get, 1},
                {:list, 0},
                {:list, 1},
                {:maybe_detect_contradiction, 2},
                {:remember, 1},
                {:remember, 2},
                {:scope_stats, 0},
                {:stats, 0},
                {:team_feed, 1},
                {:team_feed, 2},
                {:team_share, 2}
              ])

  @observations_api Enum.sort([
                      {:end_session, 1},
                      {:file_history, 1},
                      {:file_history, 2},
                      {:record, 2},
                      {:record, 3},
                      {:register_session, 2}
                    ])

  @service_api Enum.sort([
                 {:call, 3},
                 {:enabled?, 0},
                 {:get_prompt, 2},
                 {:get_prompt, 3},
                 {:handle_access_log, 1},
                 {:handle_action_create, 1},
                 {:handle_action_update, 1},
                 {:handle_audit, 1},
                 {:handle_compress_file, 1},
                 {:handle_consolidate, 1},
                 {:handle_diagnose, 1},
                 {:handle_enrich, 1},
                 {:handle_expand_query, 1},
                 {:handle_export, 1},
                 {:handle_facet_query, 1},
                 {:handle_facet_tag, 1},
                 {:handle_file_history, 1},
                 {:handle_forget, 1},
                 {:handle_frontier, 1},
                 {:handle_governance_delete, 1},
                 {:handle_graph_query, 1},
                 {:handle_graph_stats, 1},
                 {:handle_heal, 1},
                 {:handle_lease, 1},
                 {:handle_list, 1},
                 {:handle_next, 1},
                 {:handle_patterns, 1},
                 {:handle_profile, 1},
                 {:handle_profile_refresh, 1},
                 {:handle_recall, 1},
                 {:handle_relations, 1},
                 {:handle_remember, 1},
                 {:handle_sessions, 1},
                 {:handle_signal_read, 1},
                 {:handle_signal_send, 1},
                 {:handle_slot_list, 1},
                 {:handle_slot_read, 1},
                 {:handle_slot_write, 1},
                 {:handle_smart_search, 1},
                 {:handle_stats, 1},
                 {:handle_team_feed, 1},
                 {:handle_team_share, 1},
                 {:handle_timeline, 1},
                 {:handle_verify, 1},
                 {:prefix, 0},
                 {:prompts, 0},
                 {:read_resource, 1},
                 {:read_resource, 2},
                 {:resources, 0},
                 {:resources, 1},
                 {:tools, 0}
               ])

  @oban_worker_api [
    {:__opts__, 0},
    {:backoff, 1},
    {:new, 1},
    {:new, 2},
    {:perform, 1},
    {:timeout, 1}
  ]

  @worker_contracts [
    {BackplaneMemory.Workers.AccessWritebackWorker,
     Backplane.Memory.Workers.AccessWritebackWorker, 3, [{:enqueue, 1}]},
    {BackplaneMemory.Workers.EmbedWorker, Backplane.Memory.Workers.EmbedWorker, 5,
     [{:enqueue, 1}, {:perform_with_client, 2}]},
    {BackplaneMemory.Workers.EpisodicWorker, Backplane.Memory.Workers.EpisodicWorker, 3,
     [{:enqueue, 1}, {:enqueue_summary, 1}]},
    {BackplaneMemory.Workers.EvictionWorker, Backplane.Memory.Workers.EvictionWorker, 3,
     [{:candidate_ids, 4}, {:evict_candidates, 4}]},
    {BackplaneMemory.Workers.FallbackSweepWorker, Backplane.Memory.Workers.FallbackSweepWorker, 2,
     []},
    {BackplaneMemory.Workers.GraphExtractWorker, Backplane.Memory.Workers.GraphExtractWorker, 3,
     [{:enqueue, 1}, {:enqueue, 2}]},
    {BackplaneMemory.Workers.LeaseCleanupWorker, Backplane.Memory.Workers.LeaseCleanupWorker, 3,
     []},
    {BackplaneMemory.Workers.ProceduralWorker, Backplane.Memory.Workers.ProceduralWorker, 2, []},
    {BackplaneMemory.Workers.ProfileBuildWorker, Backplane.Memory.Workers.ProfileBuildWorker, 3,
     [{:enqueue, 1}, {:enqueue, 2}, {:enqueue, 3}]},
    {BackplaneMemory.Workers.SummaryWorker, Backplane.Memory.Workers.SummaryWorker, 3,
     [{:enqueue, 1}, {:enqueue, 3}, {:record_failed, 5}]}
  ]

  @legacy_modules [
                    BackplaneMemory,
                    BackplaneMemory.Memory,
                    BackplaneMemory.Observations,
                    BackplaneMemory.Service
                  ] ++ Enum.map(@worker_contracts, &elem(&1, 0))

  setup_all do
    missing_modules = Enum.reject(@legacy_modules, &Code.ensure_loaded?/1)

    assert missing_modules == [],
           "missing legacy compatibility modules: #{inspect(missing_modules)}"

    :ok
  end

  test "legacy facades export exactly the compatibility API" do
    assert functions(BackplaneMemory) == [version: 0]
    assert functions(BackplaneMemory.Memory) == @memory_api
    assert functions(BackplaneMemory.Observations) == @observations_api
    assert functions(BackplaneMemory.Service) == @service_api
  end

  test "legacy root, memory, and observations facades preserve safe-call results" do
    assert BackplaneMemory.version() == Backplane.Memory.version()

    missing_id = Ecto.UUID.generate()

    memory_calls = [
      {:get, [missing_id]},
      {:forget, [missing_id]},
      {:stats, []},
      {:list, []},
      {:list, [[limit: 1]]},
      {:count, []},
      {:count, [[scope: "compatibility"]]},
      {:maybe_detect_contradiction, [missing_id, missing_id]},
      {:scope_stats, []},
      {:team_share, [missing_id, "compatibility"]},
      {:team_feed, ["compatibility"]},
      {:team_feed, ["compatibility", 1]}
    ]

    for {function, arguments} <- memory_calls,
        do: assert(apply(BackplaneMemory.Memory, function, arguments) == {:error, :unauthorized})

    observation_calls = [
      {:end_session, ["missing-compatibility-session"]},
      {:file_history, [["compatibility/missing.ex"]]},
      {:file_history, [["compatibility/missing.ex"], [limit: 1]]}
    ]

    for {function, arguments} <- observation_calls,
        do:
          assert(
            apply(BackplaneMemory.Observations, function, arguments) == {:error, :unauthorized}
          )
  end

  test "legacy service preserves catalog and managed-service callbacks" do
    assert Backplane.Services.ManagedService in BackplaneMemory.Service.__info__(:attributes)[
             :behaviour
           ]

    for {function, arity} <- Backplane.Services.ManagedService.behaviour_info(:callbacks) do
      assert function_exported?(BackplaneMemory.Service, function, arity)
    end

    assert BackplaneMemory.Service.prefix() == Backplane.Memory.Service.prefix()
    assert BackplaneMemory.Service.enabled?() == Backplane.Memory.Service.enabled?()
    assert BackplaneMemory.Service.tools() == Backplane.Memory.Service.tools()
    assert BackplaneMemory.Service.resources() == Backplane.Memory.Service.resources()
    assert BackplaneMemory.Service.prompts() == Backplane.Memory.Service.prompts()

    assert BackplaneMemory.Service.read_resource("memory://compatibility/missing") ==
             Backplane.Memory.Service.read_resource("memory://compatibility/missing")

    assert BackplaneMemory.Service.get_prompt("compatibility_missing", %{}) ==
             Backplane.Memory.Service.get_prompt("compatibility_missing", %{})

    auth = %{kind: :client_token, client_id: "compatibility", scopes: ["memory.read"]}

    assert BackplaneMemory.Service.get_prompt("compatibility_missing", %{}, auth) ==
             Backplane.Memory.Service.get_prompt("compatibility_missing", %{}, auth)
  end

  test "legacy service preserves safe handler success and error shapes" do
    successful_calls = [
      {:handle_list, [%{}]},
      {:handle_stats, [%{}]},
      {:handle_frontier, [%{}]},
      {:handle_next, [%{}]},
      {:handle_sessions, [%{}]},
      {:handle_patterns, [%{}]},
      {:handle_timeline, [%{}]},
      {:handle_export, [%{}]},
      {:handle_audit, [%{}]},
      {:handle_graph_stats, [%{}]},
      {:handle_slot_list, [%{}]}
    ]

    for {function, arguments} <- successful_calls,
        do: assert(apply(BackplaneMemory.Service, function, arguments) == {:error, :unauthorized})

    error_calls = [
      {:handle_access_log, [%{}]},
      {:handle_action_create, [%{}]},
      {:handle_action_update, [%{}]},
      {:handle_compress_file, [%{}]},
      {:handle_consolidate, [%{}]},
      {:handle_enrich, [%{}]},
      {:handle_expand_query, [%{}]},
      {:handle_facet_query, [%{}]},
      {:handle_facet_tag, [%{}]},
      {:handle_file_history, [%{}]},
      {:handle_forget, [%{}]},
      {:handle_governance_delete, [%{}]},
      {:handle_graph_query, [%{}]},
      {:handle_lease, [%{}]},
      {:handle_profile, [%{}]},
      {:handle_profile_refresh, [%{}]},
      {:handle_recall, [%{}]},
      {:handle_relations, [%{}]},
      {:handle_remember, [%{}]},
      {:handle_signal_read, [%{}]},
      {:handle_signal_send, [%{}]},
      {:handle_slot_read, [%{}]},
      {:handle_slot_write, [%{}]},
      {:handle_smart_search, [%{}]},
      {:handle_team_feed, [%{}]},
      {:handle_team_share, [%{}]},
      {:handle_verify, [%{}]}
    ]

    for {function, arguments} <- error_calls do
      assert apply(BackplaneMemory.Service, function, arguments) == {:error, :unauthorized}
    end
  end

  test "legacy workers preserve exports, options, and legacy new/1 worker names" do
    for {legacy, current, max_attempts, helpers} <- @worker_contracts do
      expected_functions = Enum.sort(@oban_worker_api ++ helpers)
      assert functions(legacy) == expected_functions
      assert functions(current) == expected_functions

      assert Keyword.take(legacy.__opts__(), [:queue, :max_attempts]) ==
               [queue: :memory, max_attempts: max_attempts]

      assert legacy.__opts__()[:worker] == inspect(legacy)

      changeset = legacy.new(%{"compatibility" => true})
      assert Ecto.Changeset.get_field(changeset, :worker) == inspect(legacy)
      assert Ecto.Changeset.get_field(changeset, :queue) == "memory"
      assert Ecto.Changeset.get_field(changeset, :max_attempts) == max_attempts

      changeset_with_opts = legacy.new(%{"compatibility" => true}, priority: 1)
      assert Ecto.Changeset.get_field(changeset_with_opts, :worker) == inspect(legacy)
      assert Ecto.Changeset.get_field(changeset_with_opts, :queue) == "memory"
      assert Ecto.Changeset.get_field(changeset_with_opts, :max_attempts) == max_attempts
      assert Ecto.Changeset.get_field(changeset_with_opts, :priority) == 1

      for {function, arity} <- [{:perform, 1} | helpers] do
        assert function_exported?(legacy, function, arity)
      end
    end
  end

  test "legacy worker helpers delegate on safe no-op paths" do
    assert BackplaneMemory.Workers.AccessWritebackWorker.enqueue([]) ==
             Backplane.Memory.Workers.AccessWritebackWorker.enqueue([])

    access_job = %Oban.Job{args: %{"memory_ids" => []}}

    assert BackplaneMemory.Workers.AccessWritebackWorker.perform(access_job) ==
             Backplane.Memory.Workers.AccessWritebackWorker.perform(access_job)

    embed_job = %Oban.Job{args: %{"id" => Ecto.UUID.generate()}}
    unused_client = fn _texts, _mode, _opts -> flunk("unused embed client was called") end

    assert BackplaneMemory.Workers.EmbedWorker.perform_with_client(embed_job, unused_client) ==
             Backplane.Memory.Workers.EmbedWorker.perform_with_client(embed_job, unused_client)
  end

  defp functions(module), do: module.__info__(:functions)
end
