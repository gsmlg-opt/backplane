defmodule Relayixir.Support.ErrorsTest do
  use ExUnit.Case, async: true

  alias Relayixir.Support.Errors

  test "creates error struct with type only" do
    error = Errors.new(:route_not_found)
    assert error.type == :route_not_found
    assert error.metadata == %{}
  end

  test "creates error struct with type and metadata" do
    error = Errors.new(:upstream_timeout, %{upstream: "backend", duration_ms: 5000})
    assert error.type == :upstream_timeout
    assert error.metadata == %{upstream: "backend", duration_ms: 5000}
  end

  test "struct has expected fields" do
    error = %Errors{}
    assert Map.has_key?(error, :type)
    assert Map.has_key?(error, :metadata)
  end
end
