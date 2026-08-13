defmodule Backplane.HostAgent.Memory.SpoolEncryptionTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{EventEnvelope, PrivacyFilter, Store}
  alias Backplane.HostAgent.Memory.Spool.Cipher
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool
  alias Turso.Result

  @moduletag :tmp_dir

  setup do
    env_name = "BACKPLANE_CAPTURE_SPOOL_TEST_KEY_#{System.unique_integer([:positive])}"

    on_exit(fn -> System.delete_env(env_name) end)

    %{env_name: env_name}
  end

  test "ciphertext uses random nonces and authenticates the event identity", %{env_name: env_name} do
    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))
    assert {:ok, cipher} = Cipher.resolve(env_name)

    first = Cipher.encrypt(cipher, "same plaintext", "event-one")
    second = Cipher.encrypt(cipher, "same plaintext", "event-one")

    refute first == second
    assert {:ok, "same plaintext"} = Cipher.decrypt(cipher, first, "event-one")

    assert {:error, :spool_encryption_authentication_failed} =
             Cipher.decrypt(cipher, first, "different-event")
  end

  test "key verifier uses authenticated metadata identity distinct from event envelopes", %{
    env_name: env_name
  } do
    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))
    assert {:ok, cipher} = Cipher.resolve(env_name)

    verifier = Cipher.encrypt_verifier(cipher)

    assert :ok = Cipher.verify(cipher, verifier)

    assert {:error, :spool_encryption_authentication_failed} =
             Cipher.decrypt(cipher, verifier, "encryption-key-verifier")
  end

  test "empty encrypted spool requires its configured key across reopen", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "empty-encrypted.db")
    original_key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env(env_name, original_key)

    path |> start_spool!(encryption_key_env: env_name) |> stop_spool()

    assert_start_error(path, [], :spool_encryption_required)

    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))

    assert_start_error(
      path,
      [encryption_key_env: env_name],
      :spool_encryption_authentication_failed
    )

    System.put_env(env_name, original_key)
    reopened = start_spool!(path, encryption_key_env: env_name)

    assert {:ok, _event} =
             Spool.append(reopened, attrs("after-empty", "after-empty-idem", "secret"))

    assert [stored] = raw_envelopes(reopened)
    assert String.starts_with?(stored, "bpenc:v1:")
    refute stored =~ "secret"
  end

  test "established empty encrypted spool rejects a deleted verifier for every key", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "empty-missing-verifier.db")
    original_key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env(env_name, original_key)
    path |> start_spool!(encryption_key_env: env_name) |> stop_spool()

    delete_verifier!(path)

    assert_start_error(path, [], :spool_encryption_verifier_missing)

    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))

    assert_start_error(
      path,
      [encryption_key_env: env_name],
      :spool_encryption_verifier_missing
    )

    System.put_env(env_name, original_key)

    assert_start_error(
      path,
      [encryption_key_env: env_name],
      :spool_encryption_verifier_missing
    )

    assert_verifier_missing(path)
  end

  test "established encrypted spool rejects a corrupt verifier", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "corrupt-verifier.db")
    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))
    path |> start_spool!(encryption_key_env: env_name) |> stop_spool()

    update_metadata!(path, "encryption_key_verifier_v1", "bpenc:v1:not-valid-base64")

    assert_start_error(
      path,
      [encryption_key_env: env_name],
      :spool_encryption_authentication_failed
    )
  end

  test "encrypted spool remains key-bound after all event rows are compacted", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "compacted-encrypted.db")
    original_key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env(env_name, original_key)
    spool = start_spool!(path, encryption_key_env: env_name, compaction_grace_ms: 0)

    assert {:ok, _event} = Spool.append(spool, attrs("compacted", "compacted-idem", "secret"))
    assert :ok = Spool.acknowledge(spool, ["compacted"])
    send(spool, :compact_acknowledged)
    :sys.get_state(spool)
    assert [] = raw_envelopes(spool)
    stop_spool(spool)

    assert_start_error(path, [], :spool_encryption_required)
    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))

    assert_start_error(
      path,
      [encryption_key_env: env_name],
      :spool_encryption_authentication_failed
    )

    delete_verifier!(path)

    assert_start_error(
      path,
      [encryption_key_env: env_name],
      :spool_encryption_verifier_missing
    )

    System.put_env(env_name, original_key)

    assert_start_error(
      path,
      [encryption_key_env: env_name],
      :spool_encryption_verifier_missing
    )

    assert_verifier_missing(path)
  end

  test "legacy encrypted rows backfill a key verifier after authenticating the row", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "legacy-encrypted.db")
    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))
    assert {:ok, cipher} = Cipher.resolve(env_name)
    plaintext = start_spool!(path)

    assert {:ok, event} =
             Spool.append(plaintext, attrs("legacy-encrypted", "legacy-idem", "secret"))

    %{store: store} = :sys.get_state(plaintext)
    [json] = raw_envelopes(plaintext)
    encrypted = Cipher.encrypt(cipher, json, event["event_id"])

    assert {:ok, _result} =
             Store.execute(
               store,
               "UPDATE capture_event_spool SET envelope_json = ? WHERE event_id = ?",
               [encrypted, event["event_id"]]
             )

    stop_spool(plaintext)
    verified = start_spool!(path, encryption_key_env: env_name)
    assert [^event] = Spool.next_batch(verified, 10, 100_000)
    %{store: verified_store} = :sys.get_state(verified)

    assert {:ok, %Result{rows: [%{"value" => verifier}]}} =
             Store.query(
               verified_store,
               "SELECT value FROM capture_spool_metadata WHERE name = ?",
               ["encryption_key_verifier_v1"]
             )

    assert :ok = Cipher.verify(cipher, verifier)
  end

  test "configured encryption protects new rows and preserves spool behavior across reopen", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "encrypted.db")
    key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env(env_name, key)

    spool = start_spool!(path, encryption_key_env: env_name, max_spool_bytes: 1_500)
    first_attrs = attrs("encrypted-1", "idem-1", "private-marker-one")
    second_attrs = attrs("encrypted-2", "idem-2", "private-marker-two")

    assert {:ok, first} = Spool.append(spool, first_attrs)
    assert {:ok, second} = Spool.append(spool, second_attrs)
    assert {:duplicate, ^first} = Spool.append(spool, first_attrs)
    assert [^first, ^second] = Spool.next_batch(spool, 10, 100_000)
    assert %{pending_depth: 2, pending_bytes: pending_bytes} = Spool.stats(spool)

    assert pending_bytes ==
             byte_size(EventEnvelope.encode!(first)) + byte_size(EventEnvelope.encode!(second))

    [stored_first, stored_second] = raw_envelopes(spool)
    assert String.starts_with?(stored_first, "bpenc:v1:")
    assert String.starts_with?(stored_second, "bpenc:v1:")
    refute stored_first =~ "private-marker-one"
    refute stored_second =~ "private-marker-two"
    refute stored_first == stored_second
    refute inspect(:sys.get_state(spool)) =~ key

    stop_spool(spool)
    reopened = start_spool!(path, encryption_key_env: env_name)
    assert [^first, ^second] = Spool.next_batch(reopened, 10, 100_000)
    stop_spool(reopened)
    refute File.read!(path) =~ "private-marker-one"
    refute File.read!(path) =~ "private-marker-two"
  end

  test "enabling encryption transactionally migrates existing plaintext rows", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "migration.db")
    plaintext = start_spool!(path)
    assert {:ok, event} = Spool.append(plaintext, attrs("legacy", "legacy-idem", "legacy-marker"))
    assert [raw] = raw_envelopes(plaintext)
    assert raw =~ "legacy-marker"
    stop_spool(plaintext)

    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))
    encrypted = start_spool!(path, encryption_key_env: env_name)
    assert [stored] = raw_envelopes(encrypted)
    assert String.starts_with?(stored, "bpenc:v1:")
    refute stored =~ "legacy-marker"
    refute_sqlite_artifacts(path, "legacy-marker")
    assert [^event] = Spool.next_batch(encrypted, 10, 100_000)
    stop_spool(encrypted)
    refute_sqlite_artifacts(path, "legacy-marker")

    assert {:error, :spool_encryption_required} =
             Spool.start_link(database: path, name: nil)
  end

  test "missing invalid and wrong keys fail closed with explicit errors", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    missing_path = Path.join(dir, "missing.db")

    assert {:error, {:spool_encryption_key_missing, ^env_name}} =
             Spool.start_link(database: missing_path, name: nil, encryption_key_env: env_name)

    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(31)))

    assert {:error, {:invalid_spool_encryption_key, :expected_32_bytes}} =
             Spool.start_link(
               database: Path.join(dir, "invalid.db"),
               name: nil,
               encryption_key_env: env_name
             )

    path = Path.join(dir, "wrong-key.db")
    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))
    spool = start_spool!(path, encryption_key_env: env_name)
    assert {:ok, _event} = Spool.append(spool, attrs("wrong-key", "wrong-key-idem", "secret"))
    stop_spool(spool)

    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))

    assert {:error, :spool_encryption_authentication_failed} =
             Spool.start_link(database: path, name: nil, encryption_key_env: env_name)
  end

  test "encrypted spool preserves capacity ACK retry dead-letter behavior and counters", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))

    spool =
      start_spool!(Path.join(dir, "transport-state.db"),
        encryption_key_env: env_name,
        max_spool_bytes: 700,
        retry_base_ms: 1
      )

    assert {:ok, _first} = Spool.append(spool, attrs("first", "first-idem", "first"))

    assert {:error, :spool_full} =
             Spool.append(spool, attrs("second", "second-idem", "second"))

    assert :ok = Spool.acknowledge(spool, ["first"])
    assert {:ok, second} = Spool.append(spool, attrs("second", "second-idem", "second"))
    assert :ok = Spool.reject(spool, "second", "offline", false)
    assert {:ok, %{state: :pending, attempts: 1}} = Spool.event_status(spool, "second")
    assert %{pending_depth: 1, retry_count: 1, rejected_count: 1} = Spool.stats(spool)

    assert :ok = Spool.reject(spool, "second", "invalid", true)

    assert {:ok, %{state: :dead_letter, attempts: 2}} =
             Spool.event_status(spool, "second")

    assert %{pending_depth: 0, dead_letter_count: 1, retry_count: 1, rejected_count: 2} =
             Spool.stats(spool)

    assert [] = Spool.next_batch(spool, 10, 100_000)
    assert second["event_id"] == "second"
  end

  test "encrypted restart retries checkpoint cleanup after an interrupted migration", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "interrupted-checkpoint.db")
    plaintext = start_spool!(path)
    assert {:ok, event} = Spool.append(plaintext, attrs("interrupted", "idem", "wal-marker"))
    stop_spool(plaintext)

    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))

    assert {:error, {:spool_encryption_maintenance_failed, :simulated_interruption}} =
             Spool.start_link(
               database: path,
               name: nil,
               encryption_key_env: env_name,
               checkpoint_fun: fn _store -> {:error, :simulated_interruption} end
             )

    owner = self()

    checkpoint_fun = fn store ->
      send(owner, :checkpoint_retried)

      case Store.query(store, "PRAGMA wal_checkpoint(TRUNCATE)") do
        {:ok, %Result{rows: [%{"busy" => busy}]}} when busy in [0, "0"] -> :ok
        {:ok, %Result{rows: []}} -> :ok
        other -> {:error, {:unexpected_checkpoint_result, other}}
      end
    end

    recovered =
      start_spool!(path, encryption_key_env: env_name, checkpoint_fun: checkpoint_fun)

    assert_receive :checkpoint_retried
    assert [^event] = Spool.next_batch(recovered, 10, 100_000)
    refute_sqlite_artifacts(path, "wal-marker")
    stop_spool(recovered)
    refute_sqlite_artifacts(path, "wal-marker")
  end

  test "migration scrubs a large plaintext payload from main and WAL artifacts", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "large-migration.db")
    marker = "overflow-plaintext-marker"
    plaintext = start_spool!(path, max_spool_bytes: 2 * 1024 * 1024)

    large = attrs("large", "large-idem", String.duplicate(marker, 8_000))
    assert {:ok, event} = Spool.append(plaintext, large)
    stop_spool(plaintext)
    assert Enum.any?(sqlite_artifacts(path), &(File.read!(&1) =~ marker))

    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))
    encrypted = start_spool!(path, encryption_key_env: env_name)
    assert [^event] = Spool.next_batch(encrypted, 10, 2 * 1024 * 1024)
    refute_sqlite_artifacts(path, marker)
    stop_spool(encrypted)
    refute_sqlite_artifacts(path, marker)
  end

  test "raising checkpoint leaves no orphaned Store process", %{
    tmp_dir: dir,
    env_name: env_name
  } do
    path = Path.join(dir, "raising-checkpoint.db")
    plaintext = start_spool!(path)
    assert {:ok, _event} = Spool.append(plaintext, attrs("raising", "raising-idem", "marker"))
    stop_spool(plaintext)

    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))
    owner = self()

    assert {:error, _reason} =
             Spool.start_link(
               database: path,
               name: nil,
               encryption_key_env: env_name,
               checkpoint_fun: fn store ->
                 send(owner, {:checkpoint_store, store})
                 raise "checkpoint exploded"
               end
             )

    assert_receive {:checkpoint_store, store}
    store_ref = Process.monitor(store)
    refute Process.alive?(store)
    assert_receive {:DOWN, ^store_ref, :process, ^store, _reason}
  end

  test "encrypted reopen reseeds a missing redaction counter without parsing ciphertext as JSON",
       %{
         tmp_dir: dir,
         env_name: env_name
       } do
    path = Path.join(dir, "counter-recovery.db")
    System.put_env(env_name, Base.encode64(:crypto.strong_rand_bytes(32)))
    spool = start_spool!(path, encryption_key_env: env_name)

    redacted =
      attrs("redacted", "redacted-idem", "public")
      |> Map.put(:payload, %{"api_key" => "must-not-survive"})

    assert {:ok, _event} = Spool.append(spool, redacted)
    assert %{redacted_count: 1} = Spool.stats(spool)
    stop_spool(spool)

    assert {:ok, store} = Store.start_link(database: path)

    assert {:ok, _result} =
             Store.execute(
               store,
               "DELETE FROM capture_spool_counters WHERE name = 'redacted_count'"
             )

    GenServer.stop(store)

    reopened = start_spool!(path, encryption_key_env: env_name)
    assert %{captured_count: 1, redacted_count: 1} = Spool.stats(reopened)
  end

  defp raw_envelopes(spool) do
    %{store: store} = :sys.get_state(spool)

    assert {:ok, %Result{rows: rows}} =
             Store.query(
               store,
               "SELECT envelope_json FROM capture_event_spool ORDER BY enqueue_id"
             )

    Enum.map(rows, & &1["envelope_json"])
  end

  defp refute_sqlite_artifacts(path, marker) do
    for artifact <- sqlite_artifacts(path) do
      refute File.read!(artifact) =~ marker,
             "plaintext marker remained in SQLite artifact #{artifact}"
    end
  end

  defp sqlite_artifacts(path) do
    Enum.filter([path, path <> "-wal", path <> "-shm"], &File.exists?/1)
  end

  defp start_spool!(path, opts \\ []) do
    {:ok, spool} = Spool.start_link(Keyword.merge([database: path, name: nil], opts))
    on_exit(fn -> if Process.alive?(spool), do: stop_spool(spool) end)
    spool
  end

  defp stop_spool(spool) do
    if Process.alive?(spool), do: GenServer.stop(spool)
  end

  defp assert_start_error(path, opts, expected) do
    case Spool.start_link(Keyword.merge([database: path, name: nil], opts)) do
      {:error, ^expected} ->
        :ok

      {:ok, spool} ->
        stop_spool(spool)
        flunk("expected startup error #{inspect(expected)}, but the spool started")

      {:error, actual} ->
        flunk("expected startup error #{inspect(expected)}, got: #{inspect(actual)}")
    end
  end

  defp delete_verifier!(path) do
    assert {:ok, store} = Store.start_link(database: path)

    assert {:ok, %Result{rows: [%{"value" => "1"}]}} =
             Store.query(
               store,
               "SELECT value FROM capture_spool_metadata WHERE name = ?",
               ["encryption_rewrite_version"]
             )

    assert {:ok, _result} =
             Store.execute(
               store,
               "DELETE FROM capture_spool_metadata WHERE name = ?",
               ["encryption_key_verifier_v1"]
             )

    GenServer.stop(store)
  end

  defp assert_verifier_missing(path) do
    assert {:ok, store} = Store.start_link(database: path)

    assert {:ok, %Result{rows: []}} =
             Store.query(
               store,
               "SELECT value FROM capture_spool_metadata WHERE name = ?",
               ["encryption_key_verifier_v1"]
             )

    GenServer.stop(store)
  end

  defp update_metadata!(path, name, value) do
    assert {:ok, store} = Store.start_link(database: path)

    assert {:ok, _result} =
             Store.execute(
               store,
               "UPDATE capture_spool_metadata SET value = ? WHERE name = ?",
               [value, name]
             )

    GenServer.stop(store)
  end

  defp attrs(event_id, idempotency_key, marker) do
    payload = %{"message" => marker}
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
      idempotency_key: idempotency_key,
      payload_hash: EventEnvelope.payload_hash(payload),
      privacy: privacy,
      payload: payload
    }
  end
end
