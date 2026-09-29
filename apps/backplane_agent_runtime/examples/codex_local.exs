defmodule CodexLocalExample do
  alias Backplane.AgentRuntime.{Command, Conversation, EphemeralStore, Error, Plan}
  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Backplane.AgentRuntime.Tools.LocalCommand

  defmodule PortableCommand do
    use GenServer

    @behaviour Backplane.AgentRuntime.Command

    def start_link, do: GenServer.start_link(__MODULE__, %{})

    @impl Backplane.AgentRuntime.Command
    def start(command, request, _opts), do: GenServer.call(command.server, {:start, request})

    @impl Backplane.AgentRuntime.Command
    def read(command, _invocation, job, opts) do
      GenServer.call(command.server, {:read, job, Keyword.fetch!(opts, :cursor)})
    end

    @impl Backplane.AgentRuntime.Command
    def write(command, _invocation, job, chars) do
      GenServer.call(command.server, {:write, job, chars})
    end

    @impl Backplane.AgentRuntime.Command
    def cancel(command, invocation) do
      GenServer.call(command.server, {:cancel, invocation.owner_run_id})
    end

    @impl GenServer
    def init(state) do
      Process.flag(:trap_exit, true)
      {:ok, state}
    end

    @impl GenServer
    def handle_call({:start, request}, _from, state) do
      options = [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        :use_stdio,
        args: request.arguments,
        cd: request.workspace,
        env: Enum.map(request.environment, fn {key, value} -> {key, value} end)
      ]

      port = Port.open({:spawn_executable, request.executable}, options)

      current = %{
        owner_run_id: request.owner_run_id,
        output: [],
        bytes: 0,
        output_limit: request.output_limit,
        status: :running,
        exit_status: nil
      }

      {:reply, {:ok, %{port: port, owner_run_id: request.owner_run_id}},
       Map.put(state, port, current)}
    end

    def handle_call({:read, %{port: port}, cursor}, _from, state) do
      case Map.get(state, port) do
        nil ->
          {:reply, {:error, Error.new(:not_found, "portable command job not found")}, state}

        current ->
          {:reply,
           {:ok,
            %{
              output: Enum.drop(current.output, cursor),
              cursor: length(current.output),
              status: current.status,
              exit_status: current.exit_status,
              cleanup_status: :not_required,
              termination_status: :not_requested
            }}, state}
      end
    end

    def handle_call({:write, %{port: port}, chars}, _from, state) do
      case Map.get(state, port) do
        %{status: :running} ->
          if Port.command(port, chars),
            do: {:reply, :ok, state},
            else:
              {:reply,
               {:error, Error.new(:execution_failure, "portable command stdin write failed")},
               state}

        _ ->
          {:reply, {:error, Error.new(:not_found, "portable command is not running")}, state}
      end
    end

    def handle_call({:cancel, owner}, _from, state) do
      state =
        Map.new(state, fn {port, current} ->
          if current.owner_run_id == owner and current.status == :running do
            safe_close(port)
            {port, %{current | status: :cancelled}}
          else
            {port, current}
          end
        end)

      {:reply, :ok, state}
    end

    @impl GenServer
    def handle_info({port, {:data, data}}, state) do
      case Map.get(state, port) do
        nil ->
          {:noreply, state}

        current ->
          bytes = current.bytes + byte_size(data)

          if bytes <= current.output_limit do
            next = %{current | output: current.output ++ [data], bytes: bytes}
            {:noreply, Map.put(state, port, next)}
          else
            safe_close(port)
            next = %{current | status: :output_limit_exceeded, bytes: bytes}
            {:noreply, Map.put(state, port, next)}
          end
      end
    end

    def handle_info({port, {:exit_status, exit_status}}, state) do
      state =
        Map.update(state, port, nil, fn current ->
          status =
            if current.status == :running,
              do: if(exit_status == 0, do: :completed, else: :failed),
              else: current.status

          %{current | status: status, exit_status: exit_status}
        end)

      {:noreply, state}
    end

    def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}
    def handle_info(_message, state), do: {:noreply, state}

    @impl GenServer
    def terminate(_reason, state) do
      Enum.each(state, fn {port, current} ->
        if current.status == :running, do: safe_close(port)
      end)

      :ok
    end

    defp safe_close(port) do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end
  end

  defmodule ScriptedProvider do
    def stream(request, context) do
      request.messages
      |> events(context)
      |> Stream.map(& &1)
    end

    defp events(messages, context) do
      cond do
        is_nil(result_for(messages, "exec_command")) ->
          [
            tool_call("exec-1", "exec_command", %{
              "cmd" => "IFS= read -r line; printf '%s' \"$line\"",
              "login" => false,
              "workdir" => context.root,
              "yield_time_ms" => 10
            }),
            response("waiting for stdin")
          ]

        is_nil(result_for(messages, "write_stdin")) ->
          %{session_id: session_id} = result_for(messages, "exec_command")
          send(context.observer, {:codex_example_session, session_id})

          [
            tool_call("stdin-1", "write_stdin", %{
              "session_id" => session_id,
              "chars" => "hello\n",
              "yield_time_ms" => 5_000
            }),
            response("continuing command")
          ]

        is_nil(result_for(messages, "update_plan")) ->
          patch =
            "*** Begin Patch\n*** Add File: result.txt\n+from conversation\n*** End Patch\n"

          [
            tool_call("plan-1", "update_plan", %{
              "explanation" => "Exercise the public embedding path.",
              "plan" => [%{"step" => "example", "status" => "completed"}]
            }),
            tool_call("patch-1", "apply_patch", patch),
            tool_call("image-1", "view_image", %{
              "path" => Path.join(context.root, "pixel.png"),
              "detail" => "original"
            }),
            response("finishing local tools")
          ]

        true ->
          [response("all local tools completed")]
      end
    end

    defp result_for(messages, name) do
      Enum.find_value(messages, fn
        %{role: :tool, name: ^name, result: result} -> result
        _ -> nil
      end)
    end

    defp tool_call(id, name, arguments) do
      %{
        type: :tool_call_completed,
        tool_call: %{id: id, name: name, arguments: arguments}
      }
    end

    defp response(content),
      do: %{type: :response_completed, message: %{role: :assistant, content: content}}
  end

  def run do
    root =
      Path.join(
        System.tmp_dir!(),
        "backplane-codex-example-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "pixel.png"), <<137, 80, 78, 71, 13, 10, 26, 10>>)

    linux? = match?({:unix, :linux}, :os.type())
    command_adapter = if linux?, do: LocalCommand, else: PortableCommand

    {:ok, command_server} =
      if linux?, do: LocalCommand.start_link(name: nil), else: PortableCommand.start_link()

    {:ok, command} =
      Command.new(%{
        adapter: command_adapter,
        server: command_server,
        allowed_environment: %{},
        output_limit: 4_096,
        deadline_limit: 5_000
      })

    {:ok, plan} = Plan.start_link("example", %{"step" => "start"})
    {:ok, session_registry} = ResourceRegistry.start_link([])
    {:ok, store} = EphemeralStore.new(1)

    tools = [
      "exec_command",
      "write_stdin",
      "apply_patch",
      "update_plan",
      "view_image"
    ]

    context = %{
      workspace: root,
      plan: plan,
      command: command,
      caller: %{run_id: "codex-example"},
      session_registry: session_registry,
      owner_pid: self()
    }

    authority = %{
      caller: "example-host",
      run_id: "codex-example",
      grants: tools,
      tool_revisions: Map.new(tools, &{&1, 1})
    }

    try do
      {:ok, profile} = Codex.profile(:pinned_local, context, authority, tools: tools)

      {:ok, conversation} =
        Conversation.start_link(
          run_id: "codex-example",
          store: EphemeralStore,
          context: store,
          provider: ScriptedProvider,
          provider_context: %{root: root, observer: self()},
          subscriber: self(),
          registry: profile.registry,
          tools: profile.tools,
          authority: profile.authority,
          schema_admission: :strict,
          work: 20,
          run_timeout: 15_000
        )

      {:ok, _receipt} = Conversation.prompt(conversation, "exercise the local Codex tools")

      session_id =
        receive do
          {:codex_example_session, value} when is_integer(value) -> value
        after
          5_000 -> raise "exec_command did not return a resumable session"
        end

      receive do
        {:agent_runtime, "codex-example", %{type: :run_completed}} -> :ok
      after
        15_000 -> raise "Codex Conversation example did not complete"
      end

      status = Conversation.status(conversation)
      command_result = tool_result!(status.messages, "write_stdin")
      image_result = tool_result!(status.messages, "view_image")
      {:ok, plan_state} = Plan.read(plan)

      ensure!(command_result.output == "hello", "interactive command output was not preserved")
      ensure!(command_result.exit_code == 0, "interactive command did not exit successfully")

      ensure!(
        File.read!(Path.join(root, "result.txt")) == "from conversation\n",
        "apply_patch did not mutate the workspace"
      )

      ensure!(plan_state.revision == 2, "update_plan did not advance the host revision")
      ensure!(image_result.bytes == 8, "view_image did not return usable image bytes")
      ensure!(binary_part(image_result.data, 0, 4) == <<137, 80, 78, 71>>, "bad image data")

      ensure!(
        match?(
          {:error, %Error{class: :not_found}},
          ResourceRegistry.fetch_session(session_registry, session_id, "codex-example")
        ),
        "completed command session was not cleaned up"
      )

      :ok = Command.cancel(command, %{owner_run_id: "codex-example"})

      IO.puts("Codex Conversation example: PASS")
    after
      if Process.alive?(command_server), do: GenServer.stop(command_server)
      if Process.alive?(session_registry), do: GenServer.stop(session_registry)
      if Process.alive?(plan), do: GenServer.stop(plan)
      File.rm_rf!(root)
    end
  end

  defp tool_result!(messages, name) do
    case Enum.find(messages, &match?(%{role: :tool, name: ^name}, &1)) do
      %{result: %{is_error: false} = result} -> result
      other -> raise "missing successful #{name} result: #{inspect(other)}"
    end
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(message)
end

CodexLocalExample.run()
