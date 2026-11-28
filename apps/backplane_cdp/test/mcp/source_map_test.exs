defmodule Backplane.CDP.MCP.SourceMapTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Backplane.CDP.MCP.SourceMap

  @base "https://example.test/dist/app.js.map"
  @source "https://example.test/src/app.ts"
  @alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

  defp map(mappings, sources \\ ["../src/app.ts"], extra \\ %{}) do
    Map.merge(
      %{"version" => 3, "sources" => sources, "names" => [], "mappings" => mappings},
      extra
    )
  end

  defp section(line, column, map),
    do: %{"offset" => %{"line" => line, "column" => column}, "map" => map}

  defp indexed(sections), do: %{"version" => 3, "sections" => sections}

  defp vlq(value) do
    encoded = abs(value) <<< 1 ||| if(value < 0, do: 1, else: 0)
    digits(encoded)
  end

  defp digits(value) when value < 32, do: binary_part(@alphabet, value, 1)
  defp digits(value), do: binary_part(@alphabet, (value &&& 31) ||| 32, 1) <> digits(value >>> 5)
  defp segment(values), do: Enum.map_join(values, &vlq/1)

  test "resolves a standard first segment from decoded maps and JSON" do
    source_map = map("AAAA")
    expected = {:ok, %{url: @source, line: 1, column: 1}}
    assert SourceMap.resolve(source_map, @base, "src/app.ts", 1, nil) == expected
    assert SourceMap.resolve(Formata.JSON.encode!(source_map), @base, @source, 1, 1) == expected
    assert SourceMap.resolve(source_map, @base, "missing.ts", 1, nil) == :no_source

    assert SourceMap.resolve(source_map, @base, "https://elsewhere.test/src/app.ts", 1, nil) ==
             :no_source

    assert SourceMap.resolve(source_map, @base, "../src/app.ts", 1, nil) == expected
  end

  test "uses one-based columns and the closest preceding original column" do
    source_map = map("KAAK,KAAG")
    assert {:ok, %{line: 1, column: 6}} = SourceMap.resolve(source_map, @base, "app.ts", 1, nil)
    assert {:ok, %{line: 1, column: 6}} = SourceMap.resolve(source_map, @base, "app.ts", 1, 6)
    assert {:ok, %{line: 1, column: 6}} = SourceMap.resolve(source_map, @base, "app.ts", 1, 8)
    assert {:ok, %{line: 1, column: 11}} = SourceMap.resolve(source_map, @base, "app.ts", 1, 9)
    assert {:error, _} = SourceMap.resolve(source_map, @base, "app.ts", 1, 1)
    assert {:error, _} = SourceMap.resolve(source_map, @base, "app.ts", 2, nil)
  end

  test "carries original deltas across generated lines and resets generated columns" do
    source_map = map("GAAI;AACC")
    assert {:ok, %{line: 1, column: 4}} = SourceMap.resolve(source_map, @base, "app.ts", 1, 5)
    assert {:ok, %{line: 2, column: 1}} = SourceMap.resolve(source_map, @base, "app.ts", 2, 6)
  end

  test "decodes negative source, original line, and original column deltas" do
    source_map = map("ACEC,EDDD", ["a.ts", "b.ts"])

    assert {:ok, %{url: "https://example.test/dist/b.ts", line: 1, column: 1}} =
             SourceMap.resolve(source_map, @base, "b.ts", 3, 2)

    assert {:ok, %{url: "https://example.test/dist/a.ts", line: 1, column: 3}} =
             SourceMap.resolve(source_map, @base, "a.ts", 2, 1)
  end

  test "unmapped segments advance generated columns without resetting original deltas" do
    assert {:ok, %{line: 1, column: 4}} =
             SourceMap.resolve(map("AAAA,C,EAAC"), @base, "app.ts", 1, 2)
  end

  test "decodes multi-digit VLQ and name deltas" do
    mappings = segment([123, 0, 40, 200, 1]) <> "," <> segment([90, 0, -1, -150, -1])
    source_map = map(mappings, ["../src/app.ts"], %{"names" => ["first", "second"]})

    assert {:ok, %{line: 1, column: 124}} =
             SourceMap.resolve(source_map, @base, "app.ts", 41, 201)

    assert {:ok, %{line: 1, column: 214}} = SourceMap.resolve(source_map, @base, "app.ts", 40, 51)
  end

  test "omitted columns choose the first original column and duplicate locations are deterministic" do
    mappings =
      segment([0, 0, 0, 10]) <> "," <> segment([4, 0, 0, -10]) <> ";" <> segment([0, 0, 0, 0])

    assert {:ok, %{line: 1, column: 5}} =
             SourceMap.resolve(map(mappings), @base, "app.ts", 1, nil)
  end

  test "resolves relative and absolute sourceRoot paths and absolute sources" do
    assert {:ok, %{url: @source}} =
             SourceMap.resolve(
               map("AAAA", ["app.ts"], %{"sourceRoot" => "../src"}),
               @base,
               "app.ts",
               1,
               nil
             )

    assert {:ok, %{url: "https://example.test/original/app.ts"}} =
             SourceMap.resolve(
               map("AAAA", ["app.ts"], %{"sourceRoot" => "/original/"}),
               @base,
               "original/app.ts",
               1,
               nil
             )

    assert {:ok, %{url: "webpack://project/src/app.ts"}} =
             SourceMap.resolve(
               map("AAAA", ["./src/app.ts"], %{"sourceRoot" => "webpack://project"}),
               @base,
               "src/app.ts",
               1,
               nil
             )

    assert {:ok, %{url: "https://cdn.test/source.ts"}} =
             SourceMap.resolve(
               map("AAAA", ["https://cdn.test/source.ts"], %{"sourceRoot" => "../src"}),
               @base,
               "https://cdn.test/source.ts",
               1,
               nil
             )
  end

  test "rejects ambiguous suffixes and accepts longer source paths" do
    source_map = map("AAAA,CCAA", ["a/index.ts", "b/index.ts"])
    assert {:error, message} = SourceMap.resolve(source_map, @base, "index.ts", 1, nil)
    assert message =~ "multiple sources"

    assert {:ok, %{url: "https://example.test/dist/a/index.ts", column: 1}} =
             SourceMap.resolve(source_map, @base, "a/index.ts", 1, nil)

    assert {:ok, %{url: "https://example.test/dist/b/index.ts", column: 2}} =
             SourceMap.resolve(source_map, @base, "https://example.test/dist/b/index.ts", 1, nil)

    assert SourceMap.resolve(source_map, @base, "dex.ts", 1, nil) == :no_source
  end

  test "keeps source variants ambiguous unless the requested query identifies one" do
    source_map = map("AAAA,CCAA", ["index.ts?one", "index.ts?two"])
    assert {:error, _} = SourceMap.resolve(source_map, @base, "index.ts", 1, nil)

    assert {:ok, %{url: "https://example.test/dist/index.ts?two", column: 2}} =
             SourceMap.resolve(source_map, @base, "index.ts?two", 1, nil)
  end

  test "prefers a complete map-relative URL before suffix matching other sources" do
    source_map = map("AAAA,CCAA", ["app.ts", "other/app.ts"])

    assert {:ok, %{url: "https://example.test/dist/app.ts", column: 1}} =
             SourceMap.resolve(source_map, @base, "app.ts", 1, nil)

    assert SourceMap.resolve(source_map, @base, "//elsewhere.test/dist/app.ts", 1, nil) ==
             :no_source
  end

  test "applies indexed section column offsets only to their first generated line" do
    source_map =
      indexed([
        section(2, 5, map("AAAA;AACA", ["a.ts"])),
        section(4, 8, map("AAAA", ["b.ts"]))
      ])

    assert {:ok, %{line: 3, column: 6}} = SourceMap.resolve(source_map, @base, "a.ts", 1, nil)
    assert {:ok, %{line: 4, column: 1}} = SourceMap.resolve(source_map, @base, "a.ts", 2, nil)
    assert {:ok, %{line: 5, column: 9}} = SourceMap.resolve(source_map, @base, "b.ts", 1, nil)
  end

  test "composes nested section offsets and child sourceRoot" do
    child =
      indexed([
        section(0, 2, map("AAAA", ["a.ts"], %{"sourceRoot" => "../src"})),
        section(1, 4, map("AAAA", ["b.ts"]))
      ])

    source_map = indexed([section(3, 7, child)])

    assert {:ok, %{url: "https://example.test/src/a.ts", line: 4, column: 10}} =
             SourceMap.resolve(source_map, @base, "a.ts", 1, nil)

    assert {:ok, %{line: 5, column: 5}} = SourceMap.resolve(source_map, @base, "b.ts", 1, nil)
  end

  test "rejects overlapping, unsorted, external, and mixed indexed sections" do
    overlapping = indexed([section(0, 0, map(";;AAAA")), section(1, 0, map("AAAA"))])
    unsorted = indexed([section(2, 0, map("AAAA")), section(1, 0, map("AAAA"))])
    external = indexed([%{"offset" => %{"line" => 0, "column" => 0}, "url" => "other.map"}])
    mixed = indexed([]) |> Map.put("mappings", "AAAA")

    for source_map <- [overlapping, unsorted, external, mixed] do
      assert {:error, _} = SourceMap.resolve(source_map, @base, "app.ts", 1, nil)
    end
  end

  test "bounds nested sections and input mapping size" do
    deep = Enum.reduce(1..10, map("AAAA"), fn _, child -> indexed([section(0, 0, child)]) end)
    assert {:error, _} = SourceMap.resolve(deep, @base, "app.ts", 1, nil)

    assert {:error, _} =
             SourceMap.resolve(
               map(String.duplicate("A", 512 * 1024 + 1)),
               @base,
               "app.ts",
               1,
               nil
             )

    assert {:error, _} =
             SourceMap.resolve(String.duplicate(" ", 512 * 1024 + 1), @base, "app.ts", 1, nil)
  end

  test "rejects malformed VLQ, segment fields, source indices, and negative coordinates" do
    for mappings <- [
          "!",
          "g",
          "ggggggggA",
          "AA",
          "AAA",
          "AAAAAA",
          "ACAA",
          "ADAA",
          "AADA",
          "AAAD",
          "DAAA",
          "AAAAA",
          "AAAA,,AAAA"
        ] do
      assert {:error, _} = SourceMap.resolve(map(mappings), @base, "app.ts", 1, nil), mappings
    end
  end

  test "rejects malformed metadata and invalid public coordinates" do
    for source_map <- [
          map("AAAA") |> Map.put("version", 2),
          map("AAAA") |> Map.put("sources", [123]),
          map("AAAA") |> Map.put("names", nil),
          map("AAAA") |> Map.put("sourceRoot", 42)
        ] do
      assert {:error, _} = SourceMap.resolve(source_map, @base, "app.ts", 1, nil)
    end

    assert {:error, _} = SourceMap.resolve("[]", @base, "app.ts", 1, nil)
    assert {:error, _} = SourceMap.resolve(map("AAAA"), "relative.map", "app.ts", 1, nil)
    assert {:error, _} = SourceMap.resolve(map("AAAA"), @base, "app.ts", 0, nil)
    assert {:error, _} = SourceMap.resolve(map("AAAA"), @base, "app.ts", 1, 0)
    assert {:error, _} = SourceMap.resolve(map("AAAA"), @base, "app.ts", 1, 1.5)
  end
end
