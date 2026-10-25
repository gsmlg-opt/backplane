defmodule Backplane.AgentRuntime.ToolPresentationJournalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, Kernel, Plan, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{Backend, Catalog, Session, Tools}

  @moduletag capture_log: true

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:journal_provider, request, self()})

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

  defmodule Native do
    def execute(operation) do
      {:ok, actual} = Backend.execute(operation)
      send(operation.backend_context.test, {:journal_actual, operation, actual})
      ToolEffects.present(operation, actual, operation.backend_context.presentation)
    end
  end

  defmodule Outer do
    def execute(operation) do
      result =
        operation.backend_context.nested_dispatch.(%{
          tool_name: "update_plan",
          arguments: %{"plan" => [%{"step" => "native effect", "status" => "completed"}]}
        })

      send(operation.backend_context.test, {:outer_holding, result, self()})

      receive do
        :finish -> {:ok, %{text: "outer finished"}}
      end
    end
  end

  test "Kernel fences presentation identity and shape against its authoritative active invocation" do
    operation = operation()
    {:ok, active, _, []} = Kernel.execute(run(operation), {:tool_invoked, 10, operation})
    actual = %{revision: 2, is_error: false}

    {:presented, envelope} =
      ToolEffects.present(operation, actual, %{type: :block, text: "blocked"})

    {:ok, validated} = ToolEffects.validate_presentation(envelope, operation)
    record = validated.presentation
    completion = Map.put(operation, :result, actual)

    for invalid <- [
          %{},
          nil,
          [],
          put_in(record.identity.invocation_id, "another-invocation"),
          put_in(record.identity.run_id, "another-run"),
          put_in(record.identity.incarnation, 2),
          put_in(record.identity.tool_call_id, "another-call"),
          put_in(record.identity.turn_id, "another-turn"),
          put_in(record.identity.enclosing_invocation_id, "another-enclosing-call"),
          put_in(record.identity.catalog_revision, 2),
          put_in(record.identity.arguments, %{"different" => true}),
          Map.put(record, :state, :projected),
          Map.put(record, :decision, %{type: :unsupported, text: "bad"}),
          Map.put(record, :decision, %{type: :block, text: ""})
        ] do
      assert {:error, %Error{}} =
               Kernel.execute(
                 active,
                 {:tool_completed, 11, Map.put(completion, :presentation, invalid)}
               )
    end

    assert {:ok, completed, _, []} =
             Kernel.execute(
               active,
               {:tool_completed, 11, Map.put(completion, :presentation, record)}
             )

    assert completed.tool_results[operation.invocation_id] == actual
    assert completed.tool_presentations[operation.invocation_id].identity == record.identity

    assert completed.tool_presentations[operation.invocation_id].revision ==
             completed.expected_revision
  end

  test "explicit empty stopped text is accepted through public presentation and journal validation" do
    operation = operation()
    actual = %{revision: 2, is_error: false}
    decision = %{type: :stopped, text: ""}

    assert {:presented, envelope} = ToolEffects.present(operation, actual, decision)
    assert {:ok, validated} = ToolEffects.validate_presentation(envelope, operation)
    assert validated.result == actual
    assert validated.presentation.decision == decision

    assert :ok =
             ToolEffects.validate_presentation_record(validated.presentation, operation, actual)

    {:ok, active, _, []} = Kernel.execute(run(operation), {:tool_invoked, 10, operation})

    assert {:ok, completed, _, []} =
             Kernel.execute(
               active,
               {:tool_completed, 11,
                operation
                |> Map.put(:result, actual)
                |> Map.put(:presentation, validated.presentation)}
             )

    assert completed.tool_results[operation.invocation_id] == actual
    assert completed.tool_presentations[operation.invocation_id].decision == decision

    for invalid <- [
          %{type: :block, text: ""},
          %{type: :stopped},
          %{type: :stopped, text: nil},
          %{type: :stopped, text: <<255>>},
          %{type: :stopped, text: String.duplicate("x", 65_537)},
          %{type: :stopped, text: "", extra: true}
        ] do
      assert {:error, %Error{class: :unknown_outcome}} =
               ToolEffects.present(operation, actual, invalid)
    end
  end

  test "malformed selected-branch presentation records return typed restore errors without effect replay" do
    ctx = start(:stopped)
    provider = prompt(ctx)
    send(provider, {:events, [call("update_plan", %{"plan" => []}), done()]})
    assert_receive {:journal_actual, operation, %{revision: 2}}, 1_000
    assert_receive {:journal_provider, _, provider}, 1_000
    send(provider, {:events, [done()]})
    run_id = ctx.run
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 1_000
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
    assert {:ok, %{run: selected}} = EphemeralStore.load(ctx.store, ctx.run)
    record = selected.tool_presentations[operation.invocation_id]

    for invalid_run <- [
          %{selected | tool_presentations: %{operation.invocation_id => %{}}},
          %{
            selected
            | tool_presentations: %{
                operation.invocation_id => put_in(record.identity.invocation_id, "other")
              }
          },
          %{
            selected
            | tool_presentations: %{
                operation.invocation_id => put_in(record.identity.run_id, "other")
              }
          },
          %{
            selected
            | tool_presentations: %{
                operation.invocation_id => Map.put(record, :state, :projected)
              }
          },
          %{
            selected
            | tool_presentations: %{
                operation.invocation_id => Map.put(record, :decision, %{type: :block})
              }
          },
          %{selected | tool_presentations: []},
          %{selected | tool_results: Map.delete(selected.tool_results, operation.invocation_id)},
          %{
            selected
            | execution_intents:
                Map.delete(selected.execution_intents, "tool:" <> operation.invocation_id)
          }
        ] do
      assert {:error, %Error{}} = Conversation.start_link(restore_options(ctx, invalid_run))
    end

    restored =
      start_supervised!({Conversation, restore_options(ctx, selected)}, id: :valid_restored)

    assert Enum.count(
             Conversation.status(restored).messages,
             &(&1[:invocation_id] == operation.invocation_id)
           ) == 1

    assert {:ok, %{revision: 2}} = Plan.read(ctx.plan)
    refute_receive {:journal_actual, _, _}, 30
  end

  for type <- [:stopped, :block] do
    test "accepted nested #{type} survives outer cancellation as unprojected native settlement" do
      type = unquote(type)
      ctx = start(type)
      provider = prompt(ctx)
      send(provider, {:events, [call("host_outer", %{}), done()]})
      assert_receive {:journal_actual, operation, %{revision: 2}}, 1_000
      assert_receive {:outer_holding, consumer, outer}, 1_000

      assert_consumer(type, consumer)

      assert {:ok, %{run: accepted}} = EphemeralStore.load(ctx.store, ctx.run)
      assert accepted.tool_results[operation.invocation_id].revision == 2
      assert accepted.tool_presentations[operation.invocation_id].decision.type == type

      enclosing =
        accepted.tool_presentations[operation.invocation_id].identity.enclosing_invocation_id

      refute Map.has_key?(accepted.tool_results, enclosing)
      refute Enum.any?(accepted.context.conversation.messages, &(&1[:role] == :tool))

      monitor = Process.monitor(outer)
      assert :ok = Conversation.cancel(ctx.pid)
      assert_receive {:DOWN, ^monitor, :process, ^outer, _}, 1_000
      run_id = ctx.run
      assert_receive {:agent_runtime, ^run_id, %{type: :run_cancelled}}, 2_000
      assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
      assert {:ok, %{run: selected}} = EphemeralStore.load(ctx.store, ctx.run)
      assert selected.tool_results[operation.invocation_id].revision == 2
      assert selected.tool_results[operation.invocation_id].is_error == false
      assert selected.tool_presentations[operation.invocation_id].state == :accepted
      refute Map.has_key?(selected.tool_results, enclosing)

      restored =
        start_supervised!({Conversation, restore_options(ctx, selected)}, id: :cancelled_restored)

      assert Conversation.status(restored).phase == :terminal
      refute Enum.any?(Conversation.status(restored).messages, &(&1[:role] == :tool))
      assert {:ok, %{revision: 2}} = Plan.read(ctx.plan)
      refute_receive {:journal_actual, _, _}, 30
      refute_receive {:journal_provider, _, _}, 30
    end
  end

  defp start(type) do
    run = "presentation-journal-" <> Integer.to_string(System.unique_integer([:positive]))
    names = ["update_plan", "host_outer"]
    authority = %{caller: "host", run_id: run, grants: names, tool_revision: 1}
    session = start_supervised!({Session, owner_pid: self()}, id: :session)
    {:ok, binding} = Session.bind(session, authority)
    plan = start_supervised!({Plan, run}, id: :plan)
    native = Tools.contracts(%{plan: plan}) |> Enum.filter(&(&1.name == "update_plan"))

    outer = %{
      name: "host_outer",
      schema: %{"type" => "object", "properties" => %{}},
      backend: Outer,
      backend_context: %{test: self()},
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    {:ok, profile} = Catalog.admit(native ++ [outer], authority)

    registry = %{
      profile.registry
      | tools:
          Map.new(profile.registry.tools, fn {name, descriptor} ->
            descriptor = put_in(descriptor.backend_context[:session_binding], binding)

            descriptor =
              if name == "update_plan",
                do: %{
                  descriptor
                  | backend: Native,
                    backend_context:
                      Map.merge(descriptor.backend_context, %{
                        test: self(),
                        presentation: %{type: type, text: "host presentation"}
                      })
                },
                else: descriptor

            {name, descriptor}
          end)
    }

    {:ok, store} = EphemeralStore.new(1)

    opts = [
      run_id: run,
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: self()},
      registry: registry,
      tools: profile.tools,
      authority: profile.authority,
      session_binding: binding,
      subscriber: self(),
      work: 20,
      run_timeout: 10_000
    ]

    pid = start_supervised!({Conversation, opts}, id: :conversation)
    %{pid: pid, run: run, session: session, plan: plan, store: store, opts: opts}
  end

  defp restore_options(ctx, run),
    do: ctx.opts |> Keyword.delete(:session_binding) |> Keyword.put(:run, run)

  defp assert_consumer(:stopped, consumer), do: assert({:ok, %{revision: 2}} = consumer)

  defp assert_consumer(:block, consumer),
    do: assert({:error, %Error{class: :forbidden}} = consumer)

  defp prompt(ctx) do
    assert {:ok, _} = Conversation.prompt(ctx.pid, "exercise presentation journal")
    assert_receive {:journal_provider, _, provider}, 1_000
    provider
  end

  defp operation,
    do: %{
      run_id: "journal",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      enclosing_invocation_id: "invocation",
      tool_name: "native",
      tool_revision: 1,
      catalog_revision: 1,
      tool_call_id: "call",
      turn_id: "turn",
      arguments: %{}
    }

  defp run(operation),
    do: %{
      run_id: operation.run_id,
      incarnation: operation.incarnation,
      expected_revision: 0,
      state: :running,
      deadline: nil,
      children: [],
      current_step: Map.take(operation, [:step_id, :attempt_id]),
      context: %{}
    }

  defp call(name, arguments),
    do: %{type: :tool_call_completed, tool_call: %{id: "call", name: name, arguments: arguments}}

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end
