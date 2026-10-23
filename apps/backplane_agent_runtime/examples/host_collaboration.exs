# From this app: mix run examples/host_collaboration.exs
# From a consumer: mix run deps/backplane_agent_runtime/examples/host_collaboration.exs
# All providers are deterministic; this example makes no network requests.
# This script owns linked OTP resources; a host application would supervise them.
Process.flag(:trap_exit, true)

defmodule HostCollaborationExample.Adapter do
  alias Backplane.AgentRuntime.Codex.MultiAgent

  def execute(operation) do
    arguments =
      case operation.collaboration_binding.action do
        :spawn ->
          %{"task_name" => operation.arguments["name"], "message" => operation.arguments["task"]}

        :wait ->
          %{"timeout_ms" => operation.arguments["milliseconds"]}
      end

    # Keep the admitted operation intact, including its original arguments.
    case MultiAgent.call_bound(operation, arguments) do
      {:ok, result} when operation.collaboration_binding.action == :spawn ->
        {:ok, %{session: result.task_name}}

      {:ok, result} ->
        {:ok, %{ready: not result.timed_out}}

      refusal_or_error ->
        refusal_or_error
    end
  end
end

defmodule HostCollaborationExample.Provider do
  def stream(%{messages: messages}, _context) do
    cond do
      Enum.any?(messages, &(&1[:name] == "agents_wait")) ->
        [%{type: :response_completed, message: %{role: :assistant, content: "Child finished."}}]

      Enum.any?(messages, &(&1[:name] == "sessions_spawn")) ->
        tool("wait-1", "agents_wait", %{"milliseconds" => 1_000})

      true ->
        tool("spawn-1", "sessions_spawn", %{"name" => "worker", "task" => "Say hello."})
    end
  end

  defp tool(id, name, arguments) do
    [
      %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}},
      %{type: :response_completed, message: %{role: :assistant, content: "Delegating."}}
    ]
  end
end

defmodule HostCollaborationExample.ChildProvider do
  def stream(_request, _context),
    do: [%{type: :response_completed, message: %{role: :assistant, content: "Hello."}}]
end

alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolRegistry}
alias Backplane.AgentRuntime.Codex.{Catalog, MultiAgent, Session}

base_authority = %{caller: "example-host", run_id: "example-root", grants: []}

{:ok, manager} =
  MultiAgent.start_link(
    parent_run_id: base_authority.run_id,
    parent_name: "/root",
    parent_authority: base_authority,
    child_options: fn _request, run_id, _parent ->
      {:ok, store} = EphemeralStore.new(1)

      {:ok,
       [
         run_id: run_id,
         store: EphemeralStore,
         context: store,
         provider: HostCollaborationExample.ChildProvider,
         registry: %ToolRegistry{},
         authority: %{caller: "example-host", run_id: run_id, grants: []},
         work: 5,
         run_timeout: 5_000
       ]}
    end,
    min_wait_timeout_ms: 0
  )

definitions = [
  {:spawn, "sessions_spawn", %{"name" => %{"type" => "string"}, "task" => %{"type" => "string"}}},
  {:wait, "agents_wait", %{"milliseconds" => %{"type" => "integer", "minimum" => 0}}}
]

contracts =
  Enum.map(definitions, fn {action, name, properties} ->
    {:ok, contract} =
      MultiAgent.bind_contract(manager, action, %{
        name: name,
        tool_revision: 1,
        description: "Host-owned #{name} contract",
        schema: %{
          "type" => "object",
          "properties" => properties,
          "required" => Map.keys(properties),
          "additionalProperties" => false
        },
        backend: HostCollaborationExample.Adapter,
        safety: %{read_only: action == :wait, retry_safe: false, parallel_safe: false}
      })

    contract
  end)

authority =
  Map.merge(base_authority, %{
    grants: Enum.map(contracts, & &1.tool_name),
    tool_revisions: Map.new(contracts, &{&1.tool_name, &1.tool_revision}),
    tool_bindings: Map.new(contracts, &{&1.tool_name, &1.collaboration_binding.fingerprint})
  })

{:ok, session} = Session.start_link(owner_pid: self())
{:ok, binding} = Session.bind(session, authority)

contracts =
  Enum.map(contracts, fn contract ->
    put_in(contract, [:backend_context, :session_binding], binding)
  end)

{:ok, bundle} = Catalog.admit(contracts, authority)
{:ok, store} = EphemeralStore.new(1)

{:ok, conversation} =
  Conversation.start_link(
    run_id: authority.run_id,
    store: EphemeralStore,
    context: store,
    provider: HostCollaborationExample.Provider,
    registry: bundle.registry,
    tools: bundle.tools,
    authority: bundle.authority,
    session_binding: binding,
    subscriber: self(),
    work: 10,
    run_timeout: 5_000
  )

{:ok, _} = Conversation.prompt(conversation, "Delegate using the host's tool contracts.")

receive do
  {:agent_runtime, "example-root", %{type: :run_completed}} ->
    messages = Conversation.status(conversation).messages

    true =
      Enum.any?(
        messages,
        &(&1[:name] == "sessions_spawn" and &1[:result][:session] == "/root/worker")
      )

    true = Enum.any?(messages, &(&1[:name] == "agents_wait" and &1[:result][:ready] == true))
    IO.inspect(messages, label: "Original host names in the committed transcript")
after
  5_000 -> raise "host collaboration example did not complete"
end

{:ok, %{status: :confirmed}} = Session.close(session)

for process <- [conversation, manager, session],
    Process.alive?(process),
    do: GenServer.stop(process)
