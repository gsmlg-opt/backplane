defmodule Backplane.AgentRuntime.CommandInteractiveTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Command, Command.OutputBuffer}
  alias Backplane.AgentRuntime.Tools.LocalCommand

  defmodule CompletedCommand do
    def start(_command, request, _opts), do: {:ok, %{owner_run_id: request.owner_run_id}}

    def read(_command, _invocation, _job, _opts),
      do: {:ok, %{output: ["HEAD\nmiddle\nTAIL"], cursor: 1, status: :completed, exit_status: 0}}

    def cancel(_command, _invocation), do: :ok
  end

  @moduletag :tmp_dir
  test "bounded output retains head and tail with monotonic polling cursors" do
    buffer = OutputBuffer.new(8) |> OutputBuffer.append("0123456789")
    assert {"01236789", 10} = OutputBuffer.read(buffer, 0)
    buffer = OutputBuffer.append(buffer, "abcd")
    assert {"abcd", 14} = OutputBuffer.read(buffer, 10)
    assert {"", 14} = OutputBuffer.read(buffer, 14)
  end

  test "UTF8 remains intact when head and tail meet inside a codepoint" do
    buffer = OutputBuffer.new(8) |> OutputBuffer.append("中文")
    assert {"中文", 6} = OutputBuffer.read(buffer, 0)
    buffer = OutputBuffer.append(buffer, "中文中文")
    {text, 18} = OutputBuffer.read(buffer, 0)
    assert String.valid?(text)
    assert byte_size(text) <= 8
  end

  @tag :utf8_polling
  test "polling preserves a UTF8 codepoint split across output frames below the cap" do
    buffer = OutputBuffer.new(32) |> OutputBuffer.append("ok " <> <<0xE4>>)
    assert {"ok ", cursor} = OutputBuffer.read(buffer, 0)
    assert cursor == 3
    assert {"", ^cursor} = OutputBuffer.read(buffer, cursor)

    buffer = OutputBuffer.append(buffer, <<0xB8, 0xAD>> <> "!")
    assert {"中!", 7} = OutputBuffer.read(buffer, cursor)
    assert {"", 7} = OutputBuffer.read(buffer, 7)
  end

  @tag :utf8_polling
  test "polling preserves a split UTF8 codepoint in the retained tail" do
    buffer = OutputBuffer.new(8) |> OutputBuffer.append("0123456789")
    assert {"01236789", cursor} = OutputBuffer.read(buffer, 0)

    buffer = OutputBuffer.append(buffer, <<0xE4>>)
    assert {"", ^cursor} = OutputBuffer.read(buffer, cursor)

    buffer = OutputBuffer.append(buffer, <<0xB8, 0xAD>>)
    assert {"中", 13} = OutputBuffer.read(buffer, cursor)
    assert {"", 13} = OutputBuffer.read(buffer, 13)
  end

  test "command response budgets retain diagnostic tail", %{tmp_dir: root} do
    {:ok, command} = Command.new(%{adapter: CompletedCommand, allowed_environment: %{}})
    context = %{workspace: root, command: command, caller: %{run_id: "response-budget"}}

    assert {:ok, result} =
             Backplane.AgentRuntime.Codex.call(context, "exec_command", %{
               "cmd" => "ignored",
               "yield_time_ms" => 0,
               "max_output_tokens" => 2
             })

    assert result.output == "HEADTAIL"
    assert result.omitted_output_bytes == 8
  end

  test "interactive command survives output budget without a completion deadline", %{
    tmp_dir: root
  } do
    server = start_supervised!({LocalCommand, name: nil})

    {:ok, command} =
      Command.new(%{
        adapter: LocalCommand,
        server: server,
        allowed_environment: %{},
        deadline_limit: :infinity,
        output_policy: :truncate,
        output_limit: 64
      })

    invocation = %{
      owner_run_id: "interactive",
      session_id: 9182,
      incarnation: 1,
      owner_pid: self(),
      workspace: root,
      executable: System.find_executable("sh"),
      arguments: [
        "-c",
        "printf 'HEAD\\n'; i=0; while [ $i -lt 100 ]; do printf 'abcdefghij\\n'; i=$((i+1)); done; printf 'TAIL\\n'; read -r gate"
      ],
      environment: %{}
    }

    assert {:ok, job} = Command.start(command, invocation)
    assert :sys.get_state(server).active[job.port].timer == nil
    Process.sleep(100)
    assert {:ok, result} = Command.read(command, invocation, job, cursor: 0)
    assert result.status == :running
    text = IO.iodata_to_binary(result.output)
    assert byte_size(text) <= 64
    assert result.omitted_output_bytes > 0
    assert String.starts_with?(text, "HEAD")
    assert String.ends_with?(text, "TAIL\n")
    assert :ok = Command.cancel_confirmed(command, invocation, 1_500)
  end
end
