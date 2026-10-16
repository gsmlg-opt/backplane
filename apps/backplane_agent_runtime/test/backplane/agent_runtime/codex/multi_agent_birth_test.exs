defmodule Backplane.AgentRuntime.Codex.MultiAgentBirthTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{EphemeralStore, Error, Goal, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.MultiAgent

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request.run_id, self()})

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

  defmodule RejectPromptStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == :admit,
        do: {:error, Error.new(:execution_failure, "private prompt rejection")},
        else: EphemeralStore.store(context, run, meta)
    end
  end

  defmodule GoalStore do
    def load(_context, thread), do: Backplane.AgentRuntime.Goal.State.new(thread, [])
  end

  defp start_runtime(options \\ []) do
    test = self()
    attempts = :atomics.new(1, [])
    prepare = Keyword.get(options, :prepare, fn preparation -> {:ok, preparation.options} end)

    manager_options = [
      parent_run_id: "root",
      parent_name: "/root",
      parent_authority: %{caller: "host", run_id: "root", grants: []},
      subscriber: Keyword.get(options, :subscriber),
      max_agents: Keyword.get(options, :max_agents, 16),
      min_wait_timeout_ms: 0,
      child_options: fn request, run_id, parent ->
        attempt = :atomics.add_get(attempts, 1, 1)
        {:ok, store} = EphemeralStore.new(1)

        preparation = %{
          attempt: attempt,
          request: request,
          run_id: run_id,
          parent: parent,
          options: [
            run_id: run_id,
            store: EphemeralStore,
            context: store,
            provider: Provider,
            provider_context: %{test: test},
            registry: %ToolRegistry{},
            tools: [],
            authority: %{caller: "host", run_id: run_id, grants: []},
            host_metadata: %{tracking_id: "safe"},
            schema_admission: :strict,
            work: 10,
            run_timeout: :infinity
          ]
        }

        send(test, {:preparation, self(), preparation})
        prepare.(preparation)
      end
    ]

    receipt_callback = Keyword.get(options, :receipt_callback, fn _receipt -> :ok end)

    manager_options =
      if receipt_callback do
        Keyword.put(manager_options, :admission_receipt, fn receipt ->
          send(test, {:admission_receipt, self(), receipt})
          receipt_callback.(receipt)
        end)
      else
        manager_options
      end

    start_supervised!({MultiAgent, manager_options}, id: make_ref())
  end

  defp spawn_child(runtime, name \\ "worker", profile \\ :v2) do
    tool = if profile == :v2, do: "spawn_agent", else: "multi_agent_v1::spawn_agent"

    MultiAgent.call(%{
      backend_context: %{runtime: runtime, profile: profile},
      run_id: "root",
      tool_name: tool,
      arguments: %{"task_name" => name, "message" => "work"}
    })
  end

  defp assert_public(value) do
    assert is_binary(JSON.encode!(value))
    assert safe_term?(value)
  end

  defp safe_term?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, child} ->
        key not in [:pid, :opts, :authority, :grants, :store, :provider, :provider_context] and
          safe_term?(child)
      end)
  end

  defp safe_term?(value) when is_list(value), do: Enum.all?(value, &safe_term?/1)

  defp safe_term?(value),
    do: is_nil(value) or is_binary(value) or is_number(value) or is_atom(value)

  @tag :tmp_dir
  test "a blocked lifecycle observer is not the durable birth acknowledgement", %{tmp_dir: dir} do
    test = self()
    marker = Path.join(dir, "observer-birth.json")

    observer =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:codex_collaboration, %{type: :created} = event} ->
               send(test, {:observer_blocked, event})

               receive do
                 :persist ->
                   File.write!(marker, JSON.encode!(event))
                   send(test, :observer_persisted)
               end
           end
         end}
      )

    runtime = start_runtime(subscriber: observer)
    assert {:ok, %{task_name: "/root/worker"}} = spawn_child(runtime)
    assert_receive {:observer_blocked, %{agent: %{run_id: run_id}}}, 1_000
    assert_receive {:provider, ^run_id, _}, 1_000
    refute File.exists?(marker)
    send(observer, :persist)
    assert_receive :observer_persisted, 1_000
    assert File.exists?(marker)
  end

  @tag :tmp_dir
  test "trusted preparation must acknowledge its stored identity before any provider starts", %{
    tmp_dir: dir
  } do
    marker = Path.join(dir, "prepared.json")

    runtime =
      start_runtime(
        prepare: fn preparation ->
          receive do
            :persist_preparation ->
              File.write!(marker, JSON.encode!(preparation.parent.child))
              {:ok, preparation.options}
          end
        end
      )

    spawn = Task.async(fn -> spawn_child(runtime) end)
    assert_receive {:preparation, callback, preparation}, 1_000
    refute File.exists?(marker)
    refute_receive {:provider, _, _}, 0
    send(callback, :persist_preparation)
    assert {:ok, _} = Task.await(spawn, 1_000)
    assert File.exists?(marker)
    run_id = preparation.run_id
    assert_receive {:provider, ^run_id, _}, 1_000
  end

  test "a rejected preparation consumes its attempt and child identity before retry" do
    runtime =
      start_runtime(
        prepare: fn preparation ->
          metadata = if preparation.attempt == 1, do: %{unsafe: self()}, else: %{safe: true}
          {:ok, Keyword.put(preparation.options, :host_metadata, metadata)}
        end
      )

    assert {:error, %Error{class: :validation}} = spawn_child(runtime)
    assert_receive {:preparation, _, rejected}
    assert {:ok, %{task_name: "/root/worker"}} = spawn_child(runtime)
    assert_receive {:preparation, _, accepted}
    refute accepted.run_id == rejected.run_id
    refute accepted.parent.child.agent_id == rejected.parent.child.agent_id
    refute accepted.parent.child.attempt_id == rejected.parent.child.attempt_id
    assert accepted.parent.child.run_id == accepted.run_id

    assert {:ok, snapshot} = MultiAgent.snapshot(runtime)

    assert Enum.any?(
             snapshot.admissions,
             &(&1.attempt_id == rejected.parent.child.attempt_id and &1.status == :rejected)
           )

    assert Enum.any?(
             snapshot.admissions,
             &(&1.attempt_id == accepted.parent.child.attempt_id and &1.status == :created)
           )
  end

  test "a preparation exception leaves its correlated rejection and keeps the manager alive" do
    runtime =
      start_runtime(
        prepare: fn _preparation ->
          raise "private callback failure must not appear in public receipts"
        end
      )

    assert {:error, %Error{}} = spawn_child(runtime)
    assert_receive {:preparation, _, preparation}
    assert Process.alive?(runtime)
    assert {:ok, %{agents: [], admissions: [receipt]}} = MultiAgent.snapshot(runtime)
    assert receipt.attempt_id == preparation.parent.child.attempt_id
    assert receipt.status == :rejected
    refute JSON.encode!(receipt) =~ "private callback failure"
    refute_receive {:provider, _, _}, 0
  end

  @tag :tmp_dir
  test "created receipt acknowledgement gates the first prompt after the process is born", %{
    tmp_dir: dir
  } do
    marker = Path.join(dir, "created.json")

    runtime =
      start_runtime(
        receipt_callback: fn receipt ->
          receive do
            :persist_created ->
              File.write!(marker, JSON.encode!(receipt))
              :ok
          end
        end
      )

    task = Task.async(fn -> spawn_child(runtime) end)
    assert_receive {:preparation, _, preparation}, 1_000
    assert_receive {:admission_receipt, callback, %{status: :created} = receipt}, 1_000
    assert receipt.attempt_id == preparation.parent.child.attempt_id
    assert receipt.run_id == preparation.run_id
    assert receipt.agent_id == preparation.parent.child.agent_id
    assert receipt.parent_name == "/root"
    assert receipt.incarnation == 1
    assert receipt.activation == :created
    assert receipt.profile == :v2
    refute File.exists?(marker)
    refute_receive {:provider, _, _}, 0
    send(callback, :persist_created)
    assert {:ok, _} = Task.await(task, 1_000)
    assert File.exists?(marker)
    run_id = receipt.run_id
    assert_receive {:provider, ^run_id, _}, 1_000
    assert {:ok, %{agents: [agent], admissions: [acknowledged]}} = MultiAgent.snapshot(runtime)
    assert agent.attempt_id == receipt.attempt_id
    assert acknowledged.receipt_acknowledged
    assert acknowledged.receipt_error_class == nil
    assert_public(acknowledged)
  end

  test "receipt refusal, exceptions and malformed acknowledgements retire the child before prompt" do
    for failure <- [:refused, :raised, :malformed] do
      runtime =
        start_runtime(
          receipt_callback: fn
            %{status: :created} ->
              case failure do
                :refused -> {:error, Error.new(:forbidden, "private receipt refusal")}
                :raised -> raise "private receipt exception"
                :malformed -> {:ok, :not_an_acknowledgement}
              end

            %{status: :failed} ->
              :ok
          end
        )

      assert {:error, %Error{}} = spawn_child(runtime)
      assert_receive {:preparation, _, preparation}
      assert_receive {:admission_receipt, _, %{status: :created} = created}
      assert_receive {:admission_receipt, _, %{status: :failed} = failed}
      assert failed.attempt_id == created.attempt_id
      assert failed.attempt_id == preparation.parent.child.attempt_id
      assert failed.run_id == created.run_id
      assert Process.alive?(runtime)
      assert {:ok, %{agents: [agent], admissions: [receipt]}} = MultiAgent.snapshot(runtime)
      refute agent.resident
      assert receipt.status == :failed
      assert receipt.process_started
      assert receipt.receipt_acknowledged
      refute JSON.encode!(receipt) =~ "private receipt"
      assert_public(receipt)
      refute_receive {:provider, _, _}, 0
    end
  end

  test "failure to persist the rejected receipt remains visible without losing the attempt" do
    runtime =
      start_runtime(
        prepare: fn _ -> {:error, Error.new(:forbidden, "private prepare refusal")} end,
        receipt_callback: fn _ ->
          {:error, Error.new(:execution_failure, "private store failure")}
        end
      )

    assert {:error, %Error{class: :forbidden}} = spawn_child(runtime)
    assert_receive {:preparation, _, preparation}
    assert_receive {:admission_receipt, _, %{status: :rejected}}
    assert {:ok, %{agents: [], admissions: [receipt]}} = MultiAgent.snapshot(runtime)
    assert receipt.attempt_id == preparation.parent.child.attempt_id
    refute receipt.receipt_acknowledged
    assert receipt.receipt_error_class == :execution_failure
    assert receipt.error_class == :forbidden
    refute receipt.process_started
    refute JSON.encode!(receipt) =~ "private"
    assert_public(receipt)
    refute_receive {:provider, _, _}, 0
  end

  test "malformed preparation, configuration and excessive authority finalize rejected receipts" do
    for failure <- [:malformed, :invalid_options, :run_id, :authority] do
      runtime =
        start_runtime(
          prepare: fn preparation ->
            case failure do
              :malformed ->
                :not_options

              :invalid_options ->
                {:ok, %{run_id: preparation.run_id}}

              :run_id ->
                {:ok, Keyword.put(preparation.options, :run_id, "wrong-run")}

              :authority ->
                authority = %{caller: "host", run_id: preparation.run_id, grants: ["forbidden"]}
                {:ok, Keyword.put(preparation.options, :authority, authority)}
            end
          end
        )

      assert {:error, %Error{}} = spawn_child(runtime)
      assert_receive {:preparation, _, preparation}
      assert_receive {:admission_receipt, _, %{status: :rejected} = receipt}
      assert receipt.attempt_id == preparation.parent.child.attempt_id
      assert receipt.run_id == preparation.run_id

      assert {:ok, %{agents: [], admissions: [%{status: :rejected}]}} =
               MultiAgent.snapshot(runtime)

      assert Process.alive?(runtime)
      assert_public(receipt)
      refute_receive {:provider, _, _}, 0
    end
  end

  test "Goal delegation rejection after trusted preparation retains the same attempt receipt" do
    goal =
      start_supervised!(
        {Goal,
         thread_id: "root-thread",
         owner_pid: self(),
         store: GoalStore,
         store_context: nil,
         host: __MODULE__,
         host_context: nil}
      )

    assert {:ok, binding} =
             Goal.bind(goal, %{
               thread_id: "root-thread",
               run_id: "root",
               incarnation: 1,
               authority: %{caller: "host", run_id: "root", grants: []},
               usage_authoritative: true,
               mode: :execution
             })

    runtime = start_runtime()

    assert {:error, %Error{class: :forbidden}} =
             MultiAgent.call(%{
               backend_context: %{
                 runtime: runtime,
                 profile: :v2,
                 goal: goal,
                 goal_binding: %{binding | capability: make_ref()}
               },
               run_id: "root",
               tool_name: "spawn_agent",
               arguments: %{"task_name" => "worker", "message" => "work"}
             })

    assert_receive {:preparation, _, preparation}
    assert_receive {:admission_receipt, _, %{status: :rejected} = receipt}
    assert receipt.attempt_id == preparation.parent.child.attempt_id
    assert receipt.error_class == :forbidden
    assert {:ok, %{agents: [], admissions: [_]}} = MultiAgent.snapshot(runtime)
    assert_public(receipt)
    refute_receive {:provider, _, _}, 0
  end

  test "Conversation startup and prompt failures finalize correlated failed receipts" do
    for failure <- [:startup, :prompt] do
      runtime =
        start_runtime(
          prepare: fn preparation ->
            options =
              case failure do
                :startup -> Keyword.put(preparation.options, :work, 0)
                :prompt -> Keyword.put(preparation.options, :store, RejectPromptStore)
              end

            {:ok, options}
          end
        )

      assert {:error, %Error{}} = spawn_child(runtime)
      assert_receive {:preparation, _, preparation}

      if failure == :prompt do
        assert_receive {:admission_receipt, _, %{status: :created} = created}
        assert created.attempt_id == preparation.parent.child.attempt_id
      else
        refute_receive {:admission_receipt, _, %{status: :created}}, 0
      end

      assert_receive {:admission_receipt, _, %{status: :failed} = failed}
      assert failed.attempt_id == preparation.parent.child.attempt_id
      assert failed.run_id == preparation.run_id
      assert {:ok, %{admissions: [%{status: :failed} = receipt]}} = MultiAgent.snapshot(runtime)
      assert receipt.process_started == (failure == :prompt)
      assert receipt.receipt_acknowledged
      refute JSON.encode!(receipt) =~ "private"
      assert_public(receipt)
      refute_receive {:provider, _, _}, 0
    end
  end

  test "followup preserves the logical agent while preparing a unique acknowledged activation" do
    runtime = start_runtime(subscriber: self())
    assert {:ok, _} = spawn_child(runtime)
    assert_receive {:preparation, _, first}
    assert_receive {:admission_receipt, _, %{status: :created} = first_receipt}
    assert_receive {:provider, _, provider}, 1_000

    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]}
    )

    assert_receive {:codex_collaboration, %{type: :settled}}, 1_000

    assert {:ok, %{accepted: true}} =
             MultiAgent.call(%{
               backend_context: %{runtime: runtime, profile: :v2},
               run_id: "root",
               tool_name: "followup_task",
               arguments: %{"target" => "/root/worker", "message" => "again"}
             })

    assert_receive {:preparation, _, second}
    assert_receive {:admission_receipt, _, %{status: :created} = second_receipt}
    refute first.parent.child.attempt_id == second.parent.child.attempt_id
    refute first.run_id == second.run_id
    assert first.parent.child.agent_id == second.parent.child.agent_id
    assert second_receipt.activation == :followup
    assert second_receipt.incarnation == first_receipt.incarnation + 1
    assert {:ok, %{agents: [agent], admissions: [old, current]}} = MultiAgent.snapshot(runtime)
    assert [old.sequence, current.sequence] == Enum.sort([old.sequence, current.sequence])
    assert agent.attempt_id == second_receipt.attempt_id
    assert old.receipt_acknowledged and current.receipt_acknowledged
    assert_public(current)
  end

  test "V1 callers retain compatibility when the receipt callback is absent" do
    runtime = start_runtime(receipt_callback: nil)
    assert {:ok, %{agent_id: agent_id}} = spawn_child(runtime, "worker", :v1)
    assert_receive {:preparation, _, preparation}
    assert_receive {:provider, _, _}, 1_000
    assert {:ok, %{agents: [agent], admissions: [receipt]}} = MultiAgent.snapshot(runtime)
    assert agent.agent_id == agent_id
    assert receipt.attempt_id == preparation.parent.child.attempt_id
    assert receipt.status == :created
    assert receipt.profile == :v1
    assert receipt.receipt_acknowledged == nil
    refute_receive {:admission_receipt, _, _}, 0
  end

  test "V1 close releases capacity after a safely retired receipt failure" do
    runtime =
      start_runtime(
        max_agents: 1,
        receipt_callback: fn
          %{sequence: 1, status: :created} ->
            {:error, Error.new(:execution_failure, "birth persistence unavailable")}

          _ ->
            :ok
        end
      )

    assert {:error, %Error{}} = spawn_child(runtime, "first", :v1)
    assert_receive {:preparation, _, rejected}
    assert {:ok, %{agents: [%{resident: false}]}} = MultiAgent.snapshot(runtime)
    refute_receive {:provider, _, _}, 0

    assert {:ok, _} =
             MultiAgent.call(%{
               backend_context: %{runtime: runtime, profile: :v1},
               run_id: "root",
               tool_name: "multi_agent_v1::close_agent",
               arguments: %{"target" => rejected.parent.child.agent_id}
             })

    assert {:ok, _} = spawn_child(runtime, "second", :v1)
    assert_receive {:preparation, _, accepted}
    run_id = accepted.run_id
    assert_receive {:provider, ^run_id, _}, 1_000

    assert {:ok, %{admissions: [%{status: :failed}, %{status: :created}]}} =
             MultiAgent.snapshot(runtime)
  end

  test "fresh managers have independent attempt identities and no restored process-local admissions" do
    first = start_runtime()
    assert {:ok, _} = spawn_child(first)
    assert_receive {:preparation, _, _}
    assert_receive {:admission_receipt, _, first_receipt}
    assert_receive {:provider, _, _}, 1_000

    second = start_runtime()
    assert {:ok, %{agents: [], admissions: []}} = MultiAgent.snapshot(second)
    assert {:ok, _} = spawn_child(second)
    assert_receive {:preparation, _, _}
    assert_receive {:admission_receipt, _, second_receipt}
    assert first_receipt.sequence == second_receipt.sequence
    refute first_receipt.manager_id == second_receipt.manager_id
    refute first_receipt.attempt_id == second_receipt.attempt_id
    assert_public(first_receipt)
    assert_public(second_receipt)
  end
end
