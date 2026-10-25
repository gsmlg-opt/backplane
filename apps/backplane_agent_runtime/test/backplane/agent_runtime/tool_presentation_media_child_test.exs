defmodule Backplane.AgentRuntime.ToolPresentationMediaChildTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{Backend, Catalog, Contract, MultiAgent, Session, Tools}

  @moduletag :tmp_dir
  @identity_fields ~w(run_id incarnation step_id attempt_id invocation_id enclosing_invocation_id tool_name tool_revision catalog_revision tool_call_id turn_id arguments collaboration_binding)a
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:media_provider, request.run_id, request, self()})

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

  defmodule PresentedMedia do
    def execute(operation) do
      with {:ok, _owner} <- Session.validate(operation.backend_context.session_binding, operation) do
        actual = operation.backend_context.actual
        send(operation.backend_context.test, {:media_effect, operation, actual})
        ToolEffects.present(operation, actual, operation.backend_context.presentation)
      end
    end
  end

  defmodule PresentedImage do
    def execute(operation) do
      with {:ok, actual} <- Backend.execute(operation) do
        send(operation.backend_context.test, {:media_effect, operation, actual})
        ToolEffects.present(operation, actual, operation.backend_context.presentation)
      end
    end
  end

  for type <- [:block, :stopped] do
    test "#{type} preserves typed media in canonical storage and projects only consumer output" do
      type = unquote(type)
      actual = media("original typed media")
      ctx = root([contract("media", actual, type)])
      provider = prompt(ctx)
      send_calls(provider, [{"media-call", "media", %{}}])
      assert_receive {:media_effect, operation, ^actual}, 5_000
      assert_receive {:media_provider, run, request, next}, 5_000
      assert run == ctx.run
      assert_projection(List.last(request.messages).result, type)
      assert_canonical(ctx, operation, actual, type)
      finish(ctx, next)
    end
  end

  test "native view_image bytes and metadata survive a stopped model presentation", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "original.png"), @png)
    ctx = root([], workspace: dir, names: ["view_image"], native_presentation: :stopped)
    provider = prompt(ctx)
    send_calls(provider, [{"native-image", "view_image", %{"path" => "original.png"}}])
    assert_receive {:media_effect, operation, actual}, 5_000
    assert actual.data == @png
    assert actual.bytes == byte_size(@png)
    assert actual.mime_type == "image/png"
    assert actual.image_url == "data:image/png;base64," <> Base.encode64(@png)
    assert_receive {:media_provider, _, request, next}, 5_000
    assert_projection(List.last(request.messages).result, :stopped)
    assert_canonical(ctx, operation, actual, :stopped)
    finish(ctx, next)
  end

  test "one multi-tool response keeps distinct exact presentation identities and original media" do
    ctx =
      root([
        contract("first_media", media("first"), :block),
        contract("second_media", media("second"), :stopped)
      ])

    provider = prompt(ctx)

    send_calls(provider, [
      {"first-call", "first_media", %{}},
      {"second-call", "second_media", %{}}
    ])

    assert_receive {:media_effect, first, first_actual}, 5_000
    assert_receive {:media_effect, second, second_actual}, 5_000
    assert_receive {:media_provider, _, request, next}, 5_000
    operations = Map.new([first, second], &{&1.tool_name, &1})
    assert operations["first_media"].tool_call_id == "first-call"
    assert operations["second_media"].tool_call_id == "second-call"
    refute first.invocation_id == second.invocation_id
    assert first.turn_id == second.turn_id
    refute first_actual == second_actual

    for {operation, actual} <- [{first, first_actual}, {second, second_actual}] do
      type = if operation.tool_name == "first_media", do: :block, else: :stopped
      assert_canonical(ctx, operation, actual, type)
      message = Enum.find(request.messages, &(&1[:tool_call_id] == operation.tool_call_id))
      assert message.invocation_id == operation.invocation_id
      assert_projection(message.result, type)
    end

    assert {:ok, %{run: stored}} = EphemeralStore.load(ctx.table, ctx.run)
    assert map_size(stored.tool_presentations) == 2
    assert map_size(stored.tool_results) == 2
    finish(ctx, next)
  end

  test "a publicly adopted managed child persists original media before its next projected request" do
    test = self()
    run = "media-root-#{System.unique_integer([:positive])}"
    names = ["spawn_agent", "child_media"]
    root_session = start_supervised!({Session, owner_pid: test}, id: :root_session)

    host =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(host, :stop) end)
    child_session = start_supervised!({Session, owner_pid: host}, id: :child_session)
    contract_table = :ets.new(:media_contracts, [:public])

    manager =
      start_supervised!(
        {MultiAgent,
         parent_run_id: run,
         parent_name: "/root",
         parent_authority: authority(run, names),
         min_wait_timeout_ms: 0,
         child_options: fn _, child_run, parent ->
           contracts = :ets.lookup_element(contract_table, :contracts, 2)

           opts =
             options(
               child_session,
               child_run,
               parent.child.incarnation,
               names,
               contracts,
               %{},
               test
             )

           send(
             test,
             {:media_child,
              %{
                run: child_run,
                session: child_session,
                table: opts[:context],
                binding: opts[:session_binding]
              }}
           )

           {:ok, opts}
         end},
        id: :media_manager
      )

    actual = media("managed child original")
    contracts = MultiAgent.contracts(:v2, manager) ++ [contract("child_media", actual, :block)]
    :ets.insert(contract_table, {:contracts, contracts})
    opts = options(root_session, run, 1, names, contracts, %{})
    pid = start_supervised!({Conversation, opts}, id: :root_conversation)
    ctx = %{pid: pid, run: run, session: root_session, table: opts[:context]}
    on_exit(fn -> if Process.alive?(root_session), do: Session.close(root_session) end)
    provider = prompt(ctx)

    send_calls(provider, [
      {"spawn-child", "spawn_agent", %{"task_name" => "worker", "message" => "inspect media"}}
    ])

    assert_receive {:media_child, child}, 5_000
    assert_receive {:media_provider, child_run, _, child_provider}, 5_000
    assert child_run == child.run
    assert child.binding.session == child_session
    assert Session.status(child_session).phase == :active
    assert_receive {:media_provider, ^run, _, root_provider}, 5_000

    send_calls(child_provider, [{"child-image", "child_media", %{}}])
    assert_receive {:media_effect, operation, ^actual}, 5_000
    assert operation.run_id == child.run
    assert operation.incarnation == child.binding.run_incarnation
    assert_receive {:media_provider, ^child_run, request, child_next}, 5_000
    assert_projection(List.last(request.messages).result, :block)
    assert_canonical(child, operation, actual, :block)
    send(child_next, {:events, [done()]})
    eventually(fn -> Session.status(child_session).phase == :idle end)
    send(root_provider, {:events, [done()]})
    eventually(fn -> Session.status(root_session).phase == :idle end)
    assert {:ok, %{status: :confirmed}} = Session.close(root_session)
    assert Session.status(child_session).phase == :closed
  end

  defp root(contracts, opts \\ []) do
    run = "media-#{System.unique_integer([:positive])}"
    names = Keyword.get(opts, :names, Enum.map(contracts, & &1.name))
    session = start_supervised!({Session, owner_pid: self()})
    context = Map.new(Keyword.take(opts, [:workspace, :native_presentation]))
    options = options(session, run, 1, names, contracts, context)
    pid = start_supervised!({Conversation, options})
    on_exit(fn -> if Process.alive?(session), do: Session.close(session) end)
    %{pid: pid, run: run, session: session, table: options[:context]}
  end

  defp options(session, run, incarnation, names, contracts, context, test \\ self()) do
    auth = authority(run, names)

    bindings =
      Map.new(
        for c <- contracts,
            Map.has_key?(c, :collaboration_binding),
            c.tool_name in names,
            do: {c.tool_name, c.collaboration_binding.fingerprint}
      )

    auth = if map_size(bindings) > 0, do: Map.put(auth, :tool_bindings, bindings), else: auth
    {:ok, binding} = Session.bind(session, auth, incarnation: incarnation)
    context = Map.put(context, :session_binding, binding)

    selected =
      Enum.filter(
        Tools.contracts(context) ++ contracts,
        &(Contract.canonical_name(&1[:namespace], &1.name) in names)
      )

    {:ok, profile} = Catalog.admit(selected, auth)

    registry = %{
      profile.registry
      | tools:
          Map.new(profile.registry.tools, fn {name, descriptor} ->
            descriptor = put_in(descriptor.backend_context[:session_binding], binding)

            descriptor =
              if name == "view_image" do
                %{
                  descriptor
                  | backend: PresentedImage,
                    backend_context:
                      Map.merge(descriptor.backend_context, %{
                        test: test,
                        presentation: %{
                          type: context.native_presentation,
                          text: "host media presentation"
                        }
                      })
                }
              else
                descriptor
              end

            {name, descriptor}
          end)
    }

    {:ok, table} = EphemeralStore.new(1)

    [
      run_id: run,
      incarnation: incarnation,
      session_binding: binding,
      registry: registry,
      tools: profile.tools,
      authority: profile.authority,
      store: EphemeralStore,
      context: table,
      provider: Provider,
      provider_context: %{test: test},
      schema_admission: :strict,
      work: 40,
      run_timeout: 15_000,
      cleanup_timeout: 2_000
    ]
  end

  defp contract(name, actual, type),
    do: %{
      name: name,
      description: "Return original typed media",
      backend: PresentedMedia,
      backend_context: %{
        test: self(),
        actual: actual,
        presentation: %{type: type, text: "host media presentation"}
      },
      schema: %{"type" => "object", "properties" => %{}},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false}
    }

  defp media(text),
    do: %{
      content: [
        %{type: :text, text: text},
        %{type: :image, mime_type: "image/png", data: Base.encode64(@png)}
      ],
      artifacts: [%{type: :image, data: @png}],
      structured: %{caption: text}
    }

  defp assert_canonical(ctx, operation, actual, type) do
    assert {:ok, %{run: run}} = EphemeralStore.load(ctx.table, ctx.run)
    assert run.tool_results[operation.invocation_id] == Map.put(actual, :is_error, false)
    record = run.tool_presentations[operation.invocation_id]
    assert record.identity == Map.take(operation, @identity_fields)
    assert record.decision == %{type: type, text: "host media presentation"}
    assert record.state == :accepted
    assert is_integer(record.revision)
    assert record.revision <= run.expected_revision
    refute Map.has_key?(run.active_tools, operation.invocation_id)
  end

  defp assert_projection(result, :block) do
    assert %{is_error: true, error: %{class: :forbidden, message: "host media presentation"}} =
             result

    assert Map.keys(result) |> Enum.sort() == [:error, :is_error]
  end

  defp assert_projection(result, :stopped) do
    assert result == %{
             is_error: false,
             stopped: true,
             content: [%{type: :text, text: "host media presentation"}]
           }
  end

  defp prompt(ctx) do
    assert {:ok, _} = Conversation.prompt(ctx.pid, "inspect original media")
    run = ctx.run
    assert_receive {:media_provider, ^run, _, provider}, 5_000
    provider
  end

  defp send_calls(provider, calls) do
    events =
      Enum.map(calls, fn {id, name, arguments} ->
        %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}}
      end)

    send(provider, {:events, events ++ [done()]})
  end

  defp finish(ctx, provider) do
    send(provider, {:events, [done()]})
    eventually(fn -> Session.status(ctx.session).phase == :idle end)
    assert {:ok, %{status: :confirmed}} = Session.close(ctx.session)
  end

  defp authority(run, names),
    do: %{caller: "media-host", run_id: run, grants: names, tool_revision: 1}

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp eventually(fun, remaining \\ 100)

  defp eventually(fun, remaining) when remaining > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end

  defp eventually(_, 0), do: flunk("Session state did not converge")
end
