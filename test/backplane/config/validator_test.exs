defmodule Backplane.Config.ValidatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Backplane.Config.Validator

  test "validate! passes for valid config" do
    config = [
      backplane: %{port: 4100},
      upstream: [
        %{name: "test", prefix: "t", transport: "http", url: "http://localhost:4200/mcp"}
      ],
      projects: [
        %{id: "my-proj", repo: "owner/repo"}
      ]
    ]

    assert :ok = Validator.validate!(config)
  end

  test "validate! warns about missing upstream name" do
    config = [
      backplane: %{port: 4100},
      upstream: [%{prefix: "t", transport: "http", url: "http://localhost/mcp"}],
      projects: []
    ]

    log =
      capture_log(fn ->
        Validator.validate!(config)
      end)

    assert log =~ "missing required field 'name'"
  end

  test "validate! warns about missing url for http upstream" do
    config = [
      backplane: %{port: 4100},
      upstream: [%{name: "bad", prefix: "b", transport: "http"}],
      projects: []
    ]

    log =
      capture_log(fn ->
        Validator.validate!(config)
      end)

    assert log =~ "missing required field 'url'"
  end

  test "validate! warns about missing command for stdio upstream" do
    config = [
      backplane: %{port: 4100},
      upstream: [%{name: "bad", prefix: "b", transport: "stdio"}],
      projects: []
    ]

    log =
      capture_log(fn ->
        Validator.validate!(config)
      end)

    assert log =~ "missing required field 'command'"
  end

  test "validate! warns about unknown transport" do
    config = [
      backplane: %{port: 4100},
      upstream: [%{name: "bad", prefix: "b", transport: "grpc"}],
      projects: []
    ]

    log =
      capture_log(fn ->
        Validator.validate!(config)
      end)

    assert log =~ "unknown transport 'grpc'"
  end

  test "validate! warns about missing project fields" do
    config = [
      backplane: %{port: 4100},
      upstream: [],
      projects: [%{id: nil, repo: nil}]
    ]

    log =
      capture_log(fn ->
        Validator.validate!(config)
      end)

    assert log =~ "missing required field 'id'"
    assert log =~ "missing required field 'repo'"
  end

  test "validate! warns about invalid port" do
    config = [
      backplane: %{port: 99_999},
      upstream: [],
      projects: []
    ]

    log =
      capture_log(fn ->
        Validator.validate!(config)
      end)

    assert log =~ "invalid port"
  end

  test "validate! passes with empty config" do
    config = [backplane: %{port: 4100}, upstream: [], projects: []]
    assert :ok = Validator.validate!(config)
  end
end
