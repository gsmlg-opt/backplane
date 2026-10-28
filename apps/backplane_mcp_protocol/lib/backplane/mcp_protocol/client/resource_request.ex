defmodule Backplane.McpProtocol.Client.ResourceRequest do
  @moduledoc """
  Opaque caller-owned handle for an asynchronous resource operation.

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

  @doc false
  @spec owned_by?(term(), pid()) :: boolean()
  def owned_by?(%__MODULE__{owner: owner}, caller), do: owner == caller
  def owned_by?(_, _), do: false

  @doc false
  @spec client(t()) :: pid()
  def client(%__MODULE__{client: client}), do: client

  @doc false
  @spec reply_ref(t()) :: reference()
  def reply_ref(%__MODULE__{reply_ref: ref}), do: ref

  @doc false
  @spec cancellation_key(t()) :: pos_integer()
  def cancellation_key(%__MODULE__{cancellation_key: key}), do: key
end
