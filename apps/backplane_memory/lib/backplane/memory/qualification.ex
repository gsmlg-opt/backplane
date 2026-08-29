defmodule Backplane.Memory.Qualification do
  @moduledoc "Machine-readable M18 non-functional qualification verdicts."

  alias Backplane.Memory.Qualification.Profile

  def evaluate(measurements, opts \\ []) when is_map(measurements) do
    generated_at = Keyword.get(opts, :generated_at, DateTime.utc_now())
    profile = Keyword.get(opts, :profile, :performance)
    thresholds = Profile.thresholds(profile).qualification
    measurements = put_consolidation_coverage(measurements)

    gates = %{
      ingest_throughput:
        positive_count?(measurements, [:ingest, :accepted]) and
          number_at_least?(
            measurements,
            [:ingest, :events_per_second],
            thresholds.ingest_events_per_second_min
          ) and
          equal_positive_counts?(
            measurements,
            [:ingest, :accepted],
            [:ingest, :projection_jobs_durable]
          ) and
          equal_positive_counts?(
            measurements,
            [:ingest, :accepted],
            [:ingest, :projection_job_event_ids_unique]
          ),
      accepted_event_integrity:
        equal_positive_counts?(measurements, [:ingest, :accepted], [:ingest, :persisted]) and
          zero?(measurements, [:ingest, :duplicate_effects]),
      projection_lag:
        positive_count?(measurements, [:projection, :samples]) and
          equal_positive_counts?(
            measurements,
            [:projection, :samples],
            [:projection, :jobs_durable]
          ) and
          equal_positive_counts?(
            measurements,
            [:projection, :samples],
            [:projection, :jobs_completed]
          ) and
          equal_positive_counts?(
            measurements,
            [:projection, :samples],
            [:projection, :complete_subjects]
          ) and
          number_below?(
            measurements,
            [:projection, :p95_lag_ms],
            thresholds.projection_p95_lag_ms_max_exclusive
          ),
      consolidation_coverage:
        positive_count?(measurements, [:consolidation, :eligible]) and
          number_at_least?(measurements, [:consolidation, :coverage], 0.95),
      outage_recovery:
        equal_positive_counts?(measurements, [:outage, :locally_accepted], [:outage, :delivered]) and
          equal_positive_counts?(measurements, [:outage, :locally_accepted], [:outage, :persisted]) and
          zero?(measurements, [:outage, :duplicate_effects]),
      retry_contention_failure:
        equal_positive_counts?(measurements, [:resilience, :accepted], [:resilience, :persisted]) and
          zero?(measurements, [:resilience, :duplicate_effects]) and
          zero?(measurements, [:resilience, :permanent_failures]) and
          positive_count?(measurements, [:resilience, :retryable_failures_observed]) and
          positive_count?(measurements, [:resilience, :duplicate_deliveries]) and
          integer_at_least?(measurements, [:resilience, :contention_workers], 2)
    }

    configuration =
      Map.merge(
        %{
          reproducible: true,
          thresholds_source: "Backplane Memory V2 PRD NFR-004, NFR-007, and NFR-008",
          percentile_method: "nearest-rank"
        },
        Keyword.get(opts, :configuration, %{})
      )

    %{
      schema_version: 1,
      suite: "memory-v2-m18-qualification",
      profile: profile,
      performance_authoritative: Profile.authoritative?(profile),
      generated_at: DateTime.to_iso8601(generated_at),
      configuration: configuration,
      thresholds: thresholds,
      metrics: measurements,
      gates: gates,
      passed: Enum.all?(gates, fn {_gate, passed?} -> passed? end)
    }
  end

  def encode_report(report), do: Jason.encode!(stringify(report), pretty: true) <> "\n"

  defp put_consolidation_coverage(measurements) do
    eligible = get_in(measurements, [:consolidation, :eligible])
    summarized = get_in(measurements, [:consolidation, :summarized_within_four_hours])

    coverage =
      if is_integer(eligible) and eligible > 0 and is_integer(summarized) and summarized >= 0,
        do: summarized / eligible,
        else: nil

    consolidation =
      measurements
      |> Map.get(:consolidation, %{})
      |> Map.put(:coverage, coverage)

    Map.put(measurements, :consolidation, consolidation)
  end

  defp equal_positive_counts?(measurements, left, right) do
    left_value = get_in(measurements, left)
    right_value = get_in(measurements, right)
    is_integer(left_value) and left_value > 0 and left_value == right_value
  end

  defp positive_count?(measurements, path) do
    value = get_in(measurements, path)
    is_integer(value) and value > 0
  end

  defp zero?(measurements, path), do: get_in(measurements, path) == 0

  defp number_at_least?(measurements, path, threshold) do
    value = get_in(measurements, path)
    is_number(value) and value >= threshold
  end

  defp number_below?(measurements, path, threshold) do
    value = get_in(measurements, path)
    is_number(value) and value < threshold
  end

  defp integer_at_least?(measurements, path, threshold) do
    value = get_in(measurements, path)
    is_integer(value) and value >= threshold
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
