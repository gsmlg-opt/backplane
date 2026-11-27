defmodule Backplane.AgentRuntime.CodexCodeModeQueueTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}
  alias Backplane.AgentRuntime.Error

  setup do
    assert is_binary(Backplane.AgentRuntime.Codex.CodeMode.RunnerLaunch.executable(nil)),
           "these regressions require real QuickBEAM"

    assert CodeMode.lifecycle_capability(%{}) == :verified
    %{registry: start_supervised!(ResourceRegistry)}
  end

  test "Promise.all resolves every call with its own result and acknowledged context", ctx do
    test = self()

    dispatcher = fn request, context ->
      revision = Map.get(context, :revision, 0)
      send(test, {:called, request.arguments["value"], revision})
      {:ok, request.arguments, Map.put(context, :revision, revision + 1)}
    end

    source = """
    const values = await Promise.all([1, 2, 3].map(value => codex.tool('echo', {value})));
    return values.map(item => item.value);
    """

    assert {:ok, %{status: :completed, value: [1, 2, 3]}} =
             CodeMode.execute(ctx.registry, "queue", source, dispatcher: dispatcher)

    assert_receive {:called, 1, 0}
    assert_receive {:called, 2, 1}
    assert_receive {:called, 3, 2}
    refute_receive {:called, _, _}, 20
    assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, "queue")
  end

  test "catchable errors settle the matching Promise and allow queued calls to continue", ctx do
    dispatcher = fn request, _context ->
      case request.arguments["value"] do
        2 -> {:error, Error.new(:not_found, "missing second value")}
        value -> {:ok, value}
      end
    end

    source = """
    const values = await Promise.allSettled([1, 2, 3].map(value => codex.tool('echo', {value})));
    return values.map(item => item.status === 'fulfilled' ? item.value : item.reason.message);
    """

    assert {:ok, %{status: :completed, value: [1, "missing second value", 3]}} =
             CodeMode.execute(ctx.registry, "caught-queue", source, dispatcher: dispatcher)
  end

  test "queued calls wait for a resumed cell's current dispatcher", ctx do
    test = self()

    source = """
    await new Promise(resolve => setTimeout(resolve, 100));
    return await Promise.all([1, 2].map(value => codex.tool('echo', {value})));
    """

    assert {:ok, %{status: :yielded, handle: handle}} =
             CodeMode.execute(ctx.registry, "detached-queue", source,
               yield_time_ms: 0,
               dispatcher: fn _, _ -> flunk("detached code used the expired dispatcher") end
             )

    assert {:ok, worker} = ResourceRegistry.fetch(ctx.registry, handle, "detached-queue")
    await_queued(worker, 2, System.monotonic_time(:millisecond) + 2_000)

    dispatcher = fn request, context ->
      send(test, {:rebound_call, request.arguments["value"], context.revision})
      {:ok, request.arguments["value"]}
    end

    assert {:ok, %{status: :completed, value: [1, 2]}} =
             CodeMode.resume(ctx.registry, handle, nil,
               owner: "detached-queue",
               dispatcher: dispatcher,
               execution_context: %{owner_id: "detached-queue", revision: 7}
             )

    assert_receive {:rebound_call, 1, 7}
    assert_receive {:rebound_call, 2, 7}
  end

  test "cancellation joins the active dispatcher and discards calls waiting behind it", ctx do
    test = self()

    dispatcher = fn request, _context ->
      send(test, {:waiting_call, request.arguments["value"], self()})
      receive do: (:complete -> {:ok, request.arguments})
    end

    source = """
    yield 'ready';
    return await Promise.all([1, 2, 3].map(value => codex.tool('echo', {value})));
    """

    assert {:ok, %{status: :yielded, handle: handle}} =
             CodeMode.execute(ctx.registry, "cancel-queue", source, dispatcher: dispatcher)

    assert {:ok, worker} = ResourceRegistry.fetch(ctx.registry, handle, "cancel-queue")
    assert {:ok, identity} = CodeMode.Worker.os_identity(worker)
    worker_ref = Process.monitor(worker)

    waiter =
      Task.async(fn -> CodeMode.resume(ctx.registry, handle, nil, owner: "cancel-queue") end)

    assert_receive {:waiting_call, 1, dispatch}, 2_000
    dispatch_ref = Process.monitor(dispatch)
    await_queued(worker, 2, System.monotonic_time(:millisecond) + 2_000)

    assert {:ok, _} = CodeMode.cancel(ctx.registry, handle, "cancel-queue")
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    assert_receive {:DOWN, ^dispatch_ref, :process, ^dispatch, _}
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(waiter)
    assert :ok = CodeMode.Worker.cleanup_identity(identity)
    refute_receive {:waiting_call, _, _}, 20
  end

  test "a fresh synchronous dispatcher clears a previous native submission callback", ctx do
    source = "yield 'ready'; return await codex.tool('echo', {});"

    assert {:ok, %{status: :yielded, handle: handle}} =
             CodeMode.execute(ctx.registry, "submission-rebind", source,
               dispatcher: fn _, _ -> flunk("expired dispatcher") end,
               nested_submit: fn _, _ -> flunk("expired submission callback") end
             )

    assert {:ok, %{status: :completed, value: 7}} =
             CodeMode.resume(ctx.registry, handle, nil,
               owner: "submission-rebind",
               dispatcher: fn _, _ -> {:ok, 7} end,
               execution_context: %{owner_id: "submission-rebind"}
             )
  end

  test "detached queued calls consume the lifetime quota before dispatch", ctx do
    test = self()

    source = """
    await new Promise(resolve => setTimeout(resolve, 100));
    return await Promise.all([1, 2, 3].map(value => codex.tool('echo', {value})));
    """

    assert {:ok, %{status: :yielded, handle: handle}} =
             CodeMode.execute(ctx.registry, "queue-limit", source,
               yield_time_ms: 0,
               tool_limit: 2,
               dispatcher: fn _, _ ->
                 send(test, :unexpected_dispatch)
                 {:ok, nil}
               end
             )

    assert {:ok, worker} = ResourceRegistry.fetch(ctx.registry, handle, "queue-limit")
    await_terminal(worker, System.monotonic_time(:millisecond) + 2_000)

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.resume(ctx.registry, handle, nil, owner: "queue-limit")

    refute_receive :unexpected_dispatch, 20
    assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, "queue-limit")
  end

  defp await_queued(worker, count, deadline) do
    state = :sys.get_state(worker)

    if :queue.len(state.pending_tools) != count do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_queued(worker, count, deadline)
    end
  end

  defp await_terminal(worker, deadline) do
    if :sys.get_state(worker).terminal_result == nil do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_terminal(worker, deadline)
    end
  end
end
