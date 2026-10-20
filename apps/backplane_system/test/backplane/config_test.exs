defmodule Backplane.ConfigTest do
  use ExUnit.Case, async: true

  @fixtures_path "test/support/fixtures/config"

  describe "load!/1" do
    test "loads minimal config (hub section only)" do
      config = Backplane.Config.load!("#{@fixtures_path}/minimal.toml")

      assert config[:backplane].host == "0.0.0.0"
      assert config[:backplane].port == 4100
      refute Map.has_key?(config[:backplane], :auth_token)
    end

    test "loads full config with all sections populated" do
      config = Backplane.Config.load!("#{@fixtures_path}/full.toml")

      assert config[:backplane].host == "127.0.0.1"
      assert config[:backplane].port == 8080
      refute Map.has_key?(config[:backplane], :auth_token)
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

    @tag :tmp_dir
    test "rejects deprecated TOML shared tokens without printing their values", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "tokens.toml")

      for setting <- [
            ~s(auth_token = "never-print-secret"),
            ~s(auth_tokens = ["never-print-secret"])
          ] do
        File.write!(path, "[backplane]\n" <> setting)
        error = assert_raise ArgumentError, fn -> Backplane.Config.load!(path) end
        refute Exception.message(error) =~ "never-print-secret"
      end
    end

    @tag :tmp_dir
    test "rejects credential-bearing TOML seeds and loads metadata-only seeds", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "clients.toml")
      File.write!(path, "[[clients]]\nname = \"seed\"\ntoken = \"never-print-secret\"")
      error = assert_raise ArgumentError, fn -> Backplane.Config.load!(path) end
      refute Exception.message(error) =~ "never-print-secret"

      File.write!(path, "[[clients]]\nname = \"seed\"\nscopes = [\"docs::*\"]\nactive = false")

      assert [%{name: "seed", scopes: ["docs::*"], active: false, metadata: %{}}] =
               Backplane.Config.load!(path)[:clients]
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

    test "normalizes upstream prefixes", %{dir: dir} do
      path = Path.join(dir, "normalized_prefix.toml")

      File.write!(path, """
      [backplane]
      port = 5000

      [[upstream]]
      name = "github"
      prefix = " /github/ "
      transport = "http"
      url = "http://localhost:9999/mcp"
      """)

      config = Backplane.Config.load!(path)
      upstream = hd(config[:upstream])
      assert upstream.prefix == "github"
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
