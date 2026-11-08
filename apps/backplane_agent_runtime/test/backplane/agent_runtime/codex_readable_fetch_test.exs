defmodule Backplane.AgentRuntime.CodexReadableFetchTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, InputSchema}
  alias Backplane.AgentRuntime.Codex.{Services, Session, Web}

  @arguments %{
    "url" => "https://example.test/start",
    "instructions" => "Keep the original document.",
    "extract_mode" => "markdown",
    "max_chars" => 4_000
  }

  defmodule FetchHost do
    @behaviour Web.ReadableFetch

    def fetch(arguments, opts) do
      if test = opts[:test] do
        send(test, {:readable_fetch, arguments, opts, self()})
      end

      if opts[:runtime_context] do
        receive do
          :continue -> :ok
        end
      end

      {:ok, Keyword.get(opts, :fixture, fixture(arguments["url"]))}
    end

    def fixture(url) do
      %{
        "url" => url,
        "final_url" => "https://example.test/redirected/document",
        "text" => "# Original\r\n汉字 900719925474099312345 1.000000000000000001\n",
        "content_type" => "text/html; charset=utf-8",
        "title" => "Original title",
        "extractor" => "host-readability",
        "extract_mode" => "markdown",
        "length" => 64,
        "timing" => %{"elapsed_ms" => 7},
        "cache" => %{"hit" => true, "ttl_ms" => 60_000},
        "acquisition" => %{"redirects" => 1, "transfer_encoding" => "chunked"}
      }
    end
  end

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:readable_provider, request, self()})

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

  test "the factory explicitly versions readable inputs before catalog admission" do
    [raw | _] = Services.definitions()
    [readable | _] = Services.definitions(%{web_fetch_adapter: FetchHost})
    assert raw.tool_revision == 1
    refute Map.has_key?(raw.schema["properties"], "extract_mode")
    assert readable.tool_revision == 2
    assert {:ok, @arguments} = InputSchema.validate(readable.schema, @arguments)
    assert {:error, _} = InputSchema.validate(raw.schema, @arguments)

    for invalid <- [
          Map.put(@arguments, "extract_mode", "unknown"),
          Map.put(@arguments, "max_chars", 0),
          Map.put(@arguments, "runtime_context", %{})
        ] do
      assert {:error, _} = InputSchema.validate(readable.schema, invalid)
    end

    [contract] =
      Services.contracts(%{web_fetch_adapter: FetchHost, web_allowed_hosts: ["example.test"]})

    assert contract.tool_revision == 2
    assert contract.backend_context.context.web_fetch_adapter == FetchHost
    assert contract.schema == readable.schema
  end

  test "host extraction receives complete input and preserves rich documents and metadata" do
    expected = FetchHost.fixture(@arguments["url"])

    assert {:ok, ^expected} =
             Web.fetch_readable(FetchHost, @arguments,
               allowed_hosts: ["example.test"],
               test: self()
             )

    assert_receive {:readable_fetch, @arguments, opts, _}
    assert opts[:timeout] == 5_000
    refute Keyword.has_key?(opts, :runtime_context)

    size = :erlang.external_size(expected)

    assert {:ok, ^expected} =
             Web.fetch_readable(FetchHost, @arguments, allowed_hosts: :all, result_limit: size)

    assert {:error, %Error{class: :budget_exceeded}} =
             Web.fetch_readable(FetchHost, @arguments,
               allowed_hosts: :all,
               result_limit: size - 1
             )

    for invalid <- [
          Map.put(expected, "text", <<255>>),
          Map.put(expected, "url", "https://example.test/other"),
          Map.put(expected, "cache", %{hit: true}),
          Map.put(expected, "context", self()),
          Map.delete(expected, "content_type")
        ] do
      assert {:error, %Error{class: :malformed_result}} =
               Web.fetch_readable(FetchHost, @arguments, allowed_hosts: :all, fixture: invalid)
    end
  end

  test "the original effect allowance is clamped without renewing or inventing identity" do
    runtime = %{effect_deadline: fn -> {:ok, %{remaining_ms: 300}} end}
    parent = self()

    task =
      Task.async(fn ->
        Web.fetch_readable(FetchHost, @arguments,
          allowed_hosts: :all,
          test: parent,
          timeout: 100,
          runtime_context: runtime
        )
      end)

    assert_receive {:readable_fetch, @arguments, opts, adapter}, 1_000
    assert opts[:timeout] == 100
    # The fixture waits when runtime context is present; the bounded owner retires it.
    assert {:error, %Error{class: :timeout}} = Task.await(task)
    refute Process.alive?(adapter)

    error = Error.new(:resource_conflict, "original invocation is retired")

    assert {:error, ^error} =
             Web.fetch_readable(FetchHost, @arguments,
               allowed_hosts: :all,
               runtime_context: %{effect_deadline: fn -> {:error, error} end}
             )

    assert {:error, %Error{class: :timeout}} =
             Web.fetch_readable(FetchHost, @arguments,
               allowed_hosts: :all,
               runtime_context: %{effect_deadline: fn -> {:ok, %{remaining_ms: 0}} end}
             )
  end

  test "native Conversation delivers exact readable results with actual identity and deadline" do
    run_id = "readable-native"

    authority = %{
      caller: "host",
      run_id: run_id,
      grants: ["web::fetch"],
      tool_revisions: %{"web::fetch" => 2}
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 7)

    context = %{
      web_fetch_adapter: FetchHost,
      web_allowed_hosts: ["example.test"],
      web_timeout: 20_000,
      web_fetch_options: [test: self(), timeout: 50_000, runtime_context: %{identity: :private}],
      runtime_context: %{identity: :untrusted_static}
    }

    assert {:ok, profile} = Codex.profile(:service_compat, context, authority)
    assert {:ok, store} = EphemeralStore.new(7)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: run_id,
         incarnation: 7,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{test: self()},
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         catalog_revision: 3,
         schema_admission: :strict,
         run_timeout: 10_000,
         effect_timeout: 2_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "read the document")
    assert_receive {:readable_provider, %{tools: [tool]}, provider}, 2_000
    assert tool.parameters["properties"]["extract_mode"]["enum"] == ["markdown", "text"]

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "fetch", name: "web::fetch", arguments: @arguments}
         },
         done()
       ]}
    )

    assert_receive {:readable_fetch, @arguments, opts, adapter}, 3_000
    runtime = opts[:runtime_context]
    assert runtime.identity.run_id == run_id
    assert runtime.identity.tool_revision == 2
    assert runtime.identity.catalog_revision == 3
    assert runtime.identity.tool_call_id == "fetch"
    assert runtime.resource_owner_pid == conversation
    assert runtime.effect_owner_pid == :sys.get_state(conversation).effect.task.pid
    assert {:ok, budget} = runtime.effect_deadline.()
    assert budget.selected_timeout_ms == 2_000
    assert opts[:timeout] in budget.remaining_ms..2_000
    send(adapter, :continue)

    assert_receive {:readable_provider, %{messages: messages}, provider}, 3_000
    expected = FetchHost.fixture(@arguments["url"]) |> Map.put(:is_error, false)
    assert Enum.any?(messages, &match?(%{role: :tool, result: ^expected}, &1))
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 3_000
    assert {:ok, %{run: run}} = EphemeralStore.load(store, run_id)
    assert Map.values(run.tool_results) == [expected]
    assert run.context.conversation.messages == Conversation.status(conversation).messages
    assert {:error, %Error{class: :resource_conflict}} = runtime.effect_deadline.()
    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end
