defmodule Backplane.HostAgent.Memory.CaptureUploaderTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.{CaptureUploader, EventEnvelope, PrivacyFilter}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool

  @moduletag :tmp_dir

  defmodule FakeChannel do
    def push(channel, "memory_events", payload) do
      send(channel, {:memory_events, payload})
      Process.get({__MODULE__, :reply}).(payload)
    end
  end

  defmodule ExitingChannel do
    def push(_channel, "memory_events", _payload), do: exit(:channel_closed)
  end

  defmodule RaisingChannel do
    def push(_channel, "memory_events", _payload), do: raise("channel exploded")
  end

  defmodule ErrorSpool do
    @behaviour Backplane.HostAgent.Memory.Spool

    @impl true
    def append(_server, _event), do: {:error, :unused}

    @impl true
    def next_batch(reason, _max_events, _max_bytes), do: {:error, reason}

    @impl true
    def acknowledge(_server, _event_ids), do: :ok

    @impl true
    def reject(_server, _event_id, _reason, _permanent?), do: :ok

    @impl true
    def stats(_server), do: %{}
  end

  defmodule RecordingSpool do
    @behaviour Backplane.HostAgent.Memory.Spool

    @impl true
    def append(_server, _event), do: {:error, :unused}

    @impl true
    def next_batch(owner, max_events, max_bytes) do
      send(owner, {:next_batch, max_events, max_bytes})
      []
    end

    @impl true
    def acknowledge(_server, _event_ids), do: :ok

    @impl true
    def reject(_server, _event_id, _reason, _permanent?), do: :ok

    @impl true
    def stats(_server), do: %{}
  end

  defmodule MutationFailureSpool do
    @behaviour Backplane.HostAgent.Memory.Spool

    @impl true
    def append(_server, _event), do: {:error, :unused}

    @impl true
    def next_batch(_server, _max_events, _max_bytes) do
      Process.get({__MODULE__, :events}, [])
    end

    @impl true
    def acknowledge(owner, event_ids) do
      send(owner, {:acknowledge, event_ids})
      :ok
    end

    @impl true
    def reject(owner, event_id, reason, permanent?) do
      reject_number = Process.get({__MODULE__, :reject_number}, 0) + 1
      Process.put({__MODULE__, :reject_number}, reject_number)
      send(owner, {:reject, event_id, reason, permanent?})

      if reject_number == Process.get({__MODULE__, :fail_reject_number}) do
        {:error, :disk_full}
      else
        :ok
      end
    end

    @impl true
    def stats(_server), do: %{}
  end

  defmodule BoundaryFailureSpool do
    @behaviour Backplane.HostAgent.Memory.Spool

    @impl true
    def append(_server, _event), do: {:error, :unused}

    @impl true
    def next_batch(_server, _max_events, _max_bytes) do
      apply_failure(Process.get({__MODULE__, :selection}), fn ->
        Process.get({__MODULE__, :events}, [])
      end)
    end

    @impl true
    def acknowledge(_server, _event_ids) do
      apply_failure(Process.get({__MODULE__, :acknowledge}), fn -> :ok end)
    end

    @impl true
    def reject(_server, _event_id, _reason, _permanent?) do
      reject_number = Process.get({__MODULE__, :reject_number}, 0) + 1
      Process.put({__MODULE__, :reject_number}, reject_number)

      apply_failure(Process.get({__MODULE__, {:reject, reject_number}}), fn -> :ok end)
    end

    @impl true
    def stats(_server), do: %{}

    defp apply_failure({:raise, message}, _success), do: raise(message)
    defp apply_failure({:exit, reason}, _success), do: exit(reason)
    defp apply_failure(nil, success), do: success.()
  end

  test "pushes host_events.v1 batches and acknowledges accepted and duplicate events", %{
    tmp_dir: dir
  } do
    spool = start_spool!(Path.join(dir, "accepted.db"))
    append!(spool, "accepted")
    append!(spool, "duplicate")

    Process.put({FakeChannel, :reply}, fn payload ->
      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" => [
           %{"event_id" => "accepted", "status" => "accepted", "server_event_id" => "s1"},
           %{"event_id" => "duplicate", "status" => "duplicate", "server_event_id" => "s2"}
         ]
       }}
    end)

    assert {:ok,
            %{
              "status" => "delivered",
              "selected" => 2,
              "acknowledged" => 2,
              "dead_lettered" => 0,
              "retryable" => 0,
              "unacknowledged" => 0,
              "drained" => 2,
              "batch_id" => batch_id
            }} = drain(spool)

    assert is_binary(batch_id)

    assert_receive {:memory_events,
                    %{
                      "protocol" => "host_events.v1",
                      "batch_id" => ^batch_id,
                      "host_id" => "host",
                      "events" => [
                        %{"event_id" => "accepted"},
                        %{"event_id" => "duplicate"}
                      ]
                    }}

    assert [] = Spool.next_batch(spool, 100, 512 * 1024)
  end

  test "budgets the complete encoded wire payload under 512 KiB", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "wire-budget.db"))

    large =
      attrs("near-limit") |> Map.put(:payload, %{"message" => String.duplicate("x", 523_600)})

    assert {:ok, _} = Spool.append(spool, large)

    Process.put({FakeChannel, :reply}, fn payload ->
      wire_bytes = byte_size(Jason.encode!(payload))
      wrapper_bytes = byte_size(Jason.encode!(Map.put(payload, "events", [])))
      [event] = payload["events"]
      event_bytes = byte_size(EventEnvelope.encode!(event))

      assert event_bytes > 512 * 1024 - wrapper_bytes - 99
      assert event_bytes <= 512 * 1024 - wrapper_bytes
      assert wire_bytes <= 512 * 1024

      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" => [%{"event_id" => "near-limit", "status" => "accepted"}]
       }}
    end)

    assert {:ok, %{"acknowledged" => 1}} = drain(spool)
    assert_receive {:memory_events, payload}
    assert byte_size(Jason.encode!(payload)) <= 512 * 1024
  end

  test "dead-letters an oversized head and drains following events on a later tick", %{
    tmp_dir: dir
  } do
    spool = start_spool!(Path.join(dir, "oversized-head.db"))

    oversized =
      attrs("oversized") |> Map.put(:payload, %{"message" => String.duplicate("x", 525_000)})

    assert {:ok, _} = Spool.append(spool, oversized)
    append!(spool, "following")

    assert {:ok,
            %{
              "status" => "oversized_dead_lettered",
              "selected" => 1,
              "dead_lettered" => 1,
              "drained" => 1
            }} = drain(spool)

    assert {:ok, %{state: :dead_letter, reason: "payload_too_large"}} =
             Spool.event_status(spool, "oversized")

    refute_receive {:memory_events, _payload}

    reply_with_results([%{"event_id" => "following", "status" => "accepted"}])
    assert {:ok, %{"acknowledged" => 1}} = drain(spool)
    assert_receive {:memory_events, %{"events" => [%{"event_id" => "following"}]}}
  end

  test "applies valid mixed results and leaves retryable and missing results pending", %{
    tmp_dir: dir
  } do
    spool = start_spool!(Path.join(dir, "mixed.db"))

    for event_id <- ~w(accepted duplicate permanent retryable missing) do
      append!(spool, event_id)
    end

    Process.put({FakeChannel, :reply}, fn payload ->
      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" => [
           %{"event_id" => "accepted", "status" => "accepted"},
           %{"event_id" => "duplicate", "status" => "duplicate"},
           %{
             "event_id" => "permanent",
             "status" => "rejected",
             "retryable" => false,
             "reason" => "unsupported_schema"
           },
           %{
             "event_id" => "retryable",
             "status" => "failed",
             "retryable" => true,
             "reason" => "database_unavailable"
           }
         ]
       }}
    end)

    assert {:error,
            {:invalid_ack, {:missing_results, ["missing"]},
             %{
               "status" => "partial_invalid_ack",
               "selected" => 5,
               "acknowledged" => 2,
               "dead_lettered" => 1,
               "retryable" => 1,
               "unacknowledged" => 1,
               "drained" => 3
             }}} = drain(spool)

    assert {:ok, %{state: :acknowledged}} = Spool.event_status(spool, "accepted")
    assert {:ok, %{state: :acknowledged}} = Spool.event_status(spool, "duplicate")

    assert {:ok, %{state: :dead_letter, reason: "unsupported_schema", attempts: 1}} =
             Spool.event_status(spool, "permanent")

    assert {:ok, %{state: :pending, reason: "database_unavailable", attempts: 1}} =
             Spool.event_status(spool, "retryable")

    assert {:ok, %{state: :pending, reason: nil, attempts: 0}} =
             Spool.event_status(spool, "missing")

    assert [%{"event_id" => "missing"}] =
             Spool.next_batch(spool, 100, 512 * 1024)
  end

  test "unknown and malformed results are not applied to sent events", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "unknown.db"))
    append!(spool, "known")

    Process.put({FakeChannel, :reply}, fn payload ->
      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" => [
           %{"event_id" => "other", "status" => "accepted"},
           %{"event_id" => "known", "status" => "rejected", "retryable" => true}
         ]
       }}
    end)

    assert {:error, {:invalid_ack, _reason, %{"unacknowledged" => 1}}} = drain(spool)
    assert {:ok, %{state: :pending, attempts: 0}} = Spool.event_status(spool, "known")
  end

  test "mismatched batch id leaves the whole batch pending", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "batch-mismatch.db"))
    append!(spool, "one")

    Process.put({FakeChannel, :reply}, fn _payload ->
      {:ok,
       %{
         "batch_id" => "not-the-sent-batch",
         "results" => [%{"event_id" => "one", "status" => "accepted"}]
       }}
    end)

    assert {:error, {:invalid_ack, :batch_id_mismatch, %{"unacknowledged" => 1}}} =
             drain(spool)

    assert {:ok, %{state: :pending}} = Spool.event_status(spool, "one")
  end

  test "transport errors and exits mark every selected event retryable", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "transport.db"))
    append!(spool, "one")
    append!(spool, "two")

    Process.put({FakeChannel, :reply}, fn _payload -> {:error, :disconnected} end)
    assert {:error, :disconnected} = drain(spool)
    assert [] = pending(spool)

    assert {:ok, %{state: :pending, attempts: 1, reason: "transport_error"}} =
             Spool.event_status(spool, "one")

    assert {:ok, %{state: :pending, attempts: 1, reason: "transport_error"}} =
             Spool.event_status(spool, "two")

    exit_spool = start_spool!(Path.join(dir, "transport-exit.db"))
    append!(exit_spool, "exit")

    assert {:error, {:channel_exit, :channel_closed}} =
             drain(exit_spool, channel_module: ExitingChannel)

    assert {:ok, %{state: :pending, attempts: 1, reason: "transport_error"}} =
             Spool.event_status(exit_spool, "exit")
  end

  test "channel exceptions leave every batch event pending", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "channel-exception.db"))
    append!(spool, "one")

    assert {:error, {:channel_exception, %RuntimeError{message: "channel exploded"}}} =
             drain(spool, channel_module: RaisingChannel)

    assert {:ok, %{state: :pending, attempts: 1, reason: "transport_error"}} =
             Spool.event_status(spool, "one")
  end

  test "disconnected channels return success without reading the spool" do
    assert {:ok,
            %{
              "status" => "disconnected",
              "selected" => 0,
              "acknowledged" => 0,
              "dead_lettered" => 0,
              "retryable" => 0,
              "unacknowledged" => 0,
              "drained" => 0
            }} =
             CaptureUploader.drain_once(
               spool: self(),
               spool_module: RecordingSpool,
               channel: nil,
               channel_module: FakeChannel,
               host_id: "host"
             )

    refute_receive {:next_batch, _, _}
  end

  test "propagates spool errors and reserves wrapper bytes from default batch bounds" do
    assert {:error, :storage_down} =
             CaptureUploader.drain_once(
               spool: :storage_down,
               spool_module: ErrorSpool,
               channel: self(),
               channel_module: FakeChannel,
               host_id: "host"
             )

    assert {:ok, %{"status" => "empty", "selected" => 0}} =
             CaptureUploader.drain_once(
               spool: self(),
               spool_module: RecordingSpool,
               channel: self(),
               channel_module: FakeChannel,
               host_id: "host"
             )

    assert_receive {:next_batch, 100, event_budget}
    assert event_budget in 524_000..524_287
  end

  test "spool failure after acknowledgement retains truthful summary counts" do
    events = [%{"event_id" => "accepted"}, %{"event_id" => "permanent"}]
    Process.put({MutationFailureSpool, :events}, events)
    Process.put({MutationFailureSpool, :fail_reject_number}, 1)

    Process.put({FakeChannel, :reply}, fn payload ->
      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" => [
           %{"event_id" => "accepted", "status" => "accepted"},
           %{
             "event_id" => "permanent",
             "status" => "rejected",
             "retryable" => false,
             "reason" => "bad"
           }
         ]
       }}
    end)

    assert {:error,
            {:spool_update_failed, :disk_full,
             %{
               "status" => "spool_update_failed",
               "selected" => 2,
               "acknowledged" => 1,
               "dead_lettered" => 0,
               "retryable" => 0,
               "unacknowledged" => 1,
               "drained" => 1
             }}} = drain_with_mutation_spool()

    assert_receive {:acknowledge, ["accepted"]}
    assert_receive {:reject, "permanent", "bad", true}
  end

  test "spool failure after one rejection retains every applied mutation count" do
    events = [
      %{"event_id" => "accepted"},
      %{"event_id" => "permanent-one"},
      %{"event_id" => "permanent-two"}
    ]

    Process.put({MutationFailureSpool, :events}, events)
    Process.put({MutationFailureSpool, :fail_reject_number}, 2)

    Process.put({FakeChannel, :reply}, fn payload ->
      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" => [
           %{"event_id" => "accepted", "status" => "accepted"},
           %{
             "event_id" => "permanent-one",
             "status" => "rejected",
             "retryable" => false,
             "reason" => "bad one"
           },
           %{
             "event_id" => "permanent-two",
             "status" => "rejected",
             "retryable" => false,
             "reason" => "bad two"
           }
         ]
       }}
    end)

    assert {:error,
            {:spool_update_failed, :disk_full,
             %{
               "status" => "spool_update_failed",
               "selected" => 3,
               "acknowledged" => 1,
               "dead_lettered" => 1,
               "retryable" => 0,
               "unacknowledged" => 1,
               "drained" => 2
             }}} = drain_with_mutation_spool()
  end

  test "dead spool exit during selection is returned without crashing the caller", %{tmp_dir: dir} do
    {:ok, dead_spool} = Spool.start_link(database: Path.join(dir, "dead-selection.db"), name: nil)
    GenServer.stop(dead_spool)

    assert {:error, {:spool_exit, _reason}} = drain(dead_spool)
    assert Process.alive?(self())
  end

  test "spool exception during selection is returned without crashing the caller" do
    Process.put({BoundaryFailureSpool, :selection}, {:raise, "selection exploded"})

    assert {:error, {:spool_exception, %RuntimeError{message: "selection exploded"}}} =
             drain_with_boundary_spool()
  end

  test "acknowledgement exception becomes a truthful spool update failure" do
    Process.put({BoundaryFailureSpool, :events}, [%{"event_id" => "accepted"}])
    Process.put({BoundaryFailureSpool, :acknowledge}, {:raise, "ack exploded"})
    reply_with_results([%{"event_id" => "accepted", "status" => "accepted"}])

    assert {:error,
            {:spool_update_failed, {:spool_exception, %RuntimeError{message: "ack exploded"}},
             %{
               "selected" => 1,
               "acknowledged" => 0,
               "dead_lettered" => 0,
               "retryable" => 0,
               "unacknowledged" => 1,
               "drained" => 0
             }}} = drain_with_boundary_spool()
  end

  test "spool death between selection and acknowledgement is returned with truthful counts", %{
    tmp_dir: dir
  } do
    {:ok, spool} =
      Spool.start_link(database: Path.join(dir, "dead-acknowledgement.db"), name: nil)

    append!(spool, "accepted")

    Process.put({FakeChannel, :reply}, fn payload ->
      GenServer.stop(spool)

      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" => [%{"event_id" => "accepted", "status" => "accepted"}]
       }}
    end)

    assert {:error,
            {:spool_update_failed, {:spool_exit, _reason},
             %{
               "selected" => 1,
               "acknowledged" => 0,
               "dead_lettered" => 0,
               "retryable" => 0,
               "unacknowledged" => 1,
               "drained" => 0
             }}} = drain(spool)
  end

  test "reject exit after one success retains prior mutation counts" do
    events = [
      %{"event_id" => "accepted"},
      %{"event_id" => "permanent-one"},
      %{"event_id" => "permanent-two"}
    ]

    Process.put({BoundaryFailureSpool, :events}, events)
    Process.put({BoundaryFailureSpool, {:reject, 2}}, {:exit, :reject_closed})

    reply_with_results([
      %{"event_id" => "accepted", "status" => "accepted"},
      %{
        "event_id" => "permanent-one",
        "status" => "rejected",
        "retryable" => false,
        "reason" => "bad one"
      },
      %{
        "event_id" => "permanent-two",
        "status" => "rejected",
        "retryable" => false,
        "reason" => "bad two"
      }
    ])

    assert {:error,
            {:spool_update_failed, {:spool_exit, :reject_closed},
             %{
               "selected" => 3,
               "acknowledged" => 1,
               "dead_lettered" => 1,
               "retryable" => 0,
               "unacknowledged" => 1,
               "drained" => 2
             }}} = drain_with_boundary_spool()
  end

  defp drain(spool, overrides \\ []) do
    CaptureUploader.drain_once(
      Keyword.merge(
        [
          spool: spool,
          spool_module: Spool,
          channel: self(),
          channel_module: FakeChannel,
          host_id: "host"
        ],
        overrides
      )
    )
  end

  defp drain_with_mutation_spool do
    CaptureUploader.drain_once(
      spool: self(),
      spool_module: MutationFailureSpool,
      channel: self(),
      channel_module: FakeChannel,
      host_id: "host"
    )
  end

  defp drain_with_boundary_spool do
    CaptureUploader.drain_once(
      spool: self(),
      spool_module: BoundaryFailureSpool,
      channel: self(),
      channel_module: FakeChannel,
      host_id: "host"
    )
  end

  defp reply_with_results(results) do
    Process.put({FakeChannel, :reply}, fn payload ->
      {:ok, %{"batch_id" => payload["batch_id"], "results" => results}}
    end)
  end

  defp append!(spool, event_id) do
    assert {:ok, _event} = Spool.append(spool, attrs(event_id))
  end

  defp pending(spool), do: Spool.next_batch(spool, 100, 512 * 1024)

  defp start_spool!(path) do
    start_supervised!(
      {Spool, database: path, name: nil, id: {:spool, System.unique_integer([:positive])}}
    )
  end

  defp attrs(event_id) do
    payload = %{"message" => "payload #{event_id}"}
    {payload, privacy} = PrivacyFilter.filter(payload)

    %{
      event_id: event_id,
      schema_version: 1,
      host_id: "host",
      agent_id: "agent",
      integration: "codex",
      session_id: "session-#{event_id}",
      event_type: "agent.prompt.submitted",
      occurred_at: "2026-08-03T10:00:00Z",
      captured_at: "2026-08-03T10:00:00.010Z",
      idempotency_key: "idempotency-#{event_id}",
      payload_hash: EventEnvelope.payload_hash(payload),
      privacy: privacy,
      payload: payload
    }
  end
end
