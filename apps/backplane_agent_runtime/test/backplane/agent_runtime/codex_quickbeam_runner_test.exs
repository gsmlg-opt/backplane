defmodule Backplane.AgentRuntime.CodexQuickbeamRunnerTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.CodeMode
  alias Backplane.AgentRuntime.Codex.CodeMode.{ProcessObserver, Runner, RunnerLaunch}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry

  @moduletag :tmp_dir

  setup do
    runner = RunnerLaunch.executable(nil)
    assert is_binary(runner), "build the Code Mode runner or set BACKPLANE_CODE_MODE_RUNNER"
    %{runner: runner}
  end

  test "JSON snapshots and synchronous serialization errors preserve the ordered tool bridge", %{
    runner: runner
  } do
    port = open_runner(runner)

    execute(port, ~S"""
    const value = {n:1};
    text(value); store('saved', value); value.n = 2;
    for (const helper of [() => text(1n), () => store('bad', 1n), () => codex.tool('bad', 1n)]) {
      try { helper(); } catch (error) { text(error.name); }
    }
    const slow = codex.tool('slow', {missing:undefined, values:[undefined, Infinity], bytes:new Uint8Array([1,2])});
    const fast = codex.custom('fast', 'raw\r\n界');
    text(await Promise.all([slow, fast]));
    """)

    assert %{"type" => "output", "item" => %{"text" => ~s({"n":1})}} = frame(port)
    assert %{"type" => "store", "key" => "saved", "value" => %{"n" => 1}} = frame(port)

    for _ <- 1..3 do
      assert %{"type" => "output", "item" => %{"text" => "TypeError"}} = frame(port)
    end

    assert %{"type" => "tool_call", "id" => slow, "name" => "slow", "arguments" => args} =
             frame(port)

    assert args == %{"values" => [nil, nil], "bytes" => %{"0" => 1, "1" => 2}}

    assert %{"type" => "tool_call", "id" => fast, "name" => "fast", "rawInput" => raw} =
             frame(port)

    assert raw == "raw\r\n界"
    send_frame(port, %{type: "tool_result", id: fast, ok: true, value: %{"fast" => "界\r\n"}})

    send_frame(port, %{
      type: "tool_result",
      id: slow,
      ok: true,
      value: %{"slow" => [1, true, nil]}
    })

    assert %{"type" => "output", "item" => %{"text" => result}} = frame(port)
    assert JSON.decode!(result) == [%{"slow" => [1, true, nil]}, %{"fast" => "界\r\n"}]
    assert %{"type" => "complete"} = frame(port)
    close_runner(port)
  end

  test "configure is applied and acknowledged while native evaluation awaits a tool", %{
    runner: runner
  } do
    port = open_runner(runner)

    execute(
      port,
      "await codex.tool('gate', {}); text(ALL_TOOLS[0].description); text(load('current'));"
    )

    assert %{"type" => "tool_call", "id" => id, "name" => "gate"} = frame(port)

    send_frame(port, %{
      type: "configure",
      revision: 1,
      tools: [%{name: "echo", description: "applied"}],
      stored: %{current: "fresh"}
    })

    assert %{"type" => "configured", "revision" => 1} = frame(port)
    send_frame(port, %{type: "tool_result", id: id, ok: true, value: nil})
    assert %{"item" => %{"text" => "applied"}} = frame(port)
    assert %{"item" => %{"text" => "fresh"}} = frame(port)
    assert %{"type" => "complete"} = frame(port)
    close_runner(port)
  end

  test "timer slices refresh store before the retained generator resumes", %{runner: runner} do
    registry = start_supervised!(ResourceRegistry)

    assert {:ok, %{status: :completed}} =
             CodeMode.execute(registry, "quickbeam-control", "store('current', 'old');",
               code_mode_runner: runner,
               dispatcher: fn _, _ -> {:ok, nil} end
             )

    code = """
    const local = 7;
    text('before');
    while (load('current') === 'old') await new Promise(resolve => setTimeout(resolve, 5));
    text(load('current'));
    yield local;
    text('after');
    return local + 1;
    """

    assert {:ok, %{status: :yielded, handle: handle, output: first}} =
             CodeMode.execute(registry, "quickbeam-control", code,
               code_mode_runner: runner,
               dispatcher: fn _, _ -> {:ok, nil} end,
               timeout: 5_000,
               yield_time_ms: 10
             )

    assert {:ok, %{status: :completed}} =
             CodeMode.execute(registry, "quickbeam-control", "store('current', 'new');",
               code_mode_runner: runner,
               dispatcher: fn _, _ -> {:ok, nil} end
             )

    assert {:ok, %{status: :yielded, value: 7, output: middle}} =
             CodeMode.resume(registry, handle, nil,
               owner: "quickbeam-control",
               yield_time_ms: 2_000
             )

    assert first ++ middle == [
             %{"type" => "text", "text" => "before"},
             %{"type" => "text", "text" => "new"}
           ]

    assert {:ok, %{status: :completed, value: 8, output: [%{"text" => "after"}]}} =
             CodeMode.resume(registry, handle, nil, owner: "quickbeam-control")
  end

  test "module top-level await uses the existing bridge and module exit completes once", %{
    runner: runner
  } do
    port = open_runner(runner)

    execute(
      port,
      "export const value=await codex.tool('module', {}); text(value); exit(); text('late');"
    )

    assert %{"type" => "tool_call", "id" => id, "name" => "module"} = frame(port)
    send_frame(port, %{type: "tool_result", id: id, ok: true, value: "module-value"})
    assert %{"item" => %{"text" => "module-value"}} = frame(port)
    assert %{"type" => "complete"} = frame(port)
    close_runner(port)
  end

  test "the strict runner hides the native bridge and rejects ambient network and imports", %{
    runner: runner
  } do
    port = open_runner(runner)

    execute(port, """
    text([typeof Beam, typeof QuickBEAM, typeof process, typeof require]);
    const descriptor=Object.getOwnPropertyDescriptor(globalThis, '__backplaneExecute');
    text([descriptor.writable, descriptor.configurable]);
    try { await fetch('https://example.invalid'); } catch(error) { text(error.message); }
    try { await import('node:fs/promises'); text('unexpected-import'); } catch(error) { text('import-denied'); }
    """)

    assert %{"item" => %{"text" => globals}} = frame(port)
    assert JSON.decode!(globals) == List.duplicate("undefined", 4)
    assert %{"item" => %{"text" => "[false,false]"}} = frame(port)
    assert %{"item" => %{"text" => "network access is disabled"}} = frame(port)
    assert %{"item" => %{"text" => "import-denied"}} = frame(port)
    assert %{"type" => "complete"} = frame(port)
    close_runner(port)
  end

  test "out-of-order callbacks cannot move completion ahead of output, store or tool submission" do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    stdin = make_ref()
    refs = [make_ref(), make_ref(), make_ref(), make_ref()]

    events = [
      %{type: "output", item: %{type: "text", text: "first"}},
      %{type: "store", key: "saved", value: 1},
      %{type: "tool_call", id: "one", name: "write", arguments: %{}},
      %{type: "complete", value: 2}
    ]

    state = %{
      stdin: stdin,
      stdout: port,
      next_event: 1,
      events: %{},
      event_bytes: 0,
      tools: %{},
      phase: :running
    }

    queued =
      Enum.reduce([4, 3, 2], state, fn sequence, state ->
        event = JSON.encode!(Enum.at(events, sequence - 1))
        from = {self(), Enum.at(refs, sequence - 1)}
        assert {:noreply, next} = Runner.handle_call({:event, sequence, event}, from, state)
        next
      end)

    refute_receive {^port, {:data, _}}, 0

    assert {:noreply, completed} =
             Runner.handle_call({:event, 1, JSON.encode!(hd(events))}, {self(), hd(refs)}, queued)

    assert Enum.map(1..4, fn _ -> frame(port)["type"] end) ==
             ["output", "store", "tool_call", "complete"]

    assert completed.next_event == 5
    assert completed.event_bytes == 0
    assert completed.events == %{}
    assert completed.phase == :finished
    tool_ref = Enum.at(refs, 2)
    assert completed.tools == %{"one" => {self(), tool_ref}}
    refute_receive {^tool_ref, _}, 0

    result = JSON.encode!(%{type: "tool_result", id: "one", ok: true, value: "settled"})

    assert {:noreply, %{tools: %{}}} =
             Runner.handle_info(
               {stdin, {:data, result <> "\n"}},
               Map.merge(completed, %{input: [], input_bytes: 0, allowance: nil})
             )

    assert_receive {^tool_ref, ^result}
    Port.close(port)
  end

  test "sudden parent BEAM death stops runner OS processes during CPU, tool and timer waits", %{
    runner: runner,
    tmp_dir: tmp_dir
  } do
    elixir = System.find_executable("elixir")
    assert is_binary(elixir), "Elixir is required to launch the independent parent VM"
    script = Path.join(tmp_dir, "runner_parent.exs")

    File.write!(script, """
    [runner, code] = System.argv()
    port = Port.open({:spawn_executable, runner}, [:binary, :exit_status])
    {:os_pid, runner_pid} = Port.info(port, :os_pid)
    read_line = fn read_line, partial ->
      receive do
        {^port, {:data, bytes}} ->
          case :binary.split(partial <> bytes, "\\n") do
            [line, rest] -> {line, rest}
            [next] -> read_line.(read_line, next)
          end
      after
        5_000 -> raise "runner response timed out"
      end
    end
    {_ready, rest} = read_line.(read_line, "")
    true = Port.command(port, JSON.encode!(%{type: "execute", code: code, tools: [], stored: %{}}) <> "\\n")
    {_entered, _rest} = read_line.(read_line, rest)
    IO.puts(JSON.encode!(%{runner_pid: runner_pid}))
    receive do: (:never -> :ok)
    """)

    for source <- [
          "text('entered'); while(true){}",
          "await codex.tool('pending', {});",
          "const waiting=new Promise(r=>setTimeout(r,60000)); text('entered'); await waiting;"
        ] do
      parent =
        Port.open({:spawn_executable, elixir}, [
          :binary,
          :exit_status,
          args: ["--erl", "+S 1:1 +SDcpu 1 +SDio 1", script, runner, source]
        ])

      parent_identity = port_identity(parent)
      on_exit(fn -> CodeMode.Worker.cleanup_identity(parent_identity) end)
      assert %{"runner_pid" => runner_pid} = frame(parent)
      runner_identity = identity(runner_pid)
      on_exit(fn -> CodeMode.Worker.cleanup_identity(runner_identity) end)
      assert {_, 0} = System.cmd("kill", ["-KILL", to_string(parent_identity.pid)])
      assert_receive {^parent, {:exit_status, _}}, 5_000
      await_stopped(runner_identity, System.monotonic_time(:millisecond) + 3_000)
    end
  end

  defp open_runner(runner) do
    port = Port.open({:spawn_executable, runner}, [:binary, :exit_status])
    identity = port_identity(port)
    on_exit(fn -> CodeMode.Worker.cleanup_identity(identity) end)
    assert %{"type" => "ready", "protocol" => 1, "engine" => engine} = frame(port)
    assert is_binary(engine) and engine != ""
    port
  end

  defp execute(port, code),
    do: send_frame(port, %{type: "execute", code: code, tools: [], stored: %{}})

  defp send_frame(port, frame), do: assert(Port.command(port, JSON.encode!(frame) <> "\n"))

  defp frame(port) do
    buffered = Process.get({__MODULE__, port}, "")
    read_frame(port, buffered, System.monotonic_time(:millisecond) + 5_000)
  end

  defp read_frame(port, buffered, deadline) do
    case :binary.split(buffered, "\n") do
      [line, rest] ->
        Process.put({__MODULE__, port}, rest)
        JSON.decode!(line)

      [_] ->
        receive do
          {^port, {:data, bytes}} ->
            read_frame(port, buffered <> bytes, deadline)

          {^port, {:exit_status, status}} ->
            flunk("runner exited before its next frame: #{status}")
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            flunk("runner did not publish its next frame; buffered: #{inspect(buffered)}")
        end
    end
  end

  defp port_identity(port) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    identity(pid)
  end

  defp identity(pid) do
    assert {:ok, %{starttime: starttime}} = ProcessObserver.identity(pid)
    %{pid: pid, starttime: starttime}
  end

  defp close_runner(port) do
    identity = port_identity(port)
    Port.close(port)
    await_stopped(identity, System.monotonic_time(:millisecond) + 3_000)
  end

  defp await_stopped(%{pid: pid, starttime: original} = identity, deadline) do
    case ProcessObserver.identity(pid) do
      {:error, reason} when reason in [:enoent, :esrch] ->
        :ok

      {:ok, %{state: state, starttime: starttime}}
      when state in ["Z", "X"] or starttime != original ->
        :ok

      {:ok, _} ->
        assert System.monotonic_time(:millisecond) < deadline,
               "runner OS process survived parent loss: #{pid}"

        Process.sleep(10)
        await_stopped(identity, deadline)
    end
  end
end
