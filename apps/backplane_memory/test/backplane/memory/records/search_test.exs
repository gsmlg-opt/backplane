defmodule Backplane.Memory.Records.SearchTest do
  use Backplane.Memory.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Backplane.Memory.Embedding.CircuitBreaker
  alias Backplane.Memory.{EmbeddingStub, Record, Records}
  alias Backplane.Memory.Workers.EmbedRecordsWorker

  setup do
    CircuitBreaker.reset()
    HTTP.Test.verify_on_exit!()

    on_exit(fn ->
      Application.delete_env(:backplane_memory, :embed_model)
      Application.delete_env(:backplane_memory, :embedding_http_options)
      CircuitBreaker.reset()
    end)
  end

  defp configure(fixture) do
    HTTP.Test.stub(EmbeddingStub, fixture)
    Application.put_env(:backplane_memory, :embed_model, "test-embed")

    Application.put_env(:backplane_memory, :embedding_http_options,
      adapter: {HTTP.Test, EmbeddingStub}
    )
  end

  defp remember!(content, extra \\ %{}) do
    {:ok, r} = Records.remember(Map.merge(%{"content" => content, "writer" => "agent"}, extra))
    r
  end

  defp ids(records), do: Enum.map(records, & &1.id)

  test "vector-only neighbour is returned when configured, not when unconfigured" do
    far = remember!("completely unrelated words axis:7")
    near = remember!("nothing in common here axis:0")

    configure(&EmbeddingStub.plug/1)
    :ok = EmbedRecordsWorker.perform(%Styx.Job{args: %{}})

    # query text "axis:0" has no keyword overlap with `near` beyond the axis token; use a
    # query whose only link is the vector.
    # Both are embedded; the nearest vector ranks first, so limit 1 keeps only `near`.
    assert [near.id] == ids(Records.search("zzqq", %{"limit" => 1}))
    assert far.id in ids(Records.search("zzqq", %{}))

    Application.delete_env(:backplane_memory, :embed_model)
    Application.delete_env(:backplane_memory, :embedding_http_options)
    assert Records.search("zzqq", %{}) == []
  end

  describe "ranking" do
    test "a fresh exact match outranks older embedded weak matches before it is embedded" do
      configure(&EmbeddingStub.plug/1)

      older =
        for n <- 1..12 do
          remember!("launchd job job#{n} is loaded on p4 listening port #{n} axis:0", %{
            "subjects" => [%{"type" => "service", "key" => "job#{n}"}]
          })
        end

      :ok = EmbedRecordsWorker.perform(%Styx.Job{args: %{}})

      # Stored while embeddings are unavailable, so it has no vector yet.
      Application.delete_env(:backplane_memory, :embed_model)
      fresh = remember!("Acceptance: the billing service on host acc-A listens on port 8443.")
      configure(&EmbeddingStub.plug/1)

      assert is_nil(repo().one(from(r in Record, where: r.id == ^fresh.id, select: r.embedding)))
      assert Enum.all?(older, &(&1.id != fresh.id))

      assert [first | _] = Records.search("billing service port axis:0", %{})
      assert first.id == fresh.id
    end

    test "query terms do not match a subject's type prefix" do
      typed =
        remember!("alpha runs nightly", %{
          "subjects" => [%{"type" => "service", "key" => "alpha"}]
        })

      keyed =
        remember!("runs nightly", %{"subjects" => [%{"type" => "service", "key" => "billing"}]})

      refute typed.id in ids(Records.search("service", %{}))
      assert keyed.id in ids(Records.search("billing", %{}))
    end

    test "full-text fallback ranks records matching more query terms first" do
      newer = remember!("only the service word here")

      older =
        remember!("billing and port are both here", %{
          "observed_at" => DateTime.add(DateTime.utc_now(), -86_400, :second)
        })

      assert [first | rest] = Records.search("billing service port", %{})
      assert first.id == older.id
      assert newer.id in ids(rest)
    end
  end

  test "proxy 500 on query embedding falls back to full-text" do
    r = remember!("zebra crossing notes")
    configure(&EmbeddingStub.error_plug/1)

    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :debug], fn ->
        assert [r.id] == ids(Records.search("zebra", %{}))
      end)

    assert log =~ "embedding"
  end

  test "open breaker skips embedding and uses full-text" do
    r = remember!("giraffe notes")
    configure(fn _request -> flunk("breaker open; proxy must not be called") end)
    for _ <- 1..5, do: CircuitBreaker.record_failure()
    assert [r.id] == ids(Records.search("giraffe", %{}))
  end

  test "a blank query never calls the proxy and does not count as a breaker failure" do
    configure(fn _request -> flunk("blank query must not be embedded") end)

    for _ <- 1..10, do: assert(Records.search("   ", %{}) == [])

    assert CircuitBreaker.allow_request?()
  end

  test "records loaded through the schema do not carry the embedding vector" do
    a = remember!("alpha axis:3")
    configure(&EmbeddingStub.plug/1)
    assert :ok = EmbedRecordsWorker.perform(%Styx.Job{args: %{}})

    assert %{rows: [[true]]} =
             repo().query!("SELECT embedding IS NOT NULL FROM memory_records WHERE id = $1", [
               Ecto.UUID.dump!(a.id)
             ])

    assert %Record{embedding: nil} = repo().get!(Record, a.id)
    assert [%Record{embedding: nil}] = Records.search("alpha", %{})
  end

  test "worker fills embeddings for active records" do
    a = remember!("alpha axis:3", %{"title" => "T"})
    gone = remember!("beta axis:4")
    {:ok, _} = Records.forget(gone.id, "x")
    configure(&EmbeddingStub.plug/1)

    assert :ok = EmbedRecordsWorker.perform(%Styx.Job{args: %{}})

    assert %{rows: [[true]]} =
             repo().query!("SELECT embedding IS NOT NULL FROM memory_records WHERE id = $1", [
               Ecto.UUID.dump!(a.id)
             ])

    assert %{rows: [[false]]} =
             repo().query!("SELECT embedding IS NOT NULL FROM memory_records WHERE id = $1", [
               Ecto.UUID.dump!(gone.id)
             ])
  end

  test "worker leaves embedding null and warns on wrong-dimension vectors" do
    a = remember!("alpha")
    configure(&EmbeddingStub.short_plug/1)

    log = capture_log(fn -> assert :ok = EmbedRecordsWorker.perform(%Styx.Job{args: %{}}) end)

    assert log =~ "embedding"

    assert %{rows: [[false]]} =
             repo().query!("SELECT embedding IS NOT NULL FROM memory_records WHERE id = $1", [
               Ecto.UUID.dump!(a.id)
             ])

    assert %Record{} = repo().get!(Record, a.id)
  end

  test "worker does nothing when unconfigured" do
    remember!("alpha")
    assert :ok = EmbedRecordsWorker.perform(%Styx.Job{args: %{}})
  end
end
