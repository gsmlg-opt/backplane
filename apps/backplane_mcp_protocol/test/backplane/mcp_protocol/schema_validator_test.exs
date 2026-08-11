defmodule Backplane.McpProtocol.SchemaValidatorTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.SchemaValidator.Peri, as: PeriValidator
  alias Backplane.McpProtocol.Server.Component.Schema

  test "compiles and validates the proven JSON Schema subset for every JSON value shape" do
    cases = [
      {%{
         "$schema" => "https://json-schema.org/draft/2020-12/schema",
         "type" => "object",
         "properties" => %{"name" => %{"type" => "string"}},
         "required" => ["name"]
       }, %{"name" => "Ada"}, %{}},
      {%{"type" => "array", "items" => %{"type" => "integer"}}, [1, 2], [1, 1.5]},
      {%{"type" => "string"}, "value", 42},
      {%{"type" => "integer"}, 42, 42.5},
      {%{"type" => "number"}, 4.2, "4.2"},
      {%{"type" => "boolean"}, true, "true"},
      {%{"type" => "null"}, nil, false}
    ]

    for {schema, valid, invalid} <- cases do
      assert {:ok, compiled} = PeriValidator.compile(schema, [])
      assert :ok = PeriValidator.validate(compiled, valid, [])
      assert {:error, _} = PeriValidator.validate(compiled, invalid, [])
    end
  end

  test "does not treat a present null as an absent optional property" do
    schema = %{
      "type" => "object",
      "properties" => %{"nickname" => %{"type" => "string"}}
    }

    assert {:ok, compiled} = PeriValidator.compile(schema, [])
    assert :ok = PeriValidator.validate(compiled, %{}, [])
    assert {:error, _} = PeriValidator.validate(compiled, %{"nickname" => nil}, [])
  end

  test "returns every validation error collection as a list" do
    schema = %{
      "type" => "object",
      "additionalProperties" => %{"type" => "number", "minimum" => 0}
    }

    assert {:ok, compiled} = PeriValidator.compile(schema, [])
    assert {:error, [%Peri.Error{}]} = PeriValidator.validate(compiled, %{"score" => -1}, [])
    assert {:error, [:invalid_compiled_schema]} = PeriValidator.validate(:invalid, %{}, [])
  end

  test "accepts mathematically integral JSON numbers for integer schemas" do
    assert {:ok, integer} = PeriValidator.compile(%{"type" => "integer"}, [])
    assert :ok = PeriValidator.validate(integer, 1.0, [])
    assert {:error, _} = PeriValidator.validate(integer, 1.5, [])

    assert {:ok, array} =
             PeriValidator.compile(%{"type" => "array", "items" => %{"type" => "integer"}}, [])

    assert :ok = PeriValidator.validate(array, [1, 2.0], [])
    assert {:error, _} = PeriValidator.validate(array, [1, 2.5], [])
  end

  test "preserves raw JSON Schema maps term for term" do
    raw = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$defs" => %{"identifier" => %{"type" => "string"}},
      "type" => "object",
      "properties" => %{"id" => %{"$ref" => "#/$defs/identifier"}},
      "x-acme-documentation" => %{"audience" => "operators"}
    }

    assert raw |> Schema.raw() |> Schema.to_json_schema() == raw
  end

  test "declines unsupported schemas without resolving or rewriting them" do
    schemas = [
      %{"$defs" => %{"name" => %{"type" => "string"}}, "type" => "object"},
      %{"$ref" => "#/$defs/name"},
      %{"$ref" => "https://example.com/schemas/name.json"},
      %{"allOf" => [%{"type" => "string"}]},
      %{"oneOf" => [%{"type" => "string"}, %{"type" => "null"}]},
      %{"if" => %{"type" => "string"}, "then" => %{"minLength" => 1}},
      %{"type" => "object", "x-acme-keyword" => true}
    ]

    for schema <- schemas do
      assert {:unsupported, _reason} = PeriValidator.compile(schema, [])
    end
  end

  test "bounds schema traversal depth" do
    deep_schema =
      Enum.reduce(1..70, %{"type" => "string"}, fn _, nested ->
        %{"type" => "array", "items" => nested}
      end)

    assert {:unsupported, :max_depth_exceeded} = PeriValidator.compile(deep_schema, [])
  end

  test "bounds wide schema traversal" do
    properties =
      Map.new(1..1_001, fn index -> {"field_#{index}", %{"type" => "string"}} end)

    assert {:unsupported, :max_nodes_exceeded} =
             PeriValidator.compile(%{"type" => "object", "properties" => properties}, [])
  end

  test "rejects invalid regular expression patterns during compilation" do
    assert {:error, {:invalid_pattern, "["}} =
             PeriValidator.compile(%{"type" => "string", "pattern" => "["}, [])
  end

  test "rejects non-string pattern values before checking the dialect" do
    assert {:error, {:invalid_keyword_value, "pattern", 42}} =
             PeriValidator.compile(%{"type" => "string", "pattern" => 42}, [])
  end

  test "declines valid patterns with unproven regular expression semantics" do
    assert {:unsupported, {:unsupported_keyword, ["pattern"]}} =
             PeriValidator.compile(%{"type" => "string", "pattern" => "^[a-z]+$"}, [])
  end

  test "rejects negative and non-integer string length bounds" do
    for {keyword, value} <- [
          {"minLength", -1},
          {"minLength", 1.5},
          {"maxLength", -1},
          {"maxLength", 1.5}
        ] do
      assert {:error, {:invalid_keyword_value, ^keyword, ^value}} =
               PeriValidator.compile(%{"type" => "string", keyword => value}, [])
    end
  end

  test "declines string length assertions with unproven Unicode semantics" do
    decomposed_grapheme = "e\u0301"
    assert ["e", "\u0301"] = String.codepoints(decomposed_grapheme)

    for {keyword, value} <- [{"minLength", 2}, {"maxLength", 1}] do
      assert {:unsupported, {:unsupported_keyword, [^keyword]}} =
               PeriValidator.compile(%{"type" => "string", keyword => value}, [])
    end
  end

  test "rejects non-numeric number bounds" do
    for keyword <- ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] do
      assert {:error, {:invalid_keyword_value, ^keyword, "zero"}} =
               PeriValidator.compile(%{"type" => "number", keyword => "zero"}, [])
    end
  end

  test "declines unproven format assertions" do
    for format <- ["email", "date", "date-time", "hostname"] do
      assert {:unsupported, {:unsupported_format, ^format}} =
               PeriValidator.compile(%{"type" => "string", "format" => format}, [])
    end
  end

  test "declines type-specific assertions without a compatible explicit type" do
    schemas = [
      %{"minLength" => 2},
      %{"minimum" => 0},
      %{"properties" => %{"name" => %{"type" => "string"}}},
      %{"required" => ["name"]},
      %{"items" => %{"type" => "string"}}
    ]

    for schema <- schemas do
      assert {:unsupported, {:missing_compatible_type, _keyword}} =
               PeriValidator.compile(schema, [])
    end
  end

  test "enforces required keys even when an object schema has no properties" do
    schema = %{"type" => "object", "required" => ["requestId"]}

    assert {:ok, compiled} = PeriValidator.compile(schema, [])
    assert :ok = PeriValidator.validate(compiled, %{"requestId" => "req-1"}, [])
    assert {:error, _} = PeriValidator.validate(compiled, %{}, [])
  end

  test "enforces const alongside an explicit type" do
    schema = %{"type" => "string", "const" => "fixed"}

    assert {:ok, compiled} = PeriValidator.compile(schema, [])
    assert :ok = PeriValidator.validate(compiled, "fixed", [])
    assert {:error, _} = PeriValidator.validate(compiled, "different", [])
  end

  test "declines enum combined with assertions Peri cannot preserve together" do
    schema = %{"type" => "string", "enum" => ["ab"], "minLength" => 3}

    assert {:unsupported, {:unsupported_assertion_combination, ["enum", "minLength"]}} =
             PeriValidator.compile(schema, [])
  end

  test "enforces enum for a type union including null" do
    schema = %{"type" => ["string", "null"], "enum" => ["allowed"]}

    assert {:ok, compiled} = PeriValidator.compile(schema, [])
    assert :ok = PeriValidator.validate(compiled, "allowed", [])
    assert {:error, _} = PeriValidator.validate(compiled, nil, [])
  end

  test "enforces a bare enum for null" do
    assert {:ok, compiled} = PeriValidator.compile(%{"enum" => ["allowed"]}, [])
    assert {:error, _} = PeriValidator.validate(compiled, nil, [])
  end

  test "returns tagged errors for malformed required, enum, and type values" do
    assert {:error, {:invalid_keyword_value, "required", "name"}} =
             PeriValidator.compile(%{"type" => "object", "required" => "name"}, [])

    assert {:error, {:invalid_keyword_value, "enum", "value"}} =
             PeriValidator.compile(%{"enum" => "value"}, [])

    assert {:error, {:invalid_keyword_value, "type", 42}} =
             PeriValidator.compile(%{"type" => 42}, [])
  end
end
