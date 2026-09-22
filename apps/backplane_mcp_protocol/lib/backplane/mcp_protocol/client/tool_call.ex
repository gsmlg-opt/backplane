defmodule Backplane.McpProtocol.Client.ToolCall do
  @moduledoc """
  Caller-owned handle for one asynchronous tool call.

  A handle is bound to the client process and owner that created it. Its
  `logical_id` remains stable when a modern multi-round-trip request retries
  with a different wire request ID.
  """

  alias Backplane.McpProtocol.MCP.Error

  @enforce_keys [:client, :logical_id, :owner, :reply_ref]
  defstruct [:client, :logical_id, :owner, :reply_ref]

  @opaque t :: %__MODULE__{
            client: pid(),
            logical_id: String.t(),
            owner: pid(),
            reply_ref: reference()
          }

  @doc false
  @spec new(GenServer.server(), pid()) :: t()
  def new(client, owner) when is_pid(owner) do
    %__MODULE__{
      client: client,
      logical_id: Backplane.McpProtocol.MCP.ID.generate_request_id(),
      owner: owner,
      reply_ref: make_ref()
    }
  end

  @doc false
  @spec bind_client(term(), pid()) :: t()
  def bind_client(%__MODULE__{} = handle, client) when is_pid(client) do
    %{handle | client: client}
  end

  @doc false
  @spec handle?(term()) :: boolean()
  def handle?(%__MODULE__{}), do: true
  def handle?(_value), do: false

  @doc false
  @spec client(term()) :: pid() | nil
  def client(%__MODULE__{client: client}), do: client
  def client(_value), do: nil

  @doc false
  @spec logical_id(term()) :: String.t() | nil
  def logical_id(%__MODULE__{logical_id: logical_id}), do: logical_id
  def logical_id(_value), do: nil

  @doc false
  @spec monitor_owner(t()) :: reference()
  def monitor_owner(%__MODULE__{owner: owner}), do: Process.monitor(owner)

  @doc false
  @spec owned_by?(term(), pid()) :: boolean()
  def owned_by?(%__MODULE__{owner: owner}, pid) when is_pid(pid), do: owner == pid
  def owned_by?(_value, _pid), do: false

  @doc false
  @spec owner_alive?(term()) :: boolean()
  def owner_alive?(%__MODULE__{owner: owner}), do: Process.alive?(owner)
  def owner_alive?(_value), do: false

  @doc false
  @spec equal?(term(), term()) :: boolean()
  def equal?(%__MODULE__{} = left, %__MODULE__{} = right) do
    left.client == right.client and left.logical_id == right.logical_id and
      left.owner == right.owner and left.reply_ref == right.reply_ref
  end

  def equal?(_left, _right), do: false

  @doc false
  @spec deliver(term(), term()) :: :ok
  def deliver(%__MODULE__{owner: owner, reply_ref: reply_ref}, result) do
    send(owner, {__MODULE__, reply_ref, result})
    :ok
  end

  @doc false
  @spec await(term(), timeout()) :: term()
  def await(%__MODULE__{owner: owner}, _timeout) when owner != self() do
    {:error, Error.transport(:request_owner_mismatch)}
  end

  def await(%__MODULE__{client: client, reply_ref: reply_ref}, timeout) do
    monitor = Process.monitor(client)

    receive do
      {__MODULE__, ^reply_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^client, reason} ->
        {:error, Error.transport(:client_terminated, %{reason: reason})}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, Error.transport(:request_timeout, %{message: "Tool call await timed out"})}
    end
  end
end
