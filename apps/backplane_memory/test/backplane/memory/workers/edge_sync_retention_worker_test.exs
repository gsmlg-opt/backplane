defmodule Backplane.Memory.Workers.EdgeSyncRetentionWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Workers.EdgeSyncRetentionWorker

  test "scheduled worker runs recoverable bounded retention" do
    assert {:ok, %{changes: changes, snapshots: snapshots, deliveries: deliveries}} =
             EdgeSyncRetentionWorker.perform(%Oban.Job{args: %{}})

    assert changes >= 0
    assert snapshots >= 0
    assert deliveries >= 0
  end

  test "a bounded pass enqueues continuation while excess changes remain" do
    space = "00000000-0000-0000-0000-000000000002"
    binary_space = Ecto.UUID.dump!(space)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    repo().query!(
      "INSERT INTO bpm_memory_spaces (id,kind,status,inserted_at,updated_at) VALUES ($1,'private','active',$2,$2)",
      [binary_space, now]
    )

    repo().query!(
      "INSERT INTO bpm_memory_partition_revisions VALUES ($1,'retention-worker','private',4,1,$2)",
      [binary_space, now]
    )

    for revision <- 1..4 do
      repo().query!(
        "INSERT INTO bpm_memory_changes VALUES ($1,'retention-worker','private',$2,'upsert',$3,'{}',2,$4)",
        [binary_space, revision, Ecto.UUID.dump!(Ecto.UUID.generate()), now]
      )
    end

    args = %{
      "max_changes_per_partition" => 1,
      "max_deletes" => 1,
      "max_partitions" => 1
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{changes: 1, continued: true}} =
               EdgeSyncRetentionWorker.perform(%Oban.Job{args: args})

      assert Oban.Testing.assert_enqueued(
               repo: repo(),
               worker: EdgeSyncRetentionWorker,
               args: args
             )
    end)

    assert [[2]] =
             repo().query!(
               "SELECT first_available_revision FROM bpm_memory_partition_revisions WHERE memory_space_id=$1",
               [binary_space]
             ).rows
  end

  test "nightly cron registers edge synchronization retention" do
    {_plugin, opts} =
      Application.fetch_env!(:backplane, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(fn {plugin, _opts} -> plugin == Oban.Plugins.Cron end)

    assert {"15 4 * * *", EdgeSyncRetentionWorker} in Keyword.fetch!(opts, :crontab)
  end
end
