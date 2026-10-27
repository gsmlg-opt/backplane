defmodule Backplane.McpProtocol.Client.ResourceRequest do
  @moduledoc """
  Opaque caller-owned handle for an asynchronous resource operation.

  The logical identity remains stable across MRTR continuations. Awaiting is a
  one-time receive by the original owner; an observation timeout does not cancel
  the operation or transfer ownership.
  """

  @enforce_keys [:client, :logical_id, :owner, :reply_ref]
  defstruct [:client, :logical_id, :owner, :reply_ref]

  @opaque t :: %__MODULE__{
            client: pid(),
            logical_id: String.t(),
            owner: pid(),
            reply_ref: reference()
          }
end
