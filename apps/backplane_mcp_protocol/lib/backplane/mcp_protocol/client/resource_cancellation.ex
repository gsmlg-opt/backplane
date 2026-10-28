defmodule Backplane.McpProtocol.Client.ResourceCancellation do
  @moduledoc "Opaque cancellation control for one owner waiting on a resource request."

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.ControlledWait
  alias Backplane.McpProtocol.Client.ResourceRequest
  alias Backplane.McpProtocol.MCP.Error

  @enforce_keys [:owner, :token, :binding]
  defstruct [:owner, :token, :binding]
  @opaque t :: %__MODULE__{owner: pid(), token: reference(), binding: :atomics.atomics_ref()}

  @spec new() :: t()
  def new,
    do: %__MODULE__{owner: self(), token: make_ref(), binding: :atomics.new(1, signed: false)}

  @spec signal(t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def signal(%__MODULE__{} = control, reason, opts),
    do: ControlledWait.signal(control, reason, opts)

  def signal(_, _, _), do: {:error, Error.protocol(:invalid_params, %{field: "cancellation"})}

  @spec await(ResourceRequest.t(), timeout(), t()) ::
          {:ok, Backplane.McpProtocol.MCP.Response.t()}
          | {:error, Error.t()}
          | {:cancelled, map()}
  def await(handle, timeout, %__MODULE__{} = control) do
    ControlledWait.await(handle, timeout, control, fn reason, opts ->
      Client.cancel_resource_request(handle, reason, opts)
    end)
  end

  def await(_, _, _), do: {:error, Error.transport(:request_owner_mismatch)}
end
