defmodule Backplane.AgentRuntime.SigmaBuiltinToolSchemas do
  @moduledoc false

  # Copied from Sigma 143c8db27f5f3d32efc5dafffb2755dba1daa23b.
  # These are the built-in schemas that exercise every JSON Schema keyword
  # not already covered by the runtime's original primitive-object subset.
  def read do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the file to read (relative or absolute)"
        },
        "offset" => %{
          "type" => "integer",
          "description" => "Line number to start reading from (1-indexed)",
          "minimum" => 1
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of lines to read",
          "minimum" => 1
        }
      },
      "required" => ["path"]
    }
  end

  def grep do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Search pattern (regular expression)"
        },
        "path" => %{
          "type" => "string",
          "description" => "File or directory to search (default: current working directory)"
        },
        "glob" => %{
          "type" => "string",
          "description" => "Glob pattern to filter files, e.g. '*.ex' or '**/*.exs'"
        },
        "ignore_case" => %{
          "type" => "boolean",
          "description" => "Case-insensitive search (default: false)"
        },
        "context" => %{
          "type" => "integer",
          "description" => "Number of lines of context to show around each match (default: 0)",
          "minimum" => 0
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of matches to return (default: 100)",
          "minimum" => 1
        }
      },
      "required" => ["pattern"]
    }
  end

  def bash do
    object(
      %{
        "command" => string("Bash command to execute"),
        "timeout" => integer("Timeout in seconds (optional, no default timeout)")
      },
      ["command"]
    )
  end

  def glob do
    object(
      %{
        "pattern" =>
          string(
            "Glob pattern to match, e.g. '*.ex', '**/*.json', 'lib/**/*.ex'. Use ** for recursive matching."
          ),
        "path" => string("Directory to search in (default: current working directory)"),
        "limit" => integer("Maximum number of results to return (default: 1000)", 1)
      },
      ["pattern"]
    )
  end

  def write do
    object(
      %{
        "path" => string("Path to the file to create (relative or absolute)"),
        "content" => string("Content to write to the file")
      },
      ["path", "content"]
    )
  end

  def url_fetch do
    object(
      %{
        "url" => string("The URL to fetch (must be http:// or https://)"),
        "max_length" => integer("Maximum characters to return (default: 50000)", 1)
      },
      ["url"]
    )
  end

  def edit do
    object(
      %{
        "path" => string("Path to the file to edit (relative or absolute)"),
        "content" => string("The new content to write or the replacement text."),
        "old_content" =>
          string(
            "Optional: The exact text to replace. If not provided, the entire file is overwritten."
          )
      },
      ["path", "content"]
    )
  end

  def ls do
    object(
      %{
        "path" => string("Directory to list (default: current working directory)"),
        "limit" => integer("Maximum number of entries to return (default: 500)", 1)
      },
      []
    )
  end

  def ask_user_question do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{
          "type" => "string",
          "description" => "The concise question to ask the user."
        },
        "options" => %{
          "type" => "array",
          "description" =>
            "Selectable answers to show before the freeform input. If the question has concrete choices or examples, put them here instead of only mentioning them in placeholder.",
          "items" => %{
            "oneOf" => [
              %{"type" => "string"},
              %{
                "type" => "object",
                "properties" => %{
                  "label" => %{"type" => "string"},
                  "value" => %{"type" => "string"},
                  "description" => %{"type" => "string"}
                },
                "required" => ["label"]
              }
            ]
          }
        },
        "allow_freeform" => %{
          "type" => "boolean",
          "description" =>
            "Whether the user may type a custom answer instead of selecting an option."
        },
        "placeholder" => %{
          "type" => "string",
          "description" =>
            "Placeholder text for the final custom-answer input only. Do not put selectable choices here."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" => "Optional answer timeout in milliseconds.",
          "minimum" => 1_000
        }
      },
      "required" => ["question"]
    }
  end

  defp object(properties, required),
    do: %{"type" => "object", "properties" => properties, "required" => required}

  defp string(description), do: %{"type" => "string", "description" => description}

  defp integer(description), do: %{"type" => "integer", "description" => description}

  defp integer(description, minimum),
    do: %{"type" => "integer", "description" => description, "minimum" => minimum}
end
