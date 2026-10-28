defmodule Backplane.McpProtocol.Client.EventRequest do
  @moduledoc """
  Opaque caller-owned handle for an asynchronous event descriptor page.

  The logical identity remains stable across MRTR continuations. Awaiting is a
  one-time receive by the original owner; an observation timeout does not cancel
  the operation or transfer ownership.
  """

  @enforce_keys [:client, :logical_id, :owner, :reply_ref]
  defstruct [
    :client,
    :logical_id,
    :owner,
    :reply_ref,
    :identity,
    :cancellation_key,
    :retirement_deadline
  ]

  @opaque t :: %__MODULE__{
            client: pid(),
            logical_id: String.t(),
            owner: pid(),
            reply_ref: reference(),
            identity: map() | nil,
            cancellation_key: pos_integer() | nil,
            retirement_deadline: integer() | nil
          }
end
