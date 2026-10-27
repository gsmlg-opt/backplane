defmodule Backplane.McpProtocol.Client.RequestCleanup do
  @moduledoc false
  alias Backplane.McpProtocol.Client.Connection

  def release(request, transport, deadline) do
    pids =
      for task <- [request.dispatch_task, request.resolver_task],
          match?(%Task{}, task),
          do: task.pid

    pids = pids ++ List.wrap(request.resolver_supervisor)
    workers = Connection.release_workers(pids, deadline)
    transport_result = release_transport(transport, request, deadline)

    %{
      local_cleanup:
        if(workers.outcome == :confirmed and transport_result == :ok,
          do: :confirmed,
          else: :uncertain
        ),
      cleanup_evidence: %{
        workers_down: workers.outcome == :confirmed,
        worker_count: length(workers.resources),
        transport: if(transport_result == :ok, do: :confirmed, else: :uncertain)
      }
    }
  end

  defp release_transport(_transport, %{dispatch_status: :registered}, _deadline), do: :ok

  defp release_transport(%{layer: layer, name: name}, request, deadline) do
    if function_exported?(layer, :cancel_request, 3) do
      layer.cancel_request(name, request.id,
        timeout: max(deadline - System.monotonic_time(:millisecond), 1),
        deadline: deadline
      )
    else
      {:error, :request_cleanup_unsupported}
    end
  catch
    :exit, _ -> {:error, :request_cleanup_unavailable}
  end
end
