defmodule Backplane.McpProtocol.Client.OwnedRequest do
  @moduledoc false

  alias Backplane.McpProtocol.Client.{ResourceRequest, ToolCall}
  alias Backplane.McpProtocol.MCP.{Error, ID}

  @type t :: ToolCall.t() | ResourceRequest.t()
  @handle_modules [ToolCall, ResourceRequest]

  def new(module, client, owner) when module in @handle_modules do
    struct!(module,
      client: client,
      owner: owner,
      logical_id: ID.generate_request_id(),
      reply_ref: make_ref()
    )
  end

  def handle?(%{__struct__: module}) when module in @handle_modules, do: true
  def handle?(_), do: false

  def bind_client(%{__struct__: module} = handle, client) when module in @handle_modules,
    do: %{handle | client: client}

  def client(%{__struct__: module, client: client}) when module in @handle_modules, do: client
  def client(_), do: nil

  def logical_id(%{__struct__: module, logical_id: id}) when module in @handle_modules, do: id
  def logical_id(_), do: nil

  def owned_by?(%{__struct__: module, owner: owner}, pid) when module in @handle_modules,
    do: owner == pid

  def owned_by?(_, _), do: false

  def monitor_owner(handle), do: Process.monitor(handle.owner)
  def owner_alive?(handle), do: Process.alive?(handle.owner)

  def equal?(left, right), do: handle?(left) and left == right

  def deliver(%{__struct__: module, owner: owner, reply_ref: ref}, result)
      when module in @handle_modules do
    send(owner, {module, ref, result})
    :ok
  end

  def await(%{owner: owner}, _timeout) when owner != self(),
    do: {:error, Error.transport(:request_owner_mismatch)}

  def await(%{__struct__: module, client: client, reply_ref: ref}, timeout)
      when module in @handle_modules do
    monitor = Process.monitor(client)

    receive do
      {^module, ^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^client, reason} ->
        {:error, Error.transport(:client_terminated, %{reason: reason})}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])

        {:error,
         Error.transport(:request_timeout, %{message: "Resource request await timed out"})}
    end
  end
end
