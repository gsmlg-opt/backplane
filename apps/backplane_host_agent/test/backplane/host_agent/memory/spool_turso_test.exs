defmodule Backplane.HostAgent.Memory.SpoolTursoTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.{EventEnvelope, PrivacyFilter}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool

  @moduletag :tmp_dir

  test "spool behaviour callbacks accept an explicit spool instance" do
    assert {:ok, callbacks} = Code.Typespec.fetch_callbacks(Backplane.HostAgent.Memory.Spool)

    callback_arities = MapSet.new(callbacks, fn {{name, arity}, _spec} -> {name, arity} end)

    assert callback_arities ==
             MapSet.new(
               append: 2,
               next_batch: 3,
               acknowledge: 2,
               reject: 4,
               stats: 1
             )
  end

  test "filters raw payload before durable append and preserves it across reopen", %{tmp_dir: dir} do
    path = Path.join(dir, "capture.db")
    spool = start_spool!(path)

    raw_payload = %{
      "nested" => %{"api_key" => "raw-api-secret"},
      "message" => "public <private>raw private text</private> Bearer raw-token-value"
    }

    raw_attrs =
      attrs("e1", "i1", "s1")
      |> Map.put(:payload, raw_payload)
      |> Map.put(:privacy, %{"filtered" => false})
      |> Map.put(:payload_hash, "sha256:caller-controlled")

    assert {:ok, first} = Spool.append(spool, raw_attrs)
    GenServer.stop(spool)

    reopened = start_spool!(path)
    assert [^first] = Spool.next_batch(reopened, 10, 100_000)
    encoded = EventEnvelope.encode!(first)
    refute encoded =~ "raw-api-secret"
    refute encoded =~ "raw private text"
    refute encoded =~ "raw-token-value"
    assert first["privacy"]["filtered"]
    assert first["privacy"]["redaction_count"] == 2
    assert first["privacy"]["private_blocks_removed"] == 1
    assert first["payload_hash"] == EventEnvelope.payload_hash(first["payload"])
  end

  test "filters and allowlists trace metadata before durable append", %{tmp_dir: dir} do
    path = Path.join(dir, "trace-privacy.db")
    spool = start_spool!(path)
    github_token = "ghp_" <> String.duplicate("a", 36)

    raw_attrs =
      attrs("trace-event", "trace-key", "trace-session")
      |> Map.put(:trace, %{
        "correlation_id" => "Bearer raw-trace-token",
        "causation_id" => "0191f28d-8f72-7db1-86cf-5be337f58d11",
        "authorization" => github_token,
        "notes" => "<private>trace-private-text</private>"
      })

    assert {:ok, event} = Spool.append(spool, raw_attrs)
    GenServer.stop(spool)

    reopened = start_spool!(path)
    assert [^event] = Spool.next_batch(reopened, 10, 100_000)
    encoded = EventEnvelope.encode!(event)
    refute encoded =~ "raw-trace-token"
    refute encoded =~ github_token
    refute encoded =~ "trace-private-text"
    assert event["trace"] == %{"causation_id" => raw_attrs.trace["causation_id"]}
    assert event["privacy"]["redaction_count"] == 2
    assert event["privacy"]["private_blocks_removed"] == 1
  end

  test "same event id is a duplicate and preserves the first envelope", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "event-duplicate.db"))
    assert {:ok, first} = Spool.append(spool, attrs("same", "first-key", "s1"))
    assert {:duplicate, ^first} = Spool.append(spool, attrs("same", "second-key", "s1"))
    assert [^first] = Spool.next_batch(spool, 10, 100_000)
    assert %{pending_depth: 1} = Spool.stats(spool)
  end

  test "same idempotency key is a duplicate and preserves the first envelope", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "idempotency-duplicate.db"))
    assert {:ok, first} = Spool.append(spool, attrs("first-event", "same-key", "s1"))

    same_evidence =
      attrs("second-event", "same-key", "s1")
      |> Map.put(:payload, %{"message" => "payload first-event"})

    assert {:duplicate, ^first} =
             Spool.append(spool, same_evidence)

    assert [^first] = Spool.next_batch(spool, 10, 100_000)
    assert %{pending_depth: 1} = Spool.stats(spool)
  end

  test "identifier reuse with changed evidence is an identity collision", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "changed-collision.db"))
    assert {:ok, _first} = Spool.append(spool, attrs("same-event", "first-key", "s1"))

    changed =
      attrs("same-event", "second-key", "s1")
      |> Map.put(:payload, %{"message" => "changed evidence"})

    assert {:error, :identity_collision} = Spool.append(spool, changed)
    assert %{pending_depth: 1} = Spool.stats(spool)
  end

  test "crossed event and idempotency identifiers are an identity collision", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "crossed-collision.db"))
    assert {:ok, _} = Spool.append(spool, attrs("event-a", "key-a", "s1"))
    assert {:ok, _} = Spool.append(spool, attrs("event-b", "key-b", "s1"))
    assert {:error, :identity_collision} = Spool.append(spool, attrs("event-a", "key-b", "s1"))
    assert %{pending_depth: 2} = Spool.stats(spool)
  end

  test "malformed event types return errors without stopping the spool", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "malformed.db"))

    for {malformed, n} <- Enum.with_index([123, %{"bad" => true}, nil]) do
      malformed_attrs = attrs("bad-#{n}", "bad-key-#{n}", "s1") |> Map.put(:event_type, malformed)
      assert {:error, errors} = Spool.append(spool, malformed_attrs)
      assert :event_type in errors
      assert Process.alive?(spool)
    end
  end

  test "normal spool stop terminates its owned store before reopen", %{tmp_dir: dir} do
    path = Path.join(dir, "lifecycle.db")
    spool = start_spool!(path)
    assert {:ok, _} = Spool.append(spool, attrs("acked", "acked", "s1"))
    assert :ok = Spool.acknowledge(spool, ["acked"])
    %{store: store, compaction_timer: timer} = :sys.get_state(spool)
    store_ref = Process.monitor(store)
    GenServer.stop(spool, :normal)
    assert_receive {:DOWN, ^store_ref, :process, ^store, _reason}, 1_000
    assert Process.read_timer(timer) == false
    assert _reopened = start_spool!(path)
  end

  test "an oversized head is explicit instead of masquerading as an empty queue", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "oversized.db"))

    oversized =
      attrs("oversized", "oversized", "s1")
      |> Map.put(:payload, %{"message" => String.duplicate("x", 2_000)})

    assert {:ok, event} = Spool.append(spool, oversized)
    assert {:oversized, ^event} = Spool.next_batch(spool, 10, 1_000)
  end

  test "full capacity rejects append without claiming success", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "capacity.db"), max_spool_bytes: 700)

    assert {:ok, _} = Spool.append(spool, attrs("first", "first", "s1"))
    assert {:error, :spool_full} = Spool.append(spool, attrs("second", "second", "s1"))
    assert %{pending_depth: 1} = Spool.stats(spool)
    assert :ok = Spool.acknowledge(spool, ["first"])
    assert {:ok, _} = Spool.append(spool, attrs("second", "second", "s1"))
  end

  test "retryable failures use due-time selection with increasing bounded backoff", %{
    tmp_dir: dir
  } do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-08-04 00:00:00Z] end)
    now = fn -> Agent.get(clock, & &1) end

    spool =
      start_spool!(Path.join(dir, "backoff.db"),
        clock: now,
        jitter_fun: fn _delay -> 0 end,
        retry_base_ms: 100,
        retry_max_ms: 250
      )

    assert {:ok, event} = Spool.append(spool, attrs("retry", "retry", "s1"))
    assert :ok = Spool.reject(spool, "retry", "offline", false)
    assert [] = Spool.next_batch(spool, 10, 100_000)
    assert {:ok, %{attempts: 1, next_attempt_at: first_due}} = Spool.event_status(spool, "retry")
    assert first_due == "2026-08-04T00:00:00.100000Z"

    advance_clock(clock, 100)
    assert [^event] = Spool.next_batch(spool, 10, 100_000)
    assert :ok = Spool.reject(spool, "retry", "offline", false)
    assert {:ok, %{attempts: 2, next_attempt_at: second_due}} = Spool.event_status(spool, "retry")
    assert second_due == "2026-08-04T00:00:00.300000Z"

    advance_clock(clock, 200)
    assert [^event] = Spool.next_batch(spool, 10, 100_000)
    assert :ok = Spool.reject(spool, "retry", "offline", false)
    assert {:ok, %{attempts: 3, next_attempt_at: third_due}} = Spool.event_status(spool, "retry")
    assert third_due == "2026-08-04T00:00:00.550000Z"
  end

  test "a delayed retry blocks later events only within the same session", %{tmp_dir: dir} do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-08-04 00:00:00Z] end)
    now = fn -> Agent.get(clock, & &1) end

    spool =
      start_spool!(Path.join(dir, "session-order.db"),
        clock: now,
        jitter_fun: fn _delay -> 0 end,
        retry_base_ms: 100
      )

    assert {:ok, first} = Spool.append(spool, attrs("first", "first", "same"))
    assert {:ok, second} = Spool.append(spool, attrs("second", "second", "same"))
    assert {:ok, other} = Spool.append(spool, attrs("other", "other", "other"))
    assert :ok = Spool.reject(spool, "first", "offline", false)

    assert [^other] = Spool.next_batch(spool, 10, 100_000)
    assert :ok = Spool.acknowledge(spool, ["other"])
    advance_clock(clock, 100)
    assert [^first, ^second] = Spool.next_batch(spool, 10, 100_000)
  end

  test "preserves a supplied deterministic import sequence and advances the session counter", %{
    tmp_dir: dir
  } do
    spool = start_spool!(Path.join(dir, "explicit-sequence.db"))

    assert {:ok, imported} =
             Spool.append(spool, Map.put(attrs("imported", "imported", "session"), :sequence, 41))

    assert imported["sequence"] == 41
    assert {:ok, live} = Spool.append(spool, attrs("live", "live", "session"))
    assert live["sequence"] == 42
  end

  test "age warning never deletes unacknowledged events and compaction preserves pending and dead letters",
       %{
         tmp_dir: dir
       } do
    now = fn -> ~U[2026-08-10 00:00:00Z] end

    spool =
      start_spool!(Path.join(dir, "age-compaction.db"),
        clock: now,
        max_event_age_days: 1,
        compaction_batch_size: 10,
        compaction_grace_ms: 0
      )

    assert {:ok, _} = Spool.append(spool, attrs("pending", "pending", "s1"))
    assert {:ok, _} = Spool.append(spool, attrs("dead", "dead", "s1"))
    assert {:ok, _} = Spool.append(spool, attrs("acked", "acked", "s1"))
    assert {:ok, _} = Spool.append(spool, attrs("retried", "retried", "retry-session"))
    assert :ok = Spool.reject(spool, "dead", "offline", false)
    assert :ok = Spool.reject(spool, "dead", "invalid", true)
    assert :ok = Spool.reject(spool, "retried", "offline", false)
    assert :ok = Spool.acknowledge(spool, ["acked", "retried"])

    assert %{age_warning: true, pending_depth: 1, dead_letter_count: 1} = Spool.stats(spool)
    assert eventually(fn -> Spool.event_status(spool, "acked") == {:error, :not_found} end)
    assert %{captured_count: 4, rejected_count: 3, retry_count: 2} = Spool.stats(spool)
    assert {:ok, %{state: :pending, age_warning: true}} = Spool.event_status(spool, "pending")
    assert {:ok, %{state: :dead_letter}} = Spool.event_status(spool, "dead")
  end

  test "default grace schedules owned compaction that runs after an idle deadline", %{
    tmp_dir: dir
  } do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-08-04 00:00:00Z] end)
    now = fn -> Agent.get(clock, & &1) end
    spool = start_spool!(Path.join(dir, "default-grace.db"), clock: now)

    assert {:ok, _} = Spool.append(spool, attrs("acked", "acked", "s1"))
    assert :ok = Spool.acknowledge(spool, ["acked"])
    assert %{compaction_timer: timer} = :sys.get_state(spool)
    assert is_reference(timer)
    assert {:ok, %{state: :acknowledged}} = Spool.event_status(spool, "acked")

    advance_clock(clock, 60_000)
    send(spool, :compact_acknowledged)
    assert eventually(fn -> Spool.event_status(spool, "acked") == {:error, :not_found} end)
    assert %{compaction_timer: nil} = :sys.get_state(spool)
  end

  test "owned compaction drains more than one bounded batch and preserves operator rows", %{
    tmp_dir: dir
  } do
    spool =
      start_spool!(Path.join(dir, "bounded-compaction.db"),
        compaction_grace_ms: 0,
        compaction_batch_size: 2
      )

    for event_id <- ~w(a1 a2 a3 a4 a5 pending dead) do
      assert {:ok, _} = Spool.append(spool, attrs(event_id, event_id, event_id))
    end

    assert :ok = Spool.reject(spool, "dead", "invalid", true)
    assert :ok = Spool.acknowledge(spool, ~w(a1 a2 a3 a4 a5))

    assert eventually(fn ->
             Enum.all?(~w(a1 a2 a3 a4 a5), fn event_id ->
               Spool.event_status(spool, event_id) == {:error, :not_found}
             end)
           end)

    assert {:ok, %{state: :pending}} = Spool.event_status(spool, "pending")
    assert {:ok, %{state: :dead_letter}} = Spool.event_status(spool, "dead")
    assert %{compaction_timer: nil} = :sys.get_state(spool)
  end

  test "restart reschedules compaction when only acknowledged rows remain", %{tmp_dir: dir} do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-08-04 00:00:00Z] end)
    now = fn -> Agent.get(clock, & &1) end
    path = Path.join(dir, "restart-compaction.db")
    opts = [database: path, name: nil, clock: now]

    assert {:ok, spool} = Spool.start_link(opts)
    assert {:ok, _} = Spool.append(spool, attrs("acked", "acked", "s1"))
    assert :ok = Spool.acknowledge(spool, ["acked"])
    GenServer.stop(spool, :normal)

    assert {:ok, reopened} = Spool.start_link(opts)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    assert %{compaction_timer: timer} = :sys.get_state(reopened)
    assert is_reference(timer)

    advance_clock(clock, 60_000)
    send(reopened, :compact_acknowledged)
    assert eventually(fn -> Spool.event_status(reopened, "acked") == {:error, :not_found} end)
  end

  test "non-JSON payloads return errors without stopping the spool", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "invalid-payload.db"))

    invalid_payloads = [
      %{{:tuple, :key} => "value"},
      %{"pid" => self()},
      %{"reference" => make_ref()},
      %{"function" => fn -> :ok end},
      %{"tuple" => {:not, :json}},
      [1 | 2],
      %{"nested" => [1 | 2]}
    ]

    for {payload, n} <- Enum.with_index(invalid_payloads) do
      invalid = attrs("invalid-#{n}", "invalid-#{n}", "s1") |> Map.put(:payload, payload)
      assert {:error, errors} = Spool.append(spool, invalid)
      assert :payload in errors
      assert Process.alive?(spool)
    end
  end

  test "allocates increasing per-session sequences under concurrent append", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "concurrent.db"))

    sequences =
      1..20
      |> Task.async_stream(
        fn n ->
          {:ok, event} = Spool.append(spool, attrs("e#{n}", "i#{n}", "same"))
          event["sequence"]
        end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, sequence} -> sequence end)

    assert Enum.sort(sequences) == Enum.to_list(1..20)
  end

  test "bounds batches by count and encoded bytes and partially acknowledges", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "batch.db"))
    {:ok, e1} = Spool.append(spool, attrs("e1", "i1", "s"))
    {:ok, e2} = Spool.append(spool, attrs("e2", "i2", "s2"))
    {:ok, _e3} = Spool.append(spool, attrs("e3", "i3", "s3"))
    assert [^e1, ^e2] = Spool.next_batch(spool, 2, 100_000)

    two_event_bytes =
      byte_size(EventEnvelope.encode!(e1)) + byte_size(EventEnvelope.encode!(e2))

    assert [^e1] = Spool.next_batch(spool, 10, two_event_bytes)
    assert [^e1] = Spool.next_batch(spool, 10, byte_size(EventEnvelope.encode!(e1)))
    assert :ok = Spool.acknowledge(spool, ["e1"])
    assert [%{"event_id" => "e2"}, %{"event_id" => "e3"}] = Spool.next_batch(spool, 10, 100_000)
  end

  test "tracks retryable and permanent rejection and queue stats", %{tmp_dir: dir} do
    spool = start_spool!(Path.join(dir, "reject.db"))
    {:ok, _} = Spool.append(spool, attrs("e1", "i1", "s"))
    {:ok, _} = Spool.append(spool, attrs("e2", "i2", "s"))
    assert :ok = Spool.reject(spool, "e1", "offline", false)
    assert :ok = Spool.reject(spool, "e2", "invalid", true)
    assert [] = Spool.next_batch(spool, 10, 100_000)

    assert {:ok, %{state: :pending, reason: "offline", attempts: 1}} =
             Spool.event_status(spool, "e1")

    assert {:ok, %{state: :dead_letter, reason: "invalid", attempts: 1}} =
             Spool.event_status(spool, "e2")

    assert %{
             pending_depth: 1,
             retry_count: 1,
             dead_letter_count: 1,
             pending_bytes: bytes,
             oldest_occurred_at: "2026-08-03T10:00:00Z",
             oldest_captured_at: "2026-08-03T10:00:00.010Z",
             oldest_enqueued_at: oldest_enqueued_at
           } = Spool.stats(spool)

    assert bytes > 0
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(oldest_enqueued_at)
  end

  defp start_spool!(path, opts \\ []) do
    start_supervised!(
      {Spool,
       Keyword.merge(
         [database: path, name: nil, id: {:spool, System.unique_integer([:positive])}],
         opts
       )}
    )
  end

  defp advance_clock(clock, milliseconds) do
    Agent.update(clock, &DateTime.add(&1, milliseconds, :millisecond))
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp attrs(event_id, idempotency_key, session_id) do
    payload = %{"message" => "payload #{event_id}"}
    {payload, privacy} = PrivacyFilter.filter(payload)

    %{
      event_id: event_id,
      schema_version: 1,
      host_id: "host",
      agent_id: "agent",
      integration: "codex",
      session_id: session_id,
      event_type: "agent.prompt.submitted",
      occurred_at: "2026-08-03T10:00:00Z",
      captured_at: "2026-08-03T10:00:00.010Z",
      idempotency_key: idempotency_key,
      payload_hash: EventEnvelope.payload_hash(payload),
      privacy: privacy,
      payload: payload
    }
  end
end
