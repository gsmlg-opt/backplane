Code.require_file("../../fixtures/reconciliation_file_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.CodexEncryptedHistoryNotesTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{Backend, ExtensionRuntime, HistoryNotes}
  alias Backplane.AgentRuntime.ReconciliationFileHostFixture, as: FileHost

  @scope %{host_id: "host", caller_id: "caller", run_id: "encrypted", project_id: "project"}
  @encrypted "  opaque+/%\n汉字==  "
  @images [
    %{"data" => "aGVsbG8=", "mime_type" => "image/png", "detail" => "high"},
    %{"data" => "d29ybGQ=", "mime_type" => "image/jpeg"}
  ]

  defmodule Transport do
    @behaviour HistoryNotes
    def execute(operation, scope, context) do
      send(context.test, {:remote_request, operation, scope, self()})

      case context do
        %{blocked: true, workers: workers} ->
          effect = self()

          worker =
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

          Agent.update(workers, &Map.put(&1, operation.invocation_id, {effect, worker}))
          send(context.test, {:transport_started, operation.invocation_id, worker})

          receive do
            :retired -> {:error, Error.new(:cancelled, "transport retired")}
          end

        %{error: error} ->
          {:error, error}

        _ ->
          {:ok, context.result}
      end
    end

    def cancel(operation, _scope, context) do
      if context[:unverified] do
        {effect, _worker} = Agent.get(context.workers, &Map.fetch!(&1, operation.invocation_id))
        send(effect, :retired)
        {:ok, %{cancelled: true}}
      else
        {effect, worker} = Agent.get(context.workers, &Map.fetch!(&1, operation.invocation_id))
        monitor = Process.monitor(worker)
        send(worker, :stop)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _} -> :ok
        end

        send(effect, :retired)

        ToolEffects.confirm_cancellation(operation, %{
          local_cleanup: :confirmed,
          stop_generation: operation.stop_generation,
          registration_id: operation.resource_registration,
          local: :cancelled,
          remote: :unknown,
          logical_id: operation.invocation_id,
          request_id: operation.invocation_id,
          client_incarnation: "transport-1",
          method: "POST",
          cleanup_evidence: %{workers_down: true, transport: :confirmed, worker_count: 1}
        })
      end
    end
  end

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider_request, request, self()})

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

  test "encrypted fields require an explicit remote backend and local schemas stay plaintext" do
    local = start_supervised!({ExtensionRuntime, scope: @scope}, id: :local)
    remote = runtime(%{result: %{"encrypted_output" => @encrypted}})

    for {name, field} <- encrypted_fields() do
      assert contract(remote, name).schema["properties"][field] == %{
               "type" => "string",
               "encrypted" => true
             }

      assert contract(local, name).schema["properties"][field] == %{"type" => "string"}
      assert contract(remote, name).exposure == :direct_model_only
    end

    assert {:ok, profile} = profile(remote)
    assert profile.registry.tools["history::search_contents"].codex_exposure == :direct_model_only
    assert {:error, _} = HistoryNotes.configure(%{mode: :remote_encrypted})
    assert {:error, _} = HistoryNotes.configure(Map.delete(config(%{}), :request_context))

    assert {:ok, %{path: "note.md"}} =
             call(local, "notes::write_file", %{"path" => "note.md", "text" => "plain"})

    assert {:ok, %{contents: "plain"}} = call(local, "notes::read_file", %{"path" => "note.md"})
  end

  test "plaintext and unadmitted extension cancellation retains the typed unsupported contract" do
    local = start_supervised!({ExtensionRuntime, scope: @scope})

    for tool <- ["history::search_contents", "notes::write_file", "memories::list"] do
      assert {:error, %Error{class: :unsupported_capability}} =
               Backend.cancel(operation(local, tool, %{}))
    end
  end

  test "opaque arguments, trusted context, output policy and identity reach the host unchanged" do
    remote = runtime(%{result: %{"encrypted_output" => @encrypted, "images" => @images}})

    for {name, field} <- encrypted_fields() do
      args = %{field => @encrypted, "path" => "note.md"}
      assert {:ok, %{content: [encrypted, first, second]}} = call(remote, name, args)
      assert encrypted == %{type: :encrypted_content, data: %{"encrypted_content" => @encrypted}}
      assert first.data == hd(@images)
      assert second.data == List.last(@images)
      assert_receive {:remote_request, operation, @scope, _}
      assert operation.arguments === args
      assert operation.tool_call_id == "call-1"
      assert operation.invocation_id == "invocation-1"
      assert operation.history_notes_request.body[field] === @encrypted

      assert operation.history_notes_request.body["context"] == %{
               "session_id" => "session-1",
               "current_agent_name" => "writer"
             }

      assert operation.history_notes_request.headers["x-openai-encrypted-tool-arguments"] ==
               "true"

      assert JSON.decode!(
               operation.history_notes_request.headers["x-openai-tool-output-truncation-policy"]
             ) == %{"mode" => "bytes", "limit" => 4096}
    end

    assert {:error, %Error{class: :forbidden}} =
             ExtensionRuntime.call(
               operation(remote, "notes::read_file", %{})
               |> Map.put(:run_id, "other")
             )

    refute_receive {:remote_request, _, _, _}
  end

  test "ordinary remote JSON uses text before ordered images and errors retain their identity" do
    remote = runtime(%{result: %{"files" => ["one"], "images" => @images}})

    assert {:ok, %{content: [%{type: :text, text: json}, _, _]}} =
             call(remote, "notes::list_files_by_prefix", %{})

    assert JSON.decode!(json) == %{"files" => ["one"]}
    assert_receive {:remote_request, operation, _, _}

    refute Map.has_key?(
             operation.history_notes_request.headers,
             "x-openai-encrypted-tool-arguments"
           )

    error = Error.new(:transient_transport, "transport failed", details: %{request_id: "stable"})
    failed = runtime(%{error: error}, :failed)
    assert {:error, ^error} = call(failed, "history::list_windows", %{})

    oversized =
      runtime(%{result: %{"encrypted_output" => @encrypted}}, :oversized, output_limit: 1)

    assert {:error, %Error{class: :budget_exceeded}} =
             call(oversized, "history::list_windows", %{})
  end

  @tag :tmp_dir
  test "Conversation stores and reopens encrypted results and images without replaying effects",
       ctx do
    {:ok, store} = FileHost.open(ctx.tmp_dir)
    on_exit(fn -> FileHost.cleanup(store) end)
    remote = runtime(%{result: %{"encrypted_output" => @encrypted, "images" => @images}})
    {:ok, profile} = profile(remote)
    conversation = conversation(profile, FileHost, store)
    assert {:ok, _} = Conversation.prompt(conversation, "recover history")
    assert_receive {:provider_request, _, provider}, 2_000
    send(provider, {:events, [tool_call(), done()]})
    assert_receive {:remote_request, _, _, _}, 2_000
    assert_receive {:provider_request, %{messages: messages}, provider}, 2_000
    result = Enum.find(messages, &(&1.role == :tool)).result

    assert %{
             content: [
               %{type: :encrypted_content, data: %{"encrypted_content" => @encrypted}},
               _,
               _
             ]
           } = result

    send(provider, {:events, [done()]})
    assert eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    GenServer.stop(conversation)
    :ok = FileHost.cleanup(store)
    {:ok, reopened_store} = FileHost.open(ctx.tmp_dir)
    on_exit(fn -> FileHost.cleanup(reopened_store) end)
    assert {:ok, %{run: run}} = FileHost.load(reopened_store, @scope.run_id)
    assert Enum.any?(Map.values(run.tool_results), &(&1 === result))
    reopened = conversation(profile, FileHost, reopened_store, run: run)
    assert Conversation.status(reopened).messages === run.context.conversation.messages
    refute_receive {:remote_request, _, _, _}
    refute_receive {:provider_request, _, _}
  end

  test "remote calls keep the runtime responsive and cooperative cancellation retires real workers" do
    workers = start_supervised!({Agent, fn -> %{} end})
    remote = runtime(%{blocked: true, workers: workers})
    {:ok, profile} = profile(remote)
    {:ok, store} = EphemeralStore.new(1)
    conversation = conversation(profile, EphemeralStore, store)
    assert {:ok, _} = Conversation.prompt(conversation, "search")
    assert_receive {:provider_request, _, provider}, 2_000
    send(provider, {:events, [tool_call(), done()]})
    assert_receive {:remote_request, _, _, _}, 2_000
    assert_receive {:transport_started, _, worker}, 2_000
    assert length(ExtensionRuntime.contracts(%{extension_runtime: remote})) == 27
    assert :ok = Conversation.cancel(conversation)
    assert eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    refute Process.alive?(worker)
    assert Conversation.status(conversation).run.state == :cancelled
  end

  test "an admission failure releases its registration and never dispatches" do
    remote = runtime(%{result: %{"encrypted_output" => @encrypted}})
    operation = operation(remote, "history::list_windows", %{})

    operation =
      put_in(operation, [:backend_context, :register_cancellation], fn _, _ ->
        {:error, Error.new(:resource_conflict, "stale")}
      end)

    assert {:error, %Error{class: :resource_conflict}} = ExtensionRuntime.call(operation)
    assert eventually(fn -> :sys.get_state(remote).history_notes_requests == %{} end)
    refute_receive {:remote_request, _, _, _}
  end

  test "a board namespace matching history keeps board operations on its selected local backend" do
    remote =
      start_supervised!(
        {ExtensionRuntime,
         scope: @scope,
         board_namespace: "history",
         history_notes: config(%{test: self(), result: %{"encrypted_output" => @encrypted}})}
      )

    assert {:ok, %{channel: %{name: "local-board"}}} =
             call(remote, "history::create_channel", %{"channel_name" => "local-board"})

    refute_receive {:remote_request, _, _, _}
  end

  test "a worker exiting before cancellation admission releases its pending registration" do
    remote = runtime(%{result: %{"encrypted_output" => @encrypted}})
    test = self()

    worker =
      spawn(fn ->
        operation = operation(remote, "history::list_windows", %{})
        {:ok, _, _} = GenServer.call(remote, {:history_notes, {:register, operation}})
        send(test, :registered)
      end)

    monitor = Process.monitor(worker)
    assert_receive :registered
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert eventually(fn -> :sys.get_state(remote).history_notes_requests == %{} end)
  end

  test "unverified transport cancellation retains uncertainty and its registered obligation" do
    workers = start_supervised!({Agent, fn -> %{} end})
    remote = runtime(%{blocked: true, workers: workers, unverified: true})
    {:ok, profile} = profile(remote)
    {:ok, store} = EphemeralStore.new(1)
    conversation = conversation(profile, EphemeralStore, store, cleanup_timeout: 100)
    assert {:ok, _} = Conversation.prompt(conversation, "search")
    assert_receive {:provider_request, _, provider}, 2_000
    send(provider, {:events, [tool_call(), done()]})
    assert_receive {:remote_request, _, _, _}, 2_000
    assert_receive {:transport_started, _, worker}, 2_000
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    assert :ok = Conversation.cancel(conversation)
    assert eventually(fn -> Conversation.status(conversation).phase == :terminal end)
    assert Conversation.status(conversation).run.state == :unknown_outcome
    assert map_size(:sys.get_state(remote).history_notes_requests) == 1
    assert Process.alive?(worker)
  end

  test "sealing between registration and dispatch prevents remote execution" do
    remote = runtime(%{result: %{"encrypted_output" => @encrypted}})
    operation = operation(remote, "history::list_windows", %{})

    register = fn admitted, registration ->
      assert :ok = HistoryNotes.seal_admission(%{operation: admitted, registration: registration})
      {:ok, self()}
    end

    operation = put_in(operation, [:backend_context, :register_cancellation], register)
    assert {:error, %Error{class: :cancelled}} = ExtensionRuntime.call(operation)
    refute_receive {:remote_request, _, _, _}
  end

  defp runtime(context, id \\ :remote, overrides \\ []) do
    config = config(Map.put(context, :test, self())) |> Map.merge(Map.new(overrides))
    start_supervised!({ExtensionRuntime, scope: @scope, history_notes: config}, id: id)
  end

  defp config(context),
    do: %{
      mode: :remote_encrypted,
      adapter: Transport,
      context: context,
      request_context: %{session_id: "session-1", current_agent_name: "writer"},
      output_policy: %{"mode" => "bytes", "limit" => 4096}
    }

  defp encrypted_fields,
    do: [
      {"history::search_contents", "query"},
      {"notes::search_contents", "query"},
      {"notes::append_to_file", "text"},
      {"notes::write_file", "text"}
    ]

  defp contract(runtime, name) do
    Enum.find(ExtensionRuntime.contracts(%{extension_runtime: runtime}), fn contract ->
      contract.namespace && contract.namespace <> "::" <> contract.name == name
    end)
  end

  defp operation(runtime, name, args),
    do: %{
      run_id: @scope.run_id,
      incarnation: 1,
      turn_id: "turn-1",
      step_id: "step-1",
      attempt_id: "attempt-1",
      invocation_id: "invocation-1",
      tool_call_id: "call-1",
      tool_name: name,
      tool_revision: 1,
      catalog_revision: 1,
      arguments: args,
      backend_context: %{family: :extensions, runtime: runtime}
    }

  defp call(runtime, name, args), do: ExtensionRuntime.call(operation(runtime, name, args))

  defp profile(runtime) do
    names =
      Enum.map(ExtensionRuntime.contracts(%{extension_runtime: runtime}), fn c ->
        if c.namespace, do: c.namespace <> "::" <> c.name, else: c.name
      end)

    authority = %{caller: "host", run_id: @scope.run_id, grants: names, tool_revision: 1}
    Codex.profile(:extensions, %{extension_runtime: runtime}, authority)
  end

  defp conversation(profile, store, context, extra \\ []) do
    start_supervised!(
      {Conversation,
       [
         run_id: @scope.run_id,
         incarnation: 1,
         store: store,
         context: context,
         provider: Provider,
         provider_context: %{test: self()},
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         schema_admission: :strict,
         run_timeout: 10_000,
         effect_timeout: 5_000
       ] ++ extra},
      id: make_ref()
    )
  end

  defp tool_call,
    do: %{
      type: :tool_call_completed,
      tool_call: %{
        id: "encrypted-call",
        name: "history::search_contents",
        arguments: %{"query" => @encrypted}
      }
    }

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
  defp eventually(fun, remaining \\ 200)

  defp eventually(fun, remaining) when remaining > 0 do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end

  defp eventually(_, 0), do: false
end
