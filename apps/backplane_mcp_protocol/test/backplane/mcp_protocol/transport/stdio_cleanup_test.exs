defmodule Backplane.McpProtocol.Transport.STDIOVerifiedTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Transport.STDIO

  test "missing guardian fails before launching target" do
    marker = Path.join(System.tmp_dir!(), "mcp-target-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(marker) end)

    assert {:error, _} =
             STDIO.start_link(
               name: nil,
               client: self(),
               command: "sh",
               args: ["-c", "touch \"$1\"", "fixture", marker],
               cleanup: :verified,
               guardian_path: marker <> "-missing"
             )

    refute File.exists?(marker)
  end

  @fixture Path.expand("../../../fixtures/stdio_verified_target.py", __DIR__)

  test "verified JSON-RPC preserves bytes, arguments, environment and cwd; EOF reaps the direct child" do
    transport =
      start_guard("echo",
        args: ["space argument", "--flag"],
        env: %{"MCP_FIXTURE_VALUE" => "expected"},
        cwd: System.tmp_dir!()
      )

    request = JSON.encode!(%{"jsonrpc" => "2.0", "id" => "wire", "method" => "fixture"}) <> "\n"
    assert :ok = STDIO.send_message(transport, request, timeout: 1_000)
    assert_receive {:"$gen_cast", {:response, data}}, 2_000

    assert %{"id" => "wire", "result" => %{"argv" => ["space argument", "--flag"], "value" => "expected", "cwd" => cwd}} =
             JSON.decode!(data)

    assert cwd == System.tmp_dir!()
    assert {:ok, report} = STDIO.close(transport, timeout: 1_000, activation_id: "json-rpc", close_id: "once")
    assert report.outcome == :confirmed
    assert report.close_id == "once"
    assert report.activation_id == "fixture"
    assert resource(report, :direct_child).evidence.target_status == %{kind: :exit, code: 0}
    assert resource(report, :guardian).evidence.exit_status == 0
    assert resource(report, :local_pipes).evidence.closed
    assert {:ok, ^report} = STDIO.cleanup_status(transport)
    assert {:ok, ^report} = STDIO.close(transport, timeout: 100)
    assert {:error, :closing} = STDIO.send_message(transport, request, [])
    assert Process.alive?(transport)
  end

  test "close options cannot relabel construction activation or resource identities" do
    transport = start_guard("echo")
    assert {:ok, before} = STDIO.cleanup_status(transport)
    assert before.activation_id == "fixture"
    assert {:ok, report} = STDIO.close(transport, timeout: 1_000, activation_id: "another-generation")
    assert report.activation_id == before.activation_id
    assert Enum.all?(report.resources, fn resource -> elem(resource.id, 0) == before.activation_id end)
    assert {:ok, ^report} = STDIO.close(transport, timeout: 100, activation_id: "third-generation")
  end

  for {mode, escalated} <- [{"term", :term_sent}, {"kill", :kill_sent}] do
    test "verified close escalates #{mode} within the original budget" do
      transport = start_guard(unquote(mode))
      assert_receive {:"$gen_cast", {:response, "ready\n"}}, 2_000
      assert {:ok, report} = STDIO.close(transport, timeout: 1_000)
      assert report.outcome == :confirmed
      assert resource(report, :direct_child).evidence.reaped
      receipt = :sys.get_state(transport).guard_receipt
      assert Map.fetch!(receipt, unquote(escalated))
    end
  end

  test "nonzero target exit can still have confirmed local resource cleanup" do
    transport = start_guard("nonzero")
    assert_receive {:"$gen_cast", {:response, "ready\n"}}, 2_000
    await_target_exit(transport)
    assert {:ok, report} = STDIO.close(transport, timeout: 1_000)
    assert report.outcome == :confirmed
    assert resource(report, :direct_child).evidence.target_status == %{kind: :exit, code: 23}
  end

  test "a descendant holding stdout does not extend the direct child close budget" do
    transport = start_guard("descendant")
    assert_receive {:"$gen_cast", {:response, "ready\n"}}, 2_000
    await_target_exit(transport)
    assert {:ok, %{outcome: :confirmed}} = STDIO.close(transport, timeout: 500)
  end

  test "cleanup status stays responsive during TERM and KILL waits" do
    transport = start_guard("kill")
    assert_receive {:"$gen_cast", {:response, "ready\n"}}, 2_000
    closer = Task.async(fn -> STDIO.close(transport, timeout: 1_000) end)
    await_closing(transport)
    assert {:ok, %{phase: :closing, outcome: :pending}} = STDIO.cleanup_status(transport)
    assert {:ok, %{outcome: :confirmed}} = Task.await(closer, 2_000)
  end

  test "a saturated target output still allows close" do
    transport = start_guard("output")
    assert_receive {:"$gen_cast", {:response, _}}, 2_000
    assert {:ok, %{outcome: :confirmed}} = STDIO.close(transport, timeout: 1_000)
  end

  test "helper loss never becomes confirmed and does not relaunch the target" do
    transport = start_guard("echo")
    state = :sys.get_state(transport)
    assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(state.guard_pid)])
    assert {:ok, report} = STDIO.close(transport, timeout: 200)
    assert report.outcome == :unconfirmed
    refute resource(report, :direct_child).outcome == :confirmed
    assert {:ok, ^report} = STDIO.close(transport, timeout: 100)
    assert :sys.get_state(transport).target_pid == state.target_pid
    assert :sys.get_state(transport).guard_pid == state.guard_pid
  end

  test "repeated closure leaves the actual target launch count unchanged" do
    log = Path.join(System.tmp_dir!(), "mcp-stdio-launch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(log) end)
    transport = start_guard("echo", env: %{"MCP_LAUNCH_LOG" => log})
    assert :ok = STDIO.send_message(transport, ~s({"id":1}\n), [])
    assert_receive {:"$gen_cast", {:response, _}}, 1_000
    assert {:ok, %{outcome: :confirmed} = report} = STDIO.close(transport, timeout: 500)
    assert {:ok, ^report} = STDIO.close(transport, timeout: 500)
    assert [_one] = log |> File.read!() |> String.split("\n", trim: true)
  end

  test "ordinary direct mode close reports uncertainty instead of inventing waitpid proof" do
    {:ok, transport} = STDIO.start_link(name: nil, client: self(), command: "cat")
    on_exit(fn -> stop_transport(transport) end)
    assert_receive {:"$gen_cast", :negotiate}, 1_000
    assert {:ok, %{outcome: :unconfirmed}} = STDIO.close(transport, timeout: 500)
    assert Process.alive?(transport)
  end

  for mode <- ["missing", "wrong_nonce", "nonzero_helper", "deadline"] do
    test "#{mode} helper evidence cannot produce confirmed cleanup" do
      helper = Path.expand("../../../fixtures/stdio_guardian_fault.py", __DIR__)

      {:ok, transport} =
        STDIO.start_link(
          name: nil,
          client: self(),
          command: "cat",
          cleanup: :verified,
          guardian_path: helper,
          env: %{"MCP_GUARD_FAULT" => unquote(mode)}
        )

      on_exit(fn -> stop_transport(transport) end)
      assert_receive {:"$gen_cast", :negotiate}, 1_000
      assert {:ok, report} = STDIO.close(transport, timeout: 100)
      assert report.outcome == :unconfirmed

      if unquote(mode) == "nonzero_helper" do
        assert resource(report, :direct_child).outcome == :confirmed
        assert resource(report, :guardian).evidence.exit_status == 7
      end

      assert {:ok, ^report} = STDIO.cleanup_status(transport)
      Process.sleep(20)
      assert {:ok, ^report} = STDIO.close(transport, timeout: 100)
    end
  end

  test "a tiny budget retains the actual observed evidence after late port messages" do
    transport = start_guard("kill")
    assert_receive {:"$gen_cast", {:response, "ready\n"}}, 2_000
    assert {:ok, report} = STDIO.close(transport, timeout: 1)

    if report.outcome == :confirmed do
      assert resource(report, :direct_child).evidence.reaped
      assert resource(report, :local_pipes).evidence.closed
      assert resource(report, :guardian).evidence.exit_status == 0
    else
      assert report.outcome == :unconfirmed
    end

    Process.sleep(50)
    assert {:ok, ^report} = STDIO.cleanup_status(transport)
  end

  defp start_guard(mode, opts \\ []) do
    args = [@fixture, mode | Keyword.get(opts, :args, [])]
    opts = Keyword.delete(opts, :args)

    {:ok, transport} =
      STDIO.start_link(
        [
          name: nil,
          client: self(),
          command: System.find_executable("python3"),
          args: args,
          cleanup: :verified,
          activation_id: "fixture"
        ] ++ opts
      )

    on_exit(fn -> stop_transport(transport) end)
    assert_receive {:"$gen_cast", :negotiate}, 2_000
    transport
  end

  defp stop_transport(pid) do
    if Process.alive?(pid) do
      STDIO.close(pid, timeout: 1_000)
      GenServer.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  defp resource(report, scope), do: Enum.find(report.resources, &(&1.scope == scope))
  defp await_target_exit(pid, attempts \\ 100)
  defp await_target_exit(_pid, 0), do: flunk("target exit not observed")

  defp await_target_exit(pid, attempts) do
    if :sys.get_state(pid).target_status,
      do: :ok,
      else:
        (
          Process.sleep(5)
          await_target_exit(pid, attempts - 1)
        )
  end

  defp await_closing(pid, attempts \\ 100)
  defp await_closing(_pid, 0), do: flunk("close not started")

  defp await_closing(pid, attempts) do
    case STDIO.cleanup_status(pid) do
      {:ok, %{phase: :closing}} ->
        :ok

      _ ->
        Process.sleep(1)
        await_closing(pid, attempts - 1)
    end
  end
end
