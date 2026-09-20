defmodule Backplane.AiProtocol.StreamEvent do
  @moduledoc """
  One ordered provider stream observation.

  `index` is the provider item/tool index. `call_id` is the canonical call identity and
  `native_id` preserves a distinct provider identity. Argument deltas remain raw JSON bytes.
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

  @type t :: %__MODULE__{type: kind()}
end
