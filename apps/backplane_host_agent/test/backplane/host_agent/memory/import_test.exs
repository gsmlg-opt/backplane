defmodule Backplane.HostAgent.Memory.ImportTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.Import
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool

  @moduletag :tmp_dir

  test "streams Claude Code JSONL into the normal privacy-filtered durable spool", %{tmp_dir: dir} do
    transcript = Path.join(dir, "project/session.jsonl")
    File.mkdir_p!(Path.dirname(transcript))

    File.write!(
      transcript,
      Enum.join(
        [
          Jason.encode!(%{
            "type" => "user",
            "uuid" => "source-user",
            "sessionId" => "session-1",
            "timestamp" => "2026-08-12T01:02:03Z",
            "cwd" => "/safe/project",
            "message" => %{"content" => "Authorization: Bearer super-secret"}
          }),
          "{malformed",
          Jason.encode!(%{
            "type" => "assistant",
            "uuid" => "source-assistant",
            "sessionId" => "session-1",
            "timestamp" => "2026-08-12T01:02:04Z",
            "message" => %{"content" => [%{"type" => "text", "text" => "done"}]}
          })
        ],
        "\n"
      )
    )

    spool = start_spool!(Path.join(dir, "capture.db"))
    opts = [approved_roots: [dir], host_id: "host-1", agent_id: "claude", spool: spool]

    assert {:ok,
            %{
              status: :imported,
              discovered_count: 3,
              imported_count: 2,
              duplicate_count: 0,
              rejected_count: 1,
              source_path_fingerprint: "sha256:" <> _
            }} = Import.run(transcript, opts)

    assert [user, assistant] = Spool.next_batch(spool, 10, 1_000_000)
    assert user["event_type"] == "conversation.user_message"
    assert assistant["event_type"] == "conversation.agent_message"
    assert user["session_id"] == "session-1"
    assert [1, 2] == Enum.map([user, assistant], & &1["sequence"])
    assert user["payload"]["message"]["content"] != "Authorization: Bearer super-secret"
    assert user["privacy"]["redaction_count"] > 0

    assert {:ok, %{status: :unchanged, imported_count: 0, duplicate_count: 2}} =
             Import.run(transcript, opts)

    assert length(Spool.next_batch(spool, 10, 1_000_000)) == 2
  end

  test "enforces the pre-read path policy", %{tmp_dir: dir} do
    root = Path.join(dir, "allowed")
    outside = Path.join(dir, "outside.jsonl")
    secret = Path.join(root, ".ssh/history.jsonl")
    link = Path.join(root, "alias.jsonl")
    File.mkdir_p!(Path.dirname(secret))
    File.write!(outside, "{}")
    File.write!(secret, "{}")
    File.ln_s!(outside, link)

    opts = [
      approved_roots: [root],
      host_id: "host-1",
      spool_module: __MODULE__.NoopSpool,
      spool: nil
    ]

    assert {:error, :outside_approved_roots} = Import.run(outside, opts)
    assert {:error, :sensitive_path} = Import.run(secret, opts)
    assert {:error, :symlink_rejected} = Import.run(link, opts)

    multi_component_secret = Path.join(root, ".config/gcloud/history.jsonl")
    File.mkdir_p!(Path.dirname(multi_component_secret))
    File.write!(multi_component_secret, "must not be read")

    assert {:error, :sensitive_path} = Import.run(multi_component_secret, opts)
    refute_received {:spool_append, _envelope}
  end

  test "enforces traversal, file, entry, and byte caps", %{tmp_dir: dir} do
    one = Path.join(dir, "one.jsonl")
    two = Path.join(dir, "two.jsonl")

    record =
      Jason.encode!(%{"type" => "user", "sessionId" => "s", "message" => %{"content" => "x"}})

    File.write!(one, record <> "\n" <> record)
    File.write!(two, record)

    opts = [
      approved_roots: [dir],
      host_id: "host-1",
      spool_module: __MODULE__.NoopSpool,
      spool: nil
    ]

    assert {:error, :too_many_files} = Import.run(dir, Keyword.put(opts, :max_files, 1))
    assert {:error, :too_many_entries} = Import.run(one, Keyword.put(opts, :max_entries, 1))
    assert {:error, :too_many_bytes} = Import.run(one, Keyword.put(opts, :max_bytes, 2))
  end

  test "rejects self-referential and mutual symlink cycles when symlinks are enabled", %{
    tmp_dir: dir
  } do
    self_link = Path.join(dir, "self")
    first = Path.join(dir, "first")
    second = Path.join(dir, "second")
    File.ln_s!("self", self_link)
    File.ln_s!("second", first)
    File.ln_s!("first", second)

    opts = [
      approved_roots: [dir],
      allow_symlinks: true,
      host_id: "host-1",
      spool_module: __MODULE__.NoopSpool,
      spool: self()
    ]

    assert {:error, :symlink_cycle} = Import.run(self_link, opts)
    assert {:error, :symlink_cycle} = Import.run(first, opts)
    refute_received {:spool_append, _envelope}
  end

  test "fails closed when an approved file is swapped to an outside symlink before opening", %{
    tmp_dir: dir
  } do
    root = Path.join(dir, "allowed")
    transcript = Path.join(root, "session.jsonl")
    outside = Path.join(dir, "outside.jsonl")
    File.mkdir_p!(root)
    File.write!(transcript, Jason.encode!(%{"type" => "user", "sessionId" => "safe"}))

    File.write!(
      outside,
      Jason.encode!(%{
        "type" => "user",
        "sessionId" => "outside",
        "message" => %{"content" => "must never enter the spool"}
      })
    )

    swap = fn ^transcript ->
      File.rm!(transcript)
      File.ln_s!(outside, transcript)
    end

    assert {:error, :file_changed} =
             Import.run(transcript,
               approved_roots: [root],
               host_id: "host-1",
               spool_module: __MODULE__.NoopSpool,
               spool: self(),
               before_file_open: swap
             )

    refute_received {:spool_append, _envelope}
  end

  test "re-import remains byte-stable after acknowledgement and local compaction", %{tmp_dir: dir} do
    transcript = Path.join(dir, "session.jsonl")

    File.write!(
      transcript,
      Jason.encode!(%{
        "type" => "user",
        "uuid" => "durable-source",
        "sessionId" => "durable-session",
        "timestamp" => "2026-08-12T01:02:03Z",
        "message" => %{"content" => "same"}
      })
    )

    spool = start_spool!(Path.join(dir, "compact.db"), compaction_grace_ms: 0)
    opts = [approved_roots: [dir], host_id: "host-1", spool: spool]
    assert {:ok, %{imported_count: 1}} = Import.run(transcript, opts)
    assert [first] = Spool.next_batch(spool, 10, 1_000_000)
    assert :ok = Spool.acknowledge(spool, [first["event_id"]])
    send(spool, :compact_acknowledged)

    assert_eventually(fn ->
      Spool.event_status(spool, first["event_id"]) == {:error, :not_found}
    end)

    assert {:ok, %{status: :unchanged, imported_count: 0, duplicate_count: 1}} =
             Import.run(transcript, opts)

    assert Spool.next_batch(spool, 10, 1_000_000) == []
  end

  test "post-start failure emits one sanitized failed terminal lifecycle", %{tmp_dir: dir} do
    transcript = Path.join(dir, "session.jsonl")
    File.write!(transcript, Jason.encode!(%{"type" => "user", "sessionId" => "s"}))
    owner = self()

    reporter = fn payload ->
      send(owner, {:import_lifecycle, payload})
      :ok
    end

    assert {:error, {:spool_error, {:disk_full, "/private/operator/path"}}} =
             Import.run(transcript,
               approved_roots: [dir],
               host_id: "host-1",
               spool_module: __MODULE__.FailingSpool,
               spool: nil,
               reporter: reporter
             )

    assert_received {:import_lifecycle, %{"action" => "started", "batch_id" => batch_id}}

    assert_received {:import_lifecycle,
                     %{
                       "action" => "failed",
                       "batch_id" => ^batch_id,
                       "error" => "spool_error"
                     }}

    refute_received {:import_lifecycle, %{"action" => "completed"}}
  end

  test "a post-start cap failure emits failed lifecycle", %{tmp_dir: dir} do
    transcript = Path.join(dir, "session.jsonl")
    File.write!(transcript, "{}\n{}")
    owner = self()

    reporter = fn payload ->
      send(owner, {:import_lifecycle, payload})
      :ok
    end

    assert {:error, :too_many_bytes} =
             Import.run(transcript,
               approved_roots: [dir],
               host_id: "host-1",
               max_bytes: 1,
               spool_module: __MODULE__.NoopSpool,
               spool: owner,
               reporter: reporter
             )

    assert_received {:import_lifecycle, %{"action" => "started", "batch_id" => batch_id}}

    assert_received {:import_lifecycle,
                     %{"action" => "failed", "batch_id" => ^batch_id, "error" => "too_many_bytes"}}

    refute_received {:spool_append, _envelope}
  end

  test "a completed reporter exception is contained and followed by failed lifecycle", %{
    tmp_dir: dir
  } do
    transcript = Path.join(dir, "session.jsonl")
    File.write!(transcript, Jason.encode!(%{"type" => "user", "sessionId" => "s"}))
    owner = self()

    reporter = fn
      %{"action" => "completed"} ->
        raise "private /operator/path"

      payload ->
        send(owner, {:import_lifecycle, payload})
        :ok
    end

    assert {:error, {:reporter_exception, RuntimeError}} =
             Import.run(transcript,
               approved_roots: [dir],
               host_id: "host-1",
               spool_module: __MODULE__.NoopSpool,
               spool: owner,
               reporter: reporter
             )

    assert_received {:import_lifecycle, %{"action" => "started", "batch_id" => batch_id}}

    assert_received {:import_lifecycle,
                     %{
                       "action" => "failed",
                       "batch_id" => ^batch_id,
                       "error" => "reporter_exception"
                     }}
  end

  defmodule NoopSpool do
    def append(spool, envelope) do
      if is_pid(spool), do: send(spool, {:spool_append, envelope})
      {:ok, envelope}
    end
  end

  defmodule FailingSpool do
    def append(_spool, _envelope), do: {:error, {:disk_full, "/private/operator/path"}}
  end

  defp start_spool!(path, opts \\ []) do
    start_supervised!(
      {Spool,
       Keyword.merge(
         [database: path, name: nil, id: {:import_spool, System.unique_integer([:positive])}],
         opts
       )}
    )
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
