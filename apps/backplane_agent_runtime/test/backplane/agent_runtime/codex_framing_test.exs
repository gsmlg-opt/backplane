defmodule Backplane.AgentRuntime.CodexFramingTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}
  alias Backplane.AgentRuntime.Error

  @moduletag :tmp_dir
  @worker Path.expand("../../../priv/codex/code_mode_worker.js", __DIR__)
  @native_capability CodeMode.lifecycle_capability(%{})

  if match?({:unsupported, _reason}, @native_capability) do
    @moduletag skip: "native Code Mode lifecycle capability unavailable"
  end

  setup do
    deno = System.find_executable("deno")
    assert is_binary(deno), "Deno is required; framing tests must not be skipped"
    %{deno: deno}
  end

  test "record and multibyte UTF-8 splits are buffered deterministically", context do
    {output, status} =
      run_worker(context, """
      const bytes = new TextEncoder().encode(JSON.stringify({type:'execute',code:'return "你";'})+'\\n');
      const unicode = bytes.indexOf(0xe4);
      const chunks = [bytes.slice(0,5),bytes.slice(5,unicode+1),bytes.slice(unicode+1,unicode+2),bytes.slice(unicode+2)];
      """)

    assert status == 0, output
    assert output =~ ~s("type":"complete","value":"你")
    refute output =~ ~s("type":"error")
  end

  test "multiple complete records in one chunk settle a nested tool", context do
    {output, status} =
      run_worker(context, """
      const chunks = [new TextEncoder().encode(
        JSON.stringify({type:'execute',code:'return await codex.tool("echo", {});'})+'\\n'+
        JSON.stringify({type:'tool_result',id:'1',ok:true,value:42})+'\\n')];
      """)

    assert status == 0, output
    assert output =~ ~s("type":"complete","value":42)
  end

  test "large nested result fragments reach the waiting tool promise", context do
    {output, status} =
      run_worker(context, """
      const inputEncoder = new TextEncoder();
      const result = inputEncoder.encode(JSON.stringify({type:'tool_result',id:'1',ok:true,value:'界'.repeat(100000)})+'\\n');
      const chunks = [inputEncoder.encode(JSON.stringify({type:'execute',code:'return (await codex.tool("echo", {})).length;'})+'\\n')];
      for (let i=0;i<result.length;i+=997) chunks.push(result.slice(i,i+997));
      """)

    assert status == 0, output
    assert output =~ ~s("type":"complete","value":100000)
  end

  test "malformed, incomplete EOF and oversized records fail and terminate", context do
    for {input, error} <- [
          {"const chunks=[new TextEncoder().encode('{invalid}\\n')];", "malformed_result"},
          {"const chunks=[new TextEncoder().encode('{\"type\":')];", "malformed_result"},
          {"const chunks=[new Uint8Array(1048577).fill(32)];", "budget_exceeded"}
        ] do
      {output, status} = run_worker(context, input)
      assert status != 0
      assert output =~ error
    end
  end

  test "large permitted execution and nested result use the real CodeMode worker", %{deno: deno} do
    registry = start_supervised!(ResourceRegistry)

    code =
      "/*" <> String.duplicate("x", 100_000) <> "*/ return (await codex.tool('echo', {})).length;"

    opts = [deno_path: deno, dispatcher: fn _, _ -> {:ok, String.duplicate("界", 100_000)} end]

    assert {:ok, %{status: :completed, value: 100_000}} =
             CodeMode.execute(registry, "framing", code, opts)
  end

  test "oversized real nested result settles instead of hanging", %{deno: deno} do
    registry = start_supervised!(ResourceRegistry)

    opts = [
      deno_path: deno,
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
    [_, fields] = Regex.run(~r/^\d+ \(.*\) (.+)$/s, File.read!("/proc/#{pid}/stat"))
    identity = %{pid: pid, starttime: Enum.at(String.split(fields), 19)}

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

  defp run_worker(%{deno: deno, tmp_dir: dir}, input) do
    source = File.read!(@worker)

    injected = """
    #{input}
    const D = {stdout:Deno.stdout, exit:Deno.exit, stdin:{readable:new ReadableStream({start(c){for(const chunk of chunks)c.enqueue(chunk);c.close();}})}};
    """

    script = Path.join(dir, "framing.js")
    File.write!(script, String.replace(source, "const D = Deno;", injected))

    System.cmd("timeout", ["10", deno, "run", "--no-config", "--quiet", script],
      stderr_to_stdout: true
    )
  end
end
