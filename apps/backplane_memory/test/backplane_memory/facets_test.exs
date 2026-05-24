defmodule BackplaneMemory.FacetsTest do
  use BackplaneMemory.DataCase, async: false

  alias BackplaneMemory.Facets
  alias BackplaneMemory.Memory

  defp remember(content) do
    {:ok, mem} = Memory.remember(content, agent_id: "a", host_id: "h")
    mem
  end

  describe "tag/2" do
    test "succeeds for a known dimension" do
      mem = remember("Paris is the capital of France.")
      assert {:ok, 1} = Facets.tag(mem.id, [%{"dimension" => "language", "value" => "elixir"}])
    end

    test "returns {:error, {:unknown_dimension, _}} for an unknown dimension" do
      mem = remember("unknown dim content")

      assert {:error, {:unknown_dimension, "bogus_dim"}} =
               Facets.tag(mem.id, [%{"dimension" => "bogus_dim", "value" => "x"}])
    end

    test "tags with multiple known dimensions" do
      mem = remember("multi-facet memory")

      facets = [
        %{"dimension" => "language", "value" => "elixir"},
        %{"dimension" => "framework", "value" => "phoenix"}
      ]

      assert {:ok, 2} = Facets.tag(mem.id, facets)
    end

    test "upserts value on repeated tag for same dimension" do
      mem = remember("upsert test memory")
      Facets.tag(mem.id, [%{"dimension" => "language", "value" => "python"}])
      assert {:ok, 1} = Facets.tag(mem.id, [%{"dimension" => "language", "value" => "elixir"}])
      ids = Facets.query([%{"dimension" => "language", "value" => "elixir"}])
      assert mem.id in ids
    end
  end

  describe "query/1" do
    test "with a single facet returns matching memory IDs" do
      mem1 = remember("elixir memory one")
      mem2 = remember("elixir memory two")
      mem3 = remember("python memory")

      Facets.tag(mem1.id, [%{"dimension" => "language", "value" => "elixir"}])
      Facets.tag(mem2.id, [%{"dimension" => "language", "value" => "elixir"}])
      Facets.tag(mem3.id, [%{"dimension" => "language", "value" => "python"}])

      ids = Facets.query([%{"dimension" => "language", "value" => "elixir"}])
      assert mem1.id in ids
      assert mem2.id in ids
      refute mem3.id in ids
    end

    test "ANDs across multiple dimensions — both must match" do
      mem_both = remember("both dimensions match")
      mem_only_lang = remember("only language matches")
      mem_only_fw = remember("only framework matches")

      Facets.tag(mem_both.id, [
        %{"dimension" => "language", "value" => "elixir"},
        %{"dimension" => "framework", "value" => "phoenix"}
      ])

      Facets.tag(mem_only_lang.id, [%{"dimension" => "language", "value" => "elixir"}])
      Facets.tag(mem_only_fw.id, [%{"dimension" => "framework", "value" => "phoenix"}])

      ids =
        Facets.query([
          %{"dimension" => "language", "value" => "elixir"},
          %{"dimension" => "framework", "value" => "phoenix"}
        ])

      assert mem_both.id in ids
      refute mem_only_lang.id in ids
      refute mem_only_fw.id in ids
    end

    test "returns [] when no memories match" do
      assert [] = Facets.query([%{"dimension" => "language", "value" => "cobol"}])
    end

    test "returns [] for an empty list" do
      assert [] = Facets.query([])
    end
  end
end
