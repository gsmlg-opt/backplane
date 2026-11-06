defmodule Backplane.AgentRuntime.CodexCommandInspectionTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Command, Error}
  alias Backplane.AgentRuntime.Codex.{Commands, ResourceRegistry}
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir

  defmodule Backend do
    def read(%{server: agent}, _invocation, _job, opts) do
      Agent.get(agent, fn result ->
        {:ok, %{result | output: Enum.drop(result.output, opts[:cursor])}}
      end)
    end
  end

  setup do
    registry = start_supervised!(ResourceRegistry)
    result = %{output: ["one", "two"], cursor: 2, status: :running, cleanup_status: :not_started}
    agent = start_supervised!({Agent, fn -> result end})
    command = %{adapter: Backend, server: agent}

    context = %{
      session_registry: registry,
      command: command,
      resource_owner: %{owner_id: "owner", incarnation: 2}
    }

    {:ok, id} =
      ResourceRegistry.register_session(
        registry,
        "owner",
        %{
          job: %{owner_run_id: "owner"},
          cursor: 1
        },
        incarnation: 2,
        command_metadata: %{command: "printf one; printf two", workspace: "/tmp", started_at: 10}
      )

    %{registry: registry, context: context, id: id, agent: agent}
  end

  test "live list and metadata hide backend handles and log reads do not consume poll", ctx do
    assert {:ok, [%{command_id: id, command: "printf one; printf two", status: :running} = item]} =
             Commands.list(ctx.context)

    assert id == ctx.id
    refute Map.has_key?(item, :job)
    refute Map.has_key?(item, :output)
    refute Map.has_key?(item, :owner_id)

    assert {:ok, %{output: "one", cursor: 3, total_bytes: 7, truncated: true}} =
             Commands.log(ctx.context, id, max_bytes: 3)

    assert {:ok, %{output: "one"}} = Commands.log(ctx.context, id, max_bytes: 3)
    assert {:ok, %{output: "one", cursor: 3}} = Commands.poll(ctx.context, id, max_bytes: 3)
    assert {:ok, %{output: "\ntwo", cursor: 7, truncated: false}} = Commands.poll(ctx.context, id)
    assert {:ok, %{output: "", cursor: 7}} = Commands.poll(ctx.context, id)
    assert {:ok, %{cursor: 1}} = ResourceRegistry.fetch_session(ctx.registry, id, "owner", 2)
  end

  test "final snapshot survives backend loss and old live session lookup stays retired", ctx do
    assert {:ok, %{output: "one", cursor: 3}} = Commands.poll(ctx.context, ctx.id, max_bytes: 3)
    archive(ctx.registry, ctx.id, "owner", 2, "one\ntwo")
    Agent.stop(ctx.agent)

    assert {:error, %Error{class: :not_found}} =
             ResourceRegistry.fetch_session(ctx.registry, ctx.id, "owner", 2)

    assert {:ok, %{output: "one\ntwo", finalized: true, status: :completed}} =
             Commands.log(ctx.context, ctx.id)

    assert {:ok, %{output: "\ntwo", cursor: 7}} = Commands.poll(ctx.context, ctx.id)
    assert {:ok, %{output: ""}} = Commands.poll(ctx.context, ctx.id)

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.session_cleanup_status(ctx.registry, ctx.id, "owner", 2)

    assert :ok = Commands.remove(ctx.context, ctx.id)
    assert {:error, %Error{class: :not_found}} = Commands.inspect(ctx.context, ctx.id)

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.session_cleanup_status(ctx.registry, ctx.id, "owner", 2)
  end

  test "identity and remove rules retain live cleanup obligations", ctx do
    other = put_in(ctx.context, [:resource_owner, :owner_id], "other")
    stale = put_in(ctx.context, [:resource_owner, :incarnation], 1)
    assert {:ok, []} = Commands.list(other)
    assert {:error, %Error{class: :forbidden}} = Commands.log(other, ctx.id)
    assert {:error, %Error{class: :resource_conflict}} = Commands.poll(stale, ctx.id)
    assert {:error, %Error{class: :resource_conflict}} = Commands.remove(ctx.context, ctx.id)
    assert {:ok, 0} = Commands.clear_finished(ctx.context)
    assert {:ok, _} = ResourceRegistry.fetch_session(ctx.registry, ctx.id, "owner", 2)
    archive(ctx.registry, ctx.id, "owner", 2, "done")
    assert {:error, %Error{class: :forbidden}} = Commands.remove(other, ctx.id)
    assert {:error, %Error{class: :resource_conflict}} = Commands.log(stale, ctx.id)
    assert {:ok, 1} = Commands.clear_finished(ctx.context)
  end

  test "count, byte and time bounds evict finalized records only", ctx do
    registry =
      start_supervised!(
        {ResourceRegistry,
         command_history_count: 1, command_history_bytes: 1024, command_history_ttl: 40},
        id: :bounded
      )

    context = %{ctx.context | session_registry: registry}
    first = register(registry)
    archive(registry, first, "owner", 2, "first")
    second = register(registry)
    archive(registry, second, "owner", 2, "second")
    assert {:error, %Error{class: :not_found}} = Commands.inspect(context, first)
    assert {:ok, %{output: "second"}} = Commands.log(context, second)
    huge = register(registry)
    archive(registry, huge, "owner", 2, String.duplicate("a", 2048))
    assert {:error, %Error{class: :not_found}} = Commands.inspect(context, huge)
    live = register(registry)
    Process.sleep(60)
    assert {:error, %Error{class: :not_found}} = Commands.inspect(context, second)
    assert {:ok, _} = ResourceRegistry.fetch_session(registry, live, "owner", 2)
  end

  test "read options and context are validated", ctx do
    for opts <- [[cursor: -1], [max_bytes: 0], [max_bytes: 1_048_577], [:invalid]] do
      assert {:error, %Error{class: :validation}} = Commands.log(ctx.context, ctx.id, opts)
    end

    assert {:error, %Error{class: :validation}} = Commands.list(%{})
    assert {:error, %Error{class: :validation}} = Commands.inspect(ctx.context, "bad")
  end

  test "real native terminal collection retains all output after incremental delivery", ctx do
    archive(ctx.registry, ctx.id, "owner", 2, "fixture")
    server = start_supervised!({LocalCommand, name: nil})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    context =
      %{ctx.context | command: command}
      |> Map.put(:workspace, ctx.tmp_dir)
      |> Map.put(:caller, %{run_id: "turn"})

    assert {:ok, %{command_id: id, session_id: id, output: output}} =
             Codex.call(context, "exec_command", %{
               "cmd" => "printf 'first\\n'; read answer; printf 'last:%s\\n' \"$answer\"",
               "login" => false,
               "yield_time_ms" => 100
             })

    assert output == "first"

    assert {:ok, %{command_id: ^id, output: "last:answer", status: :completed} = final} =
             Codex.call(context, "write_stdin", %{
               "session_id" => id,
               "chars" => "answer\n",
               "yield_time_ms" => 1000
             })

    refute Map.has_key?(final, :session_id)
    assert {:ok, %{output: "first\nlast:answer", finalized: true}} = Commands.log(context, id)
    assert {:ok, [_, %{command_id: ^id, status: :completed}]} = Commands.list(context)
  end

  test "inspection poll settles natural completion after the backend retention interval", ctx do
    archive(ctx.registry, ctx.id, "owner", 2, "fixture")
    server = start_supervised!({LocalCommand, name: nil, completion_retention: 20})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    context =
      %{ctx.context | command: command}
      |> Map.put(:workspace, ctx.tmp_dir)
      |> Map.put(:caller, %{run_id: "turn"})

    assert {:ok, %{command_id: id, status: :running}} =
             Codex.call(context, "exec_command", %{
               "cmd" => "sleep 0.05; printf 'retained'",
               "login" => false,
               "yield_time_ms" => 0
             })

    eventually(fn ->
      match?(
        {:ok, %{status: :completed, cleanup_status: :confirmed}},
        Commands.inspect(context, id)
      )
    end)

    assert {:ok, %{finished_at: finished_at}} = Commands.inspect(context, id)
    assert is_integer(finished_at)
    Process.sleep(60)

    assert {:ok, [_, %{command_id: ^id, status: :completed, finalized: false}]} =
             Commands.list(context)

    assert {:ok, %{output: "retained", finalized: false}} = Commands.log(context, id)

    assert {:ok, %{output: "retained", finalized: true, finished_at: ^finished_at}} =
             Commands.poll(context, id)

    assert {:ok, %{output: ""}} = Commands.poll(context, id)
    Process.sleep(60)
    assert {:ok, %{output: "retained"}} = Commands.log(context, id)
  end

  test "archive is readable before backend release acknowledgement completes", ctx do
    test = self()
    context = ctx.context

    {:ok, id} =
      ResourceRegistry.register_session(ctx.registry, "owner", %{job: nil, cursor: 0},
        incarnation: 2,
        command_metadata: %{command: "test", workspace: "/tmp", started_at: 1},
        acknowledge: fn handle ->
          send(test, {:archive_during_ack, Commands.log(context, handle.session_id)})
          :ok
        end
      )

    archive(ctx.registry, id, "owner", 2, "before-ack")
    assert_receive {:archive_during_ack, {:ok, %{output: "before-ack"}}}
  end

  test "a stale concurrent snapshot cannot rewind the inspection poll cursor", ctx do
    assert {:ok, %{cursor: 7}} = Commands.poll(ctx.context, ctx.id)

    assert {:ok, %{cursor: 7, output: ""}} =
             ResourceRegistry.command_output(
               ctx.registry,
               ctx.id,
               "owner",
               2,
               %{output: "one"},
               poll: true,
               cursor: 0,
               max_bytes: 10
             )

    assert {:ok, %{cursor: 7, output: ""}} = Commands.poll(ctx.context, ctx.id)
  end

  test "uncertain terminal inspection cannot erase cleanup obligations", ctx do
    Agent.update(ctx.agent, &%{&1 | status: :failed, cleanup_status: :uncertain})

    assert {:ok, %{cleanup_status: :uncertain, finalized: false}} =
             Commands.poll(ctx.context, ctx.id)

    assert {:error, %Error{class: :resource_conflict}} = Commands.remove(ctx.context, ctx.id)

    assert {:error, %Error{class: :resource_conflict}} =
             ResourceRegistry.archive_command(
               ctx.registry,
               ctx.id,
               "owner",
               2,
               %{output: "partial", status: :failed, cleanup_status: :uncertain}
             )

    assert {:ok, _} = ResourceRegistry.fetch_session(ctx.registry, ctx.id, "owner", 2)
  end

  test "byte cursors preserve multibyte data without silently losing a fragment", ctx do
    archive(ctx.registry, ctx.id, "owner", 2, "éX")
    assert {:ok, %{output: first, cursor: 1}} = Commands.log(ctx.context, ctx.id, max_bytes: 1)
    assert {:ok, %{output: rest, cursor: 3}} = Commands.log(ctx.context, ctx.id, cursor: 1)
    assert first <> rest == "éX"
  end

  test "registry rejects timer values that the VM cannot schedule" do
    Process.flag(:trap_exit, true)

    assert {:error, %Error{class: :validation}} =
             ResourceRegistry.start_link(command_history_ttl: 4_294_967_296)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp register(registry) do
    {:ok, id} =
      ResourceRegistry.register_session(registry, "owner", %{job: nil, cursor: 0},
        incarnation: 2,
        command_metadata: %{command: "test", workspace: "/tmp", started_at: 1}
      )

    id
  end

  defp archive(registry, id, owner, incarnation, output) do
    assert :ok =
             ResourceRegistry.archive_command(registry, id, owner, incarnation, %{
               output: output,
               status: :completed,
               cleanup_status: :confirmed
             })
  end
end
