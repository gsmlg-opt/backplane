defmodule Backplane.AgentRuntime.DependencyTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Dependency
  alias Backplane.AgentRuntime.Error

  describe "dependency waits" do
    test "creates an asynchronous wait without a blocking tool slot" do
      {:ok, deps} = Dependency.new(2)

      assert {:ok, _deps, %{status: :waiting}} = Dependency.wait(deps, "run_a", "run_b")
    end

    test "rejects self-wait, held-context self-dependency, and cycles" do
      {:ok, deps} = Dependency.new(2)

      assert {:error, %Error{}} = Dependency.wait(deps, "run_a", "run_a")
      assert {:error, %Error{}} = Dependency.wait(deps, "run_a", "run_a", %{"run_a" => "run_a"})

      assert {:ok, deps, _} = Dependency.wait(deps, "run_a", "run_b")
      assert {:error, %Error{}} = Dependency.wait(deps, "run_b", "run_a")
    end

    test "rejects a transitive dependency cycle" do
      {:ok, deps} = Dependency.new(3)
      assert {:ok, deps, _} = Dependency.wait(deps, "run_a", "run_b")
      assert {:ok, deps, _} = Dependency.wait(deps, "run_b", "run_c")

      assert {:error, %Error{class: :validation, message: "dependency cycle rejected"}} =
               Dependency.wait(deps, "run_c", "run_a")
    end

    test "accepts an acyclic dependency chain" do
      {:ok, deps} = Dependency.new(3)
      assert {:ok, deps, _} = Dependency.wait(deps, "run_a", "run_b")
      assert {:ok, deps, _} = Dependency.wait(deps, "run_b", "run_c")
      assert {:ok, deps, _} = Dependency.wait(deps, "run_c", "run_d")

      assert deps.waits == [
               %{waiter: "run_a", target: "run_b"},
               %{waiter: "run_b", target: "run_c"},
               %{waiter: "run_c", target: "run_d"}
             ]
    end

    test "resolves each waiter once and preserves target result" do
      {:ok, deps} = Dependency.new(2)
      {:ok, deps, %{status: :waiting}} = Dependency.wait(deps, "run_a", "run_b")

      assert {:ok, deps, %{status: :resolved, target: "run_b"}} =
               Dependency.resolve(deps, "run_b", %{"text" => "done"})

      assert {:error, %Error{}} = Dependency.resolve(deps, "run_b", %{})
      assert deps.results["run_b"] == %{"text" => "done"}
    end

    test "overflows rather than accepting unbounded waiters" do
      {:ok, deps} = Dependency.new(0)

      assert {:error, %Error{class: :overloaded}} = Dependency.wait(deps, "run_a", "run_b")
    end
  end
end
