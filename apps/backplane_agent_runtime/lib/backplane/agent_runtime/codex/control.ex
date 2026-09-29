defmodule Backplane.AgentRuntime.Codex.Control do
  @moduledoc "Pinned interactive, permission, environment, and context control tools."

  alias Backplane.AgentRuntime.{Codex.Contract, Codex.Readiness, Error}

  @new_context_message "A new context window will start without summarizing conversation history."

  @spec contracts(map()) :: [map()]
  def contracts(context) when is_map(context) do
    context
    |> contract_attrs()
    |> Enum.filter(&configured?(&1.name, context))
  end

  @spec definitions() :: [map()]
  def definitions do
    %{}
    |> contract_attrs()
    |> Enum.map(fn attrs ->
      {:ok, contract} = Contract.new(attrs)
      Contract.provider_definition(contract)
    end)
  end

  @spec call(map()) :: {:ok, map()} | {:error, Error.t()}
  def call(%{tool_name: "request_user_input", arguments: arguments} = operation) do
    with {:ok, interact} <- callback(operation, :interact, 1),
         :ok <- validate_questions(arguments["questions"], true),
         {:ok, response} <-
           interact.(%{kind: :request_user_input, questions: arguments["questions"]}) do
      {:ok, normalize_answers(response)}
    end
  end

  def call(%{tool_name: "request_user_input_async", arguments: arguments} = operation) do
    with {:ok, emit} <- callback(operation, :emit, 1),
         :ok <- validate_questions(arguments["questions"], false),
         :ok <- emit.(%{type: :async_user_input_requested, questions: arguments["questions"]}) do
      {:ok, %{accepted: true}}
    end
  end

  def call(
        %{tool_name: "send_message_to_user_async", arguments: %{"message" => message}} =
          operation
      ) do
    with true <-
           (is_binary(message) and String.trim(message) != "") or validation("message required"),
         {:ok, emit} <- callback(operation, :emit, 1),
         :ok <- emit.(%{type: :async_user_message, message: String.trim(message)}) do
      {:ok, %{accepted: true}}
    end
  end

  def call(%{tool_name: "request_permissions", arguments: arguments} = operation) do
    with :ok <- validate_permissions(arguments),
         {:ok, interact} <- callback(operation, :interact, 1),
         {:ok, grant} <- host_callback(operation, :grant_permissions, 2),
         {:ok, response} <-
           interact.(%{
             kind: :request_permissions,
             environment_id: arguments["environment_id"],
             reason: arguments["reason"],
             permissions: arguments["permissions"]
           }),
         {:ok, _receipt} <- grant.(arguments, response) do
      {:ok, atomize_permission_response(response)}
    end
  end

  def call(
        %{tool_name: "wait_for_environment", arguments: %{"environment_id" => id}} =
          operation
      ) do
    with true <- (is_binary(id) and id != "") or validation("environment_id is required"),
         {:ok, provider} <- host_callback(operation, :environment_provider, 1),
         {:ok, state} <-
           Readiness.await(
             fn -> provider.(id) end,
             host_value(operation, :environment_wait_timeout, 300_000),
             host_value(operation, :cancelled, fn -> false end)
           ) do
      {:ok, %{environment_id: id, status: "ready", environment: state}}
    end
  end

  def call(%{tool_name: "new_context"} = operation) do
    with {:ok, request_new_context} <- callback(operation, :request_new_context, 0),
         :ok <- request_new_context.() do
      {:ok, %{message: @new_context_message}}
    end
  end

  def call(%{tool_name: "get_context_remaining"} = operation) do
    with {:ok, provider} <- host_callback(operation, :context_remaining, 0) do
      case provider.() do
        value when is_integer(value) and value >= 0 ->
          {:ok, %{tokens_left: value}}

        nil ->
          {:ok, %{tokens_left: nil}}

        _ ->
          {:error, Error.new(:malformed_result, "context token provider returned invalid data")}
      end
    end
  end

  def call(_operation),
    do: {:error, Error.new(:not_found, "unknown Codex control tool")}

  defp contract_attrs(context) do
    backend_context = %{family: :control, context: context}

    [
      contract(
        "request_permissions",
        "Request additional filesystem or network permissions from the user and wait for the client to grant a subset of the requested permission profile. Use environment_id to target a specific attached environment; omit it to use the primary environment. Relative filesystem paths resolve against the selected environment cwd. Granted permissions apply automatically to later shell-like commands in the current turn, or for the rest of the session if the client approves them at session scope.",
        permissions_schema(),
        backend_context,
        false
      ),
      contract(
        "request_user_input",
        "Request user input for one to three short questions and wait for the response.",
        request_user_input_schema(),
        backend_context,
        false
      ),
      contract(
        "request_user_input_async",
        "Ask the user one or more questions during ongoing work without waiting for a reply.",
        async_questions_schema(),
        backend_context,
        false
      ),
      contract(
        "send_message_to_user_async",
        "Send a concise message that needs the user's attention during ongoing work. The tool returns immediately without ending the turn or waiting for a reply; any reply arrives asynchronously as a new user message.",
        message_schema(),
        backend_context,
        false
      ),
      contract(
        "wait_for_environment",
        "Wait for a selected execution environment marked as `starting` to become available.",
        environment_schema(),
        backend_context,
        true
      ),
      contract(
        "new_context",
        "Start a new context window. Does not clear, reset, or otherwise affect environment state.",
        empty_schema(),
        backend_context,
        false
      ),
      contract(
        "get_context_remaining",
        "Get the remaining tokens in the current context window.",
        empty_schema(),
        backend_context,
        true,
        context_remaining_output_schema()
      )
    ]
  end

  defp configured?(name, context)
       when name in [
              "request_user_input",
              "request_user_input_async",
              "send_message_to_user_async",
              "new_context"
            ],
       do: Map.get(context, :root?, false) == true

  defp configured?("request_permissions", context),
    do: is_function(Map.get(context, :grant_permissions), 2)

  defp configured?("wait_for_environment", context),
    do: is_function(Map.get(context, :environment_provider), 1)

  defp configured?("get_context_remaining", context),
    do: is_function(Map.get(context, :context_remaining), 0)

  defp contract(name, description, schema, backend_context, read_only, output_schema \\ nil) do
    %{
      name: name,
      description: description,
      schema: schema,
      output_schema: output_schema,
      backend: Backplane.AgentRuntime.Codex.Backend,
      backend_context: backend_context,
      safety: %{read_only: read_only, retry_safe: read_only, parallel_safe: read_only},
      source: %{revision: "46fdd5ef39735f4159cdcf0ec5e85c10521494e5", family: :control}
    }
  end

  defp request_user_input_schema do
    option =
      object_schema(
        %{
          "label" => string_schema("User-facing label (1-5 words)."),
          "description" =>
            string_schema("One short sentence explaining impact/tradeoff if selected.")
        },
        ["label", "description"]
      )

    question =
      object_schema(
        %{
          "id" => string_schema("Stable identifier for mapping answers (snake_case)."),
          "header" => string_schema("Short header label shown in the UI (12 or fewer chars)."),
          "question" => string_schema("Single-sentence prompt shown to the user."),
          "options" => %{"type" => "array", "items" => option}
        },
        ["id", "header", "question", "options"]
      )

    object_schema(%{"questions" => %{"type" => "array", "items" => question}}, ["questions"])
  end

  defp async_questions_schema do
    question =
      object_schema(
        %{
          "title" => string_schema("The complete question shown to the user."),
          "options" => %{
            "type" => "array",
            "minItems" => 1,
            "items" => %{"type" => "string"}
          }
        },
        ["title"]
      )

    object_schema(
      %{"questions" => %{"type" => "array", "minItems" => 1, "items" => question}},
      ["questions"]
    )
  end

  defp message_schema,
    do:
      object_schema(
        %{"message" => string_schema("The concise question or update to send to the user.")},
        ["message"]
      )

  defp environment_schema,
    do:
      object_schema(
        %{
          "environment_id" =>
            string_schema(
              "The exact environment ID marked as `starting` in `<environment_context>`."
            )
        },
        ["environment_id"]
      )

  defp permissions_schema do
    permissions =
      object_schema(
        %{
          "network" => object_schema(%{"enabled" => %{"type" => "boolean"}}, nil),
          "file_system" =>
            object_schema(
              %{
                "read" => %{"type" => "array", "items" => %{"type" => "string"}},
                "write" => %{"type" => "array", "items" => %{"type" => "string"}}
              },
              nil
            )
        },
        nil
      )

    object_schema(
      %{
        "reason" => %{"type" => "string"},
        "environment_id" => %{"type" => "string"},
        "permissions" => permissions
      },
      ["permissions"]
    )
  end

  defp empty_schema, do: object_schema(%{}, nil)

  defp context_remaining_output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "tokens_left" => %{"anyOf" => [%{"type" => "integer"}, %{"type" => "null"}]}
      },
      "required" => ["tokens_left"],
      "additionalProperties" => false
    }
  end

  defp object_schema(properties, required) do
    %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    |> then(fn schema -> if required, do: Map.put(schema, "required", required), else: schema end)
  end

  defp string_schema(description), do: %{"type" => "string", "description" => description}

  defp validate_questions(questions, require_options?)
       when is_list(questions) and questions != [] do
    valid? =
      Enum.all?(questions, fn question ->
        is_map(question) and nonempty_string?(question["title"] || question["question"]) and
          valid_options?(question["options"], require_options?)
      end)

    if valid?, do: :ok, else: validation("questions are malformed")
  end

  defp validate_questions(_, _), do: validation("questions must not be empty")

  defp valid_options?(options, true),
    do: is_list(options) and options != [] and Enum.all?(options, &valid_option?/1)

  defp valid_options?(nil, false), do: true

  defp valid_options?(options, false),
    do: is_list(options) and options != [] and Enum.all?(options, &valid_option?/1)

  defp valid_option?(option) when is_binary(option), do: String.trim(option) != ""

  defp valid_option?(%{"label" => label, "description" => description}),
    do: nonempty_string?(label) and nonempty_string?(description)

  defp valid_option?(_), do: false

  defp validate_permissions(%{"permissions" => permissions}) when is_map(permissions) do
    if map_size(permissions) > 0,
      do: :ok,
      else: validation("request_permissions requires at least one permission")
  end

  defp validate_permissions(_), do: validation("permissions are required")

  defp normalize_answers(%{"answers" => answers}), do: %{answers: answers}
  defp normalize_answers(%{answers: answers}), do: %{answers: answers}
  defp normalize_answers(response) when is_map(response), do: response

  defp atomize_permission_response(response) when is_map(response) do
    %{
      permissions: Map.get(response, "permissions", Map.get(response, :permissions, %{})),
      scope: Map.get(response, "scope", Map.get(response, :scope, "turn")),
      strict_auto_review:
        Map.get(response, "strict_auto_review", Map.get(response, :strict_auto_review, false))
    }
  end

  defp callback(operation, key, arity) do
    value = get_in(operation, [:backend_context, key])

    if is_function(value, arity),
      do: {:ok, value},
      else: {:error, Error.new(:unsupported_capability, "#{key} callback is unavailable")}
  end

  defp host_callback(operation, key, arity) do
    value = host_value(operation, key)

    if is_function(value, arity),
      do: {:ok, value},
      else: {:error, Error.new(:unsupported_capability, "#{key} host callback is unavailable")}
  end

  defp host_value(operation, key, default \\ nil),
    do: get_in(operation, [:backend_context, :context, key]) || default

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp validation(message), do: {:error, Error.new(:validation, message)}
end
