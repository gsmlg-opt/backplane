Code.require_file("../../fixtures/sigma_builtin_tool_schemas.exs", __DIR__)

defmodule Backplane.AgentRuntime.InputSchemaTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.InputSchema
  alias Backplane.AgentRuntime.SigmaBuiltinToolSchemas, as: SigmaSchemas

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
      {SigmaSchemas.ask_user_question(), %{"question" => "Continue?", "options" => ["Yes"]}}
    ]

    Enum.each(fixtures, fn {schema, arguments} ->
      assert {:ok, ^arguments} = InputSchema.validate(schema, arguments)
    end)
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
