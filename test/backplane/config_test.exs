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
end
