defmodule Backplane.AgentRuntime.SchedulerTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Scheduler

  describe "bounded scheduling" do
    test "admits until quota, then queues continuations and rejects overflow" do
      {:ok, scheduler} = Scheduler.new(1)

      assert {:ok, scheduler, %{status: :admitted}} = Scheduler.admit(scheduler, "worker_1")

      assert {:ok, scheduler, %{status: :queued}} =
               Scheduler.admit(scheduler, "worker_2", %{continuation: true})

      assert {:error, %Error{class: :overloaded}} =
               Scheduler.admit(scheduler, "worker_3", %{continuation: true})
    end

    test "releases workers and promotes queued continuations exactly once" do
      {:ok, scheduler} = Scheduler.new(1)
      {:ok, scheduler, %{status: :admitted}} = Scheduler.admit(scheduler, "worker_1")
      {:ok, scheduler, %{status: :queued}} = Scheduler.admit(scheduler, "worker_2", %{wait: true})

      assert {:ok, scheduler} = Scheduler.release(scheduler, "worker_1")
      assert {:ok, promoted} = Scheduler.promote(scheduler, "worker_2")

      assert Map.has_key?(promoted.active, "worker_2")
      assert promoted.continuations == []

      assert {:error, %Error{class: :resource_conflict}} = Scheduler.promote(promoted, "worker_2")
    end

    test "rejects duplicate workers and unknown releases" do
      {:ok, scheduler} = Scheduler.new(2)
      {:ok, scheduler, %{status: :admitted}} = Scheduler.admit(scheduler, "worker_1")

      assert {:error, %Error{class: :resource_conflict}} =
               Scheduler.admit(scheduler, "worker_1")

      assert {:error, %Error{class: :not_found}} = Scheduler.release(scheduler, "worker_2")
    end
  end
end
