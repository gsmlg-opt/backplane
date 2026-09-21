defmodule Sigma.Coding.Tool do
  @moduledoc false
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: map()
  @callback metadata() :: map()
  @callback execute(String.t(), map(), keyword()) :: term()
  @optional_callbacks metadata: 0
end

defmodule Sigma.Tools.Store do
  @moduledoc false

  # Todo is loaded for its schema. Executing its session backend is outside this probe.
  def from_opts(opts), do: compile_only(opts)
  def get_todo_state(store), do: compile_only(store)
  def put_todo_state(_store, _state), do: compile_only(:ok)

  defp compile_only(value) do
    if System.get_env("SIGMA_SOURCE_PROBE_EXECUTE") == "true",
      do: value,
      else: raise("Sigma Todo backend must not execute in the schema probe")
  end
end

defmodule Sigma.Coding.Utils.PathUtils do
  @moduledoc false

  def safe_resolve(path, cwd), do: probe_path(path, cwd)
  def safe_resolve(path, cwd, _opts), do: probe_path(path, cwd)
  def relative_to(path, _cwd), do: path

  defp probe_path(path, cwd) do
    if System.get_env("SIGMA_SOURCE_PROBE_EXECUTE") == "true",
      do: {:ok, Path.expand(path, cwd)},
      else: {:error, :not_executed}
  end
end

defmodule Req do
  @moduledoc false

  def get(_url, _opts) do
    if System.get_env("SIGMA_SOURCE_PROBE_EXECUTE") == "true",
      do: {:ok, %{status: 599, body: "not executed"}},
      else: {:error, RuntimeError.exception("not executed")}
  end
end

defmodule SigmaSource do
  @moduledoc """
  Read-only consumer probe for Sigma provider normalization and built-in schemas.

  It loads Sigma's real provider facade, provider event structs, and built-in
  tool modules from `SIGMA_SOURCE`. The local `Sigma.Coding.Tool`, Store, path, and Req
  stubs satisfy compile-time references only; no Sigma tool implementation is
  executed. The probe therefore demonstrates provider adaptation, complete
  runtime turn execution, and exact schema-function compatibility, not Sigma
  dispatcher or tool-backend integration.
  """

  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.EphemeralStore
  alias Backplane.AgentRuntime.InputSchema
  alias Backplane.AgentRuntime.ToolRegistry

  defmodule LegacyProvider do
    def stream(params) do
      if Enum.any?(params.context.messages, &(&1[:role] == :tool)) do
        [
          {:start, %{role: :assistant}},
          {:text_delta, 0, "finished", %{}},
          {:done, :stop, %{role: :assistant, content: "finished", usage: %{input: 2, output: 1}}}
        ]
      else
        [
          {:start, %{role: :assistant}},
          {:thinking_delta, 0, "inspect", %{}},
          {:text_delta, 0, "reading", %{}},
          {:toolcall_start, 1, %{}},
          {:toolcall_delta, 1, ~s({"action":"add","content":"runtime probe"}), %{}},
          {:toolcall_end, 1,
           %{
             id: "call_1",
             name: "todo",
             arguments: %{"action" => "add", "content" => "runtime probe", "status" => "pending"}
           }, %{}},
          {:done, :tool_use,
           %{role: :assistant, content: "reading", usage: %{input: 1, output: 1}}}
        ]
      end
    end
  end

  defmodule ProviderAdapter do
    def stream(request, _context) do
      provider_request =
        struct!(Sigma.Ai.ProviderRequest,
          model: %{id: "scripted"},
          context: %{messages: request.messages},
          turn_id: request.turn_id,
          options: []
        )

      apply(Sigma.Ai.Provider, :stream, [SigmaSource.LegacyProvider, provider_request])
    end
  end

  defmodule ToolBackend do
    def execute(_operation), do: {:ok, %{text: "contents"}}
  end

  def verify! do
    sigma = System.fetch_env!("SIGMA_SOURCE")
    load_provider!(sigma)
    load_tools!(sigma)
    verify_conversation!()
    verify_schemas!()
  end

  defp load_provider!(sigma) do
    for file <- [
          "provider_usage.ex",
          "provider_request.ex",
          "provider_stop_reason.ex",
          "provider_event.ex",
          "provider_error.ex",
          "provider_capabilities.ex",
          "provider.ex"
        ] do
      Code.require_file(Path.join([sigma, "apps/sigma_ai/lib/sigma_ai", file]))
    end
  end

  defp load_tools!(sigma) do
    for tool <- ~w(read bash grep glob write url_fetch edit ls ask_user_question) do
      Code.require_file(
        Path.join([sigma, "apps/sigma_coding/lib/sigma_coding/tools", "#{tool}.ex"])
      )
    end

    for file <- ~w(result todo) do
      Code.require_file(Path.join([sigma, "apps/sigma_tools/lib/sigma_tools", "#{file}.ex"]))
    end
  end

  defp verify_conversation! do
    case Process.whereis(Sigma.Ai.ProviderTaskSupervisor) do
      nil -> {:ok, _pid} = Task.Supervisor.start_link(name: Sigma.Ai.ProviderTaskSupervisor)
      _pid -> :ok
    end

    {:ok, store} = EphemeralStore.new(1)

    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "read",
        tool_revision: 1,
        schema: apply(Sigma.Coding.Tools.Read, :schema, []),
        safety: %{read_only: true, retry_safe: true, parallel_safe: false},
        backend: ToolBackend,
        backend_context: %{}
      })

    {:ok, registry} =
      ToolRegistry.register(registry, %{
        tool_name: "todo",
        tool_revision: 1,
        schema: apply(Sigma.Tools.Todo, :schema, []),
        safety: %{read_only: false, retry_safe: false, parallel_safe: false},
        backend: ToolBackend,
        backend_context: %{}
      })

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "sigma-source",
        incarnation: 1,
        store: EphemeralStore,
        context: store,
        provider: ProviderAdapter,
        subscriber: self(),
        registry: registry,
        authority: %{
          caller: "sigma-source",
          run_id: "sigma-source",
          grants: ["read", "todo"],
          tool_revision: 1
        },
        work: 10,
        run_timeout: 5_000
      )

    try do
      {:ok, _run} = Conversation.prompt(conversation, "inspect README")
      events = receive_until_complete([])
      true = Enum.any?(events, &(&1.type == :content_thinking_delta))
      true = Enum.any?(events, &(&1.type == :content_text_delta))
      true = Enum.any?(events, &(&1.type == :tool_call_completed))

      status = Conversation.status(conversation)
      :terminal = status.phase
      3 = status.run.execution_budget.used
      2 = Enum.count(status.messages, &(&1[:role] == :assistant))

      %{role: :tool, tool_call_id: "call_1", name: "todo", result: %{is_error: false}} =
        Enum.find(status.messages, &(&1[:role] == :tool))

      "finished" = List.last(status.messages).content
    after
      if Process.alive?(conversation), do: GenServer.stop(conversation)
    end
  end

  defp receive_until_complete(events) do
    receive do
      {:agent_runtime, "sigma-source", %{type: :run_completed} = event} ->
        Enum.reverse([event | events])

      {:agent_runtime, "sigma-source", event} ->
        receive_until_complete([event | events])
    after
      5_000 -> raise "Sigma-backed conversation did not complete"
    end
  end

  defp verify_schemas! do
    todo_schema = apply(Sigma.Tools.Todo, :schema, [])

    {:error, %Backplane.AgentRuntime.Error{class: :validation, details: %{property: "action"}}} =
      InputSchema.validate(todo_schema, %{})

    fixtures = [
      {Sigma.Coding.Tools.Read, %{"path" => "README.md", "offset" => 1}},
      {Sigma.Coding.Tools.Bash, %{"command" => "mix test"}},
      {Sigma.Coding.Tools.Grep, %{"pattern" => "TODO", "context" => 0}},
      {Sigma.Coding.Tools.Glob, %{"pattern" => "**/*.ex", "limit" => 1}},
      {Sigma.Coding.Tools.Write, %{"path" => "notes.txt", "content" => "text"}},
      {Sigma.Coding.Tools.UrlFetch, %{"url" => "https://example.test", "max_length" => 1}},
      {Sigma.Coding.Tools.Edit, %{"path" => "notes.txt", "content" => "new"}},
      {Sigma.Coding.Tools.LS, %{}},
      {Sigma.Coding.Tools.AskUserQuestion,
       %{
         "question" => "Continue?",
         "options" => ["Yes", %{"label" => "No", "value" => "no"}],
         "timeout_ms" => 1_000
       }},
      {Sigma.Tools.Todo,
       %{"action" => "add", "content" => "runtime probe", "status" => "in_progress"}}
    ]

    Enum.each(fixtures, fn {tool, arguments} ->
      {:ok, ^arguments} = InputSchema.validate(tool.schema(), arguments)
    end)

    assert_enum_rejection(todo_schema, %{"action" => "archive"})
    assert_enum_rejection(todo_schema, %{"action" => "add", "status" => "paused"})
  end

  defp assert_enum_rejection(schema, arguments) do
    case InputSchema.validate(schema, arguments) do
      {:error, %Backplane.AgentRuntime.Error{class: :validation}} -> :ok
      {:ok, _} -> raise "Sigma Todo enum accepted an invalid argument"
      {:error, error} -> raise "Sigma Todo enum returned #{inspect(error)} instead of validation"
    end
  end
end
