defmodule BundledBasic do
  @moduledoc """
  Clean-consumer fixture proving bundled basic tools from the runtime artifact.
  """

  alias Backplane.AgentRuntime.Resource
  alias Backplane.AgentRuntime.Tools
  alias Backplane.AgentRuntime.Tools.LocalCommand
  alias Backplane.AgentRuntime.Tools.LocalResource

  defmodule PlanPort do
    def read(_caller), do: {:ok, %{content: %{steps: []}, revision: 1}}
    def update(_caller, revision, content), do: {:ok, %{content: content, revision: revision + 1}}
  end

  defmodule CommandPort do
    alias Backplane.AgentRuntime.Command
    alias Backplane.AgentRuntime.Tools.LocalCommand

    def start(invocation, opts) do
      {:ok, command} = Command.new(%{adapter: LocalCommand, allowed_environment: %{}})
      Command.start(command, invocation, opts)
    end

    def read(invocation, job, opts) do
      {:ok, command} = Command.new(%{adapter: LocalCommand, allowed_environment: %{}})
      Command.read(command, invocation, job, opts)
    end

    def cancel(invocation, _job) do
      {:ok, command} = Command.new(%{adapter: LocalCommand, allowed_environment: %{}})
      Command.cancel(command, invocation)
    end
  end

  def verify! do
    true = Code.ensure_loaded?(LocalResource)
    true = Code.ensure_loaded?(LocalCommand)
    {:ok, _pid} = LocalResource.start_link()
    {:ok, _pid} = LocalCommand.start_link()

    scope =
      Path.join(
        System.tmp_dir!(),
        "backplane-bundled-basic-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(scope)

    try do
      path = Path.join(scope, "sample.txt")
      File.write!(path, "bundled")
      {:ok, resource} = Resource.new(%{scope: scope, adapter: LocalResource})
      {:ok, %{content: "bundled", partial?: false}} = Resource.read(resource, %{path: path})

      {:ok, tools} = Tools.new(%{plan_port: PlanPort, command_port: CommandPort})
      [:exec, :plan] = Tools.available_tools(tools)
      {:ok, %{revision: 1}} = Tools.plan_read(tools, %{run_id: "run"})
      {:ok, %{revision: 2}} = Tools.plan_update(tools, %{run_id: "run"}, 1, %{steps: []})

      executable = System.find_executable("printf") || raise "printf is required"
      caller = %{run_id: "run"}

      invocation = %{
        executable: executable,
        arguments: ["%s", "actual-command"],
        environment: %{},
        owner_run_id: "run",
        workspace: scope
      }

      {:ok, job} = Tools.command_start(tools, caller, invocation)

      {:ok, %{output: ["actual-command"]}} =
        await_command_output(
          tools,
          caller,
          invocation,
          job,
          System.monotonic_time(:millisecond) + 1_000
        )

      :ok = Tools.command_cancel(tools, caller, invocation, job)
      :ok
    after
      File.rm_rf!(scope)
    end
  end

  defp await_command_output(tools, caller, invocation, job, deadline) do
    case Tools.command_read(tools, caller, invocation, job, cursor: 0) do
      {:ok, %{output: []}} = result ->
        if System.monotonic_time(:millisecond) >= deadline do
          result
        else
          Process.sleep(10)
          await_command_output(tools, caller, invocation, job, deadline)
        end

      result ->
        result
    end
  end
end
