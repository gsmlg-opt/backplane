defmodule Backplane.Proxy.ToolCatalogTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.MCP.Response
  alias Backplane.Proxy.ToolCatalog
  alias Backplane.Registry.Tool

  @raw_tool %{
    "name" => "lookup",
    "title" => "Lookup",
    "description" => "Find one record",
    "inputSchema" => %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object"
    },
    "outputSchema" => %{"oneOf" => [%{"type" => "boolean"}, %{"type" => "null"}]},
    "annotations" => %{
      "readOnlyHint" => true,
      "com.example/policy" => %{"audited" => true}
    },
    "icon" => %{"url" => "https://example.test/legacy.svg", "mediaType" => "image/svg+xml"},
    "icons" => [
      %{
        "src" => "https://example.test/icon.svg",
        "mimeType" => "image/svg+xml",
        "sizes" => ["any"],
        "theme" => "dark",
        "com.example/density" => 2
      }
    ],
    "_meta" => %{"vendor" => %{"stable" => true}},
    "execution" => %{"taskSupport" => "forbidden"}
  }

  describe "normalize/4" do
    test "preserves modern and legacy catalog fields plus forwarding metadata" do
      assert {:ok, %Tool{} = tool} =
               ToolCatalog.normalize(@raw_tool, "search", self(), 30_000)

      assert tool.name == "lookup"
      assert tool.title == "Lookup"
      assert tool.description == "Find one record"
      assert tool.input_schema == @raw_tool["inputSchema"]
      assert tool.output_schema == @raw_tool["outputSchema"]
      assert tool.annotations == @raw_tool["annotations"]
      assert tool.icon == @raw_tool["icon"]
      assert tool.icons == @raw_tool["icons"]
      assert tool.meta == @raw_tool["_meta"]
      assert tool.execution == @raw_tool["execution"]
      assert tool.origin == {:upstream, "search"}
      assert tool.upstream_pid == self()
      assert tool.original_name == "lookup"
      assert tool.timeout == 30_000
    end

    test "defaults only omitted description and input schema without restricting compatible names" do
      for name <- [
            "getUser",
            "DATA_EXPORT_v2",
            "admin.tools-list",
            "server::nested/tool name",
            String.duplicate("a", 129)
          ] do
        assert {:ok,
                %Tool{
                  name: ^name,
                  description: "",
                  input_schema: %{},
                  output_schema: nil
                }} = ToolCatalog.normalize(%{"name" => name}, "fixture", self(), 5_000)
      end
    end

    test "accepts explicit nil for optional fields" do
      raw = %{
        "name" => "optional",
        "title" => nil,
        "outputSchema" => nil,
        "annotations" => nil,
        "icon" => nil,
        "icons" => nil,
        "_meta" => nil,
        "execution" => nil
      }

      assert {:ok,
              %Tool{
                title: nil,
                output_schema: nil,
                annotations: nil,
                icon: nil,
                icons: nil,
                meta: nil,
                execution: nil
              }} = ToolCatalog.normalize(raw, "fixture", self(), 5_000)
    end

    test "rejects missing, non-string, empty, and invalid UTF-8 names without raising" do
      invalid = [
        %{},
        %{"name" => nil},
        %{"name" => 123},
        %{"name" => ""},
        %{"name" => <<255>>},
        :not_a_tool
      ]

      for raw <- invalid do
        assert {:error, :invalid_tool} =
                 ToolCatalog.normalize(raw, "fixture", self(), 5_000)
      end
    end

    test "rejects malformed known fields while preserving empty maps and lists" do
      invalid = [
        %{"name" => "tool", "title" => 1},
        %{"name" => "tool", "description" => nil},
        %{"name" => "tool", "description" => %{}},
        %{"name" => "tool", "inputSchema" => nil},
        %{"name" => "tool", "inputSchema" => []},
        %{"name" => "tool", "outputSchema" => []},
        %{"name" => "tool", "annotations" => []},
        %{"name" => "tool", "icon" => []},
        %{"name" => "tool", "icons" => %{}},
        %{"name" => "tool", "icons" => [%{"src" => "ok"}, "invalid"]},
        %{"name" => "tool", "_meta" => []},
        %{"name" => "tool", "execution" => []}
      ]

      for raw <- invalid do
        assert {:error, :invalid_tool} =
                 ToolCatalog.normalize(raw, "fixture", self(), 5_000)
      end

      assert {:ok,
              %Tool{
                description: "",
                input_schema: %{},
                output_schema: %{},
                annotations: %{},
                icon: %{},
                icons: [],
                meta: %{},
                execution: %{}
              }} =
               ToolCatalog.normalize(
                 %{
                   "name" => "empty",
                   "description" => "",
                   "inputSchema" => %{},
                   "outputSchema" => %{},
                   "annotations" => %{},
                   "icon" => %{},
                   "icons" => [],
                   "_meta" => %{},
                   "execution" => %{}
                 },
                 "fixture",
                 self(),
                 5_000
               )
    end

    test "validates modern icon records without discarding string-key extensions" do
      valid_icon = %{
        "src" => "https://example.test/icon.svg",
        "mimeType" => "image/svg+xml",
        "sizes" => ["16x16", "any"],
        "theme" => "light",
        "com.example/density" => 2
      }

      assert {:ok, %Tool{icons: [^valid_icon]}} =
               ToolCatalog.normalize(
                 %{"name" => "icon", "icons" => [valid_icon]},
                 "fixture",
                 self(),
                 5_000
               )

      invalid_icons = [
        [%{}],
        [%{"src" => 7}],
        [%{"src" => "relative/icon.svg"}],
        [%{"src" => "not a uri"}],
        [%{"src" => <<"https://example.test/", 255>>}],
        [%{src: "https://example.test/icon.svg"}],
        [%{"src" => "https://example.test/icon.svg", mimeType: "image/svg+xml"}],
        [%{"src" => "https://example.test/icon.svg", "mimeType" => 7}],
        [%{"src" => "https://example.test/icon.svg", "sizes" => "16x16"}],
        [%{"src" => "https://example.test/icon.svg", "sizes" => 16}],
        [%{"src" => "https://example.test/icon.svg", "sizes" => [16]}],
        [%{"src" => "https://example.test/icon.svg", "sizes" => ["16x16" | "any"]}],
        [%{"src" => "https://example.test/icon.svg", "theme" => "system"}],
        [%{"src" => "https://example.test/icon.svg", "theme" => :dark}],
        [%{"src" => "https://example.test/icon.svg", extension: true}],
        [%{"src" => "https://example.test/icon.svg"} | %{}]
      ]

      for icons <- invalid_icons do
        assert {:error, :invalid_tool} =
                 ToolCatalog.normalize(
                   %{"name" => "icon", "icons" => icons},
                   "fixture",
                   self(),
                   5_000
                 )
      end
    end

    test "validates known tool annotation fields and retains string-key extensions" do
      annotations = %{
        "title" => "Safe lookup",
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false,
        "com.example/policy" => %{"audited" => true}
      }

      assert {:ok, %Tool{annotations: ^annotations}} =
               ToolCatalog.normalize(
                 %{"name" => "annotated", "annotations" => annotations},
                 "fixture",
                 self(),
                 5_000
               )

      malformed = [
        %{"title" => 7},
        %{"readOnlyHint" => "yes"},
        %{"destructiveHint" => nil},
        %{"idempotentHint" => 1},
        %{"openWorldHint" => "false"},
        %{readOnlyHint: true},
        %{"readOnlyHint" => true, extension: "atom-key"}
      ]

      for invalid_annotations <- malformed do
        assert {:error, :invalid_tool} =
                 ToolCatalog.normalize(
                   %{"name" => "annotated", "annotations" => invalid_annotations},
                   "fixture",
                   self(),
                   5_000
                 )
      end
    end
  end

  describe "normalize_all/4" do
    test "preserves input order and returns no partial result when a later tool is malformed" do
      raw_tools = [
        Map.put(@raw_tool, "name", "first"),
        Map.put(@raw_tool, "name", "second")
      ]

      assert {:ok, [%Tool{name: "first"}, %Tool{name: "second"}]} =
               ToolCatalog.normalize_all(raw_tools, "fixture", self(), 10_000)

      assert {:error, :invalid_tool} =
               ToolCatalog.normalize_all(
                 [hd(raw_tools), %{"name" => ""}],
                 "fixture",
                 self(),
                 10_000
               )
    end

    test "rejects exact duplicate names atomically but keeps case-distinct names" do
      assert {:error, :duplicate_tool_name} =
               ToolCatalog.normalize_all(
                 [%{"name" => "echo"}, %{"name" => "echo"}],
                 "fixture",
                 self(),
                 10_000
               )

      assert {:ok, [%Tool{name: "echo"}, %Tool{name: "Echo"}]} =
               ToolCatalog.normalize_all(
                 [%{"name" => "echo"}, %{"name" => "Echo"}],
                 "fixture",
                 self(),
                 10_000
               )
    end

    test "rejects non-list catalogs safely" do
      for raw_tools <- [nil, %{}, "tools"] do
        assert {:error, :invalid_catalog} =
                 ToolCatalog.normalize_all(raw_tools, "fixture", self(), 10_000)
      end
    end
  end

  describe "fetch_all/1" do
    test "follows distinct cursors through exact package responses and preserves page order" do
      page_fun = fn
        nil ->
          send(self(), {:cursor, nil})
          page([%{"name" => "first"}], "cursor-1")

        "cursor-1" ->
          send(self(), {:cursor, "cursor-1"})
          page([%{"name" => "second"}], "cursor-2")

        "cursor-2" ->
          send(self(), {:cursor, "cursor-2"})
          page([%{"name" => "third"}])
      end

      assert {:ok, [%{"name" => "first"}, %{"name" => "second"}, %{"name" => "third"}]} =
               ToolCatalog.fetch_all(page_fun)

      assert_received {:cursor, nil}
      assert_received {:cursor, "cursor-1"}
      assert_received {:cursor, "cursor-2"}
    end

    test "rejects cursor cycles and invalid cursors" do
      cycle = fn
        nil -> page([], "same")
        "same" -> page([], "same")
      end

      assert {:error, :cursor_cycle} = ToolCatalog.fetch_all(cycle)

      longer_cycle = fn
        nil -> page([], "a")
        "a" -> page([], "b")
        "b" -> page([], "a")
      end

      assert {:error, :cursor_cycle} = ToolCatalog.fetch_all(longer_cycle)

      assert {:ok, []} =
               ToolCatalog.fetch_all(fn
                 nil -> page([], "")
                 "" -> page([])
               end)

      for invalid_cursor <- [1, false, [], %{}] do
        assert {:error, :invalid_cursor} =
                 ToolCatalog.fetch_all(fn nil -> page([], invalid_cursor) end)
      end
    end

    test "rejects exact duplicate tool names within and across pages" do
      assert {:error, :duplicate_tool_name} =
               ToolCatalog.fetch_all(fn nil ->
                 page([%{"name" => "echo"}, %{"name" => "echo"}])
               end)

      across_pages = fn
        nil -> page([%{"name" => "echo"}], "next")
        "next" -> page([%{"name" => "echo"}])
      end

      assert {:error, :duplicate_tool_name} = ToolCatalog.fetch_all(across_pages)

      assert {:ok, [%{"name" => "echo"}, %{"name" => "Echo"}]} =
               ToolCatalog.fetch_all(fn nil ->
                 page([%{"name" => "echo"}, %{"name" => "Echo"}])
               end)
    end

    test "rejects malformed package pages and tool collections atomically" do
      malformed = [
        :not_a_function,
        fn -> page([]) end,
        fn _cursor -> %Response{result: %{"tools" => []}} end,
        fn _cursor -> {:ok, %Response{result: nil}} end,
        fn _cursor -> {:ok, %Response{result: %{}}} end,
        fn _cursor -> {:ok, %Response{result: %{"tools" => nil}}} end,
        fn _cursor -> {:ok, %Response{result: %{"tools" => %{}}}} end,
        fn _cursor -> {:ok, %Response{result: %{"tools" => []}, is_error: true}} end
      ]

      for page_fun <- malformed do
        assert {:error, :invalid_catalog_page} = ToolCatalog.fetch_all(page_fun)
      end

      later_malformed = fn
        nil -> page([%{"name" => "first"}], "next")
        "next" -> {:ok, %Response{result: %{"tools" => :invalid}}}
      end

      assert {:error, :invalid_catalog_page} = ToolCatalog.fetch_all(later_malformed)
    end

    test "sanitizes returned errors, raises, throws, and exits without partial data" do
      failures = [
        fn _cursor -> {:error, %{secret: "upstream details"}} end,
        fn _cursor -> raise "private failure" end,
        fn _cursor -> throw({:private, :failure}) end,
        fn _cursor -> exit(:private_failure) end
      ]

      for page_fun <- failures do
        assert {:error, :catalog_request_failed} = ToolCatalog.fetch_all(page_fun)
      end

      later_error = fn
        nil -> page([%{"name" => "first"}], "next")
        "next" -> {:error, "private upstream message"}
      end

      assert {:error, :catalog_request_failed} = ToolCatalog.fetch_all(later_error)
    end

    test "allows a terminal 100th page" do
      calls = :atomics.new(1, signed: false)

      page_fun = fn cursor ->
        :atomics.add_get(calls, 1, 1)
        page_number = if is_nil(cursor), do: 1, else: String.to_integer(cursor)
        next_cursor = if page_number < 100, do: Integer.to_string(page_number + 1)
        page([%{"name" => "tool-#{page_number}"}], next_cursor)
      end

      assert {:ok, tools} = ToolCatalog.fetch_all(page_fun)
      assert Enum.map(tools, & &1["name"]) == Enum.map(1..100, &"tool-#{&1}")
      assert :atomics.get(calls, 1) == 100
    end

    test "rejects a catalog requiring a 101st page without requesting it" do
      calls = :atomics.new(1, signed: false)

      page_fun = fn cursor ->
        :atomics.add_get(calls, 1, 1)
        page_number = if is_nil(cursor), do: 1, else: String.to_integer(cursor)
        page([%{"name" => "tool-#{page_number}"}], Integer.to_string(page_number + 1))
      end

      assert {:error, :too_many_pages} = ToolCatalog.fetch_all(page_fun)
      assert :atomics.get(calls, 1) == 100
    end
  end

  defp page(tools, next_cursor \\ nil) do
    result = %{"tools" => tools}
    result = if is_nil(next_cursor), do: result, else: Map.put(result, "nextCursor", next_cursor)
    {:ok, %Response{result: result}}
  end
end
