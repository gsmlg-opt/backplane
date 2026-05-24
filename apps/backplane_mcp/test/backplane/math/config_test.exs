defmodule Backplane.Math.ConfigTest do
  use Backplane.DataCase, async: false

  alias Backplane.Math.Config

  setup do
    Backplane.Repo.delete_all(Backplane.Math.Config.Record)
    :ok = Config.reload()
    :ok
  end

  test "get/0 returns defaults when the table is empty" do
    cfg = Config.get()
    assert cfg.enabled == true
    assert cfg.timeout_default_ms == 5_000
    assert cfg.max_expr_nodes == 10_000
    assert cfg.units_system == "si"
  end

  test "get/1 returns a single field" do
    assert Config.get(:timeout_default_ms) == 5_000
    assert Config.get(:units_system) == "si"
  end

  test "save/1 persists changes and updates the cache" do
    assert {:ok, _} = Config.save(%{timeout_default_ms: 7_500, max_matrix_dim: 256})
    assert Config.get(:timeout_default_ms) == 7_500
    assert Config.get(:max_matrix_dim) == 256
  end

  test "save/1 rejects invalid attrs without touching the cache" do
    before = Config.get(:timeout_default_ms)
    assert {:error, %Ecto.Changeset{}} = Config.save(%{timeout_default_ms: 0})
    assert Config.get(:timeout_default_ms) == before
  end

  test "reload/0 broadcasts a pubsub event" do
    Phoenix.PubSub.subscribe(Backplane.PubSub, "math:config")
    :ok = Config.reload()
    assert_receive {:math_config_changed, %Backplane.Math.Config.Record{}}, 100
  end

  test "tool_timeout/1 returns per-tool override when set, otherwise default" do
    {:ok, _} = Config.save(%{timeout_default_ms: 5_000, timeout_per_tool: %{"integrate" => 30_000}})

    assert Config.tool_timeout("integrate") == 30_000
    assert Config.tool_timeout("evaluate") == 5_000
  end
end
