defmodule Backplane.AgentRuntime.ConversationAdapter do
  @moduledoc """
  Host boundaries for `Backplane.AgentRuntime.Conversation`.

  `stream/2` returns a lazy enumerable of normalized event maps (structs are
  accepted). Types: response_started, content_text_delta, content_thinking_delta,
  tool_call_started, tool_call_arguments_delta, tool_call_completed,
  usage_updated, response_completed, response_failed. A completed tool call has
  `%{id: binary, name: binary, arguments: map}`; response_completed carries the
  authoritative assistant `message`. The first terminal ends enumeration.

  A host may call its existing provider facade here: no HTTP/SSE parser belongs
  in this runtime. Requests contain messages, turn_id, run_id, incarnation,
  step_id and attempt_id. Context is trusted, ephemeral and never persisted.

  Optional hooks run in bounded workers: prompt/2 before appending each user
  message, stop/2 after a response with no tools and no consumed steering.
  Stop may add a user message to continue (the host owns stop-hook recursion
  policy). Tool permission/pre/post hooks belong in the registered backend's
  execute/1; the runtime's grant/schema checks still precede it. A backend gets
  `backend_context.interact.(request)` for correlated waits, resolving to
  `{:ok, value}`. Only the trusted host should expose resolve/3 to its UI after
  authenticating the responder. Interaction answers never grant tool authority.
  """
  @callback stream(map(), map()) :: Enumerable.t()
  @callback prompt(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback stop([map()], map()) :: :stop | {:continue, map()} | {:error, term()}
  @optional_callbacks prompt: 2, stop: 2
end
