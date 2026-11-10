defmodule Backplane.HostAgent.Memory.HookClientTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @script Path.expand(
            "../../../../../../integrations/memory/shared/bin/backplane-memory-hook",
            __DIR__
          )

  defmodule RecorderPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {test_pid, delay} = :persistent_term.get({__MODULE__, :config})
      {:ok, body} = read_all(conn, "")

      send(
        test_pid,
        {:request, conn.method, conn.request_path, get_req_header(conn, "content-type"), body}
      )

      if delay > 0, do: Process.sleep(delay)
      send_resp(conn, 202, "{}")
    end

    defp read_all(conn, acc) do
      case read_body(conn, length: 1_000_000) do
        {:ok, chunk, _conn} -> {:ok, acc <> chunk}
        {:more, chunk, conn} -> read_all(conn, acc <> chunk)
      end
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start_server(delay \\ 0) do
    :persistent_term.put({RecorderPlug, :config}, {self(), delay})
    on_exit(fn -> :persistent_term.erase({RecorderPlug, :config}) end)
    port = free_port()

    start_supervised!(
      Gaoxy.HTTP.child_spec(plug: {RecorderPlug, []}, ip: {127, 0, 0, 1}, port: port)
    )

    "http://127.0.0.1:#{port}"
  end

  # Runs the script with stdin fed from a file; returns {output, status, millis}.
  defp run(dir, args, stdin, base) do
    input = Path.join(dir, "stdin-#{System.unique_integer([:positive])}")
    File.write!(input, stdin)
    env = if base, do: [{"BACKPLANE_HOST_AGENT_URL", base}], else: []

    {micros, {out, status}} =
      :timer.tc(fn ->
        System.cmd("sh", ["-c", ~s(sh "$SCRIPT" "$@" < "$INPUT"), "sh" | args],
          env: [{"SCRIPT", @script}, {"INPUT", input} | env],
          stderr_to_stdout: true
        )
      end)

    {out, status, div(micros, 1000)}
  end

  test "posts the body byte-for-byte with json content type", %{tmp_dir: dir} do
    base = start_server()
    payload = ~s({"a":"b"}\n)

    assert {"", 0, _} = run(dir, ["claude_code", "PostToolUse"], payload, base)

    assert_receive {:request, "POST", "/capture/v1/hooks/claude_code/PostToolUse", ct, ^payload},
                   2_000

    assert ct == ["application/json"]
  end

  test "forwards a 300 KB payload with shell metacharacters intact", %{tmp_dir: dir} do
    base = start_server()

    chunk =
      ~S|"quoted" 'single' $(touch /nonexistent/pwn) `id` $HOME \ ; | <> "line\nbreak\n é日本 "

    payload = String.duplicate(chunk, div(300_000, byte_size(chunk)) + 1)

    assert {"", 0, _} = run(dir, ["claude_code", "PostToolUse"], payload, base)
    assert_receive {:request, "POST", _, _, body}, 5_000
    assert byte_size(body) > 300_000
    assert body == payload
  end

  test "closed port exits 0 quickly with empty stdout", %{tmp_dir: dir} do
    base = "http://127.0.0.1:#{free_port()}"
    assert {"", 0, ms} = run(dir, ["claude_code", "Stop"], "{}", base)
    assert ms < 3_000
  end

  test "slow server exits 0 within the bound with empty stdout", %{tmp_dir: dir} do
    base = start_server(10_000)
    assert {"", 0, ms} = run(dir, ["claude_code", "Stop"], "{}", base)
    assert ms < 4_000
  end

  test "cursor beforeSubmitPrompt prints continue response, even when unreachable", %{
    tmp_dir: dir
  } do
    base = start_server()

    assert {~s({"continue":true}) <> _ = out, 0, _} =
             run(dir, ["cursor", "beforeSubmitPrompt"], "{}", base)

    assert String.trim(out) == ~s({"continue":true})

    assert_receive {:request, "POST", "/capture/v1/hooks/cursor/beforeSubmitPrompt", _, "{}"},
                   2_000

    dead = "http://127.0.0.1:#{free_port()}"
    {out, 0, _} = run(dir, ["cursor", "beforeSubmitPrompt"], "{}", dead)
    assert String.trim(out) == ~s({"continue":true})
  end

  test "other cursor hooks print nothing", %{tmp_dir: dir} do
    base = start_server()
    assert {"", 0, _} = run(dir, ["cursor", "stop"], "{}", base)
    assert_receive {:request, "POST", "/capture/v1/hooks/cursor/stop", _, _}, 2_000
  end

  test "missing args exit 0 without a request", %{tmp_dir: dir} do
    base = start_server()
    assert {"", 0, _} = run(dir, [], "{}", base)
    assert {"", 0, _} = run(dir, ["claude_code"], "{}", base)
    refute_receive {:request, _, _, _, _}, 300
  end

  test "curl absent exits 0", %{tmp_dir: dir} do
    input = Path.join(dir, "in")
    File.write!(input, "{}")
    empty = Path.join(dir, "emptybin")
    File.mkdir_p!(empty)
    sh = System.find_executable("sh")

    {out, status} =
      System.cmd(sh, ["-c", ~s(PATH="$EMPTY" "$SH" "$SCRIPT" claude_code Stop < "$INPUT")],
        env: [{"EMPTY", empty}, {"SH", sh}, {"SCRIPT", @script}, {"INPUT", input}],
        stderr_to_stdout: true
      )

    assert {out, status} == {"", 0}
  end
end
