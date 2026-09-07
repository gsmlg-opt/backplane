defmodule Backplane.HostAgent.Memory.Edge.ProtectionTest do
  use ExUnit.Case, async: false
  alias Backplane.HostAgent.Memory.Edge.Protection
  @moduletag :tmp_dir

  test "rejects normalized and filesystem aliases of reserved databases", %{tmp_dir: dir} do
    path = Path.join(dir, "capture.db")
    File.write!(path, "")
    symlink = Path.join(dir, "symlink.db")
    hardlink = Path.join(dir, "hardlink.db")
    File.ln_s!(path, symlink)
    File.ln!(path, hardlink)

    for alias_path <- [Path.join(dir, "nested/../capture.db"), symlink, hardlink] do
      assert Protection.status(%{
               enabled: true,
               development_plaintext: true,
               db_path: alias_path,
               reserved_db_paths: [path]
             }) == :protection_unavailable
    end
  end

  test "disabled by default and plaintext requires explicit opt-in" do
    assert Protection.status(%{}) == :disabled
    assert Protection.status(%{enabled: true}) == :protection_unavailable

    assert Protection.status(%{enabled: true, development_plaintext: true}) ==
             :plaintext_development

    assert Protection.status(%{enabled: true, development_plaintext: "true"}) ==
             :protection_unavailable
  end

  test "production policy rejects plaintext even with a spoofed environment", %{tmp_dir: dir} do
    source =
      File.read!(
        Path.expand("../../../../../lib/backplane/host_agent/memory/edge/protection.ex", __DIR__)
      )

    production_source =
      source
      |> String.replace(
        "defmodule Backplane.HostAgent.Memory.Edge.Protection do",
        "defmodule Backplane.HostAgent.Memory.Edge.ProductionProtectionTest do"
      )
      |> String.replace("@build_env Mix.env()", "@build_env :prod")

    Code.compile_string(production_source)
    module = Backplane.HostAgent.Memory.Edge.ProductionProtectionTest

    assert apply(module, :status, [%{enabled: true, development_plaintext: true, env: :test}]) ==
             :protection_unavailable

    for file <- ["store.ex", "supervisor.ex"] do
      Path.expand("../../../../../lib/backplane/host_agent/memory/edge/#{file}", __DIR__)
      |> File.read!()
      |> String.replace(
        "Backplane.HostAgent.Memory.Edge.Store do",
        "Backplane.HostAgent.Memory.Edge.ProductionStoreTest do"
      )
      |> String.replace(
        "Backplane.HostAgent.Memory.Edge.Supervisor do",
        "Backplane.HostAgent.Memory.Edge.ProductionSupervisorTest do"
      )
      |> String.replace(
        "alias Backplane.HostAgent.Memory.Edge.Protection",
        "alias Backplane.HostAgent.Memory.Edge.ProductionProtectionTest, as: Protection"
      )
      |> String.replace(
        "alias Backplane.HostAgent.Memory.Edge.{Protection, Store, Migrator}",
        "alias Backplane.HostAgent.Memory.Edge.{Store, Migrator}\n  alias Backplane.HostAgent.Memory.Edge.ProductionProtectionTest, as: Protection"
      )
      |> Code.compile_string()
    end

    config = %{
      enabled: true,
      development_plaintext: true,
      env: :test,
      db_path: Path.join(dir, "production/edge.db")
    }

    assert :ignore =
             apply(Backplane.HostAgent.Memory.Edge.ProductionStoreTest, :start_link, [
               [database: config.db_path, config: config]
             ])

    assert :ignore =
             apply(Backplane.HostAgent.Memory.Edge.ProductionSupervisorTest, :start_link, [config])

    refute File.exists?(Path.dirname(config.db_path))
  end
end
