defmodule Backplane.AgentRuntime.CodexRawSearchTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{Services, Session, Web}

  defmodule SearchHost do
    def search(query, opts), do: {:ok, Keyword.get(opts, :fixture, fixture(query))}
    def x_search(query, opts), do: search(query, opts)

    def fixture(query) do
      data = %{
        "query" => "ordinary-protocol-relative",
        "provider" => "duckduckgo",
        "count" => 1,
        "tookMs" => 7,
        "results" => [
          %{
            "title" => "Relative source",
            "url" => "//www.relative.example/guide",
            "snippet" => "Relative ordinary snippet."
          }
        ]
      }

      data = if query == "cached", do: Map.put(data, "cached", true), else: data
      %{"kind" => "raw", "provider" => "duckduckgo", "data" => data}
    end
  end

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:raw_provider, request, self()})

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

  test "fresh and nested-cache raw envelopes preserve the full provider data and outer keys" do
    for query <- ["fresh", "cached"] do
      fixture = SearchHost.fixture(query)

      assert {:ok, ^fixture} = Web.search(SearchHost, query)
      assert {:ok, ^fixture} = Web.x_search(SearchHost, query)
      assert Enum.sort(Map.keys(fixture)) == ["data", "kind", "provider"]
      assert hd(fixture["data"]["results"])["url"] == "//www.relative.example/guide"
      assert Map.get(fixture["data"], "cached") == if(query == "cached", do: true, else: nil)
    end
  end

  test "atom envelope keys and extra metadata are preserved without rewriting portable data" do
    fixture = %{
      kind: :raw,
      provider: "duckduckgo",
      data: Map.put(SearchHost.fixture("fresh")["data"], "values", [nil, false, 2, 1.5, "汉字"]),
      metadata: %{source: "host"}
    }

    assert {:ok, ^fixture} = Web.search(SearchHost, "q", fixture: fixture)
    assert {:ok, ^fixture} = Web.x_search(SearchHost, "q", fixture: fixture)
  end

  test "the whole raw envelope retains the exact existing result bound" do
    fixture = SearchHost.fixture("cached")
    size = :erlang.external_size(fixture)

    assert {:ok, ^fixture} =
             Web.search(SearchHost, "q", fixture: fixture, result_limit: size)

    assert {:error, %Error{class: :budget_exceeded}} =
             Web.search(SearchHost, "q", fixture: fixture, result_limit: size - 1)

    assert {:error, %Error{class: :budget_exceeded}} =
             Web.x_search(SearchHost, "q", fixture: fixture, result_limit: size - 1)

    for limit <- [0, -1, nil, "large"] do
      assert {:error, %Error{class: :validation}} =
               Web.search(SearchHost, "q", fixture: fixture, result_limit: limit)
    end
  end

  test "raw envelope aliases and required fields are validated" do
    fixture = SearchHost.fixture("fresh")

    for invalid <- [
          Map.delete(fixture, "kind"),
          Map.put(fixture, "kind", "unknown"),
          Map.delete(fixture, "provider"),
          Map.put(fixture, "provider", ""),
          Map.put(fixture, "provider", <<255>>),
          Map.delete(fixture, "data"),
          Map.put(fixture, "data", []),
          Map.put(fixture, "data", nil),
          Map.put(fixture, :kind, :raw),
          Map.put(fixture, :provider, "duckduckgo"),
          Map.put(fixture, :data, fixture["data"])
        ] do
      assert {:error, %Error{class: :malformed_result}} =
               Web.search(SearchHost, "q", fixture: invalid)
    end
  end

  test "raw data permits only recursively portable plain-map JSON values" do
    fixture = SearchHost.fixture("fresh")

    for invalid_data <- [
          %URI{host: "example.test"},
          %{atom_key: "value"},
          %{<<255>> => "value"},
          %{"value" => <<255>>},
          %{"value" => self()},
          %{"value" => :opaque},
          %{"value" => {"tuple"}},
          %{"value" => fn -> :opaque end},
          %{"value" => ["head" | "tail"]},
          %{"nested" => [%{"value" => %URI{}}]}
        ] do
      invalid = Map.put(fixture, "data", invalid_data)

      assert {:error, %Error{class: :malformed_result}} =
               Web.search(SearchHost, "q", fixture: invalid)
    end
  end

  test "legacy result lists and answer envelopes retain admission and precedence" do
    for fixture <- [
          %{results: [], kind: :raw},
          %{"results" => [], "kind" => "raw"},
          %{kind: :answer, content: "answer", citations: []},
          %{"kind" => "answer", "content" => "answer", "citations" => []}
        ] do
      assert {:ok, ^fixture} = Web.search(SearchHost, "q", fixture: fixture)
    end
  end

  test "native and real Code Mode search preserve fresh and cached raw results in history and Store" do
    assert System.find_executable("deno"), "this acceptance test requires real Deno"

    for mode <- [:direct, :deno], query <- ["fresh", "cached"] do
      run_id = "raw-search-#{mode}-#{query}"
      session = start_supervised!({Session, owner_pid: self()}, id: make_ref())
      {profile, binding} = profile(session, run_id)
      {:ok, store} = EphemeralStore.new(7)

      conversation =
        start_supervised!(
          {Conversation,
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
           effect_timeout: 5_000},
          id: make_ref()
        )

      assert {:ok, _} = Conversation.prompt(conversation, "search")
      assert_receive {:raw_provider, %{run_id: ^run_id}, provider}, 2_000
      send(provider, {:events, [search_call(mode, query), done()]})
      assert_receive {:raw_provider, %{messages: messages}, provider}, 5_000
      expected = SearchHost.fixture(query)
      assert_result(messages, mode, expected)
      send(provider, {:events, [done()]})
      assert eventually(fn -> Conversation.status(conversation).phase == :terminal end)
      assert {:ok, %{run: run}} = EphemeralStore.load(store, run_id)
      assert run.context.conversation.messages == Conversation.status(conversation).messages
      assert_result(run.context.conversation.messages, mode, expected)

      journal_results =
        Enum.map(run.tool_results, fn {_id, result} -> %{role: :tool, result: result} end)

      assert_result(journal_results, mode, expected)
      GenServer.stop(conversation)
      assert {:ok, %{status: :confirmed}} = Session.close(session)
    end
  end

  defp profile(session, run_id) do
    names = ["exec", "wait", "web::search"]
    authority = %{caller: "host", run_id: run_id, grants: names, tool_revision: 1}
    {:ok, binding} = Session.bind(session, authority, incarnation: 7)
    contracts = Services.contracts(%{search_adapter: SearchHost})

    {:ok, profile} =
      Codex.profile(
        :mixed,
        %{session_binding: binding, code_mode_contracts: contracts},
        authority,
        tools: names
      )

    {profile, binding}
  end

  defp search_call(:direct, query),
    do: %{
      type: :tool_call_completed,
      tool_call: %{id: "search", name: "web::search", arguments: %{"query" => query}}
    }

  defp search_call(:deno, query),
    do: %{
      type: :tool_call_completed,
      tool_call: %{
        id: "exec-search",
        name: "exec",
        arguments: "return await tools.web__search({query: #{JSON.encode!(query)}});"
      }
    }

  defp assert_result(messages, :direct, expected) do
    assert Enum.any?(messages, fn
             %{role: :tool, result: result} -> result == Map.put(expected, :is_error, false)
             _ -> false
           end)
  end

  defp assert_result(messages, :deno, expected) do
    assert Enum.any?(messages, fn
             %{role: :tool, result: %{status: :completed, value: ^expected, is_error: false}} ->
               true

             _ ->
               false
           end)
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

  defp eventually(_fun, 0), do: false
end
