defmodule Backplane.AgentRuntime.ConversationAdapter do
  @moduledoc """
  Host boundaries for `Backplane.AgentRuntime.Conversation`.

  `stream/2` returns a lazy enumerable of normalized event maps (structs are
  accepted). Types: response_started, content_text_delta, content_thinking_delta,
  tool_call_started, tool_call_arguments_delta, tool_call_completed,
  usage_updated, response_completed, response_failed. A completed tool call has
  `%{id: binary, name: binary, arguments: map}`; response_completed carries the
  authoritative assistant `message`. The first terminal ends enumeration.

  `provider_idle_timeout` opts into a finite idle timer renewed after each valid
  normalized event. The default provider timer bounds the entire effect. Tools
  and hooks retain their total effect limit. Normalized enumeration cannot see
  raw SSE comments or transport events omitted by the adapter; the transport
  owns raw stream observation timeouts.

  Optional Goal accounting consumes cumulative usage per attempt. Normalized
  `usage_updated` and `response_completed` events carry nonnegative integer
  `input_tokens`, `cached_tokens`, `output_tokens`, and `reasoning_tokens`, or
  nil/`:unknown` for unavailable metrics. Reasoning is already included in
  output. The runtime stamps report identity from the trusted run/incarnation
  and attempt, commits usage before acknowledging enumeration, and deduplicates
  terminal repeats. Budgeted Goals require a host-issued binding with
  authoritative usage capability; unknown charge closes automatic admission.
  Provider idle observation pauses while bounded local journal/Goal storage
  acknowledges an event. Root and storage deadlines remain enforced.

  `response_failed` may carry a normalized error map with `class: :usage_limit`
  for a proven provider usage-limit rejection. Other terminal provider errors
  block automatic Goal continuation. Hosts own error classification; the runtime
  does not infer quota failures from message text. An assistant message may carry
  `phase: :commentary`, `:final`, or `:final_answer`; absent phase is final for
  Goal empty-turn accounting.

  A host may call its existing provider facade here: no HTTP/SSE parser belongs
  in this runtime. Requests contain messages, turn_id, run_id, incarnation,
  step_id, attempt_id, catalog_revision, and canonical tools shaped as
  `%{name: binary, description: binary, parameters: map}`. Context is trusted,
  ephemeral and never persisted.

  Optional hooks run in bounded workers: prompt/2 before appending each user
  message, stop/2 after a response with no tools and no consumed steering.
  Stop may add a user message to continue (the host owns stop-hook recursion
  policy). `prepare_tool/2` runs before final schema/grant checks, approval and
  the invocation commit. It receives the pinned invocation and trusted context
  with informational `input_kind: :function | :custom`; it can allow unchanged
  input, return replacement arguments/raw custom input, or reject. Only input
  changes are accepted; descriptor, backend, catalog and authority remain pinned.
  The hook runs once per invocation, including supported nested calls. It must
  not dispatch effects. Post-tool hooks belong in the registered backend. A backend gets
  `backend_context.interact.(request)` for correlated waits, resolving to
  `{:ok, value}`. Only the trusted host should expose resolve/3 to its UI after
  authenticating the responder. Interaction answers never grant tool authority.
  """
  @callback stream(map(), map()) :: Enumerable.t()
  @callback prompt(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback stop([map()], map()) :: :stop | {:continue, map()} | {:error, term()}
  @callback prepare_tool(map(), map()) ::
              :allow
              | {:allow, map() | binary()}
              | {:deny, term()}
              | {:error, Backplane.AgentRuntime.Error.t()}
  @optional_callbacks prompt: 2, stop: 2, prepare_tool: 2
end
