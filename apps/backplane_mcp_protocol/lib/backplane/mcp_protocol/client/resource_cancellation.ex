defmodule Backplane.McpProtocol.Client.ResourceCancellation do
  @moduledoc "Opaque cancellation control for one owner waiting on a resource request."
  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.ResourceRequest
  alias Backplane.McpProtocol.MCP.Error

  @enforce_keys [:owner, :token, :binding]
  defstruct [:owner, :token, :binding]
  @opaque t :: %__MODULE__{owner: pid(), token: reference(), binding: :atomics.atomics_ref()}

  @spec new() :: t()
  def new,
    do: %__MODULE__{owner: self(), token: make_ref(), binding: :atomics.new(1, signed: false)}

  def signal(%__MODULE__{owner: owner, token: token}, reason, opts)
      when is_binary(reason) and is_list(opts) do
    case Keyword.get(opts, :timeout, 5_000) do
      timeout when is_integer(timeout) and timeout > 0 and timeout <= 2_147_483_647 ->
        send(owner, {__MODULE__, token, reason, System.monotonic_time(:millisecond) + timeout})
        :ok

      _ ->
        {:error, Error.protocol(:invalid_params, %{field: "timeout"})}
    end
  end

  def signal(_, _, _), do: {:error, Error.protocol(:invalid_params, %{field: "cancellation"})}

  @spec await(ResourceRequest.t(), timeout(), t()) ::
          {:ok, Backplane.McpProtocol.MCP.Response.t()}
          | {:error, Error.t()}
          | {:cancelled, map()}
  def await(handle, timeout, %__MODULE__{
        owner: owner,
        token: token,
        binding: binding
      })
      when owner == self() do
    if ResourceRequest.owned_by?(handle, owner) do
      case bind(binding, ResourceRequest.cancellation_key(handle)) do
        :ok -> await_bound(handle, timeout, token)
        error -> error
      end
    else
      {:error, Error.transport(:request_owner_mismatch)}
    end
  end

  def await(_, _, _), do: {:error, Error.transport(:request_owner_mismatch)}

  # The binding lives only as long as the opaque control; long-lived owners do
  # not accumulate permanent process-dictionary handles or tombstones.
  defp bind(binding, key) when is_integer(key) and key > 0 do
    case :atomics.compare_exchange(binding, 1, 0, key) do
      :ok -> :ok
      ^key -> :ok
      _ -> {:error, Error.transport(:cancellation_request_mismatch)}
    end
  end

  @spec await_bound(ResourceRequest.t(), timeout(), reference()) ::
          {:ok, Backplane.McpProtocol.MCP.Response.t()}
          | {:error, Error.t()}
          | {:cancelled, map()}
  defp await_bound(handle, timeout, token) do
    client = ResourceRequest.client(handle)
    monitor = Process.monitor(client)
    ref = ResourceRequest.reply_ref(handle)

    receive do
      {ResourceRequest, ^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {__MODULE__, ^token, reason, deadline} ->
        Process.demonitor(monitor, [:flush])
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        result =
          if remaining > 0,
            do:
              Client.cancel_resource_request(handle, reason,
                notification_timeout: remaining,
                deadline: deadline,
                verified: true
              ),
            else: {:error, Error.transport(:cancellation_timeout)}

        case result do
          {:ok, report} ->
            receive do
              {ResourceRequest, ^ref, _cancelled} -> :ok
            after
              0 -> :ok
            end

            {:cancelled, report}

          {:error, %Error{reason: :request_not_found}} = error ->
            # Absence is not settlement. Only this exact delivered terminal reply
            # can reconcile completion that won the cancellation race.
            receive do
              {ResourceRequest, ^ref, result} -> result
            after
              0 -> error
            end

          error ->
            error
        end

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
