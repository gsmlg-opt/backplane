defmodule Backplane.Registry.InputValidatorTest do
  use ExUnit.Case, async: true

  alias Backplane.Registry.InputValidator

  @schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string"},
      "limit" => %{"type" => "integer"},
      "threshold" => %{"type" => "number"},
      "verbose" => %{"type" => "boolean"}
    },
    "required" => ["query"]
  }

  describe "validate/2" do
    test "accepts valid args with all required fields" do
      assert :ok = InputValidator.validate(%{"query" => "hello"}, @schema)
    end

    test "accepts valid args with optional fields" do
      args = %{"query" => "hello", "limit" => 10, "verbose" => true}
      assert :ok = InputValidator.validate(args, @schema)
    end

    test "rejects missing required fields" do
      assert {:error, msg} = InputValidator.validate(%{}, @schema)
      assert msg =~ "Missing required arguments: query"
    end

    test "rejects multiple missing required fields" do
      schema = put_in(@schema["required"], ["query", "limit"])
      assert {:error, msg} = InputValidator.validate(%{}, schema)
      assert msg =~ "query"
      assert msg =~ "limit"
    end

    test "rejects wrong type for string" do
      assert {:error, msg} = InputValidator.validate(%{"query" => 123}, @schema)
      assert msg =~ "query"
      assert msg =~ "string"
      assert msg =~ "integer"
    end

    test "rejects wrong type for integer" do
      args = %{"query" => "hi", "limit" => "ten"}
      assert {:error, msg} = InputValidator.validate(args, @schema)
      assert msg =~ "limit"
      assert msg =~ "integer"
    end

    test "rejects wrong type for boolean" do
      args = %{"query" => "hi", "verbose" => "yes"}
      assert {:error, msg} = InputValidator.validate(args, @schema)
      assert msg =~ "verbose"
      assert msg =~ "boolean"
    end

    test "accepts number type for both integer and float" do
      assert :ok = InputValidator.validate(%{"query" => "hi", "threshold" => 0.5}, @schema)
      assert :ok = InputValidator.validate(%{"query" => "hi", "threshold" => 5}, @schema)
    end

    test "allows nil values regardless of type" do
      assert :ok = InputValidator.validate(%{"query" => "hi", "limit" => nil}, @schema)
    end

    test "allows extra fields not in schema" do
      args = %{"query" => "hi", "extra_field" => "value"}
      assert :ok = InputValidator.validate(args, @schema)
    end

    test "handles schema without required key" do
      schema = Map.delete(@schema, "required")
      assert :ok = InputValidator.validate(%{}, schema)
    end

    test "handles schema without properties key" do
      schema = %{"type" => "object", "required" => []}
      assert :ok = InputValidator.validate(%{"anything" => "goes"}, schema)
    end

    test "handles non-map args gracefully" do
      assert :ok = InputValidator.validate("not a map", @schema)
    end
  end
end
