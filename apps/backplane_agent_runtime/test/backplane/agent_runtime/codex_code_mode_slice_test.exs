defmodule Backplane.AgentRuntime.CodexCodeModeSliceTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}
  alias Backplane.AgentRuntime.Error

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

  test "cancelling an unpublished generator retires Deno without advancing effects" do
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

  test "Deno failure takes priority over an unpublished generator" do
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

    assert {:ok, %{status: :yielded, value: "ready", handle: handle}} =
             CodeMode.execute(registry, "slice", source, dispatcher: dispatcher)

    assert {:ok, worker} = ResourceRegistry.fetch(registry, handle, "slice")
    assert {:ok, identity} = CodeMode.Worker.os_identity(worker)
    assert {_, 0} = System.cmd("kill", ["-STOP", to_string(identity.pid)])

    try do
      assert {:ok, %{status: :yielded} = slice} =
               CodeMode.resume(registry, handle, nil, owner: "slice", yield_time_ms: 0)

      refute Map.has_key?(slice, :value)
      assert :sys.get_state(worker).from == nil
    after
      System.cmd("kill", ["-CONT", to_string(identity.pid)])
    end

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
