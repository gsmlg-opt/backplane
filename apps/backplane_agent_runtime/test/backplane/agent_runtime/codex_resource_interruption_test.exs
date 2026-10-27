defmodule Backplane.AgentRuntime.CodexResourceInterruptionTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{DynamicRuntime, MultiAgent, Session}
  alias Backplane.McpProtocol.Client

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @resources ~w(list_mcp_resources list_mcp_resource_templates read_mcp_resource)
  @collaboration ~w(spawn_agent list_agents interrupt_agent)

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:resource_provider, request.run_id, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule Adapter do
    def read_resource(arguments, operation),
      do:
        request(operation, fn client -> Client.start_read_resource(client, arguments["uri"]) end)

    def list_resources(arguments, operation),
      do:
        request(operation, fn client ->
          Client.start_list_resources(client, cursor: arguments["cursor"])
        end)

    def list_resource_templates(arguments, operation),
      do:
        request(operation, fn client ->
          Client.start_list_resource_templates(client, cursor: arguments["cursor"])
        end)

    defp request(operation, starter) do
      case DynamicRuntime.resource_request(operation, fn ->
             starter.(operation.backend_context.client)
           end) do
        {:ok, response} ->
          {:ok, response.result}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, error} ->
          {:error, Error.new(:execution_failure, "MCP request failed", cause: error.reason)}
      end
    end
  end

  defmodule LegacyAdapter do
    def read_resource(arguments, operation),
      do:
        request(operation, fn client -> Client.start_read_resource(client, arguments["uri"]) end)

    def list_resources(arguments, operation),
      do:
        request(operation, fn client ->
          Client.start_list_resources(client, cursor: arguments["cursor"])
        end)

    def list_resource_templates(arguments, operation),
      do:
        request(operation, fn client ->
          Client.start_list_resource_templates(client, cursor: arguments["cursor"])
        end)

    defp request(operation, starter) do
      with {:ok, handle} <- starter.(operation.backend_context.client),
           {:ok, response} <- Client.await_resource_request(handle, :infinity),
           do: {:ok, response.result}
    end
  end

  for name <- @resources do
    @tag resource_tool: name
    test "legacy #{name} owner death cancels only its request", ctx do
      client = start_client(ctx.tmp_dir)
      dynamic = start_supervised!({DynamicRuntime, mcp_adapter: LegacyAdapter})
      assert {:ok, independent} = Client.start_read_resource(client, "mem://survivor-pending")
      owner = spawn(fn -> DynamicRuntime.call(operation(dynamic, client, ctx.resource_tool)) end)
      eventually(fn -> Enum.any?(wires(ctx.tmp_dir), &pending?/1) end)
      pending = Enum.find(wires(ctx.tmp_dir), &pending?/1)
      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

      eventually(fn ->
        Enum.any?(wires(ctx.tmp_dir), fn wire ->
          wire["method"] == "notifications/cancelled" and
            get_in(wire, ["params", "requestId"]) == pending["id"]
        end)
      end)

      assert {:ok, release} = Client.start_read_resource(client, "mem://release")
      assert {:ok, _} = Client.await_resource_request(release, 1_000)
      assert {:ok, _} = Client.await_resource_request(independent, 1_000)
      assert {:ok, again} = Client.start_read_resource(client, "mem://again")
      assert {:ok, _} = Client.await_resource_request(again, 1_000)
      assert Enum.count(wires(ctx.tmp_dir), &(&1["method"] == "initialize")) == 1
    end
  end

  test "pending registration cancellation, repeated acknowledgement and stale generation retain exact proof",
       ctx do
    client = start_client(ctx.tmp_dir)
    dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
    test = self()

    register = fn operation, registration ->
      send(test, {:registered, operation, registration, self()})

      receive do
        :start -> {:ok, test}
      end
    end

    original =
      operation(dynamic, client, "read_mcp_resource")
      |> put_in([:backend_context, :register_cancellation], register)

    owner = Task.async(fn -> DynamicRuntime.call(original) end)
    assert_receive {:registered, actual, registration, caller}
    cancelled = cancellation(actual, registration, "stop-one")
    waiter = Task.async(fn -> DynamicRuntime.cancel_resource(cancelled) end)
    # Ensure the signal is queued before the finite starter runs.
    eventually(fn -> :sys.get_state(dynamic).resource_requests[registration].waiters != [] end)
    send(caller, :start)
    assert {:ok, first} = Task.await(waiter)
    assert {:error, %Error{class: :cancelled}} = Task.await(owner)
    assert {:ok, second} = DynamicRuntime.cancel_resource(cancelled)
    assert second === first

    assert {:error, %Error{class: :unknown_outcome}} =
             DynamicRuntime.cancel_resource(%{cancelled | stop_generation: "old-stop"})

    Backplane.AgentRuntime.Codex.ResourceRequest.release(%{
      operation: actual,
      registration: registration
    })

    eventually(fn -> :sys.get_state(dynamic).resource_requests == %{} end)
    assert Enum.count(wires(ctx.tmp_dir), &(&1["method"] == "notifications/cancelled")) <= 1
  end

  test "completion winning cancellation and an unresponsive starter remain uncertain", ctx do
    client = start_client(ctx.tmp_dir)
    dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
    test = self()

    register = fn op, reg ->
      send(test, {:registered, op, reg})
      {:ok, test}
    end

    op =
      operation(dynamic, client, "read_mcp_resource")
      |> put_in([:arguments, "uri"], "mem://complete")
      |> put_in([:backend_context, :register_cancellation], register)

    owner = Task.async(fn -> DynamicRuntime.call(op) end)
    assert_receive {:registered, actual, registration}
    assert {:ok, _} = Task.await(owner)

    assert {:error, %Error{class: :unknown_outcome}} =
             DynamicRuntime.cancel_resource(cancellation(actual, registration, "completion-stop"))

    Backplane.AgentRuntime.Codex.ResourceRequest.release(%{
      operation: actual,
      registration: registration
    })

    stuck =
      Task.async(fn ->
        DynamicRuntime.resource_request(op, fn ->
          send(test, :starter_waiting)

          receive do
            :never -> :never
          end
        end)
      end)

    assert_receive {:registered, actual, registration}
    assert_receive :starter_waiting

    cancel =
      cancellation(actual, registration, "stuck-stop")
      |> Map.put(:cleanup_deadline, System.monotonic_time(:millisecond) + 40)

    assert {:error, %Error{class: :unknown_outcome}} = DynamicRuntime.cancel_resource(cancel)
    Task.shutdown(stuck, :brutal_kill)
    eventually(fn -> :sys.get_state(dynamic).resource_requests == %{} end)
  end

  test "retained completion is released when its live coordinator exits", ctx do
    client = start_client(ctx.tmp_dir)
    dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})

    coordinator =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    test = self()

    register = fn op, reg ->
      send(test, {:registered, op, reg})
      {:ok, coordinator}
    end

    original =
      operation(dynamic, client, "read_mcp_resource")
      |> put_in([:arguments, "uri"], "mem://complete")
      |> put_in([:backend_context, :register_cancellation], register)

    owner = Task.async(fn -> DynamicRuntime.call(original) end)
    assert_receive {:registered, _, registration}
    assert {:ok, _} = Task.await(owner)
    assert :sys.get_state(dynamic).resource_requests[registration].result != nil
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}
    eventually(fn -> :sys.get_state(dynamic).resource_requests == %{} end)
  end

  defmodule LostAckStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == :cleanup_settled do
        {:ok, _} = EphemeralStore.store(context.table, run, meta)
        send(context.test, {:cleanup_ack_lost, run.run_id})

        receive do
          :never_ack -> :never
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  test "lost Store cleanup acknowledgement fences the cancelled child", ctx do
    client = start_client(ctx.tmp_dir)
    dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
    {:ok, store} = EphemeralStore.new(1)

    context =
      runtime(client, dynamic,
        store: LostAckStore,
        context: %{table: store, test: self()},
        commit_timeout: 70
      )

    {_root_provider, _} =
      tool(context.provider, "root", "spawn_agent", %{
        "task_name" => "worker",
        "message" => "read"
      })

    assert_receive {:resource_provider, child_run, _, provider}
    send(provider, {:events, [call("read_mcp_resource", arguments("read_mcp_resource")), done()]})
    eventually(fn -> Enum.any?(wires(ctx.tmp_dir), &pending?/1) end)
    child_pid = :sys.get_state(context.manager).agents["/root/worker"].pid
    assert :ok = Conversation.cancel(child_pid)
    assert_receive {:cleanup_ack_lost, ^child_run}, 1_000
    eventually(fn -> Conversation.status(child_pid).phase == :storage_failed end)
    refute_receive {:resource_provider, ^child_run, _, _}, 80
    assert {:ok, stored} = EphemeralStore.load(store, child_run)
    assert stored.run.outcome["cleanup"]["certainty"] == "confirmed"
    assert Conversation.status(child_pid).phase == :storage_failed
    eventually(fn -> :sys.get_state(dynamic).resource_requests == %{} end)
    stop_supervised!(:root_conversation)
    Session.close(context.root_binding.session)
    stop_supervised!(:resource_manager)
    eventually(fn -> :sys.get_state(dynamic).resource_requests == %{} end)
  end

  test "cleanup deadline during starter registration stays uncertain and stale timers cannot settle it",
       ctx do
    client = start_client(ctx.tmp_dir)
    dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
    context = runtime(client, dynamic, cleanup_timeout: 70)

    {_root, _} =
      tool(context.provider, "root", "spawn_agent", %{
        "task_name" => "worker",
        "message" => "read"
      })

    assert_receive {:resource_provider, child_run, _, provider}
    client_pid = GenServer.whereis(client)
    :sys.suspend(client_pid)

    try do
      send(
        provider,
        {:events, [call("read_mcp_resource", arguments("read_mcp_resource")), done()]}
      )

      eventually(fn -> map_size(:sys.get_state(dynamic).resource_requests) == 1 end)
      child_pid = :sys.get_state(context.manager).agents["/root/worker"].pid
      send(child_pid, {:cooperative_stop_timeout, "old-generation"})
      assert Conversation.status(child_pid).phase == :running
      assert :ok = Conversation.cancel(child_pid)
      eventually(fn -> Conversation.status(child_pid).phase == :terminal end)
      assert Conversation.status(child_pid).run.state == :unknown_outcome
      refute_receive {:resource_provider, ^child_run, _, _}, 30
    after
      :sys.resume(client_pid)
    end

    assert {:ok, next} = Client.start_read_resource(client, "mem://again")
    assert {:ok, _} = Client.await_resource_request(next, 1_000)
    assert Enum.count(wires(ctx.tmp_dir), &(&1["method"] == "initialize")) == 1
    stop_supervised!(:root_conversation)
    Session.close(context.root_binding.session)
    stop_supervised!(:resource_manager)
  end

  for mode <- [:direct, :deno], name <- @resources do
    @tag mode: mode, resource_tool: name
    test "#{mode} managed-child #{name} interruption retains the shared client and parent continuation",
         ctx do
      client = start_client(ctx.tmp_dir)
      runtime = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
      context = runtime(client, runtime)

      {root_provider, _} =
        tool(context.provider, "root", "spawn_agent", %{
          "task_name" => "worker",
          "message" => "read"
        })

      assert_receive {:resource_provider, child_run, _, child_provider}, 2_000
      arguments = arguments(ctx.resource_tool)

      {name, arguments} =
        if ctx.mode == :deno do
          {"exec", "return await tools.#{ctx.resource_tool}(#{JSON.encode!(arguments)});"}
        else
          {ctx.resource_tool, arguments}
        end

      send(child_provider, {:events, [call(name, arguments), done()]})
      eventually(fn -> Enum.any?(wires(ctx.tmp_dir), &pending?/1) end)
      assert {:ok, other} = Client.start_read_resource(client, "mem://survivor-pending")
      assert {:error, %{reason: :request_timeout}} = Client.await_resource_request(other, 10)

      child_pid = :sys.get_state(context.manager).agents["/root/worker"].pid
      admitted = Conversation.status(child_pid).run.active_tools

      {root_provider, result} =
        tool(root_provider, "root", "interrupt_agent", %{"target" => "/root/worker"})

      refute result[:is_error], inspect(result)

      eventually(fn ->
        Enum.any?(wires(ctx.tmp_dir), &(&1["method"] == "notifications/cancelled"))
      end)

      {:ok, roster} = MultiAgent.snapshot(context.manager)
      [child] = roster.agents
      assert child.run_id == child_run
      assert child.cleanup == :confirmed
      settled = Conversation.status(child_pid).run
      assert settled.state == :cancelled
      assert settled.active_tools == %{}
      [evidence] = settled.outcome["cleanup"]["evidence"]

      request =
        if ctx.mode == :deno do
          assert evidence["kind"] in [:code_mode, "code_mode"]
          assert evidence["effect_down"]
          assert evidence["resources"] in [:confirmed, "confirmed"]
          assert Map.has_key?(admitted, evidence["enclosing"]["invocation_id"])
          [inner] = evidence["nested"]
          assert Map.has_key?(admitted, inner["identity"]["invocation_id"])
          inner
        else
          evidence
        end

      assert request["effect_down"]
      assert request["report"]["local_cleanup"] == "confirmed"
      assert request["report"]["remote"] == "unknown"
      assert request["report"]["cleanup_evidence"]["workers_down"]
      assert request["report"]["cleanup_evidence"]["transport"] == "confirmed"
      assert Map.keys(admitted) |> length() == if(ctx.mode == :deno, do: 2, else: 1)
      assert {:error, %{reason: :request_timeout}} = Client.await_resource_request(other, 10)
      assert {:ok, release} = Client.start_read_resource(client, "mem://release")
      assert {:ok, _} = Client.await_resource_request(release, 1_000)
      assert {:ok, _} = Client.await_resource_request(other, 1_000)
      assert {:ok, again} = Client.start_read_resource(client, "mem://again")
      assert {:ok, _} = Client.await_resource_request(again, 1_000)
      assert Enum.count(wires(ctx.tmp_dir), &(&1["method"] == "initialize")) == 1
      send(root_provider, {:events, [done()]})
      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
      assert Conversation.status(context.conversation).run.state == :completed
      assert {:ok, %{status: :confirmed}} = Session.close(context.root_binding.session)
      stop_supervised!(:root_conversation)
      stop_supervised!(:resource_manager)
    end
  end

  defp operation(dynamic, client, tool) do
    %{
      run_id: "probe",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_name: tool,
      tool_revision: 1,
      catalog_revision: 1,
      tool_call_id: "call",
      turn_id: "turn",
      enclosing_invocation_id: "invocation",
      arguments: arguments(tool),
      backend_context: %{family: :dynamic, runtime: dynamic, client: client}
    }
  end

  defp cancellation(operation, registration, generation),
    do:
      operation
      |> Map.put(:resource_registration, registration)
      |> Map.put(:stop_generation, generation)
      |> Map.put(:cleanup_deadline, System.monotonic_time(:millisecond) + 2_000)

  defp start_client(root) do
    name = String.to_atom("RuntimeResource#{System.unique_integer([:positive])}")
    fixture = Path.expand("../../fixtures/resource_cancellation_mcp.py", __DIR__)

    start_supervised!(
      {Client,
       name: name,
       transport:
         {:stdio,
          command: System.find_executable("python3"),
          args: [fixture, Path.join(root, "wire.jsonl")]},
       one_shot: true,
       client_info: %{"name" => "runtime-resource", "version" => "1"},
       capabilities: %{},
       protocol_version: "2025-11-25",
       timeout: 3_000}
    )

    assert :ok = Client.await_ready(name, timeout: 3_000)
    name
  end

  defp runtime(client, dynamic, child_overrides \\ []) do
    test = self()
    root = start_supervised!({Session, owner_pid: test}, id: :root_session)

    host =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(host, :stop) end)
    child = start_supervised!({Session, owner_pid: host}, id: :child_session)
    table = :ets.new(:resource_contracts, [:public])
    names = @resources ++ @collaboration ++ ["exec", "wait"]
    authority = authority("root", names)

    manager =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "root",
         parent_name: "/root",
         parent_authority: authority,
         min_wait_timeout_ms: 0,
         child_options: fn _, run, parent ->
           child_opts =
             options(
               child,
               run,
               parent.child.incarnation,
               names,
               :ets.lookup_element(table, :contracts, 2),
               test
             )

           {:ok, Keyword.merge(child_opts, child_overrides)}
         end},
        id: :resource_manager
      )

    contracts =
      MultiAgent.contracts(:v2, manager) ++
        Enum.map(DynamicRuntime.contracts(%{dynamic_runtime: dynamic}), fn contract ->
          put_in(contract.backend_context[:client], client)
        end)

    :ets.insert(table, {:contracts, contracts})
    opts = options(root, "root", 1, names, contracts, test)
    conversation = start_supervised!({Conversation, opts}, id: :root_conversation)
    assert {:ok, _} = Conversation.prompt(conversation, "start")
    assert_receive {:resource_provider, "root", _, provider}, 1_000

    %{
      manager: manager,
      conversation: conversation,
      provider: provider,
      root_binding: opts[:session_binding]
    }
  end

  defp options(session, run, incarnation, names, contracts, test) do
    bindings =
      Map.new(
        for c <- contracts,
            Map.has_key?(c, :collaboration_binding),
            do: {c.tool_name, c.collaboration_binding.fingerprint}
      )

    auth = Map.put(authority(run, names), :tool_bindings, bindings)
    {:ok, binding} = Session.bind(session, auth, incarnation: incarnation)

    {:ok, profile} =
      Codex.profile(:mixed, %{session_binding: binding, code_mode_contracts: contracts}, auth,
        tools: names
      )

    {:ok, store} = EphemeralStore.new(incarnation)

    [
      run_id: run,
      incarnation: incarnation,
      session_binding: binding,
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: test},
      run_timeout: 20_000,
      effect_timeout: 10_000,
      cleanup_timeout: 2_000
    ]
  end

  defp authority(run, names), do: %{caller: "host", run_id: run, grants: names, tool_revision: 1}
  defp arguments("read_mcp_resource"), do: %{"server" => "fixture", "uri" => "mem://pending"}
  defp arguments(_), do: %{"server" => "fixture", "cursor" => "pending"}

  defp call(name, arguments),
    do: %{
      type: :tool_call_completed,
      tool_call: %{
        id: "call-#{System.unique_integer([:positive])}",
        name: name,
        arguments: arguments
      }
    }

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp tool(provider, run, name, arguments) do
    send(provider, {:events, [call(name, arguments), done()]})
    assert_receive {:resource_provider, ^run, request, next}, 6_000
    message = Enum.find(Enum.reverse(request.messages), &(&1[:role] == :tool))
    {next, message.result}
  end

  defp wires(root) do
    case File.read(Path.join(root, "wire.jsonl")) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  defp pending?(wire),
    do:
      get_in(wire, ["params", "cursor"]) == "pending" or
        get_in(wire, ["params", "uri"]) == "mem://pending"

  defp eventually(fun, left \\ 300)
  defp eventually(_, 0), do: flunk("resource lifecycle did not settle")

  defp eventually(fun, left) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, left - 1)
        )
  end
end
