defmodule Backplane.AgentRuntime.CodexFramingTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}
  alias Backplane.AgentRuntime.Codex.CodeMode.RunnerLaunch
  alias Backplane.AgentRuntime.Error

  @native_capability CodeMode.lifecycle_capability(%{})

  if match?({:unsupported, _reason}, @native_capability) do
    @moduletag skip: "native Code Mode lifecycle capability unavailable"
  end

  setup do
    runner = RunnerLaunch.executable(nil)
    assert is_binary(runner), "build the Code Mode runner before running framing tests"
    %{runner: runner}
  end

  test "record and multibyte UTF-8 splits are buffered", %{runner: launcher} do
    port = start_runner(launcher)
    record = frame(%{type: "execute", code: ~s(return "你";)})
    {offset, _} = :binary.match(record, "你")
    <<first::binary-size(^offset + 1), second::binary-size(1), rest::binary>> = record
    assert Port.command(port, first)
    assert Port.command(port, second)
    assert Port.command(port, rest)
    assert read_frame(port) == %{"type" => "complete", "value" => "你"}
  end

  test "multiple complete records in one chunk settle a nested tool", %{runner: launcher} do
    port = start_runner(launcher)
    id = start_tool(port, ~s|return await codex.tool("echo", {});|)
    result = frame(%{type: "tool_result", id: id, ok: true, value: 42})
    allowance = frame(%{type: "tool_result_allowance", id: id, bytes: byte_size(result) - 1})
    assert Port.command(port, [allowance, result])
    assert read_frame(port) == %{"type" => "complete", "value" => 42}
  end

  test "large nested result fragments reach the waiting tool promise", %{runner: launcher} do
    port = start_runner(launcher)
    id = start_tool(port, ~s|return (await codex.tool("echo", {})).length;|)

    send_fragments(
      port,
      frame(%{type: "tool_result", id: id, ok: true, value: String.duplicate("界", 100_000)})
    )

    assert read_frame(port) == %{"type" => "complete", "value" => 100_000}
  end

  test "malformed and oversized records fail and terminate", %{runner: launcher} do
    for {input, error} <- [
          {"{invalid}\n", "malformed_result"},
          {<<255, ?\n>>, "malformed_result"},
          {String.duplicate(" ", 1_048_577), "budget_exceeded"}
        ] do
      port = start_runner(launcher)
      assert Port.command(port, input)
      assert %{"type" => "error", "error" => %{"class" => ^error}} = read_frame(port)
      assert_receive {^port, {:exit_status, 1}}, 2_000
    end
  end

  test "the runner rejects a truncated record at EOF", %{runner: launcher} do
    {output, status} =
      System.cmd("/bin/sh", ["-c", ~s(printf '{"type":' | "$1"), "runner-test", launcher])

    assert status == 1
    assert output =~ "incomplete Code Mode command at EOF"
  end

  test "host allowance carries one exact pending result across fragmented UTF-8 records",
       %{runner: launcher} do
    port = start_runner(launcher)
    id = start_tool(port, ~s|return (await codex.tool("image", {})).length;|)

    result =
      frame(%{type: "tool_result", id: id, ok: true, value: String.duplicate("界", 400_000)})

    assert Port.command(
             port,
             frame(%{type: "tool_result_allowance", id: id, bytes: byte_size(result) - 1})
           )

    send_fragments(port, result)
    assert read_frame(port) == %{"type" => "complete", "value" => 400_000}
  end

  test "host allowance rejects absent pending identity and mismatched following result",
       %{runner: launcher} do
    for commands <- [
          [%{type: "tool_result_allowance", id: "missing", bytes: 2_000_000}],
          [
            %{type: "tool_result_allowance", id: "1", bytes: 2_000_000},
            %{type: "tool_result", id: "2", ok: true, value: 42}
          ]
        ] do
      port = start_runner(launcher)
      assert start_tool(port, ~s|return await codex.tool("image", {});|) == "1"
      assert Port.command(port, Enum.map(commands, &frame/1))
      assert %{"type" => "error", "error" => %{"class" => "malformed_result"}} = read_frame(port)
      assert_receive {^port, {:exit_status, 1}}, 2_000
    end
  end

  test "large permitted execution and nested result use the real CodeMode worker", %{
    runner: launcher
  } do
    registry = start_supervised!(ResourceRegistry)

    code =
      "/*" <> String.duplicate("x", 100_000) <> "*/ return (await codex.tool('echo', {})).length;"

    opts = [
      code_mode_runner: launcher,
      dispatcher: fn _, _ -> {:ok, String.duplicate("界", 100_000)} end
    ]

    assert {:ok, %{status: :completed, value: 100_000}} =
             CodeMode.execute(registry, "framing", code, opts)
  end

  test "oversized real nested result settles instead of hanging", %{runner: launcher} do
    registry = start_supervised!(ResourceRegistry)

    opts = [
      code_mode_runner: launcher,
      timeout: 3_000,
      dispatcher: fn _, _ -> {:ok, String.duplicate("x", 1_100_000)} end
    ]

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.execute(registry, "oversized", "return await codex.tool('echo', {});", opts)
  end

  test "Elixir port decoder retains fragmented UTF-8 until a complete record" do
    reply = make_ref()
    state = framing_state(reply, "")
    port = state.port

    record = JSON.encode!(%{type: "complete", value: "你"}) <> "\n"
    {offset, _} = :binary.match(record, "你")
    <<first::binary-size(^offset + 1), second::binary>> = record
    assert {:noreply, buffered} = CodeMode.Worker.handle_info({port, {:data, first}}, state)
    assert buffered.buffer == first
    assert {:stop, :normal, _} = CodeMode.Worker.handle_info({port, {:data, second}}, buffered)
    assert_receive {^reply, {:ok, %{status: :completed, value: "你"}}}
  end

  test "Elixir port decoder rejects oversized records and incomplete EOF" do
    for {message, expected} <- [{:oversized, :budget_exceeded}, {:eof, :malformed_result}] do
      reply = make_ref()
      state = framing_state(reply, "{")
      port = state.port

      event =
        if message == :oversized,
          do: {:data, String.duplicate("x", 1_048_576)},
          else: {:exit_status, 0}

      assert {:stop, :normal, _} = CodeMode.Worker.handle_info({port, event}, state)
      assert_receive {^reply, {:error, %Error{class: ^expected}}}
    end
  end

  defp framing_state(reply, buffer) do
    # Exercise deterministic framing messages with a real owned port, so the
    # terminal transition also has truthful process-cleanup evidence.
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])
    {:os_pid, pid} = Port.info(port, :os_pid)

    {:ok, %{starttime: starttime}} =
      Backplane.AgentRuntime.Codex.CodeMode.ProcessObserver.identity(pid)

    identity = %{pid: pid, starttime: starttime}

    %{
      port: port,
      os_identity: identity,
      os_cleanup_status: :not_requested,
      buffer: buffer,
      from: {self(), reply},
      timer: nil,
      awaiting_resume: false,
      output_limit: 1_048_576
    }
  end

  defp start_runner(launcher) do
    port = Port.open({:spawn_executable, launcher}, [:binary, :exit_status, {:line, 1_048_576}])
    assert %{"type" => "ready", "protocol" => 1} = read_frame(port)
    port
  end

  defp start_tool(port, code) do
    assert Port.command(port, frame(%{type: "execute", code: code}))
    assert %{"type" => "tool_call", "id" => id} = read_frame(port)
    id
  end

  defp read_frame(port) do
    assert_receive {^port, {:data, {:eol, line}}}, 3_000
    JSON.decode!(line)
  end

  defp frame(value), do: JSON.encode!(value) <> "\n"

  defp send_fragments(port, bytes) when byte_size(bytes) <= 997,
    do: assert(Port.command(port, bytes))

  defp send_fragments(port, <<chunk::binary-size(997), rest::binary>>) do
    assert Port.command(port, chunk)
    send_fragments(port, rest)
  end
end
