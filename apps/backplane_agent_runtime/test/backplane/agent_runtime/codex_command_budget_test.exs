defmodule Backplane.AgentRuntime.CodexCommandBudgetTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Command}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir

  if match?({:unix, :linux}, :os.type()) and File.dir?("/proc/self") and
       is_binary(System.find_executable("coreutils")) do
    :ok
  else
    @moduletag skip: "real command regressions require Linux and coreutils"
  end

  setup %{tmp_dir: root} do
    server = start_supervised!({LocalCommand, name: nil})
    registry = start_supervised!(ResourceRegistry)

    {:ok, command} =
      Command.new(%{
        adapter: LocalCommand,
        server: server,
        allowed_environment: %{},
        output_limit: 65_536,
        deadline_limit: 5_000
      })

    %{
      context: %{
        workspace: root,
        command: command,
        caller: %{run_id: "budget-test"},
        owner_pid: self(),
        session_registry: registry
      }
    }
  end

  test "small response budget truncates output without killing a real command", %{
    context: context,
    tmp_dir: root
  } do
    assert {:ok, result} =
             Codex.call(context, "exec_command", %{
               "cmd" =>
                 "i=0; while [ $i -lt 100 ]; do printf 'abcdefghij\\n'; i=$((i+1)); done; read -r gate; printf done > completion",
               "login" => false,
               "yield_time_ms" => 50,
               "max_output_tokens" => 2
             })

    assert is_integer(result.session_id)
    assert byte_size(result.output) <= 8
    assert result.output_truncated
    assert result.omitted_output_bytes > 0
    assert result.output_budget_unit == :estimated_token_bytes
    assert result.status == :running

    assert {:ok, %{exit_code: 0}} =
             Codex.call(context, "write_stdin", %{
               "session_id" => result.session_id,
               "chars" => "continue\n",
               "yield_time_ms" => 2_000,
               "max_output_tokens" => 2
             })

    assert File.read(Path.join(root, "completion")) == {:ok, "done"}
  end

  test "successive stdin responses budget new output and intentionally advance cursor", %{
    context: context
  } do
    assert {:ok, %{session_id: id}} =
             Codex.call(context, "exec_command", %{
               "cmd" => "while IFS= read -r line; do printf '%s\\n' \"$line\"; done",
               "login" => false,
               "yield_time_ms" => 0,
               "max_output_tokens" => 1
             })

    for text <- ["abcdefghij", "klmnopqrst"] do
      assert {:ok, result} =
               Codex.call(context, "write_stdin", %{
                 "session_id" => id,
                 "chars" => text <> "\n",
                 "yield_time_ms" => 50,
                 "max_output_tokens" => 1
               })

      assert result.session_id == id
      assert result.output == binary_part(text, 0, 4)
      assert result.omitted_output_bytes == 6
      assert result.output_truncated
    end

    assert {:ok, %{output: ""}} =
             Codex.call(context, "write_stdin", %{
               "session_id" => id,
               "yield_time_ms" => 0,
               "max_output_tokens" => 1
             })
  end

  test "independent host hard cap terminates and reports cleanup evidence", %{context: context} do
    context = put_in(context.command.output_limit, 128)

    assert {:ok, result} =
             Codex.call(context, "exec_command", %{
               "cmd" => "while :; do printf 'abcdefghij\\n'; done",
               "login" => false,
               "yield_time_ms" => 2_000,
               "max_output_tokens" => 10_000
             })

    assert result.status == :output_limit_exceeded
    assert result.output_limit_exceeded?
    assert result.cleanup_status == :confirmed
    refute Map.has_key?(result, :session_id)
  end
end
