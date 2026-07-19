defmodule Mix.Interactive.UITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Interactive.UI

  test "prints JSON Schema union types with separators" do
    tools = [
      %{
        "name" => "example",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "value" => %{"type" => ["string", "null"]}
          }
        }
      }
    ]

    output = capture_io(fn -> UI.print_items("tools", tools, "name") end)

    assert output =~ "value"
    assert output =~ "string | null"
    refute output =~ "stringnull"
  end
end
