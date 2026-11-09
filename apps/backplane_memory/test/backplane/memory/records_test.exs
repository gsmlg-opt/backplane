defmodule Backplane.Memory.RecordsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Record, Records}

  defp base(attrs \\ %{}) do
    Map.merge(%{"content" => "some content", "writer" => "agent"}, attrs)
  end

  defp fact(attrs) do
    base(Map.merge(%{"kind" => "fact", "property" => "path"}, attrs))
  end

  @repo_x %{"type" => "repo", "key" => "X"}
  @host_w %{"type" => "host", "key" => "web-01"}

  test "remember/1 stores provenance" do
    at = ~U[2026-01-02 03:04:05.000000Z]
    id1 = Ecto.UUID.generate()

    {:ok, r} =
      Records.remember(
        base(%{
          "title" => "T",
          "writer" => "memory_agent",
          "host_id" => "h1",
          "agent_id" => "a1",
          "integration" => "claude",
          "session_id" => "s1",
          "client_id" => "c1",
          "source_event_ids" => [id1],
          "observed_at" => at,
          "tags" => ["a"],
          "request_key" => "rk"
        })
      )

    r = repo().get!(Record, r.id)
    assert r.status == "active"
    assert r.kind == "note"
    assert r.writer == "memory_agent"

    assert {r.host_id, r.agent_id, r.integration, r.session_id, r.client_id} ==
             {"h1", "a1", "claude", "s1", "c1"}

    assert r.source_event_ids == [id1]
    assert r.observed_at == at
    assert r.request_key == "rk"
  end

  test "remember/1 requires content and writer" do
    assert {:error, cs} = Records.remember(%{})
    assert %{content: _, writer: _} = errors_on(cs)
  end

  test "remember/1 fact supersedes same subject set and property" do
    {:ok, a} = Records.remember(fact(%{"subjects" => [@repo_x, @host_w], "content" => "/srv/x"}))

    {:ok, b} =
      Records.remember(
        fact(%{
          "subjects" => [
            %{"type" => "host", "key" => "WEB-01"},
            %{"type" => "repo", "key" => "x"}
          ],
          "content" => "/opt/x"
        })
      )

    a = repo().get!(Record, a.id)
    assert a.status == "superseded"
    assert a.superseded_by == b.id
    assert b.subject_keys == ["host:web-01", "repo:x"]
    assert {:ok, %{record: %{id: bid}, history: [h]}} = Records.get(b.id)
    assert bid == b.id
    assert h.id == a.id
  end

  test "remember/1 does not supersede other properties, kinds or forgotten facts" do
    {:ok, a} = Records.remember(fact(%{"subjects" => [@repo_x]}))
    {:ok, _} = Records.remember(fact(%{"subjects" => [@repo_x], "property" => "owner"}))
    {:ok, _} = Records.remember(base(%{"subjects" => [@repo_x], "kind" => "note"}))
    assert repo().get!(Record, a.id).status == "active"

    {:ok, _} = Records.forget(a.id, "wrong")
    {:ok, _} = Records.remember(fact(%{"subjects" => [@repo_x], "content" => "new"}))
    assert repo().get!(Record, a.id).status == "forgotten"
  end

  test "remember/1 is idempotent on request_key" do
    {:ok, a} = Records.remember(base(%{"request_key" => "k1"}))
    {:ok, b} = Records.remember(base(%{"request_key" => "k1"}))
    assert a.id == b.id
    assert repo().aggregate(Record, :count) == 1
  end

  test "forget/2" do
    {:ok, a} = Records.remember(base())
    {:ok, f} = Records.forget(a.id, "r1")
    assert f.status == "forgotten"
    assert f.forgotten_reason == "r1"
    assert f.forgotten_at
    assert {:ok, f2} = Records.forget(a.id, "r2")
    assert f2.forgotten_reason == "r1"
    assert {:error, :not_found} = Records.forget(Ecto.UUID.generate(), "x")
  end

  test "search/2 matches content, title and subject keys; inactive handling" do
    {:ok, c} = Records.remember(base(%{"content" => "the quick zebra"}))
    {:ok, t} = Records.remember(base(%{"title" => "giraffe notes", "content" => "x"}))
    {:ok, s} = Records.remember(base(%{"content" => "y", "subjects" => [@repo_x]}))

    assert [c.id] == ids(Records.search("zebra", %{}))
    assert [t.id] == ids(Records.search("giraffe", %{}))
    assert s.id in ids(Records.search("repo:x", %{}))

    {:ok, _} = Records.forget(c.id, "gone")
    assert Records.search("zebra", %{}) == []
    assert [c.id] == ids(Records.search("zebra", %{"include_inactive" => true}))
  end

  test "search/2 tolerates operator characters" do
    {:ok, r} = Records.remember(base(%{"content" => "请 部署 web-01 今天"}))
    {:ok, cjk} = Records.remember(base(%{"content" => "已经完成部署web-01上线"}))

    assert is_list(Records.search("foo & | ! :* 'x'", %{}))
    assert is_list(Records.search("&", %{}))
    found = ids(Records.search("部署 web-01", %{}))
    assert r.id in found
    assert cjk.id in found
  end

  test "search/2 applies filters and token_budget" do
    {:ok, a} =
      Records.remember(
        fact(%{
          "content" => "alpha one",
          "host_id" => "h1",
          "agent_id" => "a1",
          "subjects" => [@repo_x],
          "observed_at" => ~U[2026-01-01 00:00:00.000000Z]
        })
      )

    {:ok, b} =
      Records.remember(
        base(%{
          "content" => "alpha two",
          "host_id" => "h2",
          "agent_id" => "a2",
          "observed_at" => ~U[2026-03-01 00:00:00.000000Z]
        })
      )

    assert [a.id] == ids(Records.search("alpha", %{"host_id" => "h1"}))
    assert [b.id] == ids(Records.search("alpha", %{"agent_id" => "a2"}))
    assert [a.id] == ids(Records.search("alpha", %{"kind" => "fact"}))
    assert [a.id] == ids(Records.search("alpha", %{"subject" => "Repo:X"}))
    assert [b.id] == ids(Records.search("alpha", %{"since" => "2026-02-01T00:00:00Z"}))
    assert [a.id] == ids(Records.search("alpha", %{"until" => "2026-02-01T00:00:00Z"}))
    assert length(Records.search("alpha", %{"limit" => 1})) == 1

    big = String.duplicate("alpha ", 100)
    {:ok, _} = Records.remember(base(%{"content" => big}))
    {:ok, _} = Records.remember(base(%{"content" => big}))
    assert length(Records.search("alpha", %{"token_budget" => 10})) == 1
    assert length(Records.search("alpha", %{"token_budget" => 100_000})) == 4
  end

  test "recent/1 returns active worklogs newest first" do
    {:ok, old} =
      Records.remember(
        base(%{
          "kind" => "worklog",
          "observed_at" => ~U[2026-01-01 00:00:00.000000Z],
          "host_id" => "h"
        })
      )

    {:ok, new} =
      Records.remember(
        base(%{
          "kind" => "worklog",
          "observed_at" => ~U[2026-02-01 00:00:00.000000Z],
          "host_id" => "h"
        })
      )

    {:ok, _} = Records.remember(base(%{"kind" => "note"}))
    {:ok, gone} = Records.remember(base(%{"kind" => "worklog", "host_id" => "h"}))
    {:ok, _} = Records.forget(gone.id, "x")

    assert [new.id, old.id] == ids(Records.recent(%{"host_id" => "h"}))
    assert [new.id] == ids(Records.recent(%{"since" => "2026-01-15T00:00:00Z"}))
    assert [new.id] == ids(Records.recent(%{"limit" => 1}))
  end

  test "normalize_subjects/1" do
    assert {[%{"type" => "a", "key" => "b"}], ["a:b"]} =
             Records.normalize_subjects([
               %{"type" => "A", "key" => "B"},
               %{"type" => "a", "key" => "b"}
             ])
  end

  defp ids(rs), do: Enum.map(rs, & &1.id)

  test "forget/2 leaves superseded records unchanged" do
    {:ok, a} = Records.remember(fact(%{"subjects" => [@repo_x], "content" => "old"}))
    {:ok, _} = Records.remember(fact(%{"subjects" => [@repo_x], "content" => "new"}))
    assert {:ok, r} = Records.forget(a.id, "why")
    assert r.status == "superseded"
    assert is_nil(r.forgotten_reason)
    assert repo().get!(Record, a.id).status == "superseded"
  end

  test "remember/1 ignores lifecycle attrs from callers" do
    {:ok, r} =
      Records.remember(
        base(%{
          "status" => "forgotten",
          "forgotten_reason" => "x",
          "forgotten_at" => DateTime.utc_now(),
          "superseded_by" => Ecto.UUID.generate()
        })
      )

    r = repo().get!(Record, r.id)
    assert r.status == "active"
    assert is_nil(r.forgotten_reason) and is_nil(r.forgotten_at) and is_nil(r.superseded_by)
  end

  test "subject-less facts do not supersede each other" do
    {:ok, a} = Records.remember(fact(%{"content" => "one"}))
    {:ok, _} = Records.remember(fact(%{"content" => "two"}))
    assert repo().get!(Record, a.id).status == "active"
  end

  test "search/2 rejects invalid limit, since and token_budget" do
    assert_raise ArgumentError, fn -> Records.search("a", %{"limit" => 0}) end
    assert_raise ArgumentError, fn -> Records.search("a", %{"token_budget" => -1}) end
    assert_raise ArgumentError, fn -> Records.search("a", %{"token_budget" => "x"}) end
    assert_raise ArgumentError, fn -> Records.search("a", %{"since" => "yesterday"}) end
  end

  test "search/2 does not match everything for a single-character query" do
    {:ok, _} = Records.remember(base(%{"content" => "alpha beta gamma"}))
    {:ok, _} = Records.remember(base(%{"content" => "delta epsilon"}))

    assert Records.search("a", %{}) == []
    assert Records.search("  e ", %{}) == []
  end

  test "search/2 rejects a non-string subject filter" do
    assert_raise ArgumentError, "invalid subject", fn ->
      Records.search("alpha", %{"subject" => 123})
    end

    assert_raise ArgumentError, "invalid subject", fn ->
      Records.search("alpha", %{"subject" => %{"type" => "repo"}})
    end
  end

  describe "changed_since/3" do
    defp stamp(record, sec) do
      at = DateTime.add(~U[2026-01-01 00:00:00.000000Z], sec, :second)
      import Ecto.Query
      repo().update_all(from(r in Record, where: r.id == ^record.id), set: [updated_at: at])
      %{record | updated_at: at}
    end

    defp host_rec(host, n) do
      {:ok, r} = Records.remember(base(%{"host_id" => host, "content" => "c#{n}"}))
      stamp(r, n)
    end

    test "changed_since returns only the host's records after the cursor in order" do
      a1 = host_rec("A", 1)
      a2 = host_rec("A", 2)
      a3 = host_rec("A", 3)
      _b = host_rec("B", 2)

      assert Enum.map(Records.changed_since("A", nil, 10), & &1.id) == [a1.id, a2.id, a3.id]

      cursor = %{updated_at: a1.updated_at, id: a1.id}
      assert Enum.map(Records.changed_since("A", cursor, 10), & &1.id) == [a2.id, a3.id]
    end

    test "changed_since includes superseded and forgotten records" do
      {:ok, f} = Records.remember(fact(%{"host_id" => "A", "subjects" => [@repo_x]}))
      {:ok, g} = Records.remember(base(%{"host_id" => "A"}))
      {:ok, _} = Records.forget(g.id, "gone")
      {:ok, _} = Records.remember(fact(%{"host_id" => "A", "subjects" => [@repo_x], "content" => "n"}))

      statuses = "A" |> Records.changed_since(nil, 10) |> Enum.map(& &1.status) |> Enum.sort()
      assert statuses == ["active", "forgotten", "superseded"]
      assert Enum.any?(Records.changed_since("A", nil, 10), &(&1.id == f.id))
    end

    test "changed_since respects limit and clamps 0/1000" do
      for n <- 1..3, do: host_rec("A", n)
      assert length(Records.changed_since("A", nil, 2)) == 2
      assert length(Records.changed_since("A", nil, 0)) == 1
      assert length(Records.changed_since("A", nil, 1000)) == 3
    end
  end
end
