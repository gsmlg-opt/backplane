defmodule Backplane.AgentRuntime.InputSchemaDraft202012BoundaryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Error, InputSchema}

  @draft "https://json-schema.org/draft/2020-12/schema"

  test "rejects an explicit older dialect and required unknown vocabulary" do
    assert {:error, %Error{class: :unsupported_capability}} =
             InputSchema.validate_schema(%{
               "$schema" => "https://json-schema.org/draft/2019-09/schema",
               "type" => "object"
             })

    assert {:error, %Error{class: :unsupported_capability}} =
             InputSchema.validate_schema(%{
               "$schema" => @draft,
               "$vocabulary" => %{"https://example.test/vocab/custom" => true},
               "type" => "object"
             })
  end

  test "applies sibling assertions next to a local ref" do
    schema = %{
      "$schema" => @draft,
      "type" => "object",
      "$defs" => %{
        "payload" => %{
          "type" => "object",
          "required" => ["id"],
          "properties" => %{"id" => %{"type" => "string"}}
        }
      },
      "properties" => %{
        "payload" => %{
          "$ref" => "#/$defs/payload",
          "minProperties" => 2
        }
      },
      "required" => ["payload"]
    }

    assert :ok = InputSchema.validate_schema(schema)

    assert {:ok, _} = InputSchema.validate(schema, %{"payload" => %{"id" => "p", "x" => true}})

    assert {:error, %Error{class: :validation}} =
             InputSchema.validate(schema, %{"payload" => %{"id" => "p"}})
  end

  test "supports recursive dynamic references and boolean nested schemas" do
    schema = %{
      "$schema" => @draft,
      "$dynamicAnchor" => "node",
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "integer"},
        "children" => %{
          "type" => "array",
          "items" => %{"$dynamicRef" => "#node"}
        },
        "metadata" => true
      }
    }

    input = %{"value" => 1, "children" => [%{"value" => 2, "children" => []}]}

    assert {:ok, ^input} = InputSchema.validate(schema, input)
  end

  test "propagates evaluated properties through oneOf and unevaluatedProperties" do
    schema = %{
      "$schema" => @draft,
      "type" => "object",
      "properties" => %{"kind" => %{"type" => "string"}},
      "oneOf" => [
        %{"properties" => %{"left" => %{"type" => "string"}}, "required" => ["left"]},
        %{"properties" => %{"right" => %{"type" => "integer"}}, "required" => ["right"]}
      ],
      "unevaluatedProperties" => false
    }

    assert {:ok, _} = InputSchema.validate(schema, %{"kind" => "left", "left" => "ok"})

    assert {:error, %Error{class: :validation}} =
             InputSchema.validate(schema, %{"kind" => "left", "left" => "ok", "extra" => true})
  end

  test "keeps format and content annotations by default and supports explicit assertions" do
    format_schema = %{
      "$schema" => @draft,
      "type" => "object",
      "properties" => %{"email" => %{"type" => "string", "format" => "email"}},
      "required" => ["email"]
    }

    assert {:ok, _} = InputSchema.validate(format_schema, %{"email" => "not-an-email"})

    assert {:error, %Error{class: :validation}} =
             InputSchema.validate(format_schema, %{"email" => "not-an-email"},
               format_assertion: true
             )

    content_schema = %{
      "$schema" => @draft,
      "type" => "object",
      "properties" => %{
        "value" => %{
          "type" => "string",
          "contentMediaType" => "application/json",
          "contentSchema" => %{"type" => "integer"}
        }
      },
      "required" => ["value"]
    }

    assert {:ok, _} = InputSchema.validate(content_schema, %{"value" => "not-json"})

    assert {:error, %Error{class: :validation}} =
             InputSchema.validate(content_schema, %{"value" => "not-json"},
               content_assertion: true
             )
  end

  test "loads external references only from an explicit registry" do
    schema = %{
      "$schema" => @draft,
      "type" => "object",
      "properties" => %{"name" => %{"$ref" => "https://example.test/name"}},
      "required" => ["name"]
    }

    assert {:error, %Error{class: :validation}} = InputSchema.validate_schema(schema)

    registry = %{"https://example.test/name" => %{"type" => "string"}}

    assert {:ok, %{"name" => "Ada"}} =
             InputSchema.validate(schema, %{"name" => "Ada"}, schema_registry: registry)

    atom_key_loader = fn "https://example.test/name" -> {:ok, %{type: :string}} end

    assert {:ok, %{"name" => "Ada"}} =
             InputSchema.validate(schema, %{"name" => "Ada"}, schema_loader: atom_key_loader)
  end

  test "preflights relative external references before catalog publication" do
    schema = %{
      "$schema" => @draft,
      "type" => "object",
      "properties" => %{"name" => %{"$ref" => "name.json"}}
    }

    assert {:error, %Error{class: :validation, message: message}} =
             InputSchema.validate_schema(schema)

    assert message == "external schema reference requires an explicit loader"

    loader = fn "name.json" -> {:ok, %{"type" => "string"}} end
    assert :ok = InputSchema.validate_schema(schema, schema_loader: loader)
  end

  test "fails closed on schema depth and never creates atoms while normalizing" do
    deep = Enum.reduce(1..129, %{}, fn _, child -> %{"properties" => %{"x" => child}} end)
    assert {:error, %Error{class: :execution_failure}} = InputSchema.validate_schema(deep)

    deep_input = Enum.reduce(1..129, %{}, fn _, child -> %{"x" => child} end)

    assert {:error, %Error{class: :execution_failure}} =
             InputSchema.validate(%{"type" => "object"}, deep_input)

    untrusted_key = "untrusted_schema_key_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(untrusted_key, :utf8) end

    schema = %{
      type: :object,
      properties: %{untrusted_key => %{type: :string, description: "host schema"}},
      required: [untrusted_key]
    }

    assert :ok = InputSchema.validate_schema(schema)
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(untrusted_key, :utf8) end
  end
end
