defmodule Backplane.JsonSchema.FormatAssertionTest do
  use ExUnit.Case, async: true

  alias Backplane.JsonSchema

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @format_schema %{"type" => "string", "format" => "email"}

  for declared? <- [false, true], opts <- [[], [format_assertion: false]] do
    test "keeps format annotation-only with declared dialect #{declared?} and options #{inspect(opts)}" do
      schema =
        if unquote(declared?),
          do: Map.put(@format_schema, "$schema", @dialect),
          else: @format_schema

      assert {:ok, compiled} = JsonSchema.compile(schema, unquote(opts))
      assert :ok = JsonSchema.validate(compiled, "not-an-email")
    end
  end

  for declared? <- [false, true] do
    test "asserts formats when opted in with declared dialect #{declared?}" do
      schema =
        if unquote(declared?),
          do: Map.put(@format_schema, "$schema", @dialect),
          else: @format_schema

      assert {:ok, compiled} = JsonSchema.compile(schema, format_assertion: true)
      assert {:error, [%{rule: :format}]} = JsonSchema.validate(compiled, "not-an-email")
      assert :ok = JsonSchema.validate(compiled, "person@example.com")
    end
  end

  test "inherits the default policy in nested schemas and local references" do
    schema = %{
      "$defs" => %{"email" => @format_schema},
      "properties" => %{"direct" => @format_schema, "ref" => %{"$ref" => "#/$defs/email"}}
    }

    assert {:ok, compiled} = JsonSchema.compile(schema)
    assert :ok = JsonSchema.validate(compiled, %{"direct" => "x", "ref" => "x"})
  end

  test "uses the same policy for a fragment without a declared dialect" do
    document = %{"schema" => @format_schema}

    assert {:ok, compiled} = JsonSchema.compile_fragment(document, entry: "#/schema")
    assert :ok = JsonSchema.validate(compiled, "x")

    assert {:ok, compiled} =
             JsonSchema.compile_fragment(document, entry: "#/schema", format_assertion: true)

    assert {:error, [%{rule: :format}]} = JsonSchema.validate(compiled, "x")
  end

  test "still enables assertion when a custom dialect activates its vocabulary" do
    uri = "https://example.com/asserting-dialect"

    loader = fn ^uri ->
      {:ok,
       %{
         "$vocabulary" => %{
           "https://json-schema.org/draft/2020-12/vocab/core" => true,
           "https://json-schema.org/draft/2020-12/vocab/validation" => true,
           "https://json-schema.org/draft/2020-12/vocab/format-assertion" => true
         }
       }}
    end

    assert {:ok, compiled} =
             JsonSchema.compile(Map.put(@format_schema, "$schema", uri),
               loader: loader,
               format_assertion: false
             )

    assert {:error, [%{rule: :format}]} = JsonSchema.validate(compiled, "x")
  end

  test "preserves Draft 7 format opt-in behavior" do
    schema = Map.put(@format_schema, "$schema", "http://json-schema.org/draft-07/schema#")

    assert {:ok, compiled} = JsonSchema.compile(schema)
    assert :ok = JsonSchema.validate(compiled, "x")
    assert {:ok, compiled} = JsonSchema.compile(schema, format_assertion: true)
    assert {:error, [%{rule: :format}]} = JsonSchema.validate(compiled, "x")
  end
end
