defmodule Backplane.Observability.MetricsTest do
  use ExUnit.Case, async: false

  alias Backplane.Metrics

  setup do
    case Process.whereis(Backplane.Metrics) do
      nil -> start_supervised!(Backplane.Metrics)
      _pid -> :ok
    end

    :ok
  end

  test "increments observability writer counters from telemetry events" do
    :telemetry.execute(
      [:backplane, :observability, :events, :accepted],
      %{count: 2},
      %{domain: :llm_proxy}
    )

    :telemetry.execute(
      [:backplane, :observability, :events, :persisted],
      %{count: 1, persistence_lag_ms: 12},
      %{domain: :llm_proxy}
    )

    :telemetry.execute(
      [:backplane, :observability, :events, :dropped],
      %{count: 1},
      %{domain: :llm_proxy}
    )

    snapshot = Metrics.snapshot()

    assert get_in(snapshot, [:counters, "observability.events.accepted.llm_proxy"]) == 2
    assert get_in(snapshot, [:counters, "observability.events.persisted.llm_proxy"]) == 1
    assert get_in(snapshot, [:counters, "observability.events.dropped.llm_proxy"]) == 1
    assert get_in(snapshot, [:timings, "observability.writer.persistence_lag_ms.llm_proxy"])
  end
end
