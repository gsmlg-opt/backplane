defmodule Backplane.AgentRuntime.Issue46ToolSchemas do
  def annotated_upload do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "properties" => %{
        "archive" => %{
          "type" => "string",
          "contentEncoding" => "base64",
          "format" => "byte",
          "x-mcp-header" => "archive"
        }
      },
      "required" => ["archive"]
    }
  end

  def mixed_inputs do
    %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => ["string", "number", "boolean", "null"]},
        "metadata" => %{},
        "choice" => %{
          "oneOf" => [
            %{"type" => "boolean"},
            %{"type" => "string", "enum" => ["basic", "advanced"]},
            %{"type" => "null"}
          ]
        },
        "files" => %{
          "anyOf" => [
            %{"type" => "string", "minLength" => 1},
            %{"type" => "array", "items" => %{"type" => "string"}, "minItems" => 1}
          ]
        }
      },
      "required" => ["value", "metadata", "choice", "files"]
    }
  end

  def constrained do
    %{
      "type" => "object",
      "properties" => %{
        "count" => %{"type" => "integer", "minimum" => 1, "maximum" => 3},
        "code" => %{"type" => "string", "minLength" => 2, "pattern" => "^(none|[A-Z])$"},
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "minItems" => 1,
          "maxItems" => 2
        },
        "vars" => %{
          "type" => "object",
          "additionalProperties" => %{"type" => "number", "maximum" => 10}
        },
        "attachment" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string"},
            "content" => %{"type" => "string"}
          },
          "not" => %{"required" => ["url", "content"]}
        }
      },
      "required" => ["count", "code", "tags", "vars", "attachment"]
    }
  end
end
