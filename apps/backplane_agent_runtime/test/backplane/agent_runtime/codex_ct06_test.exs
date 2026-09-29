defmodule Backplane.AgentRuntime.CodexCT06Test do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore}
  alias Backplane.AgentRuntime.Codex.{ExtensionRuntime, Extensions}

  @scope %{host_id: "h", caller_id: "c", run_id: "r", project_id: "p"}
  @other %{host_id: "h", caller_id: "c", run_id: "other", project_id: "p"}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

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

  defp extension_call(runtime, run_id, tool_name, arguments) do
    ExtensionRuntime.call(%{
      run_id: run_id,
      tool_name: tool_name,
      arguments: arguments,
      backend_context: %{runtime: runtime}
    })
  end

  test "public extension profile exposes the pinned concrete tool set" do
    runtime = start_supervised!({ExtensionRuntime, scope: @scope})

    names =
      %{extension_runtime: runtime}
      |> ExtensionRuntime.contracts()
      |> Enum.map(fn
        %{namespace: nil, name: name} -> name
        %{namespace: namespace, name: name} -> namespace <> "::" <> name
      end)

    assert names ==
             ~w(
               get_goal create_goal update_goal
               memories::add_ad_hoc_note memories::list memories::read memories::search
               skills::list skills::read
               history::list_windows history::list_items history::read_item history::search_contents
               notes::list_files_by_prefix notes::read_file notes::search_contents notes::append_to_file notes::write_file
               collaboration::create_channel collaboration::get_channels collaboration::list_threads collaboration::search_posts
               collaboration::read_thread collaboration::read_post collaboration::subscribe collaboration::unsubscribe collaboration::post
             )

    authority = %{
      caller: "host",
      run_id: @scope.run_id,
      grants: names,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    assert {:ok, profile} = Codex.profile(:extensions, %{extension_runtime: runtime}, authority)
    assert Enum.map(profile.tools, & &1.name) == names
  end

  test "configured message-board namespace retains schemas and safety classification" do
    runtime =
      start_supervised!({ExtensionRuntime, scope: @scope, board_namespace: "message_board"})

    contracts = ExtensionRuntime.contracts(%{extension_runtime: runtime})
    post = Enum.find(contracts, &(&1.namespace == "message_board" and &1.name == "post"))
    read = Enum.find(contracts, &(&1.namespace == "message_board" and &1.name == "read_post"))

    assert post.schema["required"] == ["text"]
    refute post.safety.read_only
    assert read.schema["required"] == ["message_id"]
    assert read.safety.read_only

    skill_list = Enum.find(contracts, &(&1.namespace == "skills" and &1.name == "list"))
    assert skill_list.schema["properties"]["authority"]["enum"] == ["cloud", "executor"]
  end

  test "reference runtime rejects cross-run calls and unfinished goal replacement" do
    runtime = start_supervised!({ExtensionRuntime, scope: @scope})

    assert {:error, %{class: :forbidden}} =
             extension_call(runtime, @other.run_id, "get_goal", %{})

    assert {:ok, %{goal: %{objective: "ship CT-06", status: "active"}}} =
             extension_call(runtime, @scope.run_id, "create_goal", %{"objective" => "ship CT-06"})

    assert {:error, %{class: :resource_conflict}} =
             extension_call(runtime, @scope.run_id, "create_goal", %{"objective" => "replace"})
  end

  test "explicit owner death removes the ephemeral runtime" do
    owner = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, runtime} = ExtensionRuntime.start_link(scope: @scope, owner_pid: owner)
    Process.unlink(runtime)
    monitor = Process.monitor(runtime)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^runtime, _reason}, 1_000
  end

  test "reference backend exercises memory, skill, history, note, and board workflows" do
    runtime =
      start_supervised!(
        {ExtensionRuntime,
         scope: @scope,
         skills: [
           %{
             package: "demo",
             name: "Demo",
             description: "fixture",
             authority: %{kind: "executor"},
             main_resource: "SKILL.md",
             contents: "# Demo",
             resources: %{"guide.md" => "guide"},
             revision: "rev-1",
             digest: "sha256:fixture"
           }
         ],
         history: [
           %{window_id: "w1", id: "i1", role: "assistant", content: "shipped the change"}
         ]}
      )

    assert {:ok, %{path: memory_path}} =
             extension_call(runtime, @scope.run_id, "memories::add_ad_hoc_note", %{
               "filename" => "2026-09-29T21-00-00-ct06.md",
               "note" => "extension runtime verified"
             })

    assert {:ok, %{contents: "extension runtime verified"}} =
             extension_call(runtime, @scope.run_id, "memories::read", %{"path" => memory_path})

    assert {:ok, %{skills: [%{package: "demo", revision: "rev-1"}]}} =
             extension_call(runtime, @scope.run_id, "skills::list", %{
               "authority" => "executor"
             })

    assert {:ok, %{contents: "guide", resource: "guide.md"}} =
             extension_call(runtime, @scope.run_id, "skills::read", %{
               "package" => "demo",
               "resource" => "guide.md"
             })

    assert {:ok, %{items: [%{id: "i1"}]}} =
             extension_call(runtime, @scope.run_id, "history::search_contents", %{
               "query" => "shipped"
             })

    assert {:ok, %{path: "decisions/ct06.md"}} =
             extension_call(runtime, @scope.run_id, "notes::write_file", %{
               "path" => "decisions/ct06.md",
               "text" => "line one\nline two"
             })

    assert {:ok, %{contents: "line two"}} =
             extension_call(runtime, @scope.run_id, "notes::read_file", %{
               "path" => "decisions/ct06.md",
               "start_line" => 2,
               "stop_line" => 2
             })

    assert {:ok, %{channel: %{name: "runtime"}}} =
             extension_call(runtime, @scope.run_id, "collaboration::create_channel", %{
               "channel_name" => "runtime"
             })

    assert {:ok, %{thread_id: thread_id}} =
             extension_call(runtime, @scope.run_id, "collaboration::post", %{
               "channel_name" => "runtime",
               "text" => "CT-06 ready"
             })

    assert {:ok, %{posts: [%{text: "CT-06 ready"}]}} =
             extension_call(runtime, @scope.run_id, "collaboration::read_thread", %{
               "thread_id" => thread_id
             })
  end

  test "memory tools execute through Conversation and retain state for the next call" do
    runtime = start_supervised!({ExtensionRuntime, scope: @scope})
    tools = ["memories::add_ad_hoc_note", "memories::read"]

    authority = %{
      caller: "host",
      run_id: @scope.run_id,
      grants: tools,
      tool_revisions: Map.new(tools, &{&1, 1})
    }

    assert {:ok, profile} =
             Codex.profile(:extensions, %{extension_runtime: runtime}, authority, tools: tools)

    {:ok, store} = EphemeralStore.new(1)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: @scope.run_id,
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{test: self()},
        subscriber: self(),
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        schema_admission: :strict,
        work: 12,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(conversation, "remember")
    assert_receive {:provider, %{tools: provider_tools}, provider}
    assert Enum.map(provider_tools, & &1.name) == tools

    path = "2026-09-29T21-10-00-conversation.md"

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "memory-write",
            name: "memories::add_ad_hoc_note",
            arguments: %{"filename" => path, "note" => "through execution"}
          }
        },
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "memory-read",
            name: "memories::read",
            arguments: %{"path" => path}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "working"}}
      ]
    })

    assert_receive {:provider, %{messages: messages}, final_provider}, 5_000

    assert %{name: "memories::read", result: %{contents: "through execution", is_error: false}} =
             List.last(messages)

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "r", %{type: :run_completed}}
  end

  test "reference records are scoped, searchable, paginated, and revision safe" do
    state = Extensions.new(max_page: 2)
    {:ok, state, first} = Extensions.note_create(state, @scope, %{text: "alpha"})
    {:ok, state, _second} = Extensions.note_create(state, @scope, %{text: "beta"})
    {:ok, state, _third} = Extensions.note_create(state, @scope, %{text: "gamma"})
    assert {:error, %{class: :forbidden}} = Extensions.read(state, :notes, @other, first.id)
    assert {:ok, %{items: items, next_cursor: 2}} = Extensions.list(state, :notes, @scope)
    assert length(items) == 2

    assert {:ok, %{items: [%{data: %{text: "gamma"}}]}} =
             Extensions.list(state, :notes, @scope, cursor: 2)

    assert {:ok, state, _} =
             Extensions.update(state, :notes, @scope, first.id, 1, %{text: "changed"})

    assert {:error, %{class: :resource_conflict}} =
             Extensions.update(state, :notes, @scope, first.id, 1, %{text: "stale"})

    assert {:ok, %{items: [%{data: %{text: "gamma"}}]}} =
             Extensions.search(state, :notes, @scope, "gamma", limit: 1)
  end

  test "malformed scopes and delivery keys are rejected" do
    state = Extensions.new(max_page: -1)
    assert state.max_page == 100
    assert {:error, %{class: :forbidden}} = Extensions.subscribe(state, %{run_id: "r"}, "events")
    {:ok, state, sub} = Extensions.subscribe(state, @scope, "events")
    assert {:error, %{class: :forbidden}} = Extensions.ack(state, @scope, sub.id, :bad)
  end

  test "skills require immutable revision and digest" do
    state = Extensions.new()

    {:ok, state, skill} =
      Extensions.skill_publish(state, @scope, %{name: "lint", content: "use strict"})

    assert {:ok, ^skill} =
             Extensions.skill_read(state, @scope, "lint", skill.revision, skill.digest)

    assert {:error, %{class: :resource_conflict}} =
             Extensions.skill_read(state, @scope, "lint", skill.revision, "bad")

    {:ok, state, skill2} =
      Extensions.skill_publish(state, @scope, %{name: "lint", content: "new"})

    assert skill2.revision == skill.revision + 1

    assert {:error, %{class: :resource_conflict}} =
             Extensions.skill_read(state, @scope, "lint", skill.revision, skill.digest)
  end

  test "board duplicate delivery and subscription cleanup" do
    state = Extensions.new()
    {:ok, state, sub} = Extensions.subscribe(state, @scope, "events")

    {:ok, state, %{status: :published, delivered: 1}} =
      Extensions.publish(state, @scope, "events", %{value: 1}, "m1")

    {:ok, state, %{status: :duplicate, delivered: 0}} =
      Extensions.publish(state, @scope, "events", %{value: 1}, "m1")

    assert {:ok, [%{message_id: "m1", delivery_key: {_, "m1"}}]} =
             Extensions.poll(state, @scope, sub.id)

    {:ok, state} = Extensions.ack(state, @scope, sub.id, {sub.id, "m1"})
    assert {:ok, []} = Extensions.poll(state, @scope, sub.id)

    {:ok, state} = Extensions.unsubscribe(state, @scope, sub.id)
    assert {:error, %{class: :not_found}} = Extensions.poll(state, @scope, sub.id)
  end

  test "durability is explicitly unavailable" do
    assert %{mode: :ephemeral, durable: false, restart_recovery: false} =
             Extensions.capabilities()
  end
end
