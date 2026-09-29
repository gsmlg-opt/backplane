defmodule Backplane.AgentRuntime.CodexToolsTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Command, Error, Plan}
  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{ApplyPatch, ResourceRegistry}

  defmodule SessionCommand do
    def start(command, request, _opts) do
      Agent.update(command.server, fn _ -> %{output: [], status: :running} end)

      {:ok,
       %{
         id: 1,
         owner_run_id: request.owner_run_id,
         output: [],
         cursor: 0,
         status: :running,
         exit_status: nil
       }}
    end

    def read(command, _invocation, _job, opts) do
      cursor = Keyword.fetch!(opts, :cursor)

      Agent.get(command.server, fn state ->
        {:ok,
         %{
           output: Enum.drop(state.output, cursor),
           cursor: length(state.output),
           status: state.status,
           exit_status: if(state.status == :completed, do: 0, else: nil)
         }}
      end)
    end

    def write(command, _invocation, _job, chars) do
      Agent.update(command.server, fn state ->
        %{state | output: state.output ++ [chars], status: :completed}
      end)
    end

    def cancel(command, _invocation) do
      Agent.update(command.server, &Map.put(&1, :status, :cancelled))
    end
  end

  @tag :tmp_dir
  test "apply_patch performs add, update, move, delete and rejects symlink escape", %{
    tmp_dir: root
  } do
    patch = """
    *** Begin Patch
    *** Add File: note.txt
    +hello
    *** End Patch
    """

    assert {:ok, %{status: :applied}} = ApplyPatch.apply(root, patch)
    assert File.read!(Path.join(root, "note.txt")) == "hello\n"

    update = """
    *** Begin Patch
    *** Update File: note.txt
    -hello
    +hello world
    *** End Patch
    """

    assert {:ok, _} = ApplyPatch.apply(root, update)
    assert File.read!(Path.join(root, "note.txt")) == "hello world\n"

    update_move = """
    *** Begin Patch
    *** Update File: note.txt
    *** Move to: renamed.txt
    *** End Patch
    """

    assert {:ok, _} = ApplyPatch.apply(root, update_move)
    refute File.exists?(Path.join(root, "note.txt"))
    assert File.exists?(Path.join(root, "renamed.txt"))

    move = """
    *** Begin Patch
    *** Move to: moved.txt
    renamed.txt
    *** End Patch
    """

    assert {:ok, _} = ApplyPatch.apply(root, move)
    refute File.exists?(Path.join(root, "note.txt"))
    assert File.exists?(Path.join(root, "moved.txt"))

    delete = """
    *** Begin Patch
    *** Delete File: moved.txt
    *** End Patch
    """

    assert {:ok, _} = ApplyPatch.apply(root, delete)
    refute File.exists?(Path.join(root, "moved.txt"))

    outside = Path.join(Path.dirname(root), "codex-private-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(outside, Path.join(root, "link"))

    escaped = """
    *** Begin Patch
    *** Add File: link/secret.txt
    +bad
    *** End Patch
    """

    assert {:error, %Error{class: :forbidden}} = ApplyPatch.apply(root, escaped)
  end

  @tag :tmp_dir
  test "Codex local tools return bounded image content and hide plan CAS", %{tmp_dir: root} do
    image = Path.join(root, "pixel.png")
    File.write!(image, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    {:ok, plan} = Plan.start_link("run", %{"step" => "start"})
    context = %{workspace: root, plan: plan}

    assert {:ok, %{path: "pixel.png", mime_type: "image/png", data: data}} =
             Codex.call(context, "view_image", %{"path" => image})

    assert byte_size(data) == 8

    assert {:ok, %{revision: 2}} =
             Codex.call(context, "update_plan", %{
               "plan" => [%{"step" => "done", "status" => "completed"}]
             })

    assert {:ok,
            %{
              content: %{
                "plan" => [%{"step" => "done", "status" => "completed"}]
              },
              revision: 2
            }} = Plan.read(plan)

    assert {:ok, %{current_time: current_time}} = Codex.call(context, "clock::curr_time", %{})
    assert current_time =~ ~r/ UTC$/

    assert {:ok, %{wall_time_seconds: elapsed}} =
             Codex.call(context, "clock::sleep", %{"duration_ms" => 1})

    assert elapsed >= 0
  end

  test "write_stdin cannot cancel or read another run's command handle" do
    context = %{command: %{}, caller: %{run_id: "run_a"}}
    job = %{owner_run_id: "run_b"}

    assert {:error, %Error{class: :forbidden}} =
             Codex.call(context, "write_stdin", %{"job" => job, "cancel" => true})
  end

  @tag :tmp_dir
  test "pinned command sessions use numeric owner-bound ids and accept stdin", %{tmp_dir: root} do
    {:ok, server} = Agent.start_link(fn -> %{output: [], status: :running} end)
    {:ok, session_registry} = ResourceRegistry.start_link([])

    {:ok, command} =
      Command.new(%{
        adapter: SessionCommand,
        server: server,
        allowed_environment: %{},
        output_limit: 4_096,
        deadline_limit: 5_000
      })

    context = %{
      workspace: root,
      command: command,
      caller: %{run_id: "run-a"},
      session_registry: session_registry
    }

    assert {:ok, %{session_id: session_id, output: ""}} =
             Codex.call(context, "exec_command", %{
               "cmd" => "interactive",
               "yield_time_ms" => 0
             })

    assert is_integer(session_id)

    assert {:error, %Error{class: :forbidden}} =
             Codex.call(%{context | caller: %{run_id: "run-b"}}, "write_stdin", %{
               "session_id" => session_id
             })

    assert {:ok, %{output: "hello", exit_code: 0}} =
             Codex.call(context, "write_stdin", %{
               "session_id" => session_id,
               "chars" => "hello",
               "yield_time_ms" => 0
             })

    assert {:error, %Error{class: :not_found}} =
             Codex.call(context, "write_stdin", %{"session_id" => session_id})
  end

  @tag :tmp_dir
  test "command session is cancelled when its configured owner process dies", %{tmp_dir: root} do
    {:ok, server} = Agent.start_link(fn -> %{output: [], status: :running} end)
    {:ok, session_registry} = ResourceRegistry.start_link([])
    owner = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, command} =
      Command.new(%{
        adapter: SessionCommand,
        server: server,
        allowed_environment: %{},
        output_limit: 4_096,
        deadline_limit: 5_000
      })

    context = %{
      workspace: root,
      command: command,
      caller: %{run_id: "owner-run"},
      owner_pid: owner,
      session_registry: session_registry
    }

    assert {:ok, %{session_id: session_id}} =
             Codex.call(context, "exec_command", %{"cmd" => "interactive", "yield_time_ms" => 0})

    Process.exit(owner, :kill)

    assert_eventually(fn -> Agent.get(server, &(&1.status == :cancelled)) end)

    assert {:error, %Error{class: :not_found}} =
             ResourceRegistry.fetch_session(session_registry, session_id, "owner-run")
  end

  @tag :tmp_dir
  test "exec_command cannot select a workspace outside the host scope", %{tmp_dir: root} do
    context = %{workspace: root, command: %{}, caller: %{run_id: "run"}}

    assert {:error, %Error{class: :forbidden}} =
             Codex.call(context, "exec_command", %{
               "cmd" => "printf nope",
               "workdir" => Path.dirname(root)
             })
  end

  test "pinned local definitions match Codex public names and input kinds" do
    definitions = Codex.definitions()

    assert Enum.map(definitions, & &1.name) ==
             [
               "exec_command",
               "write_stdin",
               "apply_patch",
               "update_plan",
               "view_image",
               "clock::curr_time",
               "clock::sleep"
             ]

    by_name = Map.new(definitions, &{&1.name, &1})

    assert %{
             type: "function",
             parameters: %{
               "required" => ["cmd"],
               "properties" => %{
                 "cmd" => %{"type" => "string"},
                 "workdir" => %{"type" => "string"},
                 "tty" => %{"type" => "boolean"}
               }
             }
           } = by_name["exec_command"]

    assert %{
             type: "function",
             parameters: %{
               "required" => ["session_id"],
               "properties" => %{"chars" => %{"type" => "string"}}
             }
           } = by_name["write_stdin"]

    assert %{
             type: "custom",
             format: %{
               "type" => "grammar",
               "syntax" => "lark",
               "definition" => definition
             }
           } = by_name["apply_patch"]

    assert definition =~ ~s(start: begin_patch hunk+ end_patch)

    assert %{
             "required" => ["plan"],
             "properties" => %{"plan" => %{"type" => "array"}} = plan_properties
           } = by_name["update_plan"].parameters

    refute Map.has_key?(plan_properties, "revision")
    assert by_name["clock::curr_time"].parameters["properties"] == %{}
    assert by_name["clock::sleep"].parameters["required"] == ["duration_ms"]
  end

  test "malformed tool arguments are returned as structured validation errors" do
    assert {:error, %Error{class: :validation}} = Codex.call(%{}, "clock", :not_a_map)
    assert {:error, %Error{class: :unsupported_capability}} = Codex.call(%{}, "apply_patch", %{})
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
