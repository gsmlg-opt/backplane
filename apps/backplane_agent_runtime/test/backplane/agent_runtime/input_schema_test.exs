Code.require_file("../../fixtures/sigma_builtin_tool_schemas.exs", __DIR__)

defmodule Backplane.AgentRuntime.InputSchemaTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.InputSchema
  alias Backplane.AgentRuntime.SigmaBuiltinToolSchemas, as: SigmaSchemas

  test "validates string enums without bypassing required or type constraints" do
    schema = enum_schema(%{"type" => "string", "enum" => ["add", "list", nil, 1]})

    assert {:ok, %{"value" => "list"}} = InputSchema.validate(schema, %{"value" => "list"})

    assert {:error, %Error{class: :validation, details: %{path: "$arguments.value"}}} =
             InputSchema.validate(schema, %{"value" => "unknown"})

    for invalid <- [nil, 1, :list] do
      assert {:error, %Error{class: :validation, details: %{type: "string"}}} =
               InputSchema.validate(schema, %{"value" => invalid})
    end

    assert {:error, %Error{class: :validation, details: %{property: "value"}}} =
             InputSchema.validate(schema, %{})
  end

  test "accepts atom schema keys and uses numeric equality for enums" do
    schema = enum_schema(%{type: :number, enum: [1, 2.5], minimum: 1})
    assert {:ok, %{"value" => 1.0}} = InputSchema.validate(schema, %{"value" => 1.0})
    assert {:ok, %{"value" => 2.5}} = InputSchema.validate(schema, %{"value" => 2.5})
    assert {:error, %Error{class: :validation}} = InputSchema.validate(schema, %{"value" => 2})

    schema = enum_schema(%{type: :integer, enum: [0, 1], minimum: 1})

    assert {:error, %Error{class: :validation, details: %{minimum: 1}}} =
             InputSchema.validate(schema, %{"value" => 0})
  end

  test "compares boolean and structured enum values without coercing types" do
    for {type, allowed, valid, invalid} <- [
          {"boolean", [true], true, false},
          {"array", [[1, %{"active" => true}]], [1.0, %{"active" => true}], [true]},
          {"object", [%{"count" => 1, "label" => nil}], %{"label" => nil, "count" => 1.0},
           %{"count" => 1}}
        ] do
      schema = enum_schema(%{"type" => type, "enum" => allowed})

      assert {:ok, %{"value" => ^valid}} = InputSchema.validate(schema, %{"value" => valid})

      assert {:error, %Error{class: :validation}} =
               InputSchema.validate(schema, %{"value" => invalid})
    end

    assert {:error, %Error{class: :validation}} =
             InputSchema.validate(enum_schema(%{"type" => "boolean", "enum" => [1]}), %{
               "value" => true
             })
  end

  test "validates enums in nested array and oneOf schemas" do
    schema =
      enum_schema(%{
        "type" => "array",
        "items" => %{
          "oneOf" => [
            %{"type" => "string", "enum" => ["todo", "done"]},
            %{"type" => "integer", "enum" => [1]}
          ]
        }
      })

    assert {:ok, %{"value" => ["todo", 1]}} =
             InputSchema.validate(schema, %{"value" => ["todo", 1]})

    assert {:error, %Error{class: :validation, details: %{path: "$arguments.value[1]"}}} =
             InputSchema.validate(schema, %{"value" => ["todo", "unknown"]})
  end

  test "checks malformed enums even in absent properties and unused branches" do
    for malformed <- [
          nil,
          "list",
          %{},
          [:not_json],
          [%{"nested" => {1, 2}}],
          [%{1 => "not a JSON object key"}],
          [~D[2026-09-21]]
        ] do
      property = %{"type" => "string", "enum" => malformed}

      for schema <- [enum_schema(property), enum_schema(%{"oneOf" => [property]})] do
        assert {:error,
                %Error{class: :validation, message: "schema enum must be a list of JSON values"}} =
                 InputSchema.validate(schema, %{})
      end
    end
  end

  test "empty enums reject all supplied values and repeated choices remain valid" do
    assert {:error, %Error{class: :validation}} =
             InputSchema.validate(enum_schema(%{"type" => "string", "enum" => []}), %{
               "value" => "anything"
             })

    assert {:ok, %{"value" => "list"}} =
             InputSchema.validate(
               enum_schema(%{"type" => "string", "enum" => ["list", "list"]}),
               %{
                 "value" => "list"
               }
             )
  end

  test "enum support keeps unknown keywords fail-closed" do
    schema = enum_schema(%{"type" => "string", "enum" => ["list"], "pattern" => "list"})

    assert {:error, %Error{class: :unsupported_capability, details: %{keyword: "pattern"}}} =
             InputSchema.validate(schema, %{"value" => "list"})

    schema = enum_schema(%{"oneOf" => [%{"type" => "string"}], "enum" => ["list"]})

    assert {:error, %Error{class: :unsupported_capability}} =
             InputSchema.validate(schema, %{"value" => "list"})
  end

  defp enum_schema(property) do
    %{"type" => "object", "properties" => %{"value" => property}, "required" => ["value"]}
  end

  test "accepts all current Sigma built-in tool schema shapes" do
    fixtures = [
      {SigmaSchemas.read(), %{"path" => "README.md"}},
      {SigmaSchemas.bash(), %{"command" => "mix test", "timeout" => 30}},
      {SigmaSchemas.grep(), %{"pattern" => "TODO", "context" => 0, "limit" => 1}},
      {SigmaSchemas.glob(), %{"pattern" => "**/*.ex", "limit" => 1}},
      {SigmaSchemas.write(), %{"path" => "notes.txt", "content" => "text"}},
      {SigmaSchemas.url_fetch(), %{"url" => "https://example.test", "max_length" => 1}},
      {SigmaSchemas.edit(), %{"path" => "notes.txt", "content" => "replacement"}},
      {SigmaSchemas.ls(), %{}},
      {SigmaSchemas.ask_user_question(), %{"question" => "Continue?", "options" => ["Yes"]}},
      {SigmaSchemas.todo(), %{"action" => "add", "content" => "Ship fix", "status" => "pending"}}
    ]

    Enum.each(fixtures, fn {schema, arguments} ->
      assert {:ok, ^arguments} = InputSchema.validate(schema, arguments)
    end)
  end

  test "validates Sigma todo action and optional status enums" do
    schema = SigmaSchemas.todo()

    for action <- ~w(add update complete remove list clear) do
      assert {:ok, %{"action" => ^action}} = InputSchema.validate(schema, %{"action" => action})
    end

    for status <- ~w(pending in_progress completed) do
      assert {:ok, %{"action" => "update", "status" => ^status}} =
               InputSchema.validate(schema, %{"action" => "update", "status" => status})
    end

    for arguments <- [%{"action" => "destroy"}, %{"action" => "add", "status" => "invalid"}] do
      assert {:error, %Error{class: :validation}} = InputSchema.validate(schema, arguments)
    end
  end

  test "accepts Sigma integer minimum constraints and enforces their bounds" do
    assert {:ok, %{"path" => "README.md", "offset" => 1}} =
             InputSchema.validate(SigmaSchemas.read(), %{"path" => "README.md", "offset" => 1})

    assert {:ok, %{"pattern" => "TODO", "context" => 0}} =
             InputSchema.validate(SigmaSchemas.grep(), %{"pattern" => "TODO", "context" => 0})

    assert {:error, %Error{class: :validation, details: %{minimum: 1}}} =
             InputSchema.validate(SigmaSchemas.read(), %{"path" => "README.md", "offset" => 0})
  end

  test "validates Sigma nested array items and oneOf option shapes" do
    arguments = %{
      "question" => "Choose a formatter",
      "options" => [
        "mix format",
        %{"label" => "Custom", "value" => "custom", "description" => "Enter a command"}
      ],
      "timeout_ms" => 1_000
    }

    assert {:ok, ^arguments} = InputSchema.validate(SigmaSchemas.ask_user_question(), arguments)

    assert {:error, %Error{class: :validation}} =
             InputSchema.validate(
               SigmaSchemas.ask_user_question(),
               Map.put(arguments, "options", [%{"value" => "missing-label"}])
             )

    assert {:error, %Error{class: :validation, details: %{minimum: 1_000}}} =
             InputSchema.validate(
               SigmaSchemas.ask_user_question(),
               Map.put(arguments, "timeout_ms", 999)
             )
  end

  test "rejects unsupported keywords in every composition branch before input validation" do
    schema =
      put_in(
        SigmaSchemas.ask_user_question(),
        ["properties", "options", "items", "oneOf", Access.at(1), "properties", "value"],
        %{"type" => "string", "pattern" => "^[a-z]+$"}
      )

    assert {:error, %Error{class: :unsupported_capability, details: %{keyword: "pattern"}}} =
             InputSchema.validate(schema, %{"question" => "No options supplied"})
  end

  test "rejects malformed supported constraints explicitly" do
    schema = %{
      "type" => "object",
      "properties" => %{"count" => %{"type" => "integer", "minimum" => "one"}}
    }

    assert {:error, %Error{class: :validation}} = InputSchema.validate(schema, %{})
  end
end
