defmodule Backplane.AgentRuntime.CodexEnvironmentFailureTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, Execution}
  alias Backplane.AgentRuntime.Codex.{CodeMode, Control, Session}

  @moduletag capture_log: true

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  for path <- [:direct, :nested] do
    test "#{path} startup failure preserves native result, journal and next-tool continuation" do
      exercise(unquote(path))
    end
  end

  defp exercise(path) do
    test = self()
    run = "environment-failure-#{path}"
    id = "actual-failed-command-startup-#{path}"
    assert {:error, %Error{} = actual} = Execution.validate_limits(cleanup_timeout: 0)

    environment = %{
      environment_id: id,
      status: "failed",
      ready: false,
      authorized: true,
      error: actual
    }

    context = %{
      environment_provider: fn requested ->
        send(test, {:environment_checked, requested})
        environment
      end,
      environment_wait_timeout: 0,
      context_remaining: fn ->
        send(test, :continued)
        123
      end
    }

    names =
      if path == :direct,
        do: ~w(wait_for_environment get_context_remaining),
        else: ~w(wait_for_environment get_context_remaining exec wait)

    authority = %{caller: "host", run_id: run, grants: names, tool_revision: 1}

    {profile, binding, session} =
      if path == :direct do
        {:ok, profile} = Codex.profile(:interactive, context, authority, tools: names)
        {profile, nil, nil}
      else
        assert is_binary(System.find_executable("deno")), "requires real Deno"
        assert CodeMode.lifecycle_capability(%{}) == :verified
        session = start_supervised!({Session, owner_pid: self()})
        {:ok, binding} = Session.bind(session, authority)

        context =
          Map.merge(context, %{
            session_binding: binding,
            resource_registry: binding.resource_registry,
            session_registry: binding.resource_registry,
            code_mode_contracts: Control.contracts(context)
          })

        {:ok, profile} = Codex.profile(:mixed, context, authority, tools: names)
        {profile, binding, session}
      end

    {:ok, store} = EphemeralStore.new(1)

    options = [
      run_id: run,
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: self()},
      subscriber: self(),
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      schema_admission: :strict,
      run_timeout: 15_000,
      effect_timeout: 5_000
    ]

    options = if binding, do: Keyword.put(options, :session_binding, binding), else: options
    conversation = start_supervised!({Conversation, options})

    assert {:ok, _} = Conversation.prompt(conversation, "observe startup and continue")
    assert_receive {:provider, _, provider}, 3_000

    provider =
      if path == :direct do
        call(provider, "failure", "wait_for_environment", %{"environment_id" => id})
        assert_receive {:provider, %{messages: messages}, next_provider}, 3_000
        result = List.last(messages).result
        assert %{is_error: true, error: error} = result
        assert_error(error, id, actual.message)
        assert {:ok, before} = EphemeralStore.load(store, run)
        assert Enum.any?(before.run.tool_results, fn {_key, value} -> value == result end)
        call(next_provider, "next", "get_context_remaining", %{})
        assert_receive {:provider, %{messages: messages}, final_provider}, 3_000
        assert List.last(messages).result == %{tokens_left: 123, is_error: false}
        final_provider
      else
        code = """
        const failed = await tools.wait_for_environment({environment_id: '#{id}'});
        if (!failed.is_error || failed.error.class !== 'execution_failure') throw new Error('missing structured error');
        if (failed.error.details.environment_id !== '#{id}') throw new Error('lost environment identity');
        const next = await tools.get_context_remaining({});
        return {failed, next};
        """

        call(provider, "nested", "exec", code)
        assert_receive {:provider, %{messages: messages}, final_provider}, 5_000
        assert %{status: :completed, is_error: false, value: value} = List.last(messages).result
        assert value["failed"]["is_error"] == true
        assert_error(value["failed"]["error"], id, actual.message)
        assert value["next"] == %{"tokens_left" => 123}
        final_provider
      end

    assert_receive {:environment_checked, ^id}
    assert_receive :continued
    refute_receive {:environment_checked, _}, 50
    refute_receive :continued, 50

    {:ok, settled} = EphemeralStore.load(store, run)

    assert [{error_id, %{is_error: true, error: error} = native_error}] =
             Enum.filter(settled.run.tool_results, fn {_key, value} ->
               match?(%{is_error: true, error: %{"class" => "execution_failure"}}, value)
             end)

    assert_error(error, id, actual.message)
    assert is_binary(Jason.encode!(native_error))
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, ^run, %{type: :run_completed}}, 5_000
    {:ok, after_run} = EphemeralStore.load(store, run)
    assert after_run.run.state == :completed
    assert after_run.run.tool_results[error_id] == native_error
    assert after_run.run.tool_results == settled.run.tool_results
    if session, do: assert({:ok, %{status: :confirmed}} = Session.close(session))
  end

  defp assert_error(error, id, reason) do
    assert error == %{
             "class" => "execution_failure",
             "message" => "Environment `#{id}` failed to start: #{reason}",
             "details" => %{
               "environment_id" => id,
               "status" => "failed",
               "startup_class" => "validation",
               "reason_truncated" => false
             }
           }
  end

  defp call(provider, id, name, arguments) do
    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}},
         done()
       ]}
    )
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end
