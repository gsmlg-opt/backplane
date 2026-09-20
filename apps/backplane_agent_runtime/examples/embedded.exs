defmodule EmbeddedExample.Provider do
  @behaviour Backplane.AgentRuntime.ConversationAdapter
  def stream(%{messages: messages}, _context) do
    if Enum.any?(messages, &(&1.role == :tool)) do
      [
        %{type: :content_text_delta, delta: "The tool answered."},
        %{type: :response_completed, message: %{role: :assistant, content: "The tool answered."}}
      ]
    else
      [
        %{type: :content_thinking_delta, delta: "Use the echo tool."},
        %{
          type: :tool_call_completed,
          tool_call: %{id: "echo_1", name: "echo", arguments: %{"text" => "hello"}}
        },
        %{type: :response_completed, message: %{role: :assistant, content: "Echoing."}}
      ]
    end
  end
end

defmodule EmbeddedExample.Echo do
  def execute(%{arguments: %{"text" => text}}), do: {:ok, %{content: text}}
end

alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolRegistry}
{:ok, store} = EphemeralStore.new(1)

{:ok, registry} =
  ToolRegistry.register(%ToolRegistry{}, %{
    tool_name: "echo",
    tool_revision: 1,
    backend: EmbeddedExample.Echo,
    schema: %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string"}},
      "required" => ["text"]
    },
    safety: %{read_only: true, retry_safe: true, parallel_safe: true}
  })

{:ok, pid} =
  Conversation.start_link(
    run_id: "example",
    store: EphemeralStore,
    context: store,
    provider: EmbeddedExample.Provider,
    registry: registry,
    subscriber: self(),
    authority: %{caller: "example", run_id: "example", grants: ["echo"], tool_revision: 1},
    work: 3,
    run_timeout: 5_000
  )

{:ok, _} = Conversation.prompt(pid, "Say hello through the tool")

receive do
  {:agent_runtime, "example", %{type: :run_completed}} ->
    IO.inspect(Conversation.status(pid).messages, label: "Committed transcript")
after
  5_000 -> raise "example did not complete"
end

GenServer.stop(pid)
