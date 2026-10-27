defmodule Backplane.AgentRuntime.CodexCompletionAndAnswerTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{
    Codex,
    Conversation,
    EphemeralStore,
    Error,
    Codex.DynamicRuntime,
    Codex.Web
  }

  alias Backplane.AgentRuntime.Codex.{MultiAgent, Services, Session}
  alias Backplane.PluginProtocol
  alias Backplane.PluginProtocol.{Archive, Client}

  defmodule PluginHost do
    def request_install(arguments, operation) do
      context = operation.backend_context
      send(context.test, {:install_operation, operation})

      if Map.has_key?(context, :package_client) do
        {:ok, downloaded} = Client.download(context.package_client, context.digest)

        for {path, bytes} <- downloaded.files do
          destination = Path.join(context.root, path)
          File.mkdir_p!(Path.dirname(destination))
          File.write!(destination, bytes)
          File.chmod!(destination, Map.fetch!(downloaded.modes, path))
          ^bytes = File.read!(destination)
        end

        {:ok, %{manifest: %{"name" => "example"}}} = PluginProtocol.load_directory(context.root)
      end

      if Map.get(context, :blocked, false) do
        send(context.test, {:blocked_installer, self()})

        receive do
          {:release_installer, reason} ->
            send(context.test, {:installer_observed_stop, reason})
        end
      end

      fields = %{
        completed: true,
        user_confirmed: false,
        tool_type: arguments["tool_type"],
        action_type: arguments["action_type"],
        tool_id: arguments["tool_id"],
        tool_name: "Example"
      }

      case Map.get(context, :outcome, :completed) do
        :completed ->
          result = {:ok, {:completed, fields}}
          if Map.get(context, :blocked, false), do: send(context.test, {:late_completion, result})
          result

        :legacy ->
          {:ok, fields}

        :legacy_list ->
          {:ok, [fields]}

        :mismatch ->
          {:ok, {:completed, %{fields | tool_id: "another"}}}

        {:fields, fields} ->
          {:ok, {:completed, fields}}

        :uncertain ->
          {:error, Error.new(:unknown_outcome, "installer lost acknowledgement")}
      end
    end
  end

  defmodule SearchHost do
    def search(_query, opts), do: {:ok, Keyword.fetch!(opts, :fixture)}
    def x_search(query, opts), do: search(query, opts)
  end

  defmodule AnswerHost do
    def search(_query, _opts), do: {:ok, answer()}
    def x_search(query, opts), do: search(query, opts)

    def answer,
      do: %{
        "kind" => "answer",
        "content" => "答案\r\nnext",
        "citations" => [
          "https://example.test/a",
          %{"url" => "https://example.test/b", "title" => "B"}
        ],
        "provider" => "fixture"
      }
  end

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:completion_provider, request, self()})

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

  test "explicit native completion preserves the host receipt and actual confirmation" do
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})
    operation = operation(runtime)

    assert {:ok,
            %{
              request_id: request_id,
              status: :completed,
              completed: true,
              user_confirmed: false,
              tool_type: "plugin",
              action_type: "install",
              tool_id: "example",
              tool_name: "Example"
            }} = DynamicRuntime.call(operation)

    assert_receive {:install_operation, delivered}
    assert delivered.plugin_request_id == request_id
    assert Map.delete(delivered, :plugin_request_id) == operation
  end

  test "legacy opaque completion-like host data remains requested" do
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})

    assert {:ok, %{status: :requested, host: %{completed: true, user_confirmed: false}}} =
             DynamicRuntime.call(operation(runtime, %{outcome: :legacy}))

    assert {:ok, %{status: :requested, host: [%{completed: true}]}} =
             DynamicRuntime.call(operation(runtime, %{outcome: :legacy_list}))
  end

  test "recognized malformed completion never attests to absent installation effects" do
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})

    fields = %{
      completed: true,
      user_confirmed: true,
      tool_type: "plugin",
      action_type: "install",
      tool_id: "example"
    }

    for invalid <- [
          nil,
          [],
          Map.delete(fields, :user_confirmed),
          Map.put(fields, :completed, false),
          Map.put(fields, :user_confirmed, 1),
          Map.put(fields, :tool_type, ""),
          Map.put(fields, :action_type, "update"),
          Map.put(fields, :tool_id, <<255>>),
          Map.put(fields, :tool_name, ""),
          Map.put(fields, :unexpected, true),
          Map.new(fields, fn {key, value} -> {Atom.to_string(key), value} end)
        ] do
      assert {:error,
              %Error{class: :unknown_outcome, details: %{reason: :malformed_plugin_completion}}} =
               DynamicRuntime.call(operation(runtime, %{outcome: {:fields, invalid}}))
    end
  end

  test "mismatched attestation and actual installer uncertainty cannot confirm completion" do
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})

    assert {:error, %Error{class: :unknown_outcome}} =
             DynamicRuntime.call(operation(runtime, %{outcome: :mismatch}))

    assert {:error, %Error{class: :unknown_outcome, message: "installer lost acknowledgement"}} =
             DynamicRuntime.call(operation(runtime, %{outcome: :uncertain}))
  end

  @tag :tmp_dir
  test "the native completion follows a real local package installation and verification", ctx do
    files = %{
      "plugin.json" =>
        JSON.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
          "name" => "example"
        }),
      "assets/marker" => "installed 汉字\r\n"
    }

    assert {:ok, bytes} = Archive.pack(files)
    digest = Archive.digest(bytes)

    client =
      Client.new(
        base_url: "http://fixture.test",
        transport: fn _ -> {:ok, %{status: 200, body: bytes}} end
      )

    root = Path.join(ctx.tmp_dir, "installed")
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})

    assert {:ok, %{status: :completed, request_id: id}} =
             DynamicRuntime.call(
               operation(runtime, %{package_client: client, digest: digest, root: root})
             )

    assert_receive {:install_operation, %{plugin_request_id: ^id}}
    assert File.read!(Path.join(root, "assets/marker")) == files["assets/marker"]
    assert {:ok, %{manifest: %{"name" => "example"}}} = PluginProtocol.load_directory(root)
  end

  test "answer-only search preserves either key style and ordered citations" do
    for fixture <- [
          %{
            kind: :answer,
            content: "答案\r\nnext",
            provider: "fixture",
            query: "q",
            citations: ["https://example.test/a", %{url: "https://example.test/b", title: "B"}],
            metadata: %{took: 3}
          },
          %{
            "kind" => "answer",
            "content" => "答案\r\nnext",
            "citations" => [
              %{"url" => "https://example.test/b", "title" => "B"},
              "https://example.test/a"
            ]
          }
        ] do
      assert {:ok, ^fixture} = Web.search(SearchHost, "q", fixture: fixture)
      assert {:ok, ^fixture} = Web.x_search(SearchHost, "q", fixture: fixture)
    end
  end

  test "the existing whole-result bound includes answer metadata and citations" do
    fixture = %{
      kind: :answer,
      content: "answer",
      citations: ["https://example.test/source"],
      metadata: String.duplicate("x", 1_000)
    }

    assert {:error, %Error{class: :budget_exceeded}} =
             Web.search(SearchHost, "q", fixture: fixture, result_limit: 500)
  end

  test "valid legacy results win over answer-like metadata" do
    for fixture <- [%{results: [], kind: :answer}, %{"results" => [], "kind" => "answer"}] do
      assert {:ok, ^fixture} = Web.search(SearchHost, "q", fixture: fixture)
    end
  end

  test "answer validation rejects ambiguous aliases and malformed fields without reshaping metadata" do
    for fixture <- [
          %{kind: :answer},
          %{kind: :answer, content: ""},
          %{kind: :answer, content: <<255>>},
          %{kind: :answer, content: "a", provider: nil},
          %{kind: :answer, content: "a", query: 7},
          %{kind: :answer, content: "a", citations: %{}},
          %{kind: :answer, content: "a", citations: [""]},
          %{kind: :answer, content: "a", citations: [%{url: "u", title: <<255>>}]},
          %{kind: :answer, content: "a", citations: [%{:url => "u", "url" => "v"}]},
          %{:kind => :answer, "kind" => "answer", :content => "a"},
          %{:kind => :answer, :content => "a", "content" => "a"}
        ] do
      assert {:error, %Error{class: :malformed_result}} =
               Web.search(SearchHost, "q", fixture: fixture)
    end

    assert {:error, %Error{class: :validation}} = Web.search(AnswerHost, "q", result_limit: 0)
  end

  test "direct native and real Deno outcomes enter the next model input and settled journal once" do
    assert System.find_executable("deno"), "this acceptance test requires real Deno"
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})

    for outcome <- [:completed, :legacy], mode <- [:direct, :deno] do
      run_id = "completion-#{outcome}-#{mode}"
      session = start_supervised!({Session, owner_pid: self()}, id: make_ref())
      {profile, binding} = profile(runtime, session, run_id, 7, self(), %{outcome: outcome})
      {:ok, store} = EphemeralStore.new(7)

      opts = [
        run_id: run_id,
        incarnation: 7,
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{test: self()},
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        session_binding: binding,
        schema_admission: :strict,
        run_timeout: 15_000,
        effect_timeout: 5_000
      ]

      conversation = start_supervised!({Conversation, opts}, id: make_ref())
      assert {:ok, _} = Conversation.prompt(conversation, "install and search")
      assert_receive {:completion_provider, %{run_id: ^run_id}, provider}, 2_000
      send_calls(provider, mode)
      assert_receive {:install_operation, installed}, 3_000
      assert installed.run_id == run_id
      assert installed.incarnation == binding.run_incarnation
      assert installed.backend_context.resource_owner.owner_id == binding.owner_id
      assert is_binary(installed.invocation_id)
      assert_receive {:completion_provider, %{messages: messages}, provider}, 5_000
      expected = expected_install(installed.plugin_request_id, outcome)
      assert_outcomes(messages, mode, expected)
      send(provider, {:events, [done()]})
      assert eventually(fn -> Conversation.status(conversation).phase == :terminal end)
      assert {:ok, %{run: run}} = EphemeralStore.load(store, run_id)
      assert run.context.conversation.messages == Conversation.status(conversation).messages
      assert run.tool_results[installed.invocation_id] == Map.put(expected, :is_error, false)
      assert run.execution_intents["tool:#{installed.invocation_id}"].status == :consumed
      refute_receive {:install_operation, _}
      GenServer.stop(conversation)

      restored_opts = opts |> Keyword.delete(:session_binding) |> Keyword.put(:run, run)
      restored = start_supervised!({Conversation, restored_opts}, id: make_ref())
      assert Conversation.status(restored).phase == :terminal
      assert Conversation.status(restored).messages == run.context.conversation.messages
      assert Conversation.status(restored).run.tool_results == run.tool_results
      refute_receive {:install_operation, _}
      refute_receive {:completion_provider, _, _}
      assert {:ok, %{status: :confirmed}} = Session.close(session)
    end
  end

  test "managed-child plugin completion preserves its admitted binding and invocation identity" do
    test = self()
    runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost})
    sessions = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    manager =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "completion-root",
         parent_name: "/root",
         parent_authority: %{
           caller: "host",
           run_id: "completion-root",
           grants: ["exec", "wait", "request_plugin_install", "web::search", "web::x_search"],
           tool_revision: 1
         },
         min_wait_timeout_ms: 0,
         child_options: fn _request, run_id, parent ->
           {:ok, session} = DynamicSupervisor.start_child(sessions, {Session, owner_pid: test})

           {profile, binding} =
             profile(runtime, session, run_id, parent.child.incarnation, test, %{})

           {:ok, store} = EphemeralStore.new(parent.child.incarnation)
           send(test, {:completion_child, binding, store})

           {:ok,
            [
              run_id: run_id,
              incarnation: parent.child.incarnation,
              store: EphemeralStore,
              context: store,
              provider: Provider,
              provider_context: %{test: test},
              registry: profile.registry,
              tools: profile.tools,
              authority: profile.authority,
              session_binding: binding,
              schema_admission: :strict,
              run_timeout: 10_000,
              effect_timeout: 5_000
            ]}
         end}
      )

    assert {:ok, _} =
             MultiAgent.call(%{
               backend_context: %{runtime: manager, profile: :v2},
               run_id: "completion-root",
               tool_name: "spawn_agent",
               arguments: %{"task_name" => "install", "message" => "install"}
             })

    assert_receive {:completion_child, binding, store}, 2_000
    assert_receive {:completion_provider, %{run_id: run_id}, provider}, 2_000
    assert run_id == binding.run_id
    send_calls(provider, :direct)
    assert_receive {:install_operation, installed}, 3_000
    assert installed.run_id == binding.run_id
    assert installed.incarnation == binding.run_incarnation
    assert installed.backend_context.resource_owner.owner_id == binding.owner_id
    assert_receive {:completion_provider, %{messages: messages}, provider}, 3_000
    assert_outcomes(messages, :direct, expected_install(installed.plugin_request_id, :completed))
    send(provider, {:events, [done()]})

    assert eventually(fn ->
             {:ok, %{run: run}} = EphemeralStore.load(store, run_id)

             run.state == :completed and
               run.tool_results[installed.invocation_id].status == :completed
           end)

    refute_receive {:install_operation, _}
  end

  test "cancelled and expired plugin effects reject an independently returning tagged completion" do
    for reason <- [:cancelled, :expired] do
      runtime = start_supervised!({DynamicRuntime, plugin_adapter: PluginHost}, id: make_ref())
      session = start_supervised!({Session, owner_pid: self()}, id: make_ref())
      run_id = "late-plugin-#{reason}"
      {profile, binding} = profile(runtime, session, run_id, 9, self(), %{blocked: true})
      {:ok, store} = EphemeralStore.new(9)

      opts = [
        run_id: run_id,
        incarnation: 9,
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
        run_timeout: :infinity,
        effect_timeout: if(reason == :expired, do: 200, else: 5_000)
      ]

      conversation = start_supervised!({Conversation, opts}, id: make_ref())
      assert {:ok, _} = Conversation.prompt(conversation, "install")
      assert_receive {:completion_provider, _, provider}, 1_000

      send(
        provider,
        {:events,
         [
           %{
             type: :tool_call_completed,
             tool_call: %{
               id: "late-install",
               name: "request_plugin_install",
               arguments: arguments()
             }
           },
           done()
         ]}
      )

      assert_receive {:install_operation, installed}, 1_000
      assert_receive {:blocked_installer, installer}, 1_000
      assert installer == runtime
      state = :sys.get_state(conversation)
      effect_ref = state.effect.task.ref
      worker = state.effect.task.pid
      monitor = Process.monitor(worker)
      if reason == :cancelled, do: assert(:ok == Conversation.cancel(conversation))
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
      assert eventually(fn -> Conversation.status(conversation).phase == :terminal end)
      assert Process.alive?(installer)
      assert {:ok, %{run: before}} = EphemeralStore.load(store, run_id)
      assert before.state == :unknown_outcome
      assert before.active_tools[installed.invocation_id].tool_name == "request_plugin_install"
      assert before.execution_intents["tool:#{installed.invocation_id}"].status == :uncertain
      refute Map.has_key?(before.tool_results, installed.invocation_id)

      send(installer, {:release_installer, reason})
      assert_receive {:installer_observed_stop, ^reason}, 1_000
      assert_receive {:late_completion, {:ok, {:completed, _}}}, 1_000
      # The real adapter has returned to a dead caller. Also exercise the original
      # task reference: stale delivery cannot rewrite the authoritative settlement.
      send(
        conversation,
        {effect_ref, {:ok, expected_install(installed.plugin_request_id, :completed)}}
      )

      assert Conversation.status(conversation).run == before
      assert {:ok, %{run: ^before}} = EphemeralStore.load(store, run_id)

      assert {:error, %Error{class: :resource_conflict}} =
               Conversation.follow_up(conversation, "retry")

      GenServer.stop(conversation)

      restored =
        start_supervised!(
          {Conversation, opts |> Keyword.delete(:session_binding) |> Keyword.put(:run, before)},
          id: make_ref()
        )

      assert Conversation.status(restored).phase == :terminal
      assert Conversation.status(restored).run == before
      refute_receive {:install_operation, _}, 30
      refute_receive {:completion_provider, _, _}, 30
    end
  end

  defp profile(runtime, session, run_id, incarnation, test, context) do
    names = ["exec", "wait", "request_plugin_install", "web::search", "web::x_search"]
    authority = %{caller: "host", run_id: run_id, grants: names, tool_revision: 1}
    {:ok, binding} = Session.bind(session, authority, incarnation: incarnation)

    plugin =
      DynamicRuntime.contracts(%{dynamic_runtime: runtime})
      |> Enum.find(&(&1.name == "request_plugin_install"))

    plugin = %{
      plugin
      | backend_context: Map.merge(plugin.backend_context, Map.put(context, :test, test))
    }

    web = Services.contracts(%{search_adapter: AnswerHost, x_search_adapter: AnswerHost})

    {:ok, profile} =
      Codex.profile(
        :mixed,
        %{session_binding: binding, code_mode_contracts: [plugin | web]},
        authority,
        tools: names
      )

    {profile, binding}
  end

  defp send_calls(provider, :direct) do
    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "install", name: "request_plugin_install", arguments: arguments()}
         },
         %{
           type: :tool_call_completed,
           tool_call: %{id: "answer", name: "web::search", arguments: %{"query" => "fixture"}}
         },
         done()
       ]}
    )
  end

  defp send_calls(provider, :deno) do
    code =
      "const installed = await tools.request_plugin_install(#{JSON.encode!(arguments())}); const search = await tools.web__search({query: 'fixture'}); return {installed, search};"

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "exec-install", name: "exec", arguments: code}
         },
         done()
       ]}
    )
  end

  defp expected_install(id, outcome) do
    fields = %{
      completed: true,
      user_confirmed: false,
      tool_type: "plugin",
      action_type: "install",
      tool_id: "example",
      tool_name: "Example"
    }

    if outcome == :completed,
      do: Map.merge(fields, %{request_id: id, status: :completed}),
      else: %{request_id: id, status: :requested, host: fields}
  end

  defp assert_outcomes(messages, :direct, expected) do
    results = for %{role: :tool, result: result} <- messages, do: Map.drop(result, [:is_error])
    assert expected in results
    assert AnswerHost.answer() in results

    assert JSON.decode!(JSON.encode!(expected)) in Enum.map(
             results,
             &JSON.decode!(JSON.encode!(&1))
           )
  end

  defp assert_outcomes(messages, :deno, expected) do
    assert %{result: %{status: :completed, value: value, is_error: false}} = List.last(messages)

    assert value == %{
             "installed" => JSON.decode!(JSON.encode!(expected)),
             "search" => AnswerHost.answer()
           }
  end

  defp arguments,
    do: %{
      "tool_type" => "plugin",
      "action_type" => "install",
      "tool_id" => "example",
      "suggest_reason" => "Use example"
    }

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

  defp operation(runtime, context \\ %{}) do
    %{
      backend_context: Map.merge(%{runtime: runtime, test: self()}, context),
      caller: "fixture-host",
      run_id: "completion-fixture",
      incarnation: 3,
      invocation_id: "install-invocation",
      tool_name: "request_plugin_install",
      arguments: %{
        "tool_type" => "plugin",
        "action_type" => "install",
        "tool_id" => "example",
        "suggest_reason" => "Use example"
      }
    }
  end
end
