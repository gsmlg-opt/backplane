defmodule Backplane.Memory.Qualification.RunnerPolicyTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Qualification
  alias Backplane.Memory.Qualification.Runner
  alias Backplane.Memory.Summaries.{SourceEvent, Summary}

  @policy_keys ~w(memory.pipeline.enabled memory.session_summary.enabled)

  setup do
    original = policy_entries()
    on_exit(fn -> restore_policy(original) end)
    :ok
  end

  for prior <- [:absent, false, true] do
    test "consolidation opts in and restores #{inspect(prior)} policy entries" do
      set_policy(unquote(prior))
      previous = policy_entries()
      run_id = unique_run()

      assert {:ok, measurement} = Runner.measure_consolidation(run_id: run_id, session_count: 2)
      assert measurement.summarized_within_four_hours == 2
      assert measurement.without_provenance == 0
      assert measurement.coverage == 1.0
      assert policy_entries() == previous

      summaries =
        repo().all(from(s in Summary, where: s.host_id == ^"m18-consolidation-#{run_id}"))

      assert length(summaries) == 2

      Enum.each(summaries, fn summary ->
        assert summary.content =~ "generation_mode=deterministic"

        assert repo().aggregate(
                 from(s in SourceEvent, where: s.summary_id == ^summary.id),
                 :count
               ) == 3
      end)
    end

    test "consolidation restores #{inspect(prior)} policy after a raised error" do
      set_policy(unquote(prior))
      previous = policy_entries()

      assert_raise RuntimeError, "qualification fixture failure", fn ->
        Runner.measure_consolidation(
          run_id: unique_run(),
          session_count: 1,
          perform_summary: fn _job ->
            assert Backplane.Memory.Config.session_summary_enabled?()
            raise "qualification fixture failure"
          end
        )
      end

      assert policy_entries() == previous
    end
  end

  test "measured partial acknowledgements retain sanitized reasons and fail integrity" do
    assert {:ok, measurement} =
             Runner.measure_ingest(
               run_id: unique_run(),
               event_count: 4,
               batch_size: 4,
               warmup: false,
               ingest_batch: &partial_batch/2
             )

    assert measurement.requested == 4
    assert measurement.result_count == 4
    assert measurement.accepted == 2
    assert measurement.persisted == 2
    refute measurement.complete
    assert measurement.warmup == nil

    assert Enum.sort_by(measurement.result_counts, & &1.status) == [
             %{status: "accepted", reason: nil, retryable: nil, count: 2},
             %{status: "failed", reason: "other", retryable: true, count: 1},
             %{status: "rejected", reason: "invalid_event", retryable: false, count: 1}
           ]

    refute Jason.encode!(measurement) =~ "private diagnostic detail"
    report = Qualification.evaluate(%{ingest: measurement}, profile: :ci)
    refute report.gates.ingest_throughput
    refute report.gates.accepted_event_integrity
  end

  test "an incomplete warmup remains visible and prevents a passing measured sample" do
    assert {:ok, measurement} =
             Runner.measure_ingest(
               run_id: unique_run(),
               event_count: 4,
               batch_size: 4,
               warmup_event_count: 4,
               ingest_batch: fn auth, batch ->
                 if String.ends_with?(hd(batch["events"])["run_id"], "-warmup"),
                   do: partial_batch(auth, batch),
                   else: Ingest.ingest_batch(auth, batch)
               end
             )

    assert measurement.accepted == 4
    assert measurement.persisted == 4
    assert measurement.warmup.requested == 4
    assert measurement.warmup.accepted == 2
    assert measurement.warmup.result_count == 4
    refute measurement.warmup.complete
    assert length(measurement.warmup.result_counts) == 3
    report = Qualification.evaluate(%{ingest: measurement}, profile: :ci)
    refute report.gates.ingest_throughput
    refute report.gates.accepted_event_integrity
  end

  defp partial_batch(auth, batch) do
    [first, second, third, fourth] = batch["events"]
    {:ok, response} = Ingest.ingest_batch(auth, Map.put(batch, "events", [first, second]))

    results =
      response["results"] ++
        [
          %{
            "event_id" => third["event_id"],
            "status" => "rejected",
            "reason" => "invalid_event",
            "retryable" => false
          },
          %{
            "event_id" => fourth["event_id"],
            "status" => "failed",
            "reason" => "private diagnostic detail",
            "retryable" => true
          }
        ]

    {:ok, Map.put(response, "results", results)}
  end

  defp unique_run, do: "qualification-policy-#{System.unique_integer([:positive])}"
  defp policy_entries, do: Map.new(@policy_keys, &{&1, :ets.lookup(:backplane_settings, &1)})
  defp set_policy(:absent), do: Enum.each(@policy_keys, &:ets.delete(:backplane_settings, &1))

  defp set_policy(value),
    do: Enum.each(@policy_keys, &:ets.insert(:backplane_settings, {&1, value}))

  defp restore_policy(previous) do
    Enum.each(previous, fn {key, entries} ->
      :ets.delete(:backplane_settings, key)
      Enum.each(entries, &:ets.insert(:backplane_settings, &1))
    end)
  end
end
