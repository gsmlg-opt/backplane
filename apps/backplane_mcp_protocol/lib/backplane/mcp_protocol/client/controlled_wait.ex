defmodule Backplane.McpProtocol.Client.ControlledWait do
  @moduledoc false
  alias Backplane.McpProtocol.Client.EventCancellation
  alias Backplane.McpProtocol.Client.EventRequest
  alias Backplane.McpProtocol.Client.ResourceCancellation
  alias Backplane.McpProtocol.Client.ResourceRequest
  alias Backplane.McpProtocol.MCP.Error

  def signal(%{__struct__: control, owner: owner, token: token}, reason, opts)
      when control in [ResourceCancellation, EventCancellation] and is_binary(reason) and
             is_list(opts) do
    case Keyword.get(opts, :timeout, 5_000) do
      timeout when is_integer(timeout) and timeout > 0 and timeout <= 2_147_483_647 ->
        send(owner, {control, token, reason, System.monotonic_time(:millisecond) + timeout})
        :ok

      _ ->
        {:error, Error.protocol(:invalid_params, %{field: "timeout"})}
    end
  end

  def signal(_, _, _), do: {:error, Error.protocol(:invalid_params, %{field: "cancellation"})}

  def await(
        %{__struct__: family} = handle,
        timeout,
        %{
          __struct__: control,
          owner: owner,
          token: token,
          binding: binding
        },
        cancel
      )
      when owner == self() and is_function(cancel, 2) and
             ((family == ResourceRequest and control == ResourceCancellation) or
                (family == EventRequest and control == EventCancellation)) do
    if handle.owner == owner do
      case bind(binding, handle.cancellation_key) do
        :ok -> await_bound(handle, timeout, token, control, cancel)
        error -> error
      end
    else
      {:error, Error.transport(:request_owner_mismatch)}
    end
  end

  def await(_, _, _, _), do: {:error, Error.transport(:request_owner_mismatch)}

  # The binding lives only as long as the opaque control; long-lived owners do
  # not accumulate permanent process-dictionary handles or tombstones.
  defp bind(binding, key) when is_integer(key) and key > 0 do
    case :atomics.compare_exchange(binding, 1, 0, key) do
      :ok -> :ok
      ^key -> :ok
      _ -> {:error, Error.transport(:cancellation_request_mismatch)}
    end
  end

  # The typed wrapper binds cancellation without exposing an opaque handle to
  # a different family's API. This helper still admits only the two fixed pairs.
  defp await_bound(%{__struct__: family} = handle, timeout, token, control, cancel) do
    client = handle.client
    monitor = Process.monitor(client)
    ref = handle.reply_ref

    receive do
      {^family, ^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {^control, ^token, reason, deadline} ->
        Process.demonitor(monitor, [:flush])
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        result =
          if remaining > 0,
            do:
              cancel.(reason,
                notification_timeout: remaining,
                deadline: deadline,
                verified: true
              ),
            else: {:error, Error.transport(:cancellation_timeout)}

        case result do
          {:ok, report} ->
            receive do
              {^family, ^ref, _cancelled} -> :ok
            after
              0 -> :ok
            end

            {:cancelled, report}

          {:error, %Error{reason: :request_not_found}} = error ->
            # Absence is not settlement. Only this exact delivered terminal reply
            # can reconcile completion that won the cancellation race.
            receive do
              {^family, ^ref, result} -> result
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
