defmodule Backplane.Memory.Records.SearchTest do
  use Backplane.Memory.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Backplane.Memory.Embedding.CircuitBreaker
  alias Backplane.Memory.{EmbeddingStub, Record, Records}
  alias Backplane.Memory.Workers.EmbedRecordsWorker

  setup do
    CircuitBreaker.reset()

    on_exit(fn ->
      Application.delete_env(:backplane_memory, :embed_model)
      Application.delete_env(:backplane_memory, :embedding_req_options)
      CircuitBreaker.reset()
    end)
  end

  defp configure(plug) do
    Application.put_env(:backplane_memory, :embed_model, "test-embed")
    Application.put_env(:backplane_memory, :embedding_req_options, plug: plug)
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
    Application.delete_env(:backplane_memory, :embedding_req_options)
    assert Records.search("zzqq", %{}) == []
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
    configure(fn _conn -> flunk("breaker open; proxy must not be called") end)
    for _ <- 1..5, do: CircuitBreaker.record_failure()
    assert [r.id] == ids(Records.search("giraffe", %{}))
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
