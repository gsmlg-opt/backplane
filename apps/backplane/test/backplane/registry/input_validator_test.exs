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

    test "rejects non-map args with descriptive error" do
      assert {:error, msg} = InputValidator.validate("not a map", @schema)
      assert msg =~ "Arguments must be an object"
      assert msg =~ "string"
    end

    test "rejects list args" do
      assert {:error, msg} = InputValidator.validate([1, 2], @schema)
      assert msg =~ "Arguments must be an object"
      assert msg =~ "array"
    end

    test "rejects nil args" do
      assert {:error, msg} = InputValidator.validate(nil, @schema)
      assert msg =~ "Arguments must be an object"
      assert msg =~ "null"
    end

    test "accepts map args with non-map schema" do
      assert :ok = InputValidator.validate(%{"key" => "val"}, nil)
    end

    test "validates object type" do
      schema = %{
        "type" => "object",
        "properties" => %{"config" => %{"type" => "object"}},
        "required" => []
      }

      assert :ok = InputValidator.validate(%{"config" => %{"key" => "val"}}, schema)
      assert {:error, msg} = InputValidator.validate(%{"config" => "not_object"}, schema)
      assert msg =~ "object"
    end

    test "validates array type" do
      schema = %{
        "type" => "object",
        "properties" => %{"tags" => %{"type" => "array"}},
        "required" => []
      }

      assert :ok = InputValidator.validate(%{"tags" => ["a", "b"]}, schema)
      assert {:error, msg} = InputValidator.validate(%{"tags" => "not_array"}, schema)
      assert msg =~ "array"
    end

    test "rejects wrong type for number" do
      args = %{"query" => "hi", "threshold" => "high"}
      assert {:error, msg} = InputValidator.validate(args, @schema)
      assert msg =~ "threshold"
      assert msg =~ "number"
    end

    test "rejects float when integer expected" do
      args = %{"query" => "hi", "limit" => 3.5}
      assert {:error, msg} = InputValidator.validate(args, @schema)
      assert msg =~ "limit"
      assert msg =~ "integer"
    end

    test "properties without type spec pass validation" do
      schema = %{
        "type" => "object",
        "properties" => %{"data" => %{"description" => "any data"}},
        "required" => []
      }

      assert :ok = InputValidator.validate(%{"data" => 42}, schema)
      assert :ok = InputValidator.validate(%{"data" => "str"}, schema)
    end

    test "rejects boolean when string expected and reports boolean type" do
      args = %{"query" => true}
      assert {:error, msg} = InputValidator.validate(args, @schema)
      assert msg =~ "got boolean"
    end

    test "rejects map when string expected and reports object type" do
      args = %{"query" => %{"nested" => "value"}}
      assert {:error, msg} = InputValidator.validate(args, @schema)
      assert msg =~ "got object"
    end

    test "rejects list when string expected and reports array type" do
      args = %{"query" => [1, 2, 3]}
      assert {:error, msg} = InputValidator.validate(args, @schema)
      assert msg =~ "got array"
    end

    test "rejects tuple when string expected and reports unknown type" do
      args = %{"query" => {:a, :b}}
      assert {:error, msg} = InputValidator.validate(args, @schema)
      assert msg =~ "got unknown"
    end

    test "nil value for required field is rejected" do
      args = %{"query" => nil}
      assert {:error, msg} = InputValidator.validate(args, @schema)
      assert msg =~ "Missing required arguments: query"
    end

    test "nil value for optional field passes validation" do
      args = %{"query" => "test", "limit" => nil}
      assert :ok = InputValidator.validate(args, @schema)
    end
  end

  describe "enum validation" do
    @enum_schema %{
      "type" => "object",
      "properties" => %{
        "level" => %{"type" => "string", "enum" => ["debug", "info", "warning", "error"]}
      },
      "required" => ["level"]
    }

    test "accepts value in enum" do
      assert :ok = InputValidator.validate(%{"level" => "info"}, @enum_schema)
    end

    test "rejects value not in enum" do
      assert {:error, msg} = InputValidator.validate(%{"level" => "trace"}, @enum_schema)
      assert msg =~ "must be one of"
      assert msg =~ "debug"
    end
  end

  describe "constraint validation" do
    @constraint_schema %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 50},
        "count" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}
      },
      "required" => []
    }

    test "accepts values within constraints" do
      args = %{"name" => "hello", "count" => 50}
      assert :ok = InputValidator.validate(args, @constraint_schema)
    end

    test "rejects string shorter than minLength" do
      assert {:error, msg} = InputValidator.validate(%{"name" => ""}, @constraint_schema)
      assert msg =~ "length >= 1"
    end

    test "rejects string longer than maxLength" do
      long = String.duplicate("a", 51)
      assert {:error, msg} = InputValidator.validate(%{"name" => long}, @constraint_schema)
      assert msg =~ "length <= 50"
    end

    test "rejects number below minimum" do
      assert {:error, msg} = InputValidator.validate(%{"count" => -1}, @constraint_schema)
      assert msg =~ ">= 0"
    end

    test "rejects number above maximum" do
      assert {:error, msg} = InputValidator.validate(%{"count" => 101}, @constraint_schema)
      assert msg =~ "<= 100"
    end
  end
end
