defmodule Backplane.McpProtocol.Client.Connection do
  @moduledoc false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.MCP.Error

  def close(supervisor, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    if is_integer(timeout) and timeout > 0 and timeout <= 2_147_483_647 do
      deadline = now() + timeout
      close_tree(supervisor, deadline, opts)
    else
      {:error, Error.protocol(:invalid_params, %{field: "timeout"})}
    end
  end

  defp close_tree(supervisor, deadline, opts) do
    children = observe(fn -> GenServer.call(supervisor, :which_children, remaining(deadline)) end)

    {client, transport, layer} = connection_children(children)
    if is_pid(client), do: GenServer.cast(client, :seal_admission)

    transport_result =
      if is_pid(transport) and function_exported?(layer, :close, 2) do
        observe_transport_close(layer, transport, opts, deadline)
      else
        {:error, Error.transport(:cleanup_unconfirmed, %{reason: :missing_transport_evidence})}
      end

    workers =
      observe(fn -> GenServer.call(client, {:seal_connection, deadline}, remaining(deadline)) end)

    teardown = stop_supervisor(supervisor, deadline)

    confirmed =
      confirmed_transport?(transport_result) and confirmed?(workers) and
        teardown.outcome == :confirmed

    {:ok,
     %{
       version: 1,
       close_id: close_id(transport_result),
       activation_id: activation_id(transport_result),
       outcome: if(confirmed, do: :confirmed, else: :unconfirmed),
       transport: transport_result,
       client_workers: workers,
       supervisor: teardown
     }}
  end

  defp connection_children(children) when is_list(children) do
    client =
      Enum.find_value(children, fn
        {Client, pid, _, _} when is_pid(pid) -> pid
        _ -> nil
      end)

    transport =
      Enum.find_value(children, fn
        {id, pid, _, [layer]} when id != Client and is_pid(pid) -> {pid, layer}
        _ -> nil
      end)

    case transport do
      {pid, layer} -> {client, pid, layer}
      nil -> {client, nil, nil}
    end
  end

  defp connection_children(_), do: {nil, nil, nil}

  defp observe_transport_close(layer, transport, opts, deadline) do
    task =
      Task.Supervisor.async_nolink(Client.OperationSupervisor, fn ->
        observe(fn ->
          layer.close(transport, Keyword.put(opts, :timeout, remaining(deadline)))
        end)
      end)

    case Task.yield(task, remaining(deadline)) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, Error.transport(:cleanup_unconfirmed, %{reason: :observation_failed})}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, Error.transport(:cleanup_unconfirmed, %{reason: :deadline_exceeded})}
    end
  end

  defp stop_supervisor(supervisor, deadline) when is_pid(supervisor) do
    monitor = Process.monitor(supervisor)
    result = observe(fn -> Supervisor.stop(supervisor, :normal, remaining(deadline)) end)

    down =
      receive do
        {:DOWN, ^monitor, :process, ^supervisor, :normal} -> true
        {:DOWN, ^monitor, :process, ^supervisor, _} -> false
      after
        remaining(deadline) -> false
      end

    Process.demonitor(monitor, [:flush])

    %{
      outcome: if(result == :ok and down, do: :confirmed, else: :uncertain),
      evidence: %{down: down},
      error: if(result == :ok, do: nil, else: result)
    }
  end

  defp stop_supervisor(_, _),
    do: %{outcome: :uncertain, evidence: %{down: false}, error: :missing_supervisor}

  @doc false
  def release_workers(pids, deadline) do
    monitors =
      pids
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()
      |> Enum.map(fn pid ->
        monitor = Process.monitor(pid)
        Process.unlink(pid)
        Process.exit(pid, :kill)
        {pid, monitor}
      end)

    resources =
      Enum.map(monitors, fn {pid, monitor} ->
        down =
          receive do
            {:DOWN, ^monitor, :process, ^pid, _reason} -> true
          after
            remaining(deadline) -> false
          end

        Process.demonitor(monitor, [:flush])

        %{
          id: "beam:" <> inspect(pid),
          scope: :owned_beam_worker,
          outcome: if(down, do: :confirmed, else: :uncertain),
          evidence: %{down: down},
          error: if(down, do: nil, else: :deadline_exceeded)
        }
      end)

    %{
      outcome:
        if(Enum.all?(resources, &(&1.outcome == :confirmed)), do: :confirmed, else: :unconfirmed),
      resources: resources
    }
  end

  defp confirmed?({:ok, %{outcome: :confirmed}}), do: true
  defp confirmed?(_), do: false

  defp confirmed_transport?(
         {:ok, %{version: 1, phase: :closed, outcome: :confirmed, resources: resources}}
       )
       when is_list(resources),
       do: Enum.all?(resources, &match?(%{outcome: :confirmed}, &1))

  defp confirmed_transport?(_), do: false

  defp close_id({:ok, %{close_id: id}}), do: id
  defp close_id(_), do: nil
  defp activation_id({:ok, %{activation_id: id}}), do: id
  defp activation_id(_), do: nil

  defp observe(fun) do
    fun.()
  rescue
    _ -> {:error, Error.transport(:cleanup_unconfirmed, %{reason: :observation_failed})}
  catch
    :exit, _ -> {:error, Error.transport(:cleanup_unconfirmed, %{reason: :observation_failed})}
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
end
