defmodule Backplane.AgentRuntime.CodexCodeModeSliceTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}
  alias Backplane.AgentRuntime.Error

  test "wait slices expire during synchronous JavaScript without admitting a stale tool call" do
    registry = start_supervised!(ResourceRegistry)
    test = self()

    dispatcher = fn request, context ->
      send(test, {:effect, context.catalog_revision, request.arguments})
      {:ok, request.arguments, context}
    end

    source = """
    const input = yield 'ready';
    const deadline = Date.now() + 1500;
    text('busy');
    while (Date.now() < deadline) {}
    const effect = await codex.tool('echo', {value: input});
    return [effect.value, ALL_TOOLS[0].name];
    """

    assert {:ok, %{status: :yielded, value: "ready", handle: handle}} =
             CodeMode.execute(registry, "slice", source, dispatcher: dispatcher)

    assert {:ok, %{status: :yielded} = initial} =
             CodeMode.resume(registry, handle, 42, owner: "slice", yield_time_ms: 10)

    refute Map.has_key?(initial, :value)

    {elapsed, result} =
      :timer.tc(
        fn ->
          CodeMode.resume(registry, handle, "ignored",
            owner: "slice",
            yield_time_ms: 10,
            dispatcher: dispatcher,
            execution_context: %{owner_id: "slice", catalog_revision: 1},
            tools: [%{name: "stale"}]
          )
        end,
        :millisecond
      )

    assert elapsed < 1_000, "wait took #{elapsed} ms while JavaScript was busy"
    assert {:ok, %{status: :yielded} = running} = result
    refute Map.has_key?(running, :value)
    assert :ok = ResourceRegistry.owner_transfer_ready(registry, "slice")
    refute_receive {:effect, _, _}, 0

    assert {:ok, %{status: :completed, value: [42, "current"], output: output}} =
             CodeMode.resume(registry, handle, nil,
               owner: "slice",
               dispatcher: dispatcher,
               execution_context: %{owner_id: "slice", catalog_revision: 2},
               tools: [%{name: "current"}]
             )

    assert initial.output ++ running.output ++ output == [%{"type" => "text", "text" => "busy"}]
    assert_receive {:effect, 2, %{"value" => 42}}
    refute_receive {:effect, _, _}, 0
  end

  test "a generator arriving after a timer slice is published before JavaScript resumes" do
    registry = start_supervised!(ResourceRegistry)
    test = self()

    dispatcher = fn request, context ->
      send(test, {:effect, request.arguments})
      {:ok, request.arguments, context}
    end

    source = """
    yield 'ready';
    text('before');
    const answer = yield 'first';
    text(answer);
    const effect = await codex.tool('echo', {value: 42});
    yield 'second';
    text('after');
    return effect.value;
    """

    {handle, worker, identity} = slice_before_generator(registry, source, dispatcher)
    ref = Process.monitor(worker)

    assert {:ok, %{status: :yielded, value: "first", output: output}} =
             CodeMode.resume(registry, handle, "ignored", owner: "slice")

    assert output == [%{"type" => "text", "text" => "before"}]
    refute_receive {:effect, _}, 0

    assert {:ok, %{status: :yielded, value: "second", output: output}} =
             CodeMode.resume(registry, handle, "accepted", owner: "slice")

    assert output == [%{"type" => "text", "text" => "accepted"}]
    assert_receive {:effect, %{"value" => 42}}

    assert {:ok, %{status: :completed, value: 42, output: output}} =
             CodeMode.resume(registry, handle, nil, owner: "slice")

    assert output == [%{"type" => "text", "text" => "after"}]
    refute_receive {:effect, _}, 0
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    assert {:error, %Error{class: :not_found}} = ResourceRegistry.fetch(registry, handle, "slice")
    assert :ok = CodeMode.Worker.cleanup_identity(identity)
  end

  test "an explicit yield while configuration is pending returns before queued tool dispatch" do
    registry = start_supervised!(ResourceRegistry)
    test = self()

    dispatcher = fn request, context ->
      send(test, {:effect, context.catalog_revision, request.arguments})
      {:ok, request.arguments, context}
    end

    source = """
    yield 'ready';
    const deadline = Date.now() + 800;
    while (Date.now() < deadline) {}
    text('explicit');
    yield_control();
    return await codex.tool('echo', {value: 42});
    """

    assert {:ok, %{status: :yielded, value: "ready", handle: handle}} =
             CodeMode.execute(registry, "slice", source, dispatcher: dispatcher)

    assert {:ok, %{status: :yielded}} =
             CodeMode.resume(registry, handle, nil, owner: "slice", yield_time_ms: 10)

    assert {:ok, %{status: :yielded, output: [%{"type" => "text", "text" => "explicit"}]} = slice} =
             CodeMode.resume(registry, handle, nil,
               owner: "slice",
               dispatcher: dispatcher,
               execution_context: %{owner_id: "slice", catalog_revision: 1}
             )

    refute Map.has_key?(slice, :value)
    refute_receive {:effect, _, _}, 0

    assert {:ok, %{status: :completed, value: %{"value" => 42}, output: []}} =
             CodeMode.resume(registry, handle, nil,
               owner: "slice",
               dispatcher: dispatcher,
               execution_context: %{owner_id: "slice", catalog_revision: 2}
             )

    assert_receive {:effect, 2, %{"value" => 42}}
    refute_receive {:effect, _, _}, 0
  end

  test "cancelling an unpublished generator retires QuickBEAM without advancing effects" do
    registry = start_supervised!(ResourceRegistry)
    test = self()

    dispatcher = fn _, context ->
      send(test, :unexpected_effect)
      {:ok, nil, context}
    end

    source = "yield 'ready'; yield 'pending'; await codex.tool('echo', {});"
    {handle, worker, identity} = slice_before_generator(registry, source, dispatcher)
    ref = Process.monitor(worker)
    assert {:generator, {:ok, %{value: "pending"}}} = :sys.get_state(worker).pending_yield
    assert {:ok, _} = CodeMode.cancel(registry, handle, "slice")
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert :ok = CodeMode.Worker.cleanup_identity(identity)
    refute_receive :unexpected_effect, 0
  end

  test "QuickBEAM failure takes priority over an unpublished generator" do
    registry = start_supervised!(ResourceRegistry)
    source = "yield 'ready'; yield 'pending'; return 'unreachable';"
    dispatcher = fn _, context -> {:ok, nil, context} end
    {handle, worker, identity} = slice_before_generator(registry, source, dispatcher)
    ref = Process.monitor(worker)
    assert {_, 0} = System.cmd("kill", ["-KILL", to_string(identity.pid)])
    await_terminal(worker, System.monotonic_time(:millisecond) + 2_000)

    assert {:error, %Error{class: :execution_failure}} =
             CodeMode.resume(registry, handle, nil, owner: "slice")

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    assert :ok = CodeMode.Worker.cleanup_identity(identity)
  end

  defp slice_before_generator(registry, source, dispatcher) do
    assert CodeMode.lifecycle_capability(%{}) == :verified

    source =
      String.replace(
        source,
        "yield 'ready';",
        "yield 'ready'; await new Promise(resolve => setTimeout(resolve, 150));",
        global: false
      )

    assert {:ok, %{status: :yielded, value: "ready", handle: handle}} =
             CodeMode.execute(registry, "slice", source, dispatcher: dispatcher)

    assert {:ok, worker} = ResourceRegistry.fetch(registry, handle, "slice")
    assert {:ok, identity} = CodeMode.Worker.os_identity(worker)

    assert {:ok, %{status: :yielded} = slice} =
             CodeMode.resume(registry, handle, nil, owner: "slice", yield_time_ms: 0)

    refute Map.has_key?(slice, :value)
    assert :sys.get_state(worker).from == nil

    await_generator(worker, System.monotonic_time(:millisecond) + 2_000)
    {handle, worker, identity}
  end

  defp await_terminal(worker, deadline) do
    if :sys.get_state(worker).terminal_result == nil do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_terminal(worker, deadline)
    end
  end

  defp await_generator(worker, deadline) do
    state = :sys.get_state(worker)

    if state.pending_yield == nil and state.terminal_result == nil do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_generator(worker, deadline)
    end
  end
end
