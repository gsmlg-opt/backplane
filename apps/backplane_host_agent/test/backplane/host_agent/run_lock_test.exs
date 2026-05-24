defmodule Backplane.HostAgent.RunLockTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.RunLock

  test "acquire writes pid file and release removes it" do
    config_path = config_path()

    assert {:ok, lock} = RunLock.acquire(config_path)
    assert lock.path == RunLock.path_for(config_path)
    assert File.exists?(lock.path)

    assert :ok = RunLock.release(lock)
    refute File.exists?(lock.path)
  end

  test "acquire rejects another live runner for the same config path" do
    config_path = config_path()
    assert {:ok, lock} = RunLock.acquire(config_path)

    assert {:error, {:already_running, pid, path}} = RunLock.acquire(config_path)
    assert pid == lock.pid
    assert path == lock.path

    assert :ok = RunLock.release(lock)
  end

  test "acquire clears stale pid files" do
    config_path = config_path()
    lock_path = RunLock.path_for(config_path)
    File.mkdir_p!(Path.dirname(lock_path))
    File.write!(lock_path, "999999999\n")

    assert {:ok, lock} = RunLock.acquire(config_path)
    assert lock.path == lock_path
    refute lock.pid == "999999999"

    assert :ok = RunLock.release(lock)
  end

  defp config_path do
    Path.join(
      System.tmp_dir!(),
      "backplane-run-lock-#{System.unique_integer([:positive])}/host_agent.yaml"
    )
  end
end
