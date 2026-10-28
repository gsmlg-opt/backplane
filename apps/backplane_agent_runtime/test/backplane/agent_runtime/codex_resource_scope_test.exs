Code.require_file("../../fixtures/reconciliation_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.CodexResourceScopeTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{DynamicRuntime, MultiAgent, Reconciliation, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.ReconciliationHostFixture, as: Host
  alias Backplane.McpProtocol.Client
  @moduletag :tmp_dir
  @moduletag capture_log: true
  @resources ~w(list_mcp_resources list_mcp_resource_templates read_mcp_resource)
  @collaboration ~w(spawn_agent list_agents interrupt_agent)

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:resource_provider, request.run_id, request, self()})

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

  defmodule Adapter do
    def list_events(arguments, op) do
      send(op.backend_context.test, {:events_owner, self()})

      result =
        DynamicRuntime.event_request(op, fn reserved ->
          send(op.backend_context.test, {:events_reserved, reserved})

          reserved =
            if arguments["cursor"] == "untracked",
              do: Keyword.put(reserved, :track_retirement, false),
              else: reserved

          if arguments["cursor"] == "wrong-family" do
            {:ok, wrong} = Client.start_list_resources(hd(op.backend_context.client), reserved)
            {:ok, _} = Client.await_resource_request(wrong, 1_000)
            {:ok, wrong}
          else
            Client.start_list_events(
              hd(op.backend_context.client),
              Keyword.merge([cursor: arguments["cursor"]], reserved)
            )
          end
        end)

      case result do
        {:ok, response} ->
          {:ok, response.result}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, error} ->
          {:error, Error.new(:execution_failure, "Events failed", cause: error.reason)}
      end
    end

    def list_resources(arguments, op), do: request(arguments, op, :list)
    def list_resource_templates(arguments, op), do: request(arguments, op, :templates)
    def read_resource(arguments, op), do: request(arguments, op, :read)

    defp request(%{"uri" => "mem://stale-scope"}, op, _) do
      scope = DynamicRuntime.resource_request_scope(op, & &1)

      refused =
        DynamicRuntime.resource_request(scope, fn _ ->
          send(op.backend_context.test, :forbidden_start)
        end)

      {:ok, %{refused: error_class(refused)}}
    end

    defp request(%{"uri" => "mem://stale-session"} = args, op, kind) do
      stale = update_in(op.session_binding_identity.incarnation, &(&1 + 1))
      request(Map.put(args, "uri", "mem://done"), stale, kind)
    end

    defp request(arguments, op, kind) do
      original = op.backend_context.register_cancellation

      register = fn operation, registration ->
        send(op.backend_context.test, {:scope_registration, operation, registration})
        if arguments["uri"] == "mem://pre-registration", do: pause(op, :before_registration)
        result = original.(operation, registration)
        if arguments["uri"] == "mem://coordinate-race", do: pause(op, :coordinate_ack)
        result
      end

      op = put_in(op.backend_context.register_cancellation, register)

      op =
        if arguments["uri"] == "mem://deadline-race" do
          original_deadline = op.backend_context.effect_deadline

          accessor = fn ->
            due = original_deadline.()
            count = Process.get(:scope_deadline_reads, 0) + 1
            Process.put(:scope_deadline_reads, count)
            if count == 2, do: pause(op, :deadline_read)
            due
          end

          put_in(op.backend_context.effect_deadline, accessor)
        else
          op
        end

      DynamicRuntime.resource_request_scope(op, fn scope ->
        send(op.backend_context.test, {:scope_owner, self()})

        scenario =
          if arguments["cursor"] == "scope-pages", do: "mem://pages", else: arguments["uri"]

        case scenario do
          "mem://empty" ->
            pause(op, :empty)
            {:ok, %{empty: true}}

          "mem://refusals" ->
            nested =
              DynamicRuntime.resource_request_scope(op, fn _ ->
                send(op.backend_context.test, :forbidden_start)
              end)

            foreign =
              Task.async(fn ->
                DynamicRuntime.resource_request(scope, fn _ ->
                  send(op.backend_context.test, :forbidden_start)
                end)
              end)
              |> Task.await()

            result =
              DynamicRuntime.resource_request(scope, fn opts ->
                reentrant =
                  DynamicRuntime.resource_request(scope, fn _ ->
                    send(op.backend_context.test, :forbidden_start)
                  end)

                send(
                  op.backend_context.test,
                  {:scope_refusals, error_class(nested), error_class(foreign),
                   error_class(reentrant)}
                )

                Client.start_read_resource(hd(op.backend_context.client), "mem://done", opts)
              end)

            business([result])

          "mem://limit" ->
            results =
              for _ <- 1..128 do
                DynamicRuntime.resource_request(scope, fn opts ->
                  Client.start_read_resource(hd(op.backend_context.client), "mem://done", opts)
                end)
              end

            overflow =
              DynamicRuntime.resource_request(scope, fn _ ->
                send(op.backend_context.test, :forbidden_start)
              end)

            {:ok,
             %{
               count: length(Enum.filter(results, &match?({:ok, _}, &1))),
               overflow: error_class(overflow)
             }}

          "mem://raw-error" ->
            first =
              DynamicRuntime.resource_request(scope, fn opts ->
                Client.start_read_resource(hd(op.backend_context.client), "mem://error", opts)
              end)

            second =
              DynamicRuntime.resource_request(scope, fn opts ->
                Client.start_read_resource(
                  List.last(op.backend_context.client),
                  "mem://done",
                  opts
                )
              end)

            send(op.backend_context.test, {:scope_raw_results, first, second})
            {:ok, %{host_continued: true}}

          "mem://missing-proof" ->
            first =
              DynamicRuntime.resource_request(scope, fn opts ->
                Client.start_read_resource(
                  hd(op.backend_context.client),
                  "mem://done",
                  Keyword.put(opts, :track_retirement, false)
                )
              end)

            sealed =
              DynamicRuntime.resource_request(scope, fn _ ->
                send(op.backend_context.test, :forbidden_start)
              end)

            send(op.backend_context.test, {:scope_missing_proof, first, sealed})
            pause(op, :missing_proof)
            business([first])

          _ ->
            results =
              Enum.map(Enum.with_index(op.backend_context.client), fn {client, index} ->
                if index == 1 && scenario == "mem://between", do: pause(op, :between)

                DynamicRuntime.resource_request(scope, fn opts ->
                  if scenario == "mem://deadline-race",
                    do: send(op.backend_context.test, :forbidden_start)

                  if index == 1 && scenario == "mem://startup", do: pause(op, :startup)

                  uri =
                    cond do
                      index == 0 -> "mem://first"
                      scenario in ["mem://startup", "mem://attach"] -> "mem://pending"
                      true -> arguments["uri"]
                    end

                  opts =
                    Keyword.merge(
                      [
                        meta: %{"source" => Integer.to_string(index)},
                        timeout: 99_999,
                        registration_timeout: 99_999,
                        retirement_deadline: System.monotonic_time(:millisecond) + 99_999,
                        track_retirement: false
                      ],
                      opts
                    )

                  send(op.backend_context.test, {:scope_reserved, index, opts})

                  result =
                    case kind do
                      :list ->
                        Client.start_list_resources(
                          client,
                          Keyword.merge(
                            [
                              cursor:
                                if(scenario == "mem://pages",
                                  do: if(index == 0, do: "first", else: "pending"),
                                  else: arguments["cursor"]
                                )
                            ],
                            opts
                          )
                        )

                      :templates ->
                        Client.start_list_resource_templates(
                          client,
                          Keyword.merge([cursor: arguments["cursor"]], opts)
                        )

                      :read ->
                        Client.start_read_resource(client, uri, opts)
                    end

                  if index == 1 && scenario == "mem://attach", do: pause(op, :attach)
                  result
                end)
              end)

            if scenario == "mem://finished", do: pause(op, :finished)
            business(results)
        end
      end)
    end

    defp pause(op, phase) do
      send(op.backend_context.test, {:scope_pause, phase, self()})

      receive do
        :continue -> :ok
      end
    end

    defp error_class({:error, %Error{class: class}}), do: class

    defp business(results) do
      case Enum.find(results, &match?({:error, _}, &1)) do
        nil ->
          {:ok, %{sources: Enum.map(results, fn {:ok, response} -> response.result end)}}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, error} ->
          {:error, Error.new(:execution_failure, "resource failed", cause: error.reason)}
      end
    end
  end

  for mode <- [:direct, :deno], name <- @resources do
    @tag mode: mode, resource_tool: name
    test "#{mode} #{name} aggregates two actual caller-owned sources", ctx do
      a = Path.join(ctx.tmp_dir, "a")
      b = Path.join(ctx.tmp_dir, "b")
      File.mkdir_p!(a)
      File.mkdir_p!(b)
      clients = [start_client(a), start_client(b)]
      dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
      context = runtime(clients, dynamic)

      args =
        if ctx.resource_tool == "read_mcp_resource",
          do: %{"server" => "both", "uri" => "mem://done"},
          else: %{"cursor" => "opaque-page"}

      {name, args} =
        if ctx.mode == :deno,
          do: {"exec", "return await tools.#{ctx.resource_tool}(#{JSON.encode!(args)});"},
          else: {ctx.resource_tool, args}

      {provider, result} = tool(context.provider, "root", name, args)
      refute result[:is_error], inspect(result)
      assert length(if(ctx.mode == :deno, do: result.value["sources"], else: result.sources)) == 2

      assert_receive {:scope_reserved, 0, first_opts}
      assert_receive {:scope_reserved, 1, second_opts}
      assert first_opts[:retirement_deadline] == second_opts[:retirement_deadline]

      for opts <- [first_opts, second_opts] do
        assert opts[:track_retirement] == true
        assert opts[:timeout] > 0 && opts[:timeout] <= 10_000
        assert opts[:registration_timeout] > 0 && opts[:registration_timeout] <= 5_000
      end

      for {root, index} <- Enum.with_index([a, b]) do
        actual =
          Enum.filter(
            wires(root),
            &(&1["method"] in ["resources/list", "resources/templates/list", "resources/read"])
          )

        assert length(actual) == 1
        assert hd(actual)["params"]["_meta"]["source"] == Integer.to_string(index)

        unless ctx.resource_tool == "read_mcp_resource",
          do: assert(hd(actual)["params"]["cursor"] == "opaque-page")
      end

      send(provider, {:events, [done()]})
      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
      assert Conversation.status(context.conversation).run.state == :completed
      assert {:ok, %{status: :confirmed}} = Session.close(context.root_binding.session)
      stop_supervised!(:root_conversation)
      stop_supervised!(:resource_manager)
    end
  end

  for mode <- [:direct, :deno] do
    @tag mode: mode
    test "#{mode} cancellation retires completed first source and current second source", ctx do
      roots =
        for source <- ["a", "b"] do
          root = Path.join(ctx.tmp_dir, source)
          File.mkdir_p!(root)
          root
        end

      clients = Enum.map(roots, &start_client/1)
      dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
      context = runtime(clients, dynamic)
      args = %{"server" => "both", "uri" => "mem://pending"}

      {name, args} =
        if ctx.mode == :deno,
          do: {"exec", "return await tools.read_mcp_resource(#{JSON.encode!(args)});"},
          else: {"read_mcp_resource", args}

      send(context.provider, {:events, [call(name, args), done()]})
      eventually(fn -> Enum.any?(wires(Enum.at(roots, 1)), &pending?/1) end)
      assert :ok = Conversation.cancel(context.conversation)
      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
      status = Conversation.status(context.conversation)
      settled = status.run
      assert settled.state == :cancelled
      [evidence] = settled.outcome["cleanup"]["evidence"]

      report =
        if ctx.mode == :deno, do: hd(evidence["nested"])["report"], else: evidence["report"]

      assert report["record_type"] == "resource_scope_cancellation"
      assert report["inventory_count"] == 2
      assert Enum.map(report["slots"], & &1["receipt"]["terminal"]) == ["completed", "cancelled"]
      assert report["local_cleanup"] == "confirmed"
      proofs = assert_retirement_records(context.store, status, ctx.mode)
      host = Host.new()
      :ok = Host.put(host, {:store, "original"}, {EphemeralStore, context.store})
      monitor = Process.monitor(context.conversation)
      stop_supervised!(:root_conversation)
      assert_receive {:DOWN, ^monitor, :process, _, _}
      refute Process.alive?(context.provider)
      assert Session.status(context.root_binding.session).phase == :closed
      assert_cold_reconciliation(host, settled, proofs, context.root_binding, ctx.mode)
      stop_supervised!(:resource_manager)
    end
  end

  for mode <- [:direct, :deno] do
    @tag mode: mode, full_resource_retirement: true
    test "#{mode} parent interruption preserves shared paginated client through complete child retirement",
         ctx do
      client = start_client(ctx.tmp_dir, "resource_scope_retirement_mcp.py")
      dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
      host = Host.new()
      context = runtime([client, client], dynamic, recovery_host: host)

      {parent, _} =
        tool(context.provider, "root", "spawn_agent", %{
          "task_name" => "worker",
          "message" => "list pages"
        })

      assert_receive {:resource_provider, child_run, _, provider}, 2_000

      {name, input} =
        if ctx.mode == :direct,
          do: {"list_mcp_resources", %{"cursor" => "scope-pages"}},
          else: {"exec", "return await tools.list_mcp_resources({cursor: 'scope-pages'});"}

      send(provider, {:events, [call(name, input), done()]})
      eventually(fn -> Enum.any?(wires(ctx.tmp_dir), &pending?/1) end)
      assert {:ok, other} = Client.start_read_resource(client, "mem://survivor-pending")
      assert {:error, %{reason: :request_timeout}} = Client.await_resource_request(other, 10)
      {parent, result} = tool(parent, "root", "interrupt_agent", %{"target" => "/root/worker"})
      refute result[:is_error], inspect(result)
      assert {:ok, snapshot} = MultiAgent.snapshot(context.manager)
      [child] = snapshot.agents
      assert child.run_id == child_run && child.cleanup == :confirmed
      # Public roster identifies the child; Runtime status supplies original persisted proofs.
      child_pid = :sys.get_state(context.manager).agents[child.name].pid
      status = Conversation.status(child_pid)
      assert status.run.state == :cancelled
      proofs = assert_retirement_records(host.store, status, ctx.mode)
      resource = Enum.find(proofs, &(&1["record_type"] == "resource_scope_retirement"))
      [first, second] = resource["cancellation"]["slots"]
      assert first["identity"]["client_incarnation"] == second["identity"]["client_incarnation"]
      assert first["receipt"]["terminal"] == "completed"
      assert second["receipt"]["terminal"] == "cancelled"
      resource_wires = Enum.filter(wires(ctx.tmp_dir), &(&1["method"] == "resources/list"))
      assert Enum.map(resource_wires, & &1["params"]["cursor"]) == ["first", "pending"]

      cancellations =
        Enum.filter(wires(ctx.tmp_dir), &(&1["method"] == "notifications/cancelled"))

      assert Enum.map(cancellations, & &1["params"]["requestId"]) == [
               second["identity"]["request_id"]
             ]

      assert {:error, %{reason: :request_timeout}} = Client.await_resource_request(other, 10)
      assert {:ok, release} = Client.start_read_resource(client, "mem://release")
      assert {:ok, _} = Client.await_resource_request(release, 1_000)
      assert {:ok, _} = Client.await_resource_request(other, 1_000)
      assert {:ok, again} = Client.start_read_resource(client, "mem://again")
      assert {:ok, _} = Client.await_resource_request(again, 1_000)
      assert Enum.count(wires(ctx.tmp_dir), &(&1["method"] == "initialize")) == 1
      {parent, result} = tool(parent, "root", "list_agents", %{})
      refute result[:is_error], inspect(result)
      send(parent, {:events, [done()]})
      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
      assert Conversation.status(context.conversation).run.state == :completed
      monitor = Process.monitor(child_pid)
      assert :ok = MultiAgent.close_session(context.manager)
      assert_receive {:DOWN, ^monitor, :process, ^child_pid, _}, 2_000
      refute Process.alive?(provider)
      assert Session.status(context.child_session).phase == :closed
      seal_actual_child_inventory(host, child, status.run)
      assert {:ok, manifest} = MultiAgent.recovery_manifest(context.manager, child.name)

      assert {:ok, %{"retirement" => "confirmed"} = receipt} =
               reconcile_actual(host, manifest, proofs, "child-retired")

      assert {:ok, %{status: :confirmed}} =
               MultiAgent.reconcile_child(context.manager, receipt["receipt_id"])

      assert {:ok, manager_manifest} = MultiAgent.recovery_manifest(context.manager, :manager)

      assert {:ok, %{"retirement" => "confirmed"} = manager_receipt} =
               reconcile_actual(host, manager_manifest, proofs, "manager-retired")

      assert {:ok, %{status: :confirmed}} =
               MultiAgent.reconcile_close(context.manager, manager_receipt["receipt_id"])

      assert {:ok, %{status: :confirmed}} = Session.close(context.root_binding.session)
      assert {:ok, original} = EphemeralStore.load(host.store, child_run)
      assert original.run == status.run
      cleanup_context(context)
    end
  end

  for mode <- [:direct, :deno], phase <- [:between, :empty, :finished, :startup, :attach] do
    @tag mode: mode, pause: phase
    test "#{mode} cancellation at #{phase} retains the exact admitted inventory", ctx do
      {context, roots} = setup_scope(ctx)
      uri = "mem://#{ctx.pause}"
      args = %{"server" => "both", "uri" => uri}
      {name, args} = native_call(ctx.mode, args)
      send(context.provider, {:events, [call(name, args), done()]})
      assert_receive {:scope_pause, phase, owner}, 3_000
      assert phase == ctx.pause
      monitor = Process.monitor(owner)
      assert :ok = Conversation.cancel(context.conversation)
      if phase in [:startup, :attach], do: send(owner, :continue)
      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
      assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
      settled = Conversation.status(context.conversation).run
      assert settled.state == :cancelled
      [evidence] = settled.outcome["cleanup"]["evidence"]

      report =
        if ctx.mode == :deno, do: hd(evidence["nested"])["report"], else: evidence["report"]

      expected =
        case phase do
          :empty -> 0
          :between -> 1
          _ -> 2
        end

      assert report["inventory_count"] == expected
      assert length(report["slots"]) == expected

      if phase in [:empty, :between],
        do: refute(Enum.any?(wires(Enum.at(roots, 1)), &resource_wire?/1))

      if phase == :empty do
        assert report["slots"] == []
        refute Map.has_key?(report, "logical_id")
        refute Map.has_key?(report, "local")
      end

      cleanup_context(context)
    end
  end

  test "scope rejects nested, foreign, reentrant and closed capabilities before starters", ctx do
    {context, _} = setup_scope(ctx)

    {provider, result} =
      tool(context.provider, "root", "read_mcp_resource", %{
        "server" => "both",
        "uri" => "mem://refusals"
      })

    refute result[:is_error]
    assert_receive {:scope_refusals, :unknown_outcome, :unknown_outcome, :unknown_outcome}

    {provider, result} =
      tool(provider, "root", "read_mcp_resource", %{
        "server" => "both",
        "uri" => "mem://stale-scope"
      })

    assert result.refused == :unknown_outcome
    refute_receive :forbidden_start
    finish_context(context, provider)
  end

  test "slot 129 is refused before starter without truncating the 128 real requests", ctx do
    {context, roots} = setup_scope(ctx)

    {provider, result} =
      tool(context.provider, "root", "read_mcp_resource", %{
        "server" => "both",
        "uri" => "mem://limit"
      })

    refute result[:is_error], inspect(result)
    assert result.count == 128
    assert result.overflow == :budget_exceeded
    refute_receive :forbidden_start
    assert Enum.count(wires(hd(roots)), &resource_wire?/1) == 128
    finish_context(context, provider)
  end

  test "missing tracked receipt keeps the raw result and seals subsequent starts", ctx do
    {context, _} = setup_scope(ctx, cleanup_timeout: 80)

    send(
      context.provider,
      {:events,
       [call("read_mcp_resource", %{"server" => "both", "uri" => "mem://missing-proof"}), done()]}
    )

    assert_receive {:scope_missing_proof, {:ok, response},
                    {:error, %Error{class: :unknown_outcome}}},
                   1_000

    assert response.result == %{"contents" => []}
    assert_receive {:scope_pause, :missing_proof, _}
    refute_receive :forbidden_start
    assert :ok = Conversation.cancel(context.conversation)
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert Conversation.status(context.conversation).run.state == :unknown_outcome
    cleanup_context(context)
  end

  test "stale Session admission rejects the scope before the callback", ctx do
    {context, roots} = setup_scope(ctx)

    {provider, result} =
      tool(context.provider, "root", "read_mcp_resource", %{
        "server" => "both",
        "uri" => "mem://stale-session"
      })

    assert result.is_error
    assert result.error.class == :resource_conflict
    refute_receive {:scope_owner, _}
    assert Enum.all?(roots, fn root -> not Enum.any?(wires(root), &resource_wire?/1) end)
    finish_context(context, provider)
  end

  test "ordinary MCP error is preserved and host can continue to the other source", ctx do
    {context, roots} = setup_scope(ctx)

    {provider, result} =
      tool(context.provider, "root", "read_mcp_resource", %{
        "server" => "both",
        "uri" => "mem://raw-error"
      })

    assert result.host_continued
    assert_receive {:scope_raw_results, {:error, error}, {:ok, response}}
    assert error.reason == :server_error
    assert response.result == %{"contents" => []}
    assert Enum.all?(roots, fn root -> Enum.count(wires(root), &resource_wire?/1) == 1 end)

    assert Enum.all?(roots, fn root ->
             not Enum.any?(wires(root), &(&1["method"] == "notifications/cancelled"))
           end)

    finish_context(context, provider)
  end

  test "actual effect owner DOWN cannot synthesize scope cleanup", ctx do
    {context, roots} = setup_scope(ctx, cleanup_timeout: 100)

    send(
      context.provider,
      {:events,
       [call("read_mcp_resource", %{"server" => "both", "uri" => "mem://pending"}), done()]}
    )

    assert_receive {:scope_owner, owner}
    eventually(fn -> Enum.any?(wires(List.last(roots)), &pending?/1) end)
    Process.exit(owner, :kill)
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert Conversation.status(context.conversation).run.state == :unknown_outcome
    assert Conversation.status(context.conversation).run.tool_results == %{}
    refute Enum.any?(wires(hd(roots)), &(&1["method"] == "notifications/cancelled"))
    cleanup_context(context)
  end

  test "coordinator teardown releases the original effect and keeps shared clients usable", ctx do
    {context, roots} = setup_scope(ctx)

    send(
      context.provider,
      {:events,
       [call("read_mcp_resource", %{"server" => "both", "uri" => "mem://pending"}), done()]}
    )

    assert_receive {:scope_owner, owner}
    monitor = Process.monitor(owner)
    eventually(fn -> Enum.any?(wires(List.last(roots)), &pending?/1) end)
    stop_supervised!(:root_conversation)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
    assert {:ok, %{status: :confirmed}} = Session.close(context.root_binding.session)
    stop_supervised!(:resource_manager)
    # Both clients retain their original transport connection after owner cleanup.
    for root <- roots, do: assert(Enum.count(wires(root), &(&1["method"] == "initialize")) == 1)
  end

  test "original finite effect deadline does not permit an admitted starter to dispatch later",
       ctx do
    {context, roots} = setup_scope(ctx, effect_timeout: 80, cleanup_timeout: 80)

    send(
      context.provider,
      {:events,
       [call("read_mcp_resource", %{"server" => "both", "uri" => "mem://startup"}), done()]}
    )

    assert_receive {:scope_pause, :startup, owner}, 1_000
    monitor = Process.monitor(owner)
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert Conversation.status(context.conversation).run.state == :unknown_outcome
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
    send(owner, :continue)
    refute Enum.any?(wires(List.last(roots)), &resource_wire?/1)
    cleanup_context(context)
  end

  defmodule LostAckStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == context.kind do
        {:ok, _} = EphemeralStore.store(context.table, run, meta)
        send(context.test, {:scope_ack_lost, context.kind, run.run_id})

        receive do
          :never_ack -> :never
        end
      else
        EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  for kind <- [:tool_completed, :cleanup_settled] do
    @tag ack_kind: kind
    test "#{kind} Store acknowledgement loss remains recovery-required", ctx do
      {:ok, table} = EphemeralStore.new(1)

      {context, roots} =
        setup_scope(ctx,
          store: LostAckStore,
          context: %{table: table, test: self(), kind: ctx.ack_kind},
          commit_timeout: 100
        )

      uri = if ctx.ack_kind == :tool_completed, do: "mem://done", else: "mem://pending"

      send(
        context.provider,
        {:events, [call("read_mcp_resource", %{"server" => "both", "uri" => uri}), done()]}
      )

      if ctx.ack_kind == :cleanup_settled do
        eventually(fn -> Enum.any?(wires(List.last(roots)), &pending?/1) end)
        assert :ok = Conversation.cancel(context.conversation)
      end

      assert_receive {:scope_ack_lost, _, "root"}, 2_000
      eventually(fn -> Conversation.status(context.conversation).phase == :storage_failed end)
      refute_receive {:resource_provider, "root", _, _}, 30
      assert {:ok, stored} = EphemeralStore.load(table, "root")

      if ctx.ack_kind == :cleanup_settled,
        do: assert(stored.run.outcome["cleanup"]["certainty"] == "confirmed")

      assert Conversation.status(context.conversation).phase == :storage_failed
      cleanup_context(context)
    end
  end

  test "stop fence rejects queued admission after an earlier live deadline read", ctx do
    {context, roots} = setup_scope(ctx)

    send(
      context.provider,
      {:events,
       [call("read_mcp_resource", %{"server" => "both", "uri" => "mem://deadline-race"}), done()]}
    )

    assert_receive {:scope_pause, :deadline_read, owner}, 1_000
    :sys.suspend(context.dynamic)

    try do
      send(owner, :continue)

      # This only controls scheduling; acceptance below uses real dispatch and public run evidence.
      eventually(fn -> elem(Process.info(context.dynamic, :message_queue_len), 1) > 0 end)
      assert :ok = Conversation.cancel(context.conversation)
    after
      :sys.resume(context.dynamic)
    end

    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    refute_receive :forbidden_start
    assert Conversation.status(context.conversation).run.state == :cancelled
    [evidence] = Conversation.status(context.conversation).run.outcome["cleanup"]["evidence"]
    assert evidence["report"]["inventory_count"] == 0
    assert Enum.all?(roots, fn root -> not Enum.any?(wires(root), &resource_wire?/1) end)
    cleanup_context(context)
  end

  defmodule AckBarrierStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      if elem(meta.command, 0) == :tool_completed do
        send(context.test, {:scope_result_pending, self()})

        receive do
          :ack -> :ok
        end
      end

      EphemeralStore.store(context.table, run, meta)
    end
  end

  test "callback completion and owner DOWN retain the inventory until result Store acknowledgement",
       ctx do
    {:ok, table} = EphemeralStore.new(1)

    {context, roots} =
      setup_scope(ctx, store: AckBarrierStore, context: %{table: table, test: self()})

    send(
      context.provider,
      {:events, [call("read_mcp_resource", %{"server" => "both", "uri" => "mem://done"}), done()]}
    )

    assert_receive {:scope_result_pending, writer}, 2_000
    assert_receive {:scope_owner, owner}
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
    assert :ok = Conversation.cancel(context.conversation)
    send(writer, :ack)
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert Conversation.status(context.conversation).run.state == :cancelled

    assert Conversation.status(context.conversation).run.outcome["cleanup"]["certainty"] ==
             "confirmed"

    assert Enum.all?(roots, fn root -> Enum.count(wires(root), &resource_wire?/1) == 1 end)
    cleanup_context(context)
  end

  test "typed aggregate validator rejects malformed inventory and stale scope generation without raising",
       ctx do
    {context, roots} = setup_scope(ctx)

    send(
      context.provider,
      {:events,
       [call("read_mcp_resource", %{"server" => "both", "uri" => "mem://pending"}), done()]}
    )

    assert_receive {:scope_registration, operation, registration}, 1_000
    eventually(fn -> Enum.any?(wires(List.last(roots)), &pending?/1) end)
    assert :ok = Conversation.cancel(context.conversation)
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    [entry] = Conversation.status(context.conversation).run.outcome["cleanup"]["evidence"]
    report = entry["report"]

    operation =
      operation
      |> Map.put(:resource_registration, registration)
      |> Map.put(:stop_generation, report["stop_generation"])

    proof =
      Map.new(report, fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Map.merge(%{
        record_type: :resource_scope_cancellation,
        gate: :sealed,
        local_cleanup: :confirmed,
        remote: :unknown,
        inventory_count: report["inventory_count"],
        slots: List.duplicate(:malformed, report["inventory_count"])
      })

    assertion = %ToolEffects.AggregateCancellation{
      identity: ToolEffects.cancellation_identity(operation),
      evidence: proof
    }

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.validate_cancellation(assertion, operation)

    slots = Enum.map(report["slots"], &native_slot/1)
    valid_proof = proof |> Map.put(:slots, slots) |> Map.put(:inventory_count, length(slots))
    actual = %{assertion | evidence: valid_proof}
    assert {:ok, _} = ToolEffects.validate_cancellation(actual, operation)

    swapped =
      slots
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {slot, index} -> %{slot | index: index} end)

    swapped_proof = %{
      valid_proof
      | slots: swapped,
        inventory_digest: Backplane.AgentRuntime.Codex.Reconciliation.Evidence.digest(swapped)
    }

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.validate_cancellation(%{actual | evidence: swapped_proof}, operation)

    foreign_root = Path.join(ctx.tmp_dir, "foreign")
    File.mkdir_p!(foreign_root)
    foreign = start_client(foreign_root)

    assert {:ok, foreign_handle} =
             Client.start_read_resource(foreign, "mem://done", track_retirement: true)

    assert {:ok, _} = Client.await_resource_request(foreign_handle, 1_000)
    assert {:ok, foreign_identity} = Client.resource_request_identity(foreign_handle)
    assert {:ok, foreign_receipt} = Client.retire_resource_request(foreign_handle)

    substituted = [
      %{hd(slots) | identity: foreign_identity, receipt: foreign_receipt} | tl(slots)
    ]

    substituted_proof = %{
      valid_proof
      | slots: substituted,
        inventory_digest: Backplane.AgentRuntime.Codex.Reconciliation.Evidence.digest(substituted)
    }

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.validate_cancellation(%{actual | evidence: substituted_proof}, operation)

    omitted = Enum.take(slots, 1)

    omitted_proof =
      valid_proof
      |> Map.put(:slots, omitted)
      |> Map.put(:inventory_count, length(omitted))
      |> Map.put(
        :inventory_digest,
        Backplane.AgentRuntime.Codex.Reconciliation.Evidence.digest(omitted)
      )

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.validate_cancellation(%{actual | evidence: omitted_proof}, operation)

    malformed_operation = put_in(operation.resource_scope_admission.gate, make_ref())

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.validate_cancellation(actual, malformed_operation)

    [first | rest] = slots

    for invalid_receipt <- [
          Map.delete(first.receipt, :terminal),
          %{first.receipt | client_incarnation: "foreign"},
          %{first.receipt | request_ids: first.receipt.request_ids ++ first.receipt.request_ids},
          %{first.receipt | request_ids: for(n <- 1..257, do: "wire-#{n}")}
        ] do
      invalid_slots = [%{first | receipt: invalid_receipt} | rest]

      invalid =
        valid_proof
        |> Map.put(:slots, invalid_slots)
        |> Map.put(
          :inventory_digest,
          Backplane.AgentRuntime.Codex.Reconciliation.Evidence.digest(invalid_slots)
        )

      assert {:error, %Error{class: :unknown_outcome}} =
               ToolEffects.validate_cancellation(%{actual | evidence: invalid}, operation)
    end

    assertion = %{assertion | evidence: %{proof | scope_generation: "old"}}

    assert {:error, %Error{class: :unknown_outcome}} =
             ToolEffects.validate_cancellation(assertion, operation)

    cleanup_context(context)
  end

  test "registered scope cancellation before coordinate acknowledgement confirms its real empty inventory",
       ctx do
    {context, roots} = setup_scope(ctx, cleanup_timeout: 200)

    send(
      context.provider,
      {:events,
       [
         call("read_mcp_resource", %{"server" => "both", "uri" => "mem://coordinate-race"}),
         done()
       ]}
    )

    assert_receive {:scope_pause, :coordinate_ack, owner}, 1_000
    monitor = Process.monitor(owner)
    assert :ok = Conversation.cancel(context.conversation)
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
    assert Conversation.status(context.conversation).run.state == :cancelled
    [evidence] = Conversation.status(context.conversation).run.outcome["cleanup"]["evidence"]
    assert evidence["report"]["inventory_count"] == 0
    assert Enum.all?(roots, fn root -> not Enum.any?(wires(root), &resource_wire?/1) end)
    cleanup_context(context)
  end

  test "owner DOWN before Conversation registration releases the unregistered scope", ctx do
    {context, roots} = setup_scope(ctx, cleanup_timeout: 100)

    send(
      context.provider,
      {:events,
       [
         call("read_mcp_resource", %{"server" => "both", "uri" => "mem://pre-registration"}),
         done()
       ]}
    )

    assert_receive {:scope_pause, :before_registration, owner}, 1_000
    Process.exit(owner, :kill)
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert Conversation.status(context.conversation).run.state == :unknown_outcome
    # Bookkeeping leak check only; cleanup acceptance comes from public run evidence above.
    eventually(fn -> :sys.get_state(context.dynamic).resource_requests == %{} end)
    assert Enum.all?(roots, fn root -> not Enum.any?(wires(root), &resource_wire?/1) end)
    cleanup_context(context)
  end

  test "registered owner DOWN before coordinate retains inventory through cleanup Store acknowledgement",
       ctx do
    {:ok, table} = EphemeralStore.new(1)

    {context, roots} =
      setup_scope(ctx,
        store: LostAckStore,
        context: %{table: table, test: self(), kind: :cleanup_settled},
        commit_timeout: 300
      )

    send(
      context.provider,
      {:events,
       [
         call("read_mcp_resource", %{"server" => "both", "uri" => "mem://coordinate-race"}),
         done()
       ]}
    )

    assert_receive {:scope_registration, _, registration}, 1_000
    assert_receive {:scope_pause, :coordinate_ack, owner}, 1_000
    Process.exit(owner, :kill)
    assert_receive {:scope_ack_lost, :cleanup_settled, "root"}, 1_000
    # Observe retention only; an owner DOWN never supplies positive MCP cleanup evidence.
    assert Map.has_key?(:sys.get_state(context.dynamic).resource_requests, registration)
    eventually(fn -> Conversation.status(context.conversation).phase == :storage_failed end)
    eventually(fn -> :sys.get_state(context.dynamic).resource_requests == %{} end)
    assert Enum.all?(roots, fn root -> not Enum.any?(wires(root), &resource_wire?/1) end)
    cleanup_context(context)
  end

  defmodule EventAckStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      kind = elem(meta.command, 0)

      if kind in [:tool_invoked, :tool_completed] do
        send(context.test, {:event_ack_pending, kind, self()})

        receive do
          :ack -> :ok
        end
      end

      EphemeralStore.store(context.table, run, meta)
    end
  end

  @tag native_events: true
  test "Events tool advertisement requires the adapter callback and an explicit source" do
    unavailable = start_supervised!({DynamicRuntime, []}, id: :no_events_adapter)

    refute Enum.any?(
             DynamicRuntime.contracts(%{dynamic_runtime: unavailable}),
             &(&1.name == "mcp_events")
           )

    available = start_supervised!({DynamicRuntime, mcp_adapter: Adapter}, id: :events_adapter)

    event =
      Enum.find(
        DynamicRuntime.contracts(%{dynamic_runtime: available}),
        &(&1.name == "mcp_events")
      )

    assert event.schema["required"] == ["server"]
    assert event.schema["properties"]["cursor"] == %{"type" => "string"}
  end

  @tag native_events: true
  test "ordinary modern HTTP Events retains exact request retirement through both Store ACKs",
       ctx do
    client = start_event_client(ctx.tmp_dir)
    dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
    {:ok, table} = EphemeralStore.new(1)

    context =
      runtime([client], dynamic, store: EventAckStore, context: %{table: table, test: self()})

    args = %{"server" => "explicit", "cursor" => "opaque/+page=汉字"}
    send(context.provider, {:events, [call("mcp_events", args), done()]})
    assert_receive {:event_ack_pending, :tool_invoked, intent_writer}, 2_000
    refute Enum.any?(wires(ctx.tmp_dir), &(&1["method"] == "events/list"))
    send(intent_writer, :ack)
    assert_receive {:event_ack_pending, :tool_completed, result_writer}, 3_000
    assert_receive {:events_owner, owner}
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
    refute_receive {:resource_provider, "root", _, _}, 30
    # Read-only retention observation, not manufactured request/cleanup evidence.
    [entry] = Map.values(:sys.get_state(dynamic).event_requests)
    assert entry.phase == :retired && entry.receipt.schema == :event_retirement
    assert entry.receipt.local_cleanup == :confirmed && entry.receipt.terminal == :completed
    assert entry.identity.method == "events/list"
    assert_receive {:events_reserved, opts}

    assert opts[:track_retirement] &&
             opts[:retirement_deadline] > System.monotonic_time(:millisecond)

    [request] = Enum.filter(wires(ctx.tmp_dir), &(&1["method"] == "events/list"))
    assert request["params"]["cursor"] == args["cursor"]
    send(result_writer, :ack)
    assert_receive {:resource_provider, "root", request, next}, 3_000
    result = Enum.find(Enum.reverse(request.messages), &(&1[:role] == :tool)).result
    assert result[:is_error] === false
    assert Map.delete(result, :is_error) == events_page()
    eventually(fn -> :sys.get_state(dynamic).event_requests == %{} end)
    assert {:ok, again} = Client.start_list_events(client, cursor: "fresh")
    assert {:ok, response} = Client.await_event_request(again, 1_000)
    assert response.result == Map.delete(result, :is_error)
    assert Enum.count(wires(ctx.tmp_dir), &(&1["method"] == "server/discover")) == 1
    refute Enum.any?(wires(ctx.tmp_dir), &(&1["method"] == "notifications/cancelled"))
    finish_context(context, next)
  end

  for mode <- [:direct, :deno] do
    @tag mode: mode, native_events: true
    test "#{mode} Events interruption retains the actual request through complete child retirement",
         ctx do
      client = start_event_client(ctx.tmp_dir)
      dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
      host = Host.new()
      context = runtime([client], dynamic, recovery_host: host)

      {parent, _} =
        tool(context.provider, "root", "spawn_agent", %{
          "task_name" => "worker",
          "message" => "browse Events"
        })

      assert_receive {:resource_provider, child_run, _, provider}, 2_000

      {name, input} =
        if ctx.mode == :direct,
          do: {"mcp_events", %{"server" => "explicit", "cursor" => "pending"}},
          else:
            {"exec", "return await tools.mcp_events({server: 'explicit', cursor: 'pending'});"}

      send(provider, {:events, [call(name, input), done()]})
      assert_receive {:events_owner, effect_owner}, 3_000
      effect_monitor = Process.monitor(effect_owner)
      eventually(fn -> Enum.any?(wires(ctx.tmp_dir), &pending?/1) end)
      assert {:ok, other} = Client.start_read_resource(client, "mem://survivor-pending")
      assert {:error, %{reason: :request_timeout}} = Client.await_resource_request(other, 10)
      {parent, result} = tool(parent, "root", "interrupt_agent", %{"target" => "/root/worker"})
      refute result[:is_error], inspect(result)
      assert_receive {:DOWN, ^effect_monitor, :process, ^effect_owner, _}, 1_000
      assert {:ok, snapshot} = MultiAgent.snapshot(context.manager)
      [child] = snapshot.agents
      assert child.run_id == child_run && child.cleanup == :confirmed
      child_pid = :sys.get_state(context.manager).agents[child.name].pid
      status = Conversation.status(child_pid)
      assert status.run.state == :cancelled
      proofs = status.retirement_evidence
      event = Enum.find(proofs, &(&1["record_type"] == "event_request_retirement"))
      assert is_map(event) && event["executor_down"] && event["resources"] == "confirmed"
      assert event["outcome"] == "unknown" && event["local_cleanup"] == "confirmed"
      receipt = event["cancellation"]["receipt"]
      assert receipt["schema"] == "event_retirement" && receipt["terminal"] == "cancelled"
      assert receipt["request_ids"] == [event["cancellation"]["request_identity"]["request_id"]]
      assert {:ok, original} = EphemeralStore.load(host.store, child_run)
      assert original.run == status.run
      retained = retained_records(original.run.outcome["cleanup"]["evidence"])
      assert Enum.all?(proofs, &(&1 in retained))

      if ctx.mode == :deno do
        outer = Enum.find(proofs, &(&1["record_type"] == "code_mode_retirement"))

        assert Enum.any?(
                 outer["nested"],
                 &(&1["kind"] == "event_request_retirement" &&
                     &1["evidence_digest"] == event["retirement_digest"])
               )
      end

      cancellations =
        Enum.filter(wires(ctx.tmp_dir), &(&1["method"] == "notifications/cancelled"))

      assert Enum.map(cancellations, & &1["params"]["requestId"]) == receipt["request_ids"]
      assert {:error, %{reason: :request_timeout}} = Client.await_resource_request(other, 10)
      assert {:ok, release} = Client.start_read_resource(client, "mem://release")
      assert {:ok, _} = Client.await_resource_request(release, 1_000)
      assert {:ok, _} = Client.await_resource_request(other, 1_000)
      assert {:ok, again} = Client.start_list_events(client, cursor: "fresh")
      assert {:ok, response} = Client.await_event_request(again, 1_000)
      assert response.result == events_page()
      assert Enum.count(wires(ctx.tmp_dir), &(&1["method"] == "server/discover")) == 1
      send(parent, {:events, [done()]})
      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
      assert Conversation.status(context.conversation).run.state == :completed
      monitor = Process.monitor(child_pid)
      assert :ok = MultiAgent.close_session(context.manager)
      assert_receive {:DOWN, ^monitor, :process, ^child_pid, _}, 2_000
      refute Process.alive?(provider)
      assert Session.status(context.child_session).phase == :closed
      seal_actual_child_inventory(host, child, status.run)
      assert {:ok, manifest} = MultiAgent.recovery_manifest(context.manager, child.name)

      assert {:ok, %{"retirement" => "confirmed"} = reconciled} =
               reconcile_actual(host, manifest, proofs, "events-child")

      assert {:ok, %{status: :confirmed}} =
               MultiAgent.reconcile_child(context.manager, reconciled["receipt_id"])

      changed =
        event
        |> put_in(["cancellation", "request_identity", "client_incarnation"], "substitution")
        |> put_in(["cancellation", "receipt", "client_incarnation"], "substitution")
        |> Evidence.seal("retirement_digest")

      replaced = Enum.map(proofs, fn p -> if p == event, do: changed, else: p end)

      assert {:error, %Error{class: :unknown_outcome}} =
               reconcile_actual(host, manifest, replaced, "events-substituted")

      assert {:ok, manager_manifest} = MultiAgent.recovery_manifest(context.manager, :manager)

      assert {:ok, %{"retirement" => "confirmed"} = manager_receipt} =
               reconcile_actual(host, manager_manifest, proofs, "events-manager")

      assert {:ok, %{status: :confirmed}} =
               MultiAgent.reconcile_close(context.manager, manager_receipt["receipt_id"])

      assert {:ok, %{status: :confirmed}} = Session.close(context.root_binding.session)
      cleanup_context(context)
    end
  end

  for mode <- [:direct, :deno] do
    @tag mode: mode, native_events: true
    test "#{mode} Events owner DOWN cannot acknowledge an unretired request", ctx do
      client = start_event_client(ctx.tmp_dir)
      dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
      context = runtime([client], dynamic, cleanup_timeout: 100)

      {name, args} =
        if ctx.mode == :direct,
          do: {"mcp_events", %{"server" => "explicit", "cursor" => "pending"}},
          else:
            {"exec", "return await tools.mcp_events({server: 'explicit', cursor: 'pending'});"}

      send(context.provider, {:events, [call(name, args), done()]})
      assert_receive {:events_owner, owner}, 2_000
      eventually(fn -> Enum.any?(wires(ctx.tmp_dir), &pending?/1) end)
      Process.exit(owner, :kill)
      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
      status = Conversation.status(context.conversation)
      assert status.run.state == :unknown_outcome
      assert status.run.tool_results == %{}
      assert status.retirement_evidence == []
      [entry] = Map.values(:sys.get_state(dynamic).event_requests)
      assert entry.receipt == nil
      refute_receive {:resource_provider, "root", _, _}, 30
      assert {:ok, again} = Client.start_list_events(client)
      assert {:ok, _} = Client.await_event_request(again, 1_000)
      cleanup_context(context)
    end
  end

  @tag native_events: true
  for cursor <- ["untracked", "wrong-family"] do
    @tag cursor: cursor, native_events: true
    test "#{cursor} Events retirement cannot publish the consumed page as normal success", ctx do
      client = start_event_client(ctx.tmp_dir)
      dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
      context = runtime([client], dynamic, cleanup_timeout: 80)

      send(
        context.provider,
        {:events, [call("mcp_events", %{"server" => "explicit", "cursor" => ctx.cursor}), done()]}
      )

      eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
      status = Conversation.status(context.conversation)
      assert status.run.state == :unknown_outcome
      assert status.retirement_evidence == []
      assert status.run.tool_results == %{}
      [entry] = Map.values(:sys.get_state(dynamic).event_requests)
      assert entry.phase == :uncertain
      assert entry.receipt == nil
      method = if ctx.cursor == "untracked", do: "events/list", else: "resources/list"
      assert Enum.count(wires(ctx.tmp_dir), &(&1["method"] == method)) == 1
      refute_receive {:resource_provider, "root", _, _}, 30
      assert {:ok, another} = Client.start_list_events(client)
      assert {:ok, response} = Client.await_event_request(another, 1_000)
      assert response.result == events_page()
      cleanup_context(context)
    end
  end

  @tag native_events: true
  test "lost Events result ACK retains exact terminal retirement and blocks provider continuation",
       ctx do
    client = start_event_client(ctx.tmp_dir)
    dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
    {:ok, table} = EphemeralStore.new(1)

    context =
      runtime([client], dynamic,
        store: LostAckStore,
        context: %{table: table, test: self(), kind: :tool_completed},
        commit_timeout: 100
      )

    send(context.provider, {:events, [call("mcp_events", %{"server" => "explicit"}), done()]})
    assert_receive {:scope_ack_lost, :tool_completed, "root"}, 2_000
    [entry] = Map.values(:sys.get_state(dynamic).event_requests)
    assert entry.phase == :retired && entry.receipt.local_cleanup == :confirmed
    eventually(fn -> Conversation.status(context.conversation).phase == :storage_failed end)
    [retained] = Map.values(:sys.get_state(dynamic).event_requests)

    assert Map.drop(retained, [:monitor, :coordinator_monitor]) ==
             Map.drop(entry, [:monitor, :coordinator_monitor])

    refute_receive {:resource_provider, "root", _, _}, 30
    assert {:ok, stored} = EphemeralStore.load(table, "root")
    assert map_size(stored.run.tool_results) == 1
    assert Enum.count(wires(ctx.tmp_dir), &(&1["method"] == "events/list")) == 1
    cleanup_context(context)

    eventually(fn ->
      case Map.values(:sys.get_state(dynamic).event_requests) do
        [%{coordinator_monitor: nil}] -> true
        _ -> false
      end
    end)

    [after_exit] = Map.values(:sys.get_state(dynamic).event_requests)
    assert :atomics.get(after_exit.gate, 1) >= 2

    assert Map.drop(after_exit, [:monitor, :coordinator_monitor]) ==
             Map.drop(entry, [:monitor, :coordinator_monitor])
  end

  defp start_event_client(root) do
    fixture = Path.expand("../../fixtures/events_http_mcp.py", __DIR__)
    caller = self()

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, System.find_executable("python3")}, [
            :binary,
            :exit_status,
            args: [fixture, Path.join(root, "wire.jsonl")]
          ])

        receive do
          {^port, {:data, data}} -> send(caller, {:event_http_port, self(), data})
        end

        receive do
          :stop ->
            Port.command(port, "stop\n")

            receive do
              {^port, {:exit_status, 0}} -> :ok
              {^port, {:exit_status, code}} -> exit({:fixture_exit, code})
            after
              2_000 ->
                Port.close(port)
                exit(:fixture_exit_unconfirmed)
            end
        end
      end)

    on_exit(fn ->
      monitor = Process.monitor(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 3_000
    end)

    assert_receive {:event_http_port, ^owner, data}, 2_000
    {number, _} = Integer.parse(data)
    name = String.to_atom("RuntimeEvents#{System.unique_integer([:positive])}")

    start_supervised!(
      {Client,
       name: name,
       transport: {:streamable_http, url: "http://127.0.0.1:#{number}/mcp"},
       one_shot: true,
       client_info: %{"name" => "native-events", "version" => "1"},
       capabilities: %{},
       protocol_version: "2026-07-28",
       timeout: 3_000}
    )

    assert :ok = Client.await_ready(name, timeout: 3_000)
    name
  end

  defp events_page,
    do: %{
      "events" => [
        %{
          "name" => "changed",
          "title" => "Changed 汉字",
          "description" => "first",
          "schema" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}},
          "_meta" => %{"fixture/order" => 1}
        },
        %{"name" => "deleted", "description" => "second", "schema" => %{"type" => "object"}}
      ],
      "nextCursor" => "opaque/+next=汉字",
      "_meta" => %{"fixture/page" => [2, true, nil]}
    }

  defp assert_retirement_records(store, status, mode) do
    proofs = status.retirement_evidence
    resource = Enum.find(proofs, &(&1["record_type"] == "resource_scope_retirement"))
    assert is_map(resource)
    assert resource["executor_down"] == true
    assert resource["resources"] == "confirmed"
    assert resource["local_cleanup"] == "confirmed"
    assert resource["outcome"] == "unknown"
    assert {:ok, stored} = EphemeralStore.load(store, status.run.run_id)
    assert stored.run == status.run
    retained = retained_records(stored.run.outcome["cleanup"]["evidence"])
    assert Enum.all?(proofs, &(&1 in retained))

    assert :erlang.term_to_binary(resource) ==
             :erlang.term_to_binary(Enum.find(retained, &(&1 == resource)))

    if mode == :deno do
      outer = Enum.find(proofs, &(&1["record_type"] == "code_mode_retirement"))
      assert is_map(outer)
      assert outer["executor_down"] && outer["resources"] == "confirmed"
      assert outer["stop_generation"] == resource["stop_generation"]
      assert resource["identity"]["enclosing_invocation_id"] == outer["identity"]["invocation_id"]

      assert Enum.find(outer["nested"], &(&1["kind"] == "resource_scope_retirement")) == %{
               "kind" => "resource_scope_retirement",
               "identity" => resource["identity"],
               "evidence_digest" => resource["retirement_digest"]
             }
    end

    proofs
  end

  defp retained_records(%{"record_type" => type} = record)
       when type in [
              "resource_scope_retirement",
              "event_request_retirement",
              "code_mode_retirement"
            ],
       do: [record]

  defp retained_records(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&retained_records/1)

  defp retained_records(value) when is_list(value), do: Enum.flat_map(value, &retained_records/1)
  defp retained_records(_), do: []

  defp assert_cold_reconciliation(host, run, proofs, binding, mode) do
    {:ok, obligations} = Reconciliation.run_obligations(run, run.incarnation, "actual-owner")

    subject = %{
      "kind" => "session",
      "scope_id" => "scope",
      "owner_id" => binding.owner_id,
      "incarnation" => binding.incarnation
    }

    refs = [
      %{
        "store_ref" => "original",
        "run_id" => run.run_id,
        "original_incarnation" => run.incarnation
      }
    ]

    manifest = Host.manifest(subject, refs, obligations)

    assert {:ok, %{"retirement" => "confirmed"}} =
             reconcile_actual(host, manifest, proofs, "cold")

    resource = Enum.find(proofs, &(&1["record_type"] == "resource_scope_retirement"))
    [first | rest] = resource["cancellation"]["slots"]

    replacement =
      first
      |> put_in(["identity", "client_incarnation"], "different-client")
      |> put_in(["receipt", "client_incarnation"], "different-client")

    slots = [replacement | rest]

    changed =
      resource
      |> put_in(["cancellation", "slots"], slots)
      |> put_in(["cancellation", "inventory_digest"], Evidence.digest(slots))
      |> Evidence.seal("retirement_digest")

    altered = Enum.map(proofs, fn p -> if p == resource, do: changed, else: p end)

    assert {:error, %Error{class: :unknown_outcome}} =
             reconcile_actual(host, manifest, altered, "replaced-#{mode}")
  end

  defp reconcile_actual(host, manifest, proofs, id) do
    observations =
      Enum.map(manifest["obligations"], fn obligation ->
        fact = Host.observe(obligation, "closed")

        if obligation["kind"] == "tool" do
          invocation = obligation["identity"]["invocation_id"]
          proof = Enum.find(proofs, &(&1["identity"]["invocation_id"] == invocation))
          assert is_map(proof)
          ref = id <> ":effect:" <> invocation
          :ok = Host.put(host, {:evidence, ref}, proof)
          Map.put(fact, "effect_retirement_ref", ref)
        else
          fact
        end
      end)

    :ok = Host.put(host, {:evidence, id}, Host.bundle(manifest, observations))
    Reconciliation.reconcile(Host.config(host), Host.request(manifest, id, id))
  end

  defp recovery_admission(host, request, parent, options) do
    identity = parent.child.recovery_identity
    ref = "admission:" <> parent.child.attempt_id
    {:ok, request} = Evidence.public(request)

    {:ok, ceiling} =
      Evidence.public(
        Map.take(options[:authority], [:grants, :tool_revisions, :tool_bindings, :tool_revision])
      )

    configuration = %{"provider_ref" => "resource-provider", "profile" => "native-resource"}

    admission = %{
      "schema_version" => 1,
      "record_type" => "child_admission",
      "child_identity" => identity,
      "store_ref" => "source",
      "config_ref" => ref <> ":config",
      "authority_ceiling_ref" => ref <> ":ceiling",
      "tool_profile" => request["profile"],
      "admission_receipt_ref" => ref,
      "child_request" => request,
      "configuration" => configuration,
      "authority_ceiling" => ceiling,
      "artifact_refs" => [],
      "inventory_ref" => ref <> ":inventory"
    }

    :ok = Host.put(host, {:evidence, ref}, admission)
    :ok = Host.put(host, {:evidence, admission["config_ref"]}, configuration)
    :ok = Host.put(host, {:evidence, admission["authority_ceiling_ref"]}, ceiling)
    :ok = Host.put(host, {:store, "source"}, {EphemeralStore, host.store})

    Keyword.merge(options,
      context: host.store,
      recovery_admission_ref: ref,
      recovery_store_ref: "source",
      recovery_config_ref: admission["config_ref"],
      recovery_authority_ref: admission["authority_ceiling_ref"],
      recovery_tool_profile: String.to_existing_atom(request["profile"])
    )
  end

  defp seal_actual_child_inventory(host, child, run) do
    ref = "admission:" <> child.attempt_id
    {:ok, admission} = Host.load_evidence(host, ref)
    {:ok, obligations} = Reconciliation.run_obligations(run, run.incarnation, "actual-runtime")

    :ok =
      Host.put(host, {:evidence, admission["inventory_ref"]}, %{
        "schema_version" => 1,
        "record_type" => "child_inventory",
        "child_identity" => admission["child_identity"],
        "complete" => true,
        "producer_ref" => "actual-managed-child-owner-ledger",
        "obligations" => obligations
      })
  end

  defp native_slot(slot) do
    receipt =
      Map.new(slot["receipt"], fn {key, value} -> {String.to_existing_atom(key), value} end)

    receipt =
      Enum.reduce([:schema, :terminal, :local, :local_cleanup, :remote], receipt, fn key, acc ->
        Map.update!(acc, key, &String.to_existing_atom/1)
      end)

    cleanup = receipt.cleanup_evidence

    receipt = %{
      receipt
      | cleanup_evidence: %{
          workers_down: cleanup["workers_down"],
          worker_count: cleanup["worker_count"],
          transport: String.to_existing_atom(cleanup["transport"])
        }
    }

    %{
      index: slot["index"],
      identity:
        Map.new(slot["identity"], fn {key, value} -> {String.to_existing_atom(key), value} end),
      receipt: receipt,
      phase: :retired
    }
  end

  defp setup_scope(ctx, opts \\ []) do
    roots =
      for source <- ["a", "b"] do
        root = Path.join(ctx.tmp_dir, source)
        File.mkdir_p!(root)
        root
      end

    clients = Enum.map(roots, &start_client/1)
    dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
    {runtime(clients, dynamic, opts), roots}
  end

  defp native_call(:direct, args), do: {"read_mcp_resource", args}

  defp native_call(:deno, args),
    do: {"exec", "return await tools.read_mcp_resource(#{JSON.encode!(args)});"}

  defp resource_wire?(wire),
    do: wire["method"] in ["resources/list", "resources/templates/list", "resources/read"]

  defp cleanup_context(_context) do
    stop_supervised!(:root_conversation)
    stop_supervised!(:resource_manager)
  end

  defp finish_context(context, provider) do
    send(provider, {:events, [done()]})
    eventually(fn -> Conversation.status(context.conversation).phase == :terminal end)
    assert Conversation.status(context.conversation).run.state == :completed
    assert {:ok, %{status: :confirmed}} = Session.close(context.root_binding.session)
    cleanup_context(context)
  end

  defp start_client(root, fixture_name \\ "resource_scope_mcp.py") do
    name = String.to_atom("RuntimeResource#{System.unique_integer([:positive])}")
    fixture = Path.expand("../../fixtures/" <> fixture_name, __DIR__)

    start_supervised!(
      {Client,
       name: name,
       transport:
         {:stdio,
          command: System.find_executable("python3"),
          args: [fixture, Path.join(root, "wire.jsonl")]},
       one_shot: true,
       client_info: %{"name" => "runtime-resource", "version" => "1"},
       capabilities: %{},
       protocol_version: "2025-11-25",
       timeout: 3_000}
    )

    assert :ok = Client.await_ready(name, timeout: 3_000)
    name
  end

  defp runtime(client, dynamic, child_overrides \\ []) do
    test = self()
    {recovery_host, child_overrides} = Keyword.pop(child_overrides, :recovery_host)

    recovery =
      if recovery_host,
        do: [recovery: Host.config(recovery_host), recovery_scope_id: "scope"],
        else: []

    root = start_supervised!({Session, [owner_pid: test] ++ recovery}, id: :root_session)

    host =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(host, :stop) end)
    child = start_supervised!({Session, [owner_pid: host] ++ recovery}, id: :child_session)
    table = :ets.new(:resource_contracts, [:public])
    names = @resources ++ @collaboration ++ ["exec", "wait", "mcp_events"]
    authority = authority("root", names)

    manager =
      start_supervised!(
        {MultiAgent,
         [root_agent_id: "root-agent"] ++
           recovery ++
           [
             parent_run_id: "root",
             parent_name: "/root",
             parent_authority: authority,
             min_wait_timeout_ms: 0,
             child_options: fn request, run, parent ->
               child_opts =
                 options(
                   child,
                   run,
                   parent.child.incarnation,
                   names,
                   :ets.lookup_element(table, :contracts, 2),
                   test
                 )

               child_opts = Keyword.merge(child_opts, child_overrides)

               child_opts =
                 if recovery_host,
                   do: recovery_admission(recovery_host, request, parent, child_opts),
                   else: child_opts

               {:ok, child_opts}
             end
           ]},
        id: :resource_manager
      )

    contracts =
      MultiAgent.contracts(:v2, manager) ++
        Enum.map(DynamicRuntime.contracts(%{dynamic_runtime: dynamic}), fn contract ->
          contract
          |> put_in([:backend_context, :client], client)
          |> put_in([:backend_context, :test], test)
        end)

    :ets.insert(table, {:contracts, contracts})
    opts = Keyword.merge(options(root, "root", 1, names, contracts, test), child_overrides)
    conversation = start_supervised!({Conversation, opts}, id: :root_conversation)
    assert {:ok, _} = Conversation.prompt(conversation, "start")
    assert_receive {:resource_provider, "root", _, provider}, 1_000

    %{
      manager: manager,
      conversation: conversation,
      provider: provider,
      root_binding: opts[:session_binding],
      dynamic: dynamic,
      store: opts[:context],
      child_session: child
    }
  end

  defp options(session, run, incarnation, names, contracts, test) do
    bindings =
      Map.new(
        for c <- contracts,
            Map.has_key?(c, :collaboration_binding),
            do: {c.tool_name, c.collaboration_binding.fingerprint}
      )

    auth = Map.put(authority(run, names), :tool_bindings, bindings)
    {:ok, binding} = Session.bind(session, auth, incarnation: incarnation)

    {:ok, profile} =
      Codex.profile(:mixed, %{session_binding: binding, code_mode_contracts: contracts}, auth,
        tools: names
      )

    {:ok, store} = EphemeralStore.new(incarnation)

    [
      run_id: run,
      incarnation: incarnation,
      session_binding: binding,
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: test},
      run_timeout: 20_000,
      effect_timeout: 10_000,
      cleanup_timeout: 2_000
    ]
  end

  defp authority(run, names), do: %{caller: "host", run_id: run, grants: names, tool_revision: 1}

  defp call(name, arguments),
    do: %{
      type: :tool_call_completed,
      tool_call: %{
        id: "call-#{System.unique_integer([:positive])}",
        name: name,
        arguments: arguments
      }
    }

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp tool(provider, run, name, arguments) do
    send(provider, {:events, [call(name, arguments), done()]})
    assert_receive {:resource_provider, ^run, request, next}, 6_000
    message = Enum.find(Enum.reverse(request.messages), &(&1[:role] == :tool))
    {next, message.result}
  end

  defp wires(root) do
    case File.read(Path.join(root, "wire.jsonl")) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  defp pending?(wire),
    do:
      get_in(wire, ["params", "cursor"]) == "pending" or
        get_in(wire, ["params", "uri"]) == "mem://pending"

  defp eventually(fun, left \\ 300)
  defp eventually(_, 0), do: flunk("resource lifecycle did not settle")

  defp eventually(fun, left) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, left - 1)
        )
  end
end
