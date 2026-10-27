defmodule Backplane.AgentRuntime.McpCleanupReportTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Plugins.MCP
  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.HTTP.Lifecycle

  # This connection has no client work or remote effects. Its real lifecycle
  # and supervision receipts exercise the adapter's cross-package report gate.
  defmodule ReceiptClient do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)
    def init(state), do: {:ok, state}
    def handle_cast(:seal_admission, state), do: {:noreply, state}

    def handle_call({:seal_connection, _deadline}, _from, state),
      do: {:reply, {:ok, %{outcome: :confirmed, resources: []}}, state}
  end

  defmodule ReceiptTransport do
    use GenServer

    def start_link(activation), do: GenServer.start_link(__MODULE__, activation)

    def init(activation) do
      {:ok, lifecycle} = Lifecycle.start_link(:streamable_http, activation)
      {:ok, lifecycle}
    end

    def close(pid, opts), do: GenServer.call(pid, {:close, opts})
    def handle_call(:lifecycle, _from, lifecycle), do: {:reply, lifecycle, lifecycle}

    def handle_call({:close, opts}, _from, lifecycle),
      do: {:reply, Lifecycle.close(lifecycle, opts), lifecycle}
  end

  test "the default adapter accepts actual compacted lifecycle receipts" do
    {connection, lifecycle} = connection()

    for _ <- 1..90 do
      assert {:ok, _worker} = Lifecycle.start(lifecycle, fn -> :ok end)
    end

    assert eventually(fn -> map_size(:sys.get_state(lifecycle).jobs) == 0 end)
    assert {:ok, report} = MCP.close(connection, timeout: 1_000)
    assert MCP.confirmed_close?({:ok, report}, connection.activation_id)
    assert {:ok, %{outcome: :confirmed, resources: resources}} = report.transport

    assert [%{evidence: %{confirmed_count: 26}}] =
             Enum.filter(resources, & &1.evidence[:aggregate])

    assert length(resources) == 65
    refute Process.alive?(connection.supervisor)
  end

  test "the default adapter retains cleanup-worker receipts without hiding missing handles" do
    {connection, lifecycle} = connection()
    owner = self()

    assert {:ok, _worker} =
             Lifecycle.start(lifecycle, fn ->
               {^lifecycle, job} = Process.get(:mcp_http_lifecycle)
               {:ok, _allocation} = Lifecycle.allocation(lifecycle, job)
               send(owner, :allocated_without_handoff)
               receive do: (:release -> :ok)
             end)

    assert_receive :allocated_without_handoff
    assert {:ok, %{outcome: :unconfirmed} = report} = MCP.close(connection, timeout: 1_000)
    refute MCP.confirmed_close?({:ok, report}, connection.activation_id)
    assert {:ok, %{resources: resources}} = report.transport
    assert Enum.any?(resources, &(&1.scope == :http_request and &1.outcome == :uncertain))
    workers = Enum.filter(resources, &(&1.scope == :http_worker))
    assert length(workers) == 2
    assert Enum.all?(workers, &match?(%{id: {_, id}} when is_reference(id), &1))
  end

  defp connection do
    activation = "receipt-#{System.unique_integer([:positive])}"

    children = [
      %{id: Client, start: {ReceiptClient, :start_link, [[]]}, restart: :temporary},
      %{
        id: ReceiptTransport,
        start: {ReceiptTransport, :start_link, [activation]},
        modules: [ReceiptTransport],
        restart: :temporary
      }
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_all)
    Process.unlink(supervisor)
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)

    {_, transport, _, _} =
      List.keyfind(Supervisor.which_children(supervisor), ReceiptTransport, 0)

    {%{supervisor: supervisor, activation_id: activation}, GenServer.call(transport, :lifecycle)}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
