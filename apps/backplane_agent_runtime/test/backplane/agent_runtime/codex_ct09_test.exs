defmodule Backplane.AgentRuntime.CodexCt09Test do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex.{Hosted, Image, Services, Web}

  defmodule Transport do
    def request(uri, _timeout),
      do:
        {:ok,
         %{status: 200, headers: [{"content-type", "text/plain"}], body: "hello:" <> uri.host}}
  end

  defmodule SearchAdapter do
    def search(query, _opts),
      do: {:ok, %{results: [%{title: query, url: "https://example.test"}]}}

    def x_search(query, _opts), do: {:ok, %{results: [%{text: query}], citations: []}}
  end

  defmodule LocalHttpServer do
    def start(body) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_address, port}} = :inet.sockname(listener)
      pid = spawn(fn -> serve(listener, body) end)
      {pid, port}
    end

    defp serve(listener, body) do
      {:ok, socket} = :gen_tcp.accept(listener)

      response =
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, _request} -> :gen_tcp.send(socket, response)
        {:error, :closed} -> :ok
      end

      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end
  end

  defmodule RawHttpServer do
    def start(response) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_address, port}} = :inet.sockname(listener)

      pid =
        spawn(fn ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, _} = :gen_tcp.recv(socket, 0, 2_000)
          :ok = :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end)

      {pid, port}
    end
  end

  defmodule CleanupHttpServer do
    def start(parent) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_address, port}} = :inet.sockname(listener)

      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _} = :gen_tcp.recv(socket, 0, 2_000)
        :ok = :gen_tcp.send(socket, String.duplicate("x", 131_072))
        send(parent, {:peer_result, :gen_tcp.recv(socket, 0, 2_000)})
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

      port
    end
  end

  defmodule ImageAdapter do
    def generate(request, _opts),
      do:
        {:ok,
         %{type: "image", prompt: Map.get(request, :prompt, request["prompt"]), data: "bytes"}}
  end

  defmodule WebRunAdapter do
    def run(%{"search_query" => [%{"q" => query}]}, _opts),
      do: {:ok, %{results: [%{title: query, url: "https://example.test/result"}]}}
  end

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

  defmodule SlowImageAdapter do
    def generate(_request, _opts), do: Process.sleep(100) && {:ok, %{data: "late"}}
  end

  defmodule ProviderAdapter do
    def negotiate(capabilities, _context), do: {:ok, %{accepted: capabilities}}

    def invoke_hosted(declaration, input, _context),
      do: {:ok, %{id: declaration["id"], output: input}}

    def observe_hosted(events), do: {:ok, %{events: events, complete?: true}}
    def cancel_hosted(_declaration, _context), do: {:ok, %{cancelled: true}}
  end

  test "web fetch enforces scheme, host authorization, and byte limits" do
    assert {:ok, %{status: 200, body: "hello:example.test", content_type: "text/plain"}} =
             Web.fetch("https://example.test/path",
               transport: Transport,
               allowed_hosts: ["example.test"]
             )

    assert {:error, %Error{class: :forbidden}} = Web.fetch("file:///tmp/no", transport: Transport)

    assert {:error, %Error{class: :forbidden}} =
             Web.fetch("https://other.test",
               transport: Transport,
               allowed_hosts: ["example.test"]
             )

    assert {:error, %Error{class: :budget_exceeded}} =
             Web.fetch("https://example.test",
               transport: Transport,
               allowed_hosts: ["example.test"],
               max_bytes: 2
             )
  end

  test "web fetch crosses a real local HTTP boundary" do
    {server, port} = LocalHttpServer.start("wire-body")
    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :kill) end)

    assert {:ok, %{status: 200, body: "wire-body", content_type: "text/plain"}} =
             Web.fetch("http://127.0.0.1:#{port}/resource",
               allowed_hosts: ["127.0.0.1"],
               timeout: 2_000
             )
  end

  test "default HTTP transport rejects redirects, chunking, and oversized streams" do
    redirect =
      "HTTP/1.1 302 Found\r\nlocation: http://elsewhere.test\r\ncontent-length: 0\r\n\r\n"

    {_server, port} = RawHttpServer.start(redirect)

    assert {:error, %Error{class: :forbidden}} =
             Web.fetch("http://127.0.0.1:#{port}/", allowed_hosts: ["127.0.0.1"])

    chunked = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    {_server, port} = RawHttpServer.start(chunked)

    assert {:error, %Error{class: :unsupported_capability}} =
             Web.fetch("http://127.0.0.1:#{port}/", allowed_hosts: ["127.0.0.1"])

    body = String.duplicate("x", 70_000)
    response = "HTTP/1.1 200 OK\r\ncontent-length: 70000\r\n\r\n" <> body
    {_server, port} = RawHttpServer.start(response)

    assert {:error, %Error{class: :budget_exceeded}} =
             Web.fetch("http://127.0.0.1:#{port}/", allowed_hosts: ["127.0.0.1"], max_bytes: 8)
  end

  test "default transport closes failed sockets and rejects unverified HTTPS" do
    port = CleanupHttpServer.start(self())

    assert {:error, %Error{class: :budget_exceeded}} =
             Web.fetch("http://127.0.0.1:#{port}/",
               allowed_hosts: ["127.0.0.1"],
               max_bytes: 1
             )

    assert_receive {:peer_result, {:error, :closed}}, 2_000

    assert {:error, %Error{class: :unsupported_capability}} =
             Web.fetch("https://example.test/", allowed_hosts: ["example.test"])
  end

  test "search adapters preserve bounded result and backend errors" do
    assert {:ok, %{results: [%{title: "query"}]}} =
             Web.search(SearchAdapter, "query", result_limit: 10_000)

    assert {:ok, %{results: [%{text: "post"}], citations: []}} =
             Web.x_search(SearchAdapter, "post")

    assert {:error, %Error{class: :unsupported_capability}} =
             Web.search(UnknownAdapter, "query")
  end

  test "image adapter and missing service are explicit" do
    assert {:ok, %{type: "image", data: "bytes"}} =
             Image.generate(ImageAdapter, %{prompt: "cat"}, [])

    assert {:error, %Error{class: :unsupported_capability}} = Image.generate(nil, %{}, [])

    assert {:error, %Error{class: :timeout}} =
             Image.generate(SlowImageAdapter, %{prompt: "cat"}, timeout: 1)
  end

  test "provider-hosted capabilities negotiate and preserve observed results" do
    assert {:ok, %{accepted: ["web_search"]}} =
             Hosted.negotiate(ProviderAdapter, ["web_search"], %{})

    assert {:ok, %{id: "call-1", output: %{"q" => "x"}}} =
             Hosted.invoke(ProviderAdapter, %{"id" => "call-1"}, %{"q" => "x"}, %{})

    assert {:ok, %{complete?: true}} = Hosted.observe(ProviderAdapter, [%{type: "done"}])

    assert {:ok, %{cancelled: true}} =
             Hosted.cancel(ProviderAdapter, %{"id" => "call-1"}, %{})

    assert {:error, %Error{class: :unsupported_capability}} = Hosted.observe(UnknownAdapter, [])
  end

  test "provider-hosted web search is declared separately and never enters the local registry" do
    context = %{
      provider_hosted: %{
        adapter: ProviderAdapter,
        capabilities: ["web_search"],
        context: %{provider: "fixture"},
        web_search: %{
          mode: :indexed,
          search_context_size: "high",
          search_content_types: ["text", "image"]
        }
      }
    }

    assert {:ok,
            [
              %{
                type: "web_search",
                external_web_access: true,
                indexed_web_access: true,
                search_context_size: "high",
                search_content_types: ["text", "image"]
              }
            ] = hosted_tools} = Hosted.declarations(context)

    authority = %{caller: "host", run_id: "hosted-run", grants: [], tool_revisions: %{}}

    assert {:ok, profile} =
             Codex.profile(:configured, context, authority,
               families: [:interactive],
               tools: []
             )

    assert profile.hosted_tools == hosted_tools
    assert profile.registry.tools == %{}

    {:ok, store} = EphemeralStore.new(1)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "hosted-run",
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{test: self()},
        subscriber: self(),
        registry: profile.registry,
        tools: profile.tools,
        hosted_tools: profile.hosted_tools,
        authority: profile.authority,
        schema_admission: :strict,
        work: 6,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(conversation, "hosted search")
    assert_receive {:provider, %{tools: ^hosted_tools}, provider}

    hosted_event = %{
      type: :provider_hosted_event,
      capability: "web_search",
      event: %{status: "completed", id: "search-1"}
    }

    send(provider, {
      :events,
      [
        hosted_event,
        %{type: :response_completed, message: %{role: :assistant, content: "found"}}
      ]
    })

    assert_receive {:agent_runtime, "hosted-run", %{type: :provider_hosted_event}}
    assert_receive {:agent_runtime, "hosted-run", %{type: :run_completed}}
  end

  test "service profile is explicit and keeps backend authority in context" do
    names = Enum.map(Services.definitions(), & &1.tool_name)
    assert names == ["web::fetch", "web::search", "web::x_search"]

    assert {:error, %Error{class: :unsupported_capability}} =
             Services.call(%{}, "web::search", %{"query" => "query"})

    assert {:error, %Error{class: :unsupported_capability}} =
             Services.call(%{}, "image::generate", %{"prompt" => "cat"})

    assert {:error, %Error{class: :forbidden}} =
             Services.admitted_definitions(%{caller: "host", run_id: "run"})

    assert {:error, %Error{class: :forbidden}} =
             Services.admitted_definitions(%{
               caller: "host",
               run_id: "run",
               grants: ["web::fetch"],
               tool_revisions: %{"web::fetch" => 1}
             })

    assert {:ok, %{accepted: ["web::fetch", "web::search", "web::x_search"]}} =
             Services.admitted_definitions(%{
               caller: "host",
               run_id: "run",
               grants: ["web::fetch", "web::search", "web::x_search"],
               tool_revisions: %{
                 "web::fetch" => 1,
                 "web::search" => 1,
                 "web::x_search" => 1
               }
             })
  end

  test "pinned web and image extensions are public only with configured adapters" do
    tools = ["web::run", "image_gen::imagegen"]
    context = %{web_run_adapter: WebRunAdapter, image_adapter: ImageAdapter}

    authority = %{
      caller: "host",
      run_id: "service-run",
      grants: tools,
      tool_revisions: Map.new(tools, &{&1, 1})
    }

    assert {:ok, profile} = Codex.profile(:service_compat, context, authority, tools: tools)
    assert Enum.map(profile.tools, & &1.name) == tools

    web_parameters = Enum.find(profile.tools, &(&1.name == "web::run")).parameters

    assert Map.keys(web_parameters["properties"]) |> MapSet.new() ==
             MapSet.new(
               ~w(search_query image_query open click find screenshot finance weather sports time response_length)
             )

    refute Map.has_key?(web_parameters, "additionalProperties")

    {:ok, store} = EphemeralStore.new(1)

    {:ok, conversation} =
      Conversation.start_link(
        run_id: "service-run",
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{test: self()},
        subscriber: self(),
        registry: profile.registry,
        tools: profile.tools,
        authority: profile.authority,
        schema_admission: :strict,
        work: 10,
        run_timeout: 5_000
      )

    assert {:ok, _} = Conversation.prompt(conversation, "use services")
    assert_receive {:provider, %{tools: provider_tools}, provider}
    assert MapSet.new(provider_tools, & &1.name) == MapSet.new(tools)

    send(provider, {
      :events,
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "web-run",
            name: "web::run",
            arguments: %{
              "search_query" => [%{"q" => "backplane"}],
              "future_command" => []
            }
          }
        },
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "imagegen",
            name: "image_gen::imagegen",
            arguments: %{"prompt" => "runtime diagram"}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "calling"}}
      ]
    })

    assert_receive {:provider, %{messages: messages}, final_provider}, 5_000

    assert %{name: "image_gen::imagegen", result: %{data: "bytes", is_error: false}} =
             List.last(messages)

    assert Enum.any?(messages, fn
             %{name: "web::run", result: %{results: [%{title: "backplane"}]}} -> true
             _ -> false
           end)

    send(final_provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })

    assert_receive {:agent_runtime, "service-run", %{type: :run_completed}}
  end
end
