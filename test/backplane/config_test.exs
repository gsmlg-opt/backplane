defmodule Backplane.ConfigTest do
  use ExUnit.Case, async: true

  @fixtures_path "test/support/fixtures/config"

  describe "load!/1" do
    test "loads minimal config (hub section only)" do
      config = Backplane.Config.load!("#{@fixtures_path}/minimal.toml")

      assert config[:backplane].host == "0.0.0.0"
      assert config[:backplane].port == 4100
      assert config[:backplane].auth_token == nil
    end

    test "loads full config with all sections populated" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")

      assert config[:backplane].host == "127.0.0.1"
      assert config[:backplane].port == 8080
      assert config[:backplane].auth_token == "test-secret-token"
    end

    test "parses single github credential with token and api_url" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      github = config[:github]

      default = Enum.find(github, &(&1.name == "default"))
      assert default.token == "ghp_test123"
      assert default.api_url == "https://api.github.com"
    end

    test "parses multiple github instances" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      github = config[:github]

      assert length(github) == 2
      enterprise = Enum.find(github, &(&1.name == "enterprise"))
      assert enterprise.token == "ghp_enterprise456"
      assert enterprise.api_url == "https://github.corp.example.com/api/v3"
    end

    test "parses single gitlab credential" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      gitlab = config[:gitlab]

      default = Enum.find(gitlab, &(&1.name == "default"))
      assert default.token == "glpat-test789"
    end

    test "parses multiple gitlab instances" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      gitlab = config[:gitlab]

      assert length(gitlab) == 2
      self_hosted = Enum.find(gitlab, &(&1.name == "self_hosted"))
      assert self_hosted.token == "glpat-selfhosted"
    end

    test "parses projects list with all fields" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      [proj1, proj2] = config[:projects]

      assert proj1.id == "test-project"
      assert proj1.repo == "github:test-org/test-repo"
      assert proj1.ref == "develop"
      assert proj1.parsers == ["elixir", "markdown"]
      assert proj1.reindex_interval == "2h"
      assert proj1.webhook_secret == "whsec_test"

      assert proj2.id == "minimal-project"
    end

    test "defaults ref to main when omitted" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      proj2 = Enum.at(config[:projects], 1)

      assert proj2.ref == "main"
    end

    test "defaults parsers to [generic] when omitted" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      proj2 = Enum.at(config[:projects], 1)

      assert proj2.parsers == ["generic"]
    end

    test "parses upstream servers with stdio transport" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      stdio = Enum.find(config[:upstream], &(&1.transport == "stdio"))

      assert stdio.name == "filesystem"
      assert stdio.command == "npx"
      assert stdio.args == ["-y", "@anthropic/mcp-filesystem"]
      assert stdio.prefix == "fs"
    end

    test "parses upstream servers with http transport" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      http = Enum.find(config[:upstream], &(&1.transport == "http"))

      assert http.name == "postgres-mcp"
      assert http.url == "http://localhost:4200/mcp"
      assert http.prefix == "pg"
    end

    test "parses skill sources with git source" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      git_skill = Enum.find(config[:skills], &(&1.source == "git"))

      assert git_skill.name == "elixir-patterns"
      assert git_skill.repo == "github:test-org/skills"
      assert git_skill.path == "elixir/"
      assert git_skill.ref == "main"
      assert git_skill.sync_interval == "1h"
    end

    test "parses skill sources with local source" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      local_skill = Enum.find(config[:skills], &(&1.source == "local"))

      assert local_skill.name == "local-experiments"
      assert local_skill.path == "/tmp/test-skills"
    end

    test "reads auth_token from hub section" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")
      assert config[:backplane].auth_token == "test-secret-token"
    end

    test "defaults port to 4100 when omitted" do
      config = Backplane.Config.load!("#{@fixtures_path}/minimal.toml")
      assert config[:backplane].port == 4100
    end

    test "raises on missing config file" do
      assert_raise RuntimeError, ~r/Config file not found/, fn ->
        Backplane.Config.load!("nonexistent.toml")
      end
    end

    test "raises on malformed TOML" do
      assert_raise RuntimeError, ~r/Failed to parse config file/, fn ->
        Backplane.Config.load!("#{@fixtures_path}/invalid.toml")
      end
    end
  end

  describe "edge cases" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "backplane_config_edge_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "config with no github/gitlab sections returns empty lists", %{dir: dir} do
      path = Path.join(dir, "no_git.toml")

      File.write!(path, """
      [backplane]
      port = 5000
      """)

      config = Backplane.Config.load!(path)
      assert config[:github] == []
      assert config[:gitlab] == []
    end

    test "config with non-list projects section returns empty list", %{dir: dir} do
      path = Path.join(dir, "bad_projects.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [projects]
      id = "single"
      """)

      config = Backplane.Config.load!(path)
      assert config[:projects] == []
    end

    test "config with non-list upstream section returns empty list", %{dir: dir} do
      path = Path.join(dir, "bad_upstream.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [upstream]
      name = "single"
      """)

      config = Backplane.Config.load!(path)
      assert config[:upstream] == []
    end

    test "config with non-list skills section returns empty list", %{dir: dir} do
      path = Path.join(dir, "bad_skills.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [skills]
      name = "single"
      """)

      config = Backplane.Config.load!(path)
      assert config[:skills] == []
    end

    test "upstream with unknown transport type uses base config", %{dir: dir} do
      path = Path.join(dir, "unknown_transport.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [[upstream]]
      name = "custom"
      prefix = "cust"
      transport = "grpc"
      """)

      config = Backplane.Config.load!(path)
      upstream = hd(config[:upstream])
      assert upstream.name == "custom"
      assert upstream.transport == "grpc"
    end

    test "skill with unknown source type uses base config", %{dir: dir} do
      path = Path.join(dir, "unknown_skill_source.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [[skills]]
      name = "remote"
      source = "s3"
      """)

      config = Backplane.Config.load!(path)
      skill = hd(config[:skills])
      assert skill.name == "remote"
      assert skill.source == "s3"
    end

    test "upstream stdio with env map parses env", %{dir: dir} do
      path = Path.join(dir, "stdio_env.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [[upstream]]
      name = "with-env"
      prefix = "env"
      transport = "stdio"
      command = "node"
      args = ["server.js"]

      [upstream.env]
      NODE_ENV = "production"
      DEBUG = "true"
      """)

      config = Backplane.Config.load!(path)
      upstream = hd(config[:upstream])
      assert upstream.env == %{"NODE_ENV" => "production", "DEBUG" => "true"}
    end

    test "upstream stdio with no env defaults to empty map", %{dir: dir} do
      path = Path.join(dir, "stdio_no_env.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [[upstream]]
      name = "no-env"
      prefix = "ne"
      transport = "stdio"
      command = "node"
      """)

      config = Backplane.Config.load!(path)
      upstream = hd(config[:upstream])
      assert upstream.env == %{}
    end

    test "config with non-map github section returns empty list", %{dir: dir} do
      path = Path.join(dir, "bad_github.toml")

      File.write!(path, """
      github = "not-a-map"

      [backplane]
      port = 5000
      """)

      config = Backplane.Config.load!(path)
      assert config[:github] == []
    end

    test "upstream stdio with non-map env defaults to empty map", %{dir: dir} do
      path = Path.join(dir, "stdio_bad_env.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [[upstream]]
      name = "bad-env"
      prefix = "be"
      transport = "stdio"
      command = "node"
      args = ["server.js"]
      env = "not-a-map"
      """)

      config = Backplane.Config.load!(path)
      upstream = hd(config[:upstream])
      assert upstream.env == %{}
    end

    test "upstream with timeout and refresh_interval", %{dir: dir} do
      path = Path.join(dir, "upstream_timeouts.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [[upstream]]
      name = "custom-timeouts"
      prefix = "ct"
      transport = "http"
      url = "http://localhost:9999/mcp"
      timeout = 60000
      refresh_interval = 120000
      """)

      config = Backplane.Config.load!(path)
      upstream = hd(config[:upstream])
      assert upstream.timeout == 60_000
      assert upstream.refresh_interval == 120_000
    end

    test "upstream without timeout and refresh_interval defaults to nil", %{dir: dir} do
      path = Path.join(dir, "upstream_no_timeouts.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [[upstream]]
      name = "default-timeouts"
      prefix = "dt"
      transport = "http"
      url = "http://localhost:9999/mcp"
      """)

      config = Backplane.Config.load!(path)
      upstream = hd(config[:upstream])
      assert upstream.timeout == nil
      assert upstream.refresh_interval == nil
    end

    test "database section is parsed", %{dir: dir} do
      path = Path.join(dir, "with_db.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [database]
      url = "postgres://localhost/backplane_test"
      """)

      config = Backplane.Config.load!(path)
      assert config[:database].url == "postgres://localhost/backplane_test"
    end
  end
end
