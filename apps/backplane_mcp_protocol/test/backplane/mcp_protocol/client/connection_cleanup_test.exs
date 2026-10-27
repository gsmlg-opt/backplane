defmodule Backplane.McpProtocol.Client.ConnectionCleanupTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.{Client, MCP.Error}

  defmodule CleanupTransport do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))
    def init(state), do: {:ok, state}
    def supported_protocol_versions, do: :all
    def shutdown(pid), do: GenServer.cast(pid, :best_effort)

    def send_message(pid, wire, _opts) do
      test = GenServer.call(pid, :test)
      send(test, {:dispatch, self(), JSON.decode!(wire)})

      receive do
        :release -> :ok
      end
    end

    def close(pid, _opts) do
      case GenServer.call(pid, :close) do
        {:blocked, test} ->
          send(test, {:blocked_close_observer, self()})

          receive do
            :release -> {:ok, %{}}
          end

        result ->
          result
      end
    end

    def handle_call(:test, _from, state), do: {:reply, state.test, state}

    def handle_call(:close, _from, state) do
      send(state.test, :transport_close)
      {:reply, state.result, state}
    end

    def handle_cast(:best_effort, state) do
      send(state.test, :best_effort_shutdown)
      {:noreply, state}
    end
  end

  test "owned close requires real transport evidence and observes worker and supervisor DOWN" do
    {sup, client, _transport} = start_connection({:ok, transport_report(:confirmed)})
    assert {:ok, handle} = Client.start_read_resource(client, "fixture://blocked")
    assert_receive {:dispatch, worker, %{"method" => "resources/read"}}
    worker_ref = Process.monitor(worker)

    assert {:ok,
            %{
              version: 1,
              outcome: :confirmed,
              transport: {:ok, transport},
              client_workers: {:ok, %{outcome: :confirmed, resources: [_]}},
              supervisor: %{outcome: :confirmed, evidence: %{down: true}}
            }} =
             Client.close_connection(sup, timeout: 1_000)

    assert transport.activation_id == "fixture-activation"
    assert_receive :transport_close
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}

    assert {:error, %Error{reason: :request_cancelled}} =
             Client.await_resource_request(handle, 1_000)

    refute Process.alive?(sup)
    refute_receive :best_effort_shutdown
    assert {:ok, %{outcome: :unconfirmed}} = Client.close_connection(sup, timeout: 50)
  end

  test "transport failure survives successful BEAM teardown" do
    failure = Error.transport(:cleanup_unconfirmed, %{reason: :lost_receipt})
    {sup, _client, _transport} = start_connection({:error, failure})

    assert {:ok,
            %{
              outcome: :unconfirmed,
              transport: {:error, ^failure},
              supervisor: %{outcome: :confirmed}
            }} =
             Client.close_connection(sup, timeout: 1_000)
  end

  test "a transport callback cannot extend the overall close deadline" do
    {sup, _client, _transport} = start_connection({:blocked, self()})
    closing = Task.async(fn -> Client.close_connection(sup, timeout: 50) end)
    assert_receive {:blocked_close_observer, observer}
    monitor = Process.monitor(observer)

    assert {:ok,
            %{
              outcome: :unconfirmed,
              transport:
                {:error,
                 %Error{reason: :cleanup_unconfirmed, data: %{reason: :deadline_exceeded}}}
            }} = Task.await(closing, 500)

    assert_receive {:DOWN, ^monitor, :process, ^observer, _}
  end

  test "a success-shaped pending or malformed transport result never confirms cleanup" do
    for result <- [
          {:ok, %{outcome: :confirmed}},
          {:ok, %{transport_report(:confirmed) | phase: :closing}},
          {:ok, %{transport_report(:confirmed) | resources: [%{outcome: :uncertain}]}}
        ] do
      {sup, _client, _transport} = start_connection(result)
      assert {:ok, %{outcome: :unconfirmed}} = Client.close_connection(sup, timeout: 1_000)
    end
  end

  test "one-shot outer children are temporary while ordinary clients retain restart behavior" do
    assert Client.child_spec(one_shot: true).restart == :temporary
    assert Client.child_spec([]).restart == :permanent
  end

  defp transport_report(outcome) do
    %{
      version: 1,
      close_id: "fixture-close",
      activation_id: "fixture-activation",
      transport: :stdio,
      phase: :closed,
      outcome: outcome,
      resources: [
        %{
          id: "fixture",
          scope: :fixture,
          outcome: outcome,
          evidence: %{released: true},
          error: nil
        }
      ],
      remote: %{outcome: :unknown}
    }
  end

  defp start_connection(result) do
    test = self()
    {:ok, transport} = CleanupTransport.start_link(test: test, result: result)
    Process.unlink(transport)
    name = String.to_atom("CleanupClient#{System.unique_integer([:positive])}")

    client_opts = [
      name: name,
      transport: [layer: Backplane.McpProtocol.ToolCallTransport, name: transport],
      client_info: %{"name" => to_string(name), "version" => "1"},
      capabilities: %{},
      protocol_version: "2026-07-28"
    ]

    children = [
      %{id: Client, start: {Client, :start_link_server, [client_opts]}, restart: :temporary},
      %{
        id: CleanupTransport,
        start: {__MODULE__, :adopt, [transport]},
        modules: [CleanupTransport],
        restart: :temporary
      }
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_all)
    Process.unlink(sup)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)
    client = Process.whereis(name)

    :sys.replace_state(
      client,
      &%{
        &1
        | transport: %{layer: CleanupTransport, name: transport},
          era: :modern,
          negotiated_version: "2026-07-28",
          negotiation_status: :ready,
          server_capabilities: %{"resources" => %{}}
      }
    )

    {sup, client, transport}
  end

  def adopt(pid) do
    Process.link(pid)
    {:ok, pid}
  end
end
