# Run producer and consumer in separate, sequential BEAM processes. The fixture
# persists trusted local test data, not executable adapters or Dynamic receipts.
defmodule Backplane.AgentRuntime.PluginCompletionColdBeamFixture do
  import ExUnit.Assertions
  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore}
  alias Backplane.AgentRuntime.Codex.{DynamicRuntime, Session}

  defmodule Host do
    def request_install(arguments, operation) do
      context = operation.backend_context
      File.write!(Path.join(context.dir, "#{context.mode}-installer"), "x", [:append])
      send(context.test, {:installed, operation})

      {:ok,
       {:completed,
        %{
          completed: true,
          user_confirmed: false,
          tool_type: arguments["tool_type"],
          action_type: arguments["action_type"],
          tool_id: arguments["tool_id"],
          tool_name: "Cold plugin"
        }}}
    end
  end

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do: ({:events, events} -> {events, state})
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule JournalStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      case EphemeralStore.store(context.table, run, meta) do
        {:ok, _} = result ->
          Agent.update(context.journal, &(&1 ++ [meta.command]))
          result

        error ->
          error
      end
    end
  end

  def run(mode, dir) do
    File.mkdir_p!(dir)
    {:ok, runtime} = DynamicRuntime.start_link(plugin_adapter: Host)
    {:ok, session} = Session.start_link(owner_pid: self())
    run_id = "cold-settled-plugin"

    authority = %{
      caller: "host",
      run_id: run_id,
      grants: ["request_plugin_install"],
      tool_revision: 1
    }

    {:ok, binding} = Session.bind(session, authority, incarnation: 23)

    contract =
      Enum.find(
        DynamicRuntime.contracts(%{dynamic_runtime: runtime}),
        &(&1.name == "request_plugin_install")
      )

    contract = %{
      contract
      | backend_context:
          Map.merge(contract.backend_context, %{test: self(), dir: dir, mode: mode})
    }

    {:ok, profile} =
      Codex.profile(
        :mixed,
        %{session_binding: binding, code_mode_contracts: [contract]},
        authority,
        tools: ["request_plugin_install"]
      )

    {:ok, table} = EphemeralStore.new(23)
    {:ok, journal} = Agent.start_link(fn -> [] end)

    opts = [
      run_id: run_id,
      incarnation: 23,
      store: JournalStore,
      context: %{table: table, journal: journal},
      provider: Provider,
      provider_context: %{test: self()},
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      schema_admission: :strict,
      run_timeout: 10_000
    ]

    case mode do
      "producer" -> producer(dir, opts, binding, table, journal)
      "consumer" -> consumer(dir, opts, table, journal)
    end
  end

  defp producer(dir, opts, binding, table, journal) do
    {:ok, conversation} = Conversation.start_link(Keyword.put(opts, :session_binding, binding))
    assert {:ok, _} = Conversation.prompt(conversation, "install the plugin")
    assert_receive {:provider, _, provider}, 2_000

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: "cold-install",
             name: "request_plugin_install",
             arguments: %{
               "tool_type" => "plugin",
               "action_type" => "install",
               "tool_id" => "cold",
               "suggest_reason" => "fixture"
             }
           }
         },
         done()
       ]}
    )

    assert_receive {:installed, operation}, 2_000
    assert operation.run_id == "cold-settled-plugin"
    assert operation.incarnation == 23
    assert operation.backend_context.resource_owner.owner_id == binding.owner_id
    assert_receive {:provider, %{messages: next_messages}, provider}, 2_000

    result = %{
      request_id: operation.plugin_request_id,
      is_error: false,
      status: :completed,
      completed: true,
      user_confirmed: false,
      tool_type: "plugin",
      action_type: "install",
      tool_id: "cold",
      tool_name: "Cold plugin"
    }

    assert Enum.any?(next_messages, &match?(%{role: :tool, result: ^result}, &1))
    send(provider, {:events, [done()]})
    assert eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    {:ok, %{run: run} = record} = EphemeralStore.load(table, "cold-settled-plugin")
    commands = Agent.get(journal, & &1)
    assert run.state == :completed
    assert run.tool_results[operation.invocation_id] == result
    assert run.execution_intents["tool:#{operation.invocation_id}"].status == :consumed

    assert Enum.any?(commands, fn
             {:tool_completed, _, %{invocation_id: id, result: value}} ->
               id == operation.invocation_id and value == result

             _ ->
               false
           end)

    data = %{
      record: record,
      commands: commands,
      result: result,
      invocation_id: operation.invocation_id,
      next_messages: next_messages,
      producer_os_pid: System.pid()
    }

    # Runtime :run restores committed records for inspection without re-admission.
    # A binary fixture preserves exact atom keys and historical values.
    File.write!(Path.join(dir, "settled.etf"), :erlang.term_to_binary(data))
    assert File.read!(Path.join(dir, "producer-installer")) == "x"
    GenServer.stop(conversation)
    assert {:ok, %{status: :confirmed}} = Session.close(binding.session)

    IO.puts(
      JSON.encode!(%{
        producer_os_pid: System.pid(),
        request_id: result.request_id,
        journal_commands: length(commands),
        installer_calls: 1
      })
    )
  end

  defp consumer(dir, opts, table, journal) do
    # This is a fixture-owned local file from the completed producer process.
    data = dir |> Path.join("settled.etf") |> File.read!() |> :erlang.binary_to_term()
    refute data.producer_os_pid == System.pid()
    run = data.record.run
    :ets.insert(table, {run.run_id, Map.delete(data.record, :ephemeral)})
    Agent.update(journal, fn _ -> data.commands end)
    before = File.read!(Path.join(dir, "settled.etf"))

    for _ <- 1..2 do
      {:ok, restored} = Conversation.start_link(Keyword.put(opts, :run, run))
      status = Conversation.status(restored)
      assert status.phase == :terminal
      assert status.run == run
      assert status.messages == run.context.conversation.messages
      assert status.run.tool_results[data.invocation_id] == data.result
      assert data.result.request_id == run.tool_results[data.invocation_id].request_id
      assert Enum.take(status.messages, length(data.next_messages)) == data.next_messages
      assert {:ok, record} = EphemeralStore.load(table, run.run_id)
      assert record == data.record
      assert Agent.get(journal, & &1) == data.commands
      refute_receive {:installed, _}, 50
      refute_receive {:provider, _, _}, 50
      GenServer.stop(restored)
    end

    assert File.read!(Path.join(dir, "settled.etf")) == before
    assert File.read!(Path.join(dir, "producer-installer")) == "x"
    refute File.exists?(Path.join(dir, "consumer-installer"))

    IO.puts(
      JSON.encode!(%{
        producer_os_pid: data.producer_os_pid,
        consumer_os_pid: System.pid(),
        request_id: data.result.request_id,
        journal_unchanged: true,
        history_unchanged: true,
        consumer_installer_calls: 0,
        producer_installer_calls: 1
      })
    )
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp eventually(_, 0), do: false
end

[mode, dir] = System.argv()
Backplane.AgentRuntime.PluginCompletionColdBeamFixture.run(mode, dir)
