defmodule Backplane.AiProtocol.ExecutionContext do
  @moduledoc """
  Trusted host-owned execution data.

  This type is host-local. A payload cannot create it, and it must never be exposed as a
  portable `Request` field.
  """

  alias Backplane.AiProtocol.Error

  @enforce_keys [:principal, :resolved_endpoint]
  defstruct [
    :principal,
    :permissions,
    :resolved_endpoint,
    :credential_binding,
    :transport,
    :deadlines,
    :route_policy,
    :capability_revision,
    :resource_limits,
    :logging_policy
  ]

  @type t :: %__MODULE__{
          principal: term(),
          permissions: term() | nil,
          resolved_endpoint: term(),
          credential_binding: term() | nil,
          transport: map() | nil,
          deadlines: map() | nil,
          route_policy: map() | nil,
          capability_revision: term() | nil,
          resource_limits: map() | nil,
          logging_policy: map() | nil
        }

  @keys [
    :principal,
    :permissions,
    :resolved_endpoint,
    :credential_binding,
    :transport,
    :deadlines,
    :route_policy,
    :capability_revision,
    :resource_limits,
    :logging_policy
  ]

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(_attrs),
    do: {:error, Error.invalid!("ExecutionContext cannot be created from a payload")}

  @doc """
  Rejects any attempt to materialize trusted execution context from a portable request payload.
  """
  @spec from_portable_payload(map()) :: {:error, Error.t()}
  def from_portable_payload(_attrs),
    do: {:error, Error.invalid!("ExecutionContext cannot be created from a payload")}

  @doc false
  def keys, do: @keys
end
