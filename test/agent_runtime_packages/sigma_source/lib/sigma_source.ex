defmodule SigmaSource do
  @moduledoc """
  Read-only consumer probe for Sigma's current provider and tool catalog.

  Loads actual Sigma source without compile scaffolding. Sigma's catalog composes
  native Runtime profiles and MCP descriptors; its provider normalizes scripted
  legacy events into a complete Conversation turn. Native plan execution and the
  Sigma tool-result adapter execute, while MCP network access, commands, hooks,
  Sigma sessions, and persistence remain outside this probe.
  """

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, InputSchema, Plan}

  @native_tools ~w(apply_patch update_plan view_image clock::curr_time clock::sleep)
  @plan %{"plan" => [%{"step" => "runtime probe", "status" => "completed"}]}
  @echo_schema %{
    "type" => "object",
    "properties" => %{"mode" => %{"type" => "string", "enum" => ["inspect", "report"]}},
    "required" => ["mode"],
    "additionalProperties" => false
  }

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
          {:text_delta, 0, "planning", %{}},
          {:toolcall_start, 1, %{}},
          {:toolcall_delta, 1, ~s({"plan":[{"step":"runtime probe","status":"completed"}]}), %{}},
          {:toolcall_end, 1,
           %{
             id: "call_plan",
             name: "update_plan",
             arguments: %{"plan" => [%{"step" => "runtime probe", "status" => "completed"}]}
           }, %{}},
          {:toolcall_end, 2,
           %{id: "call_echo", name: "probe::echo", arguments: %{"mode" => "inspect"}}, %{}},
          {:done, :tool_use,
           %{role: :assistant, content: "planning", usage: %{input: 1, output: 1}}}
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

  def verify! do
    load_sources!(System.fetch_env!("SIGMA_SOURCE"))
    {:ok, supervisor} = Task.Supervisor.start_link(name: Sigma.Ai.ProviderTaskSupervisor)
    {:ok, plan} = Plan.start_link("sigma-source")

    try do
      admitted = admit_catalog!(plan)
      verify_schemas!(admitted)
      verify_conversation!(admitted, plan)
    after
      if Process.alive?(plan), do: GenServer.stop(plan)
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
    end
  end

  defp load_sources!(sigma) do
    files = [
      {"sigma_ai", ~w(provider_usage provider_request provider_stop_reason provider_event
         provider_error provider_capabilities provider)},
      {"sigma_coding", ~w(mcp/tool mcp utils/path_utils tool_metadata tool tool_error tool_update
         tool_result)},
      {"sigma_agent", ~w(backplane/tool_backend backplane/tool_catalog)}
    ]

    paths =
      for {app, modules} <- files, module <- modules do
        Path.join([sigma, "apps", app, "lib", app, module <> ".ex"])
      end

    case Kernel.ParallelCompiler.compile(paths) do
      {:ok, _modules, []} -> :ok
      result -> raise "Sigma source compilation failed or warned: #{inspect(result)}"
    end
  end

  defp admit_catalog!(plan) do
    authority = %{
      caller: "sigma-source",
      run_id: "sigma-source",
      grants: @native_tools ++ ["probe::echo"],
      tool_revision: 1
    }

    {:ok, profile} =
      Codex.profile(
        :pinned_local,
        %{workspace: File.cwd!(), plan: plan},
        %{authority | grants: @native_tools},
        tools: @native_tools
      )

    tool =
      struct!(Sigma.Coding.MCP.Tool,
        name: "probe::echo",
        description: "Read-only source probe",
        schema: @echo_schema,
        server_id: "probe",
        server_tool_name: "echo"
      )

    test = self()

    execute = fn operation ->
      "probe::echo" = operation.tool_name
      %{"mode" => "inspect"} = operation.arguments
      send(test, :sigma_backend_executed)
      {:ok, %{content: [%{type: :text, text: "inspected"}], details: %{source: "sigma"}}}
    end

    {:ok, admitted} =
      apply(Sigma.Agent.Backplane.ToolCatalog, :admit, [
        [tool],
        authority,
        execute,
        [profiles: [profile]]
      ])

    true = Enum.sort(admitted.accepted) == Enum.sort(authority.grants)
    [] = admitted.rejected
    [] = admitted.hosted_tools

    Enum.each(@native_tools, fn name ->
      true = admitted.registry.tools[name] == profile.registry.tools[name]
    end)

    @echo_schema = admitted.registry.tools["probe::echo"].schema

    {:error, %Error{class: :forbidden}} =
      apply(Sigma.Agent.Backplane.ToolCatalog, :admit, [
        [],
        %{authority | caller: "another-host"},
        execute,
        [profiles: [profile]]
      ])

    admitted
  end

  defp verify_conversation!(admitted, plan) do
    {:ok, store} = EphemeralStore.new(1)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "sigma-source",
        incarnation: 1,
        store: EphemeralStore,
        context: store,
        provider: ProviderAdapter,
        subscriber: self(),
        registry: admitted.registry,
        tools: admitted.tools,
        authority: admitted.authority,
        schema_admission: :strict,
        work: 10,
        run_timeout: 5_000
      )

    try do
      {:ok, _run} = Conversation.prompt(conversation, "inspect and update the plan")
      events = receive_until_complete([])
      true = Enum.any?(events, &(&1.type == :content_thinking_delta))
      true = Enum.any?(events, &(&1.type == :content_text_delta))
      2 = Enum.count(events, &(&1.type == :tool_call_completed))

      receive do
        :sigma_backend_executed -> :ok
      after
        0 -> raise "Sigma tool backend was not executed"
      end

      status = Conversation.status(conversation)
      :terminal = status.phase
      4 = status.run.execution_budget.used
      2 = Enum.count(status.messages, &(&1[:role] == :assistant))

      for {id, name} <- [{"call_plan", "update_plan"}, {"call_echo", "probe::echo"}] do
        %{role: :tool, tool_call_id: ^id, name: ^name, result: %{is_error: false}} =
          Enum.find(status.messages, &(&1[:tool_call_id] == id))
      end

      {:ok, %{revision: 2, content: %{"plan" => steps}}} = Plan.read(plan)
      true = steps == @plan["plan"]
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

  defp verify_schemas!(admitted) do
    fixtures = [
      {"update_plan", @plan},
      {"view_image", %{"path" => "pixel.png", "detail" => "original"}},
      {"clock::curr_time", %{}},
      {"clock::sleep", %{"duration_ms" => 1}},
      {"probe::echo", %{"mode" => "report"}}
    ]

    Enum.each(fixtures, fn {name, arguments} ->
      {:ok, ^arguments} = InputSchema.validate(admitted.registry.tools[name].schema, arguments)
    end)

    [%{type: "custom", name: "apply_patch", format: %{"syntax" => "lark"}}] =
      Enum.filter(admitted.tools, &(&1.name == "apply_patch"))

    plan_schema = admitted.registry.tools["update_plan"].schema
    {:error, %Error{class: :validation}} = InputSchema.validate(plan_schema, %{})

    assert_rejection(plan_schema, %{"plan" => [%{"step" => "invalid", "status" => "paused"}]})

    assert_rejection(admitted.registry.tools["view_image"].schema, %{
      "path" => "x",
      "detail" => "low"
    })

    assert_rejection(@echo_schema, %{"mode" => "write"})
  end

  defp assert_rejection(schema, arguments) do
    {:error, %Error{class: :validation}} = InputSchema.validate(schema, arguments)
  end
end
