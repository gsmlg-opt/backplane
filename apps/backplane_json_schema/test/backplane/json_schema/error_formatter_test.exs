defmodule Backplane.JsonSchema.ErrorFormatterTest do
  use ExUnit.Case, async: true

  alias Backplane.JsonSchema

  test "formats a top-level array index as decimal text" do
    {:ok, schema} = JsonSchema.compile(%{"items" => %{"type" => "string"}})
    {:error, [error]} = JsonSchema.validate(schema, ["a", 2])

    assert JsonSchema.format_error(error) == "At /1: Expected type string, got integer"
  end

  test "formats nested array indexes including indexes larger than one byte" do
    {:ok, schema} =
      JsonSchema.compile(%{"properties" => %{"items" => %{"items" => %{"type" => "string"}}}})

    for index <- [0, 1, 256] do
      data = %{"items" => List.duplicate("a", index) ++ [2]}
      {:error, [error]} = JsonSchema.validate(schema, data)

      assert JsonSchema.format_error(error) ==
               "At /items/#{index}: Expected type string, got integer"
    end
  end

  test "preserves the order of nested object and array segments" do
    {:ok, schema} =
      JsonSchema.compile(%{
        "properties" => %{
          "groups" => %{
            "items" => %{"properties" => %{"values" => %{"items" => %{"type" => "string"}}}}
          }
        }
      })

    {:error, [error]} = JsonSchema.validate(schema, %{"groups" => [%{"values" => ["a", 2]}]})

    assert JsonSchema.format_error(error) ==
             "At /groups/0/values/1: Expected type string, got integer"
  end

  test "escapes JSON Pointer characters in a single property segment" do
    {:ok, schema} = JsonSchema.compile(%{"properties" => %{"~1/" => %{"type" => "string"}}})
    {:error, [error]} = JsonSchema.validate(schema, %{"~1/" => 2})

    assert JsonSchema.format_error(error) == "At /~01~1: Expected type string, got integer"
  end

  test "escapes nested property segments and preserves unicode" do
    {:ok, schema} =
      JsonSchema.compile(%{"properties" => %{"项目~/" => %{"items" => %{"type" => "string"}}}})

    {:error, [error]} = JsonSchema.validate(schema, %{"项目~/" => ["a", 2]})

    assert JsonSchema.format_error(error) ==
             "At /项目~0~1/1: Expected type string, got integer"
  end

  test "keeps root validation errors without a location prefix" do
    {:ok, schema} = JsonSchema.compile(%{"type" => "string"})
    {:error, [error]} = JsonSchema.validate(schema, 2)

    assert JsonSchema.format_error(error) == "Expected type string, got integer"
  end
end
