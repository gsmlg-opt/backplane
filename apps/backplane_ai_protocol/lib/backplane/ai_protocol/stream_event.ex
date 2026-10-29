defmodule Backplane.AiProtocol.StreamEvent do
  @moduledoc """
  One ordered provider stream observation.

  `index` is the provider item/tool index. `call_id` is the canonical call identity and
  `native_id` preserves a distinct provider identity. Argument deltas remain raw input bytes. Responses custom deltas carry
  `extensions["openai_responses::input_kind"] == "custom"`; completed calls retain
  the `{:custom, text}` argument tag.

  `resolved_model` is the latest non-empty model/version string observed in this
  provider stream, or `nil` until supplied by the provider. It is copied to each
  subsequent emitted event, including the terminal event; request model affinity
  never supplies it. Observations are scoped to one `Codec.stream_new/2` state.
  Hosts should consume events through `stream_finish/3` before finalizing a result,
  and keep protocol completion separate from provenance and transport ownership.
  """

  defstruct [
    :type,
    :index,
    :content_index,
    :call_id,
    :native_id,
    :name,
    :text,
    :arguments_delta,
    :content,
    :provider_state,
    :usage,
    :stop_reason,
    :completeness,
    :resolved_model,
    :error,
    extensions: %{}
  ]

  @type kind ::
          :text_delta
          | :reasoning_delta
          | :content
          | :tool_call_start
          | :tool_call_delta
          | :tool_call_done
          | :provider_state
          | :usage
          | :terminal
          | :error

  @type t :: %__MODULE__{type: kind(), resolved_model: String.t() | nil}
end
