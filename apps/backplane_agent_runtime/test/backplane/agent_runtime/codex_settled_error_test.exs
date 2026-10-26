defmodule Backplane.AgentRuntime.CodexSettledErrorTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Command, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry, Session, Tools}
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defmodule Opaque do
    defstruct [:value]
  end

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

  setup do
    assert is_binary(System.find_executable("deno")), "these regressions require real Deno"
    assert CodeMode.lifecycle_capability(%{}) == :verified
    %{registry: start_supervised!(ResourceRegistry)}
  end

  for tuple <- [:two, :three] do
    test "real Deno inspects settled native errors and continues with #{tuple}-element success",
         ctx do
      tuple = unquote(tuple)
      test = self()

      nested = Error.new(:forbidden, "nested", details: %{reason: "界"}, cause: self())

      error =
        Error.new(:not_found, "command session is unknown",
          details: %{nested: [nested], kept: [nil, true, 7]},
          cause: make_ref()
        )

      result = %{is_error: true, error: error, extra: [%{other: error}], encoded: ~D[2026-10-26]}

      dispatcher = fn request, context ->
        send(test, {:dispatch, request.tool_name, context})

        case request.tool_name do
          "expired" ->
            success_tuple(tuple, result, context)

          "next" ->
            {:ok, %{continued: true}}
        end
      end

      code = """
      const expired = await codex.tool('expired', {});
      if (!expired.is_error || expired.error.class !== 'not_found') throw new Error('lost settled error');
      const next = await codex.tool('next', {});
      return {expired, next};
      """

      assert {:ok, %{status: :completed, value: value}} =
               CodeMode.execute(ctx.registry, "settled", code, opts(dispatcher))

      assert value["next"] == %{"continued" => true}
      assert value["expired"]["encoded"] == "2026-10-26"
      public = value["expired"]["error"]

      assert public == %{
               "class" => "not_found",
               "message" => "command session is unknown",
               "details" => %{
                 "nested" => [
                   %{
                     "class" => "forbidden",
                     "message" => "nested",
                     "details" => %{"reason" => "界"}
                   }
                 ],
                 "kept" => [nil, true, 7]
               }
             }

      assert value["expired"]["extra"] == [%{"other" => public}]
      assert_receive {:dispatch, "expired", %{revision: 1}}
      assert_receive {:dispatch, "next", next_context}
      assert next_context.revision == unquote(if tuple == :three, do: 2, else: 1)
      refute_receive {:dispatch, _, _}, 50
      assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, "settled")
    end
  end

  test "unsupported result values fail after settlement with confirmed cleanup", ctx do
    values = [
      self(),
      fn -> :secret end,
      make_ref(),
      {:unsupported, :tuple},
      %Opaque{value: "private"},
      %{{:unsupported, :key} => "bad key"},
      <<255>>
    ]

    for value <- values, envelope <- [:ordinary, :details, :transport] do
      test = self()

      dispatcher = fn request, context ->
        send(test, {:dispatch, request.tool_name})

        case envelope do
          :ordinary ->
            {:ok, %{value: value}, Map.put(context, :revision, 2)}

          :details ->
            {:ok, %{is_error: true, error: Error.new(:not_found, "gone", details: %{bad: value})}}

          :transport ->
            {:error, Error.new(:forbidden, "denied", details: %{bad: value})}
        end
      end

      assert {:error, %Error{class: :malformed_result, cause: nil, details: %{}}} =
               CodeMode.execute(
                 ctx.registry,
                 "invalid",
                 "await codex.tool('first', {}); await codex.tool('later', {});",
                 opts(dispatcher)
               )

      assert_receive {:dispatch, "first"}
      refute_receive {:dispatch, _}, 10
      assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, "invalid")
    end
  end

  test "settled context and active marker update before an encoding failure", _ctx do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])
    {:os_pid, pid} = Port.info(port, :os_pid)
    [_, fields] = Regex.run(~r/^\d+ \(.*\) (.+)$/s, File.read!("/proc/#{pid}/stat"))
    reply = make_ref()
    ref = make_ref()

    state = %{
      port: port,
      os_identity: %{pid: pid, starttime: Enum.at(String.split(fields), 19)},
      os_cleanup_status: :not_requested,
      active_tool: %{ref: ref, id: "1"},
      context: %{revision: 1},
      from: {self(), reply},
      timer: nil,
      awaiting_resume: false
    }

    assert {:stop, :normal, final} =
             CodeMode.Worker.handle_info({ref, {:ok, self(), %{revision: 2}}}, state)

    assert final.context == %{revision: 2}
    assert final.active_tool == nil
    assert final.os_cleanup_status == :ok
    assert_receive {^reply, {:error, %Error{class: :malformed_result, cause: nil}}}
  end

  test "transport errors project nested public details and can be caught", ctx do
    test = self()

    dispatcher = fn request, _ ->
      send(test, {:dispatch, request.tool_name})

      case request.tool_name do
        "denied" ->
          {:error,
           Error.new(:forbidden, "denied",
             details: %{nested: Error.new(:not_found, "gone", cause: self())},
             cause: make_ref()
           )}

        "next" ->
          {:ok, 42}
      end
    end

    code = """
    let denied;
    try { await codex.tool('denied', {}); } catch (error) { denied = error.message; }
    return {denied, next: await codex.tool('next', {})};
    """

    assert {:ok, %{value: value}} =
             CodeMode.execute(ctx.registry, "caught", code, opts(dispatcher))

    assert value == %{"denied" => "denied", "next" => 42}
    assert_receive {:dispatch, "denied"}
    assert_receive {:dispatch, "next"}
    refute_receive {:dispatch, _}, 50
  end

  test "UTF-8 result records honor the exact byte bound excluding newline", ctx do
    limit = 1_048_576
    overhead = byte_size(JSON.encode!(%{type: "tool_result", id: "1", ok: true, value: ""}))
    bytes = limit - overhead
    value = String.duplicate("界", div(bytes, 3)) <> String.duplicate("x", rem(bytes, 3))

    assert byte_size(JSON.encode!(%{type: "tool_result", id: "1", ok: true, value: value})) ==
             limit

    assert {:ok, %{status: :completed, value: ^bytes}} =
             CodeMode.execute(
               ctx.registry,
               "exact",
               "return new TextEncoder().encode(await codex.tool('echo', {})).length;",
               opts(fn _, _ -> {:ok, value} end)
             )

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.execute(
               ctx.registry,
               "over",
               "return await codex.tool('echo', {});",
               opts(fn _, _ -> {:ok, value <> "x"} end)
             )

    assert {:ok, []} = ResourceRegistry.owner_status(ctx.registry, "over")
  end

  test "explicit unknown outcome remains terminal and never dispatches later effects", ctx do
    test = self()

    dispatcher = fn request, _ ->
      send(test, {:dispatch, request.tool_name})
      {:error, Error.new(:unknown_outcome, "unconfirmed effect", details: %{private: self()})}
    end

    assert {:error, %Error{class: :unknown_outcome, message: "unconfirmed effect"}} =
             CodeMode.execute(
               ctx.registry,
               "uncertain",
               "try { await codex.tool('first', {}); } catch (_) {} await codex.tool('later', {});",
               opts(dispatcher)
             )

    assert_receive {:dispatch, "first"}
    refute_receive {:dispatch, _}, 50
  end

  test "unconfirmed real Deno cleanup remains terminal after settled encoding failure", ctx do
    test = self()

    dispatcher = fn request, _context ->
      send(test, {:blocked_dispatch, request.tool_name, self()})

      receive do
        :settle -> {:ok, self()}
      end
    end

    task =
      Task.async(fn ->
        CodeMode.execute(
          ctx.registry,
          "cleanup",
          "await codex.tool('first', {}); await codex.tool('later', {});",
          opts(dispatcher)
        )
      end)

    assert_receive {:blocked_dispatch, "first", dispatch}, 3_000
    on_exit(fn -> send(dispatch, :settle) end)
    {:ok, supervisor} = ResourceRegistry.worker_supervisor(ctx.registry)
    [{_, worker, _, _}] = DynamicSupervisor.which_children(supervisor)
    worker_ref = Process.monitor(worker)
    %{port: port} = :sys.get_state(worker)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    # Exercise a genuine unavailable-identity cleanup result while still owning
    # and closing the real Deno port; never report that cleanup as confirmed.
    :sys.replace_state(worker, &%{&1 | os_identity: nil})
    send(dispatch, :settle)
    assert {:error, %Error{class: :unknown_outcome}} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 3_000
    refute_receive {:blocked_dispatch, "later", _}, 50

    case File.read("/proc/#{os_pid}/stat") do
      {:error, :enoent} -> :ok
      {:ok, stat} -> assert Regex.match?(~r/\) [ZX] /, stat)
    end
  end

  test "public Session command handle errors cross real Deno without rewriting native settlement",
       ctx do
    server = start_supervised!({LocalCommand, name: nil})
    session = start_supervised!({Session, owner_pid: self()})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    names = ~w(exec_command write_stdin exec wait)
    authority = %{caller: "host", run_id: "completed-handle", grants: names, tool_revision: 1}
    {:ok, binding} = Session.bind(session, authority)

    context = %{
      command: command,
      workspace: ctx.tmp_dir,
      caller: %{run_id: authority.run_id},
      session_binding: binding,
      resource_registry: binding.resource_registry,
      session_registry: binding.resource_registry
    }

    targets = Enum.filter(Tools.contracts(context), &(&1.name in ~w(exec_command write_stdin)))

    {:ok, profile} =
      Codex.profile(:mixed, Map.put(context, :code_mode_contracts, targets), authority,
        tools: names
      )

    {:ok, store} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: authority.run_id,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{test: self()},
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         schema_admission: :strict,
         run_timeout: 15_000,
         effect_timeout: 5_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "complete then reuse command")
    assert_receive {:provider, _, provider}, 3_000

    call(provider, "start", "exec_command", %{
      "cmd" => "IFS= read -r line; printf '%s' \"$line\"",
      "shell" => "/bin/sh",
      "login" => false,
      "yield_time_ms" => 0
    })

    assert_receive {:provider, %{messages: messages}, provider}, 3_000
    assert %{status: :running, session_id: handle} = List.last(messages).result

    call(provider, "complete", "write_stdin", %{
      "session_id" => handle,
      "chars" => "finished\n",
      "yield_time_ms" => 1_000
    })

    assert_receive {:provider, %{messages: messages}, provider}, 3_000

    assert %{status: :completed, exit_code: 0, output: "finished", cleanup_status: :confirmed} =
             List.last(messages).result

    {:ok, before} = EphemeralStore.load(store, authority.run_id)

    original =
      Enum.find(before.run.tool_results, fn {_id, result} ->
        match?(%{exit_code: 0, output: "finished"}, result)
      end)

    assert {original_id, original_result} = original

    code = """
    const expired = await tools.write_stdin({session_id: #{handle}, chars: 'unused\\n'});
    if (!expired.is_error || expired.error.class !== 'not_found') throw new Error('expected expired handle');
    const next = await tools.exec_command({cmd: "printf x >> next-count; printf continued", shell: '/bin/sh', login: false});
    return {expired, output: next.output, exit_code: next.exit_code};
    """

    call(provider, "nested", "exec", code)
    assert_receive {:provider, %{messages: messages}, provider}, 5_000
    assert %{status: :completed, is_error: false, value: value} = List.last(messages).result

    assert value == %{
             "expired" => %{
               "is_error" => true,
               "error" => %{
                 "class" => "not_found",
                 "message" => "command session is unknown",
                 "details" => %{}
               }
             },
             "output" => "continued",
             "exit_code" => 0
           }

    assert File.read!(Path.join(ctx.tmp_dir, "next-count")) == "x"
    {:ok, settled} = EphemeralStore.load(store, authority.run_id)

    assert {error_id, %{is_error: true, error: %Error{class: :not_found}} = native_error} =
             Enum.find(settled.run.tool_results, fn {_id, result} ->
               match?(%{is_error: true, error: %Error{class: :not_found}}, result)
             end)

    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "completed-handle", %{type: :run_completed}}, 5_000
    {:ok, after_run} = EphemeralStore.load(store, authority.run_id)
    assert after_run.run.state == :completed
    assert after_run.run.tool_results[original_id] == original_result
    assert after_run.run.tool_results[error_id] == native_error

    assert Enum.count(after_run.run.tool_results, fn {_id, result} ->
             match?(%{is_error: true, error: %Error{class: :not_found}}, result)
           end) == 1

    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  defp success_tuple(:two, result, _context), do: {:ok, result}
  defp success_tuple(:three, result, context), do: {:ok, result, Map.put(context, :revision, 2)}

  defp opts(dispatcher),
    do: [dispatcher: dispatcher, execution_context: %{revision: 1}, timeout: 3_000]

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
