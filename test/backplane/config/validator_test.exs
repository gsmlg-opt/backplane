defmodule Backplane.Config.ValidatorTest do
  use ExUnit.Case, async: true

  alias Backplane.Config.Validator

  test "validate returns no warnings for valid config" do
    config = [
      backplane: %{port: 4100},
      upstream: [
        %{name: "test", prefix: "t", transport: "http", url: "http://localhost:4200/mcp"}
      ],
      projects: [
        %{id: "my-proj", repo: "owner/repo"}
      ]
    ]

    assert Validator.validate(config) == []
  end

  test "validate warns about missing upstream name" do
    config = [
      backplane: %{port: 4100},
      upstream: [%{prefix: "t", transport: "http", url: "http://localhost/mcp"}],
      projects: []
    ]

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "missing required field 'name'"))
  end

  test "validate warns about missing url for http upstream" do
    config = [
      backplane: %{port: 4100},
      upstream: [%{name: "bad", prefix: "b", transport: "http"}],
      projects: []
    ]

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "missing required field 'url'"))
  end

  test "validate warns about missing command for stdio upstream" do
    config = [
      backplane: %{port: 4100},
      upstream: [%{name: "bad", prefix: "b", transport: "stdio"}],
      projects: []
    ]

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "missing required field 'command'"))
  end

  test "validate warns about unknown transport" do
    config = [
      backplane: %{port: 4100},
      upstream: [%{name: "bad", prefix: "b", transport: "grpc"}],
      projects: []
    ]

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "unknown transport 'grpc'"))
  end

  test "validate warns about missing project fields" do
    config = [
      backplane: %{port: 4100},
      upstream: [],
      projects: [%{id: nil, repo: nil}]
    ]

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "missing required field 'id'"))
    assert Enum.any?(warnings, &(&1 =~ "missing required field 'repo'"))
  end

  test "validate warns about invalid port" do
    config = [
      backplane: %{port: 99_999},
      upstream: [],
      projects: []
    ]

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "invalid port"))
  end

  test "validate returns no warnings with empty config" do
    config = [backplane: %{port: 4100}, upstream: [], projects: []]
    assert Validator.validate(config) == []
  end

  test "validate warns about missing transport and does not warn about unknown transport" do
    config = %{
      backplane: %{port: 4100},
      upstream: [%{name: "no-transport", prefix: "nt"}],
      projects: []
    }

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "missing required field 'transport'"))
    refute Enum.any?(warnings, &(&1 =~ "unknown transport"))
  end

  test "validate returns no warnings when backplane section is absent" do
    config = %{upstream: [], projects: []}

    warnings = Validator.validate(config)
    refute Enum.any?(warnings, &(&1 =~ "invalid port"))
  end

  test "validate warns when upstream name is an empty string" do
    config = %{
      backplane: %{port: 4100},
      upstream: [%{name: "", prefix: "t", transport: "http", url: "http://localhost/mcp"}],
      projects: []
    }

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "'name' cannot be empty"))
  end

  test "validate warns when upstream prefix is an empty string" do
    config = %{
      backplane: %{port: 4100},
      upstream: [%{name: "myup", prefix: "", transport: "http", url: "http://localhost/mcp"}],
      projects: []
    }

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "'prefix' cannot be empty"))
  end

  test "validate warns about invalid upstream timeout" do
    config = [
      backplane: %{port: 4100},
      upstream: [
        %{
          name: "bad-timeout",
          prefix: "bt",
          transport: "http",
          url: "http://localhost/mcp",
          timeout: -1
        }
      ],
      projects: []
    ]

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "'timeout' must be a positive integer"))
  end

  test "validate warns about non-integer refresh_interval" do
    config = [
      backplane: %{port: 4100},
      upstream: [
        %{
          name: "bad-refresh",
          prefix: "br",
          transport: "stdio",
          command: "node",
          refresh_interval: "5m"
        }
      ],
      projects: []
    ]

    warnings = Validator.validate(config)
    assert Enum.any?(warnings, &(&1 =~ "'refresh_interval' must be a positive integer"))
  end

  test "validate returns no warnings with valid timeout and refresh_interval" do
    config = [
      backplane: %{port: 4100},
      upstream: [
        %{
          name: "ok",
          prefix: "ok",
          transport: "http",
          url: "http://localhost/mcp",
          timeout: 60_000,
          refresh_interval: 120_000
        }
      ],
      projects: []
    ]

    warnings = Validator.validate(config)
    refute Enum.any?(warnings, &(&1 =~ "timeout"))
    refute Enum.any?(warnings, &(&1 =~ "refresh_interval"))
  end

  describe "duplicate detection" do
    test "warns about duplicate upstream prefixes" do
      config = [
        backplane: %{port: 4100},
        upstream: [
          %{name: "first", prefix: "dup", transport: "http", url: "http://a/mcp"},
          %{name: "second", prefix: "dup", transport: "http", url: "http://b/mcp"}
        ],
        projects: []
      ]

      warnings = Validator.validate(config)
      assert Enum.any?(warnings, &(&1 =~ "duplicate upstream prefix 'dup'"))
    end

    test "warns about duplicate upstream names" do
      config = [
        backplane: %{port: 4100},
        upstream: [
          %{name: "same", prefix: "a", transport: "http", url: "http://a/mcp"},
          %{name: "same", prefix: "b", transport: "http", url: "http://b/mcp"}
        ],
        projects: []
      ]

      warnings = Validator.validate(config)
      assert Enum.any?(warnings, &(&1 =~ "duplicate upstream name 'same'"))
    end

    test "warns about duplicate project ids" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [
          %{id: "proj", repo: "github:a/b"},
          %{id: "proj", repo: "github:c/d"}
        ]
      ]

      warnings = Validator.validate(config)
      assert Enum.any?(warnings, &(&1 =~ "duplicate project id 'proj'"))
    end

    test "no warnings when all upstream prefixes and project ids are unique" do
      config = [
        backplane: %{port: 4100},
        upstream: [
          %{name: "first", prefix: "a", transport: "http", url: "http://a/mcp"},
          %{name: "second", prefix: "b", transport: "http", url: "http://b/mcp"}
        ],
        projects: [
          %{id: "proj1", repo: "github:a/b"},
          %{id: "proj2", repo: "github:c/d"}
        ]
      ]

      warnings = Validator.validate(config)
      refute Enum.any?(warnings, &(&1 =~ "duplicate"))
    end
  end

  describe "skill validation" do
    test "validate returns no warnings for valid git skill config" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "my-skill", source: "git", repo: "https://github.com/o/r.git"}]
      ]

      warnings = Validator.validate(config)
      refute Enum.any?(warnings, &(&1 =~ "skill"))
    end

    test "validate returns no warnings for valid local skill config" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "local-skill", source: "local", path: "/opt/skills"}]
      ]

      warnings = Validator.validate(config)
      refute Enum.any?(warnings, &(&1 =~ "skill"))
    end

    test "validate warns about missing skill name" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{source: "git", repo: "https://github.com/o/r.git"}]
      ]

      warnings = Validator.validate(config)
      assert Enum.any?(warnings, &(&1 =~ "missing required field 'name'"))
    end

    test "validate warns about missing skill source" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "no-source"}]
      ]

      warnings = Validator.validate(config)
      assert Enum.any?(warnings, &(&1 =~ "missing required field 'source'"))
    end

    test "validate warns about missing repo for git skill" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "git-skill", source: "git"}]
      ]

      warnings = Validator.validate(config)
      assert Enum.any?(warnings, &(&1 =~ "missing required field 'repo'"))
    end

    test "validate warns about missing path for local skill" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "local-skill", source: "local"}]
      ]

      warnings = Validator.validate(config)
      assert Enum.any?(warnings, &(&1 =~ "missing required field 'path'"))
    end

    test "validate warns about unknown skill source" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "bad-skill", source: "s3"}]
      ]

      warnings = Validator.validate(config)
      assert Enum.any?(warnings, &(&1 =~ "unknown source 's3'"))
    end

    test "validate returns no warnings when skills section is absent" do
      config = [backplane: %{port: 4100}, upstream: [], projects: []]

      warnings = Validator.validate(config)
      refute Enum.any?(warnings, &(&1 =~ "skill"))
    end

    test "validate warns about empty skill name" do
      config = [
        backplane: %{port: 4100},
        upstream: [],
        projects: [],
        skills: [%{name: "", source: "git", repo: "https://github.com/o/r.git"}]
      ]

      warnings = Validator.validate(config)
      assert Enum.any?(warnings, &(&1 =~ "'name' cannot be empty"))
    end
  end
end
