defmodule Backplane.Skills.SyncStatusesTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.{HostStatus, Hosts, SyncStatuses}

  describe "record_sync_result/2" do
    test "persists a valid sync result for a host" do
      assert {:ok, host, _token} = Hosts.create_host(%{"name" => "sync-status-host"})

      assert {:ok, [%HostStatus{} = status]} =
               SyncStatuses.record_sync_result(host, %{
                 "results" => [
                   %{
                     "skill_name" => "agent-tools",
                     "skill_slug" => "agent-tools",
                     "checksum" => "sha256:abc",
                     "targets" => ["agents"],
                     "status" => "installed"
                   }
                 ]
               })

      assert status.host_id == host.id
      assert status.skill_name == "agent-tools"
      assert status.status == "installed"
      assert status.skill_slug == "agent-tools"
      assert status.desired_checksum == "sha256:abc"
      assert status.installed_checksum == "sha256:abc"
      assert status.targets == ["agents"]

      persisted = Repo.get_by!(HostStatus, host_id: host.id, skill_name: "agent-tools")
      assert persisted.id == status.id
    end

    test "upserts by host and skill name" do
      assert {:ok, host, _token} = Hosts.create_host(%{"name" => "sync-status-upsert-host"})

      assert {:ok, [%HostStatus{} = first]} =
               SyncStatuses.record_sync_result(host, %{
                 "results" => [
                   %{
                     "skill_name" => "agent-tools",
                     "checksum" => "sha256:abc",
                     "status" => "installed"
                   }
                 ]
               })

      Process.sleep(2)

      assert {:ok, [%HostStatus{} = updated]} =
               SyncStatuses.record_sync_result(host, %{
                 "results" => [
                   %{
                     "skill_name" => "agent-tools",
                     "checksum" => "sha256:def",
                     "status" => "failed",
                     "error" => "checksum mismatch"
                   }
                 ]
               })

      assert updated.status == "failed"
      assert updated.desired_checksum == "sha256:def"
      assert updated.installed_checksum == "sha256:def"
      assert updated.error == "checksum mismatch"
      assert DateTime.compare(updated.updated_at, first.updated_at) == :gt

      assert [persisted] = Repo.all(HostStatus)
      assert persisted.id == updated.id
      assert persisted.host_id == host.id
      assert persisted.skill_name == "agent-tools"
    end

    test "defaults explicit nil targets and metadata" do
      assert {:ok, host, _token} = Hosts.create_host(%{"name" => "sync-status-nil-default-host"})

      assert {:ok, [%HostStatus{} = status]} =
               SyncStatuses.record_sync_result(host, %{
                 "results" => [
                   %{
                     "skill_name" => "agent-tools",
                     "targets" => nil,
                     "metadata" => nil,
                     "status" => "installed"
                   }
                 ]
               })

      assert status.targets == []
      assert status.metadata == %{}
    end

    test "rolls back all statuses when a later result is invalid" do
      assert {:ok, host, _token} = Hosts.create_host(%{"name" => "sync-status-rollback-host"})

      assert {:error, %Ecto.Changeset{}} =
               SyncStatuses.record_sync_result(host, %{
                 "results" => [
                   %{"skill_name" => "valid-skill", "status" => "installed"},
                   %{
                     "skill_name" => "invalid-skill",
                     "targets" => "not-a-list",
                     "status" => "failed"
                   }
                 ]
               })

      assert [] = Repo.all(HostStatus)
    end

    test "rejects invalid payloads" do
      assert {:ok, host, _token} = Hosts.create_host(%{"name" => "sync-status-invalid-host"})

      assert {:error, :invalid_payload} = SyncStatuses.record_sync_result(host, %{})

      assert {:error, :invalid_payload} =
               SyncStatuses.record_sync_result(host, %{"results" => "bad"})

      assert {:error, :invalid_payload} =
               SyncStatuses.record_sync_result(host, %{"results" => ["bad"]})

      assert {:error, %Ecto.Changeset{}} =
               SyncStatuses.record_sync_result(host, %{
                 "results" => [
                   %{
                     "skill_name" => "agent-tools",
                     "metadata" => "not-a-map",
                     "status" => "failed"
                   }
                 ]
               })
    end
  end
end
