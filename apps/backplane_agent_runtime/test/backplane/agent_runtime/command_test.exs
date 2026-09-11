defmodule Backplane.AgentRuntime.CommandTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Command
  alias Backplane.AgentRuntime.Error

  defmodule FakeAdapter do
    @behaviour Backplane.AgentRuntime.Command

    @impl Backplane.AgentRuntime.Command
    def start(_command, invocation, _opts) do
      {:ok,
       %{
         job_id: "job_#{invocation.owner_run_id}",
         owner_run_id: invocation.owner_run_id,
         workspace: invocation.workspace,
         deadline_limit: invocation.deadline_limit,
         output_limit: invocation.output_limit,
         executable: invocation.executable,
         arguments: invocation.arguments,
         environment: invocation.environment
       }}
    end

    @impl Backplane.AgentRuntime.Command
    def cancel(_command, _invocation), do: :ok

    @impl Backplane.AgentRuntime.Command
    def read(_command, _invocation, _job, _opts), do: {:ok, %{}}
  end

  defmodule JobAdapter do
    @behaviour Backplane.AgentRuntime.Command

    @impl Backplane.AgentRuntime.Command
    def start(_command, request, _opts) do
      {:ok, %{owner_run_id: request.owner_run_id}}
    end

    @impl Backplane.AgentRuntime.Command
    def read(_command, _invocation, _job, opts), do: {:ok, %{cursor: opts[:cursor]}}

    @impl Backplane.AgentRuntime.Command
    def cancel(_command, _invocation), do: :ok
  end

  describe "authorized command execution" do
    test "starts a command with allowed environment and explicit arguments" do
      {:ok, command} =
        Command.new(%{adapter: FakeAdapter, allowed_environment: %{"WORKSPACE" => "/tmp"}})

      invocation = %{
        executable: "/bin/true",
        arguments: [],
        owner_run_id: "run_1",
        workspace: "/tmp/workspace",
        environment: %{"WORKSPACE" => "/tmp/safe"}
      }

      assert {:ok, job} = Command.start(command, invocation)

      assert job.owner_run_id == "run_1"
      assert job.workspace == "/tmp/workspace"
      assert job.deadline_limit == 300_000
      assert job.output_limit == 1_048_576

      assert {:ok, result} =
               Command.start(
                 command,
                 %{invocation | owner_run_id: "run_2", workspace: "/tmp/other"}
               )

      assert result.executable == "/bin/true"
      assert result.environment == %{"WORKSPACE" => "/tmp/safe"}
      assert Command.workspace_conflict?(%{workspace: "/tmp/workspace"}, invocation)
    end

    test "rejects cross-run job reads and cancellation" do
      {:ok, command} = Command.new(%{adapter: JobAdapter, allowed_environment: %{}})

      invocation = %{
        executable: "/bin/true",
        arguments: [],
        owner_run_id: "run_1",
        workspace: "/tmp"
      }

      assert {:ok, %{owner_run_id: "run_1"}} = Command.start(command, invocation)

      assert {:error, %Error{class: :forbidden}} =
               Command.read(command, invocation, %{owner_run_id: "run_2"}, cursor: 0)

      assert {:ok, %{cursor: 0}} =
               Command.read(command, invocation, %{owner_run_id: "run_1"}, cursor: 0)

      assert :ok = Command.cancel(command, invocation)
    end

    test "rejects shell strings, forbidden environment variables, and invalid arguments" do
      {:ok, command} =
        Command.new(%{adapter: FakeAdapter, allowed_environment: %{"WORKSPACE" => "/tmp"}})

      assert {:error, %Error{}} =
               Command.start(command, %{executable: "/bin/sh -c echo hi", arguments: []})

      assert {:error, %Error{}} =
               Command.start(command, %{
                 executable: "/bin/true",
                 arguments: [],
                 environment: %{"SECRET" => "value"}
               })

      assert {:error, %Error{}} =
               Command.start(command, %{executable: "/bin/true", arguments: "invalid"})
    end
  end
end
