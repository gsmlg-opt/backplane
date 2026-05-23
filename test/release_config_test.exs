defmodule Backplane.ReleaseConfigTest do
  use ExUnit.Case, async: true

  test "umbrella defines backplane and host agent releases" do
    releases = Mix.Project.config() |> Keyword.fetch!(:releases)

    assert [:backplane, :host_agent] = Keyword.keys(releases)

    assert releases[:backplane][:applications][:backplane] == :permanent
    assert releases[:backplane][:applications][:backplane_web] == :permanent
    assert releases[:backplane][:applications][:backplane_memory] == :permanent
    refute Keyword.has_key?(releases[:backplane][:applications], :backplane_host_agent)

    assert releases[:host_agent][:applications][:backplane_host_agent] == :permanent
    refute Keyword.has_key?(releases[:host_agent][:applications], :backplane)
    refute Keyword.has_key?(releases[:host_agent][:applications], :backplane_web)
  end

  test "root mix release is an alias for building both configured releases" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert is_function(aliases[:release], 1)
  end
end
