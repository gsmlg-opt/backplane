defmodule Backplane.Metrics.PrometheusTest do
  use ExUnit.Case, async: false

  alias Backplane.Metrics.Prometheus

  describe "render/0" do
    test "outputs valid Prometheus exposition format" do
      output = Prometheus.render()
      assert is_binary(output)
      assert output =~ "# HELP"
      assert output =~ "# TYPE"
    end

    test "includes tool_calls_total counter" do
      output = Prometheus.render()
      assert output =~ "backplane_tool_calls_total"
      assert output =~ "# TYPE backplane_tool_calls_total counter"
    end

    test "includes tool_call_duration summary" do
      output = Prometheus.render()
      assert output =~ "backplane_tool_call_duration_microseconds"
      assert output =~ "# TYPE backplane_tool_call_duration_microseconds summary"
    end

    test "includes upstream_status gauge" do
      output = Prometheus.render()
      assert output =~ "backplane_upstream_status"
      assert output =~ "# TYPE backplane_upstream_status gauge"
    end

    test "includes cache metrics" do
      output = Prometheus.render()
      assert output =~ "backplane_cache_hit_ratio"
      assert output =~ "# TYPE backplane_cache_hit_ratio gauge"
    end
  end
end
