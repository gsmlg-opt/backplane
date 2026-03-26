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

  test "validate! passes (no transport warning) for upstream with no transport field" do
    # L50: check_upstream_transport catch-all clause — upstream has no :transport key at all.
    # The function simply returns warnings unchanged (no clause matches a missing key).
    config = %{
      backplane: %{port: 4100},
      upstream: [%{name: "no-transport", prefix: "nt"}],
      projects: []
    }

    log =
      capture_log(fn ->
        assert :ok = Validator.validate!(config)
      end)

    # check_required warns about the missing :transport field but the
    # catch-all check_upstream_transport/2 clause does not add an extra warning
    assert log =~ "missing required field 'transport'"
    refute log =~ "unknown transport"
  end

  test "validate! passes when backplane section is absent" do
    # L69: validate_port catch-all clause — no :backplane key in config at all.
    config = %{upstream: [], projects: []}

    log =
      capture_log(fn ->
        assert :ok = Validator.validate!(config)
      end)

    # No port warning should be emitted when the section is entirely absent
    refute log =~ "invalid port"
  end

  test "validate! warns when upstream name is an empty string" do
    # L74: check_required/4 branch for empty string value.
    config = %{
      backplane: %{port: 4100},
      upstream: [%{name: "", prefix: "t", transport: "http", url: "http://localhost/mcp"}],
      projects: []
    }

    log =
      capture_log(fn ->
        assert :ok = Validator.validate!(config)
      end)

    assert log =~ "'name' cannot be empty"
  end

  test "validate! warns when upstream prefix is an empty string" do
    # L74: same empty string branch for a different required field.
    config = %{
      backplane: %{port: 4100},
      upstream: [%{name: "myup", prefix: "", transport: "http", url: "http://localhost/mcp"}],
      projects: []
    }

    log =
      capture_log(fn ->
        assert :ok = Validator.validate!(config)
      end)

    assert log =~ "'prefix' cannot be empty"
  end

  describe "skill validation" do
    test "validate! passes for valid git skill config" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "my-skill", source: "git", repo: "https://github.com/o/r.git"}]
      ]

      log = capture_log(fn -> assert :ok = Validator.validate!(config) end)
      refute log =~ "skill"
    end

    test "validate! passes for valid local skill config" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "local-skill", source: "local", path: "/opt/skills"}]
      ]

      log = capture_log(fn -> assert :ok = Validator.validate!(config) end)
      refute log =~ "skill"
    end

    test "validate! warns about missing skill name" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{source: "git", repo: "https://github.com/o/r.git"}]
      ]

      log = capture_log(fn -> Validator.validate!(config) end)
      assert log =~ "missing required field 'name'"
    end

    test "validate! warns about missing skill source" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "no-source"}]
      ]

      log = capture_log(fn -> Validator.validate!(config) end)
      assert log =~ "missing required field 'source'"
    end

    test "validate! warns about missing repo for git skill" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "git-skill", source: "git"}]
      ]

      log = capture_log(fn -> Validator.validate!(config) end)
      assert log =~ "missing required field 'repo'"
    end

    test "validate! warns about missing path for local skill" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "local-skill", source: "local"}]
      ]

      log = capture_log(fn -> Validator.validate!(config) end)
      assert log =~ "missing required field 'path'"
    end

    test "validate! warns about unknown skill source" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "bad-skill", source: "s3"}]
      ]

      log = capture_log(fn -> Validator.validate!(config) end)
      assert log =~ "unknown source 's3'"
    end

    test "validate! does not warn when skills section is absent" do
      config = [backplane: %{port: 4100}, upstream: [], projects: []]

      log = capture_log(fn -> assert :ok = Validator.validate!(config) end)
      refute log =~ "skill"
    end

    test "validate! warns about empty skill name" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "", source: "git", repo: "https://github.com/o/r.git"}]
      ]

      log = capture_log(fn -> Validator.validate!(config) end)
      assert log =~ "'name' cannot be empty"
    end
  end
end
