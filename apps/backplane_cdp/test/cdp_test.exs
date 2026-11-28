defmodule Backplane.CDPTest do
  use ExUnit.Case, async: true

  alias Backplane.CDP
  alias Backplane.CDP.CLI

  test "commands validate MCP arguments before contacting the browser" do
    assert {:error, "Missing or invalid page_id"} = CDP.call("take_snapshot", %{})

    assert {:error, "Missing or invalid x"} =
             CDP.call("click", %{"page_id" => "id", "x" => -1, "y" => 0})

    for url <- ["file:///tmp/index.html", "javascript:void(0)", "http:///no-host"] do
      assert {:error, "Missing or invalid url"} = CDP.call("new_page", %{"url" => url})
    end

    assert {:error, "Unexpected CDP arguments"} = CDP.call("list_pages", %{"port" => 9222})
  end

  test "script and logpoint validation preserves the session before connecting to Chrome" do
    for args <- [
          %{},
          %{"function" => "document.title", "sourcePath" => "a.js"},
          %{"format" => "script", "function" => "document.title", "args" => ["uid"]},
          %{"sourcePath" => "/unconfigured/script.js"}
        ] do
      assert {:error, message, %{}} = CDP.MCP.Script.call("evaluate_script", args, %{})
      assert is_binary(message)
    end

    for entry <- [
          "src.ts:0 'label'",
          "app.js:5:0 count",
          "app.js:2 count = 1",
          "missing-location",
          "app.js:2 'unterminated"
        ] do
      assert {:error, message, %{}} =
               CDP.MCP.Logpoints.call("set_logpoints", %{"logpoints" => [entry]}, %{})

      assert is_binary(message)
    end
  end

  test "CLI help exposes each tool and rejects malformed arguments" do
    assert {:ok, help} = CLI.run(["--help"])

    for %{"name" => "cdp::" <> name, "inputSchema" => schema} <- CDP.tools() do
      assert help =~ Enum.join([name | schema["required"]], " ")
    end

    assert {:error, "Usage: cdp navigate_page page_id url"} =
             CLI.run(["navigate_page", "only-id"])

    assert {:error, "Missing or invalid y"} = CLI.run(["click", "id", "32.5", "11px"])
    assert {:error, "Unknown CDP command bad." <> _} = CLI.run(["bad"])
  end
end
