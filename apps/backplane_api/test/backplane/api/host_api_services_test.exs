defmodule Backplane.Api.HostApiServicesTest do
  use Backplane.Api.ChannelCase, async: false

  import Plug.Conn, except: [push: 3]

  alias Backplane.{Clients, Embedding}
  alias Backplane.HostAgent.ApiForwarder
  alias Backplane.HostApi.Transport

  alias Backplane.LLM.{
    HostServices,
    ModelAlias,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    ProxyPlug,
    RateLimiter
  }

  alias Backplane.Settings.Credentials
  alias Backplane.Skills.Hosts

  defmodule Upstream do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, {owner, response}) do
      {:ok, body, conn} = read_body(conn)

      send(
        owner,
        {:upstream, conn.request_path, conn.query_string, conn.req_headers, Jason.decode!(body)}
      )

      case response do
        {:json, status, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-local-api", "yes")
          |> send_resp(status, body)

        {:stream, chunks} ->
          conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

          Enum.reduce(chunks, conn, fn bytes, conn ->
            {:ok, conn} = chunk(conn, bytes)
            conn
          end)
      end
    end
  end

  defmodule ClosedDownstream do
    defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
    def chunk(_state, _body), do: {:error, :closed}
  end

  setup do
    {:ok, host, host_token, token} =
      Hosts.create_agent_with_token(%{"name" => "host-api-integration"})

    {:ok, socket} =
      connect(Backplane.Api.HostAgentSocket, %{"host_id" => host.id},
        connect_info: %{x_headers: [{"x-backplane-host-token", token}]}
      )

    {:ok, _, socket} =
      subscribe_and_join(socket, "host_agent:#{host.id}", %{
        "host_api" => %{"protocol" => "host_api.v1"}
      })

    assert_push("api_services", inventory)
    owner = self()

    forwarder =
      start_supervised!(
        {ApiForwarder,
         channel: socket.channel_pid,
         push: fn frame ->
           ref = make_ref()
           send(owner, {:frame, self(), ref, frame})

           receive do
             {^ref, result} -> result
           after
             5_000 -> {:error, :timeout}
           end
         end}
      )

    register(socket, forwarder, inventory)

    {:ok, _, client_token} =
      Clients.issue_client(%{name: "host-api-client", scopes: ["llm::invoke"], active: true})

    ModelResolver.clear_cache()
    RateLimiter.reset()
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})
    :ok = Backplane.Settings.set(ModelAlias.provider_setting_key(), [])
    on_exit(fn -> ModelResolver.clear_cache() end)

    %{
      host: host,
      host_token: host_token,
      socket: socket,
      forwarder: forwarder,
      token: client_token
    }
  end

  test "embedding traverses the authenticated channel, injects only upstream credentials and uses the exact endpoint",
       c do
    response = Jason.encode!(%{data: [%{embedding: [0.1, 0.2]}]})
    url = upstream({:json, 200, response}) <> "/custom/encode?purpose=host"
    service = service(c, %{"openai_embeddings" => url})
    {:ok, _} = Credentials.store("host-api-key", "local-key", "llm")

    {:ok, %{provider: provider, model: model}} =
      Embedding.create_provider_with_model(%{
        "name" => "host-embedding",
        "host_service_id" => service.id,
        "credential" => "host-api-key",
        "enabled" => true,
        "model" => "local-vector",
        "model_enabled" => true
      })

    model_id = Embedding.model_id(%{model | provider: provider})
    result = request(c, "/v1/embeddings", %{model: model_id, input: ["hello"]}) |> complete(c)
    assert result.status == 200
    assert result.resp_body == response
    assert get_resp_header(result, "x-local-api") == ["yes"]
    assert_receive {:upstream, "/custom/encode", "purpose=host", headers, body}
    assert body == %{"model" => "local-vector", "input" => ["hello"]}
    assert {"authorization", "Bearer local-key"} in headers
    refute {"authorization", "Bearer #{c.token}"} in headers
    refute Enum.any?(headers, fn {name, _} -> name in ["x-api-key", "cookie"] end)
  end

  for {api, path, family, stream?} <- [
        {:openai_chat_completions, "/v1/chat/completions", :openai, false},
        {:openai_responses, "/v1/responses", :openai, true},
        {:anthropic_messages, "/v1/messages", :anthropic, true}
      ] do
    @api api
    @path path
    @family family
    @stream stream?
    test "routes #{@api} through the host and restores the requested model", c do
      response =
        if @stream do
          # The model field is deliberately split across independent HTTP writes.
          {:stream,
           [
             "data: {\"model\":\"local",
             "-chat\",\"text\":\"hello\"}\n\n",
             "data: [DONE]\n\n",
             "data: {\"partial\":"
           ]}
        else
          {:json, 200, Jason.encode!(%{model: "local-chat", choices: []})}
        end

      service = service(c, %{to_string(@api) => upstream(response) <> "/native/inference"})
      model = llm_model(service, @api, @family)

      result =
        request(c, @path, %{
          model: model,
          stream: @stream,
          messages: [],
          input: "hello",
          max_tokens: 10
        })
        |> complete(c)

      assert result.status == 200

      if @stream do
        assert result.state == :chunked
        assert result.resp_body =~ "\"model\":\"#{model}\""
        assert result.resp_body =~ "data: [DONE]\n\n"
        assert String.ends_with?(result.resp_body, "data: {\"partial\":")
      else
        assert Jason.decode!(result.resp_body)["model"] == model
      end

      assert_receive {:upstream, "/native/inference", "", headers, body}
      assert body["model"] == "local-chat"

      refute Enum.any?(headers, fn {name, _} ->
               name in ["authorization", "x-api-key", "cookie"]
             end)
    end
  end

  test "preserves upstream errors and stops routing after a service is disabled", c do
    response = ~s({"error":{"message":"local capacity"}})

    service =
      service(c, %{"openai_chat_completions" => upstream({:json, 429, response}) <> "/busy"})

    model = llm_model(service, :openai_chat_completions, :openai)
    result = request(c, "/v1/chat/completions", %{model: model}) |> complete(c)
    assert result.status == 429
    assert result.resp_body == response
    assert {:ok, _} = HostServices.update(service, %{enabled: false})
    assert_push("api_services", inventory)
    register(c.socket, c.forwarder, inventory)
    result = request(c, "/v1/chat/completions", %{model: model}) |> complete(c)
    assert result.status == 503
    refute_push("api_request", _)
  end

  test "endpoint updates retire pending work and require the new inventory registration", c do
    url = upstream({:json, 200, ~s({"data":[]})}) <> "/updated/encode"
    service = service(c, %{"openai_embeddings" => "http://127.0.0.1:1/old"})

    payload = %{
      "api" => "openai_embeddings",
      "headers" => [],
      "body_base64" => Base.encode64("{}")
    }

    {:ok, id} = Transport.open(c.host.id, service.id, 1, payload)
    assert_push("api_request", _)
    {:ok, updated} = HostServices.update(service, %{endpoints: %{"openai_embeddings" => url}})
    assert_push("api_services", inventory)
    assert_receive {:host_api_error, ^id, :service_unavailable}
    assert_push("api_cancel", %{"request_id" => ^id})

    assert {:error, :service_unavailable} =
             Transport.open(c.host.id, service.id, updated.revision, payload)

    register(c.socket, c.forwarder, inventory)

    {:ok, %{provider: provider, model: model}} =
      Embedding.create_provider_with_model(%{
        "name" => "updated-embedding",
        "host_service_id" => service.id,
        "enabled" => true,
        "model" => "vector",
        "model_enabled" => true
      })

    result =
      request(c, "/v1/embeddings", %{
        model: Embedding.model_id(%{model | provider: provider}),
        input: "hello"
      })
      |> complete(c)

    assert result.status == 200
    assert_receive {:upstream, "/updated/encode", _, _, _}
  end

  test "downstream write failure cancels the remote call without acknowledging more bytes", c do
    service =
      service(c, %{
        "openai_responses" =>
          upstream({:stream, ["data: {\"model\":\"local-chat\"}\n\n"]}) <> "/stream"
      })

    model = llm_model(service, :openai_responses, :openai)
    task = request(c, "/v1/responses", %{model: model, stream: true}, closed_downstream: true)
    result = complete(task, c)
    assert result.private.relayixir_downstream_disconnected

    id =
      receive do
        {:cancelled, id} ->
          id

        %Phoenix.Socket.Message{event: "api_cancel", payload: %{"request_id" => id}} ->
          :ok = ApiForwarder.cancel(c.forwarder, id)
          id
      after
        1_000 -> flunk("downstream failure did not cancel the remote request")
      end

    assert {:error, :not_found} = Transport.ack(id)
  end

  test "requires declaration, authenticated ownership and active host credentials", c do
    service = service(c, %{"openai_responses" => "http://127.0.0.1:1/responses"})

    payload = %{
      "api" => "openai_responses",
      "headers" => [],
      "body_base64" => Base.encode64("{}")
    }

    assert {:error, :not_connected} = Transport.open(Ecto.UUID.generate(), service.id, 1, payload)
    assert {:ok, id} = Transport.open(c.host.id, service.id, 1, payload)
    assert_push("api_request", _)

    ref =
      push(c.socket, "api_response", %{
        "request_id" => id,
        "type" => "headers",
        "status" => 200,
        "headers" => []
      })

    assert_receive {:host_api_frame, ^id, {:headers, 200, []}}
    refute_reply(ref, :ok, _, 20)
    :ok = Transport.ack(id)
    assert_reply(ref, :ok, _)
    {:ok, _} = Hosts.revoke_auth_token_for_agent(c.host, c.host_token.id)
    ref = push(c.socket, "api_response", %{"request_id" => id, "type" => "done"})
    assert_reply(ref, :error, %{"code" => "unauthorized"})
    assert_receive {:host_api_error, ^id, :not_connected}
    assert {:error, :not_connected} = Transport.open(c.host.id, service.id, 1, payload)
  end

  test "real host socket callbacks register, stream large responses and receive configuration changes",
       c do
    {:ok, host, _, token} = Hosts.create_agent_with_token(%{"name" => "real-host-api-socket"})
    event = Jason.encode!(%{model: "local-chat", text: String.duplicate("x", 100_000)})
    upstream_url = upstream({:stream, ["data: " <> event <> "\n\n", "data: [DONE]\n\n"]})

    {:ok, service} =
      HostServices.create(%{
        host_id: host.id,
        name: "real-socket-service",
        endpoints: %{"openai_chat_completions" => upstream_url <> "/real/chat"}
      })

    model = llm_model(service, :openai_chat_completions, :openai)

    endpoint =
      start_supervised!(
        Supervisor.child_spec(
          {Gaoxy.HTTP, plug: {Backplane.Api.Endpoint, []}, ip: {127, 0, 0, 1}, port: 0},
          id: :host_api_public
        )
      )

    %{local: {:ok, {_, port}}} = Gaoxy.info(endpoint, :http)

    unless Process.whereis(Backplane.HostAgent.ApiForwarderSupervisor) do
      start_supervised!(
        {DynamicSupervisor,
         name: Backplane.HostAgent.ApiForwarderSupervisor, strategy: :one_for_one}
      )
    end

    socket =
      start_supervised!(
        {Phoenix.SocketClient,
         name: __MODULE__.LiveSocket,
         url: "ws://127.0.0.1:#{port}/host-agent/socket/websocket?host_id=#{host.id}",
         headers: [{"X-Backplane-Host-Token", token}],
         reconnect?: false,
         default_channel_module: Backplane.HostAgent.AgentChannel}
      )

    eventually(fn -> Phoenix.SocketClient.connected?(socket) end)
    assert {:ok, _, _channel} = Backplane.HostAgent.Channel.join(socket, host.id)
    eventually(fn -> ready_revision(host.id, service.id) == 1 end)

    for path <- ["/real/chat", "/real/updated"] do
      if path == "/real/updated" do
        {:ok, _} =
          HostServices.update(service, %{
            endpoints: %{"openai_chat_completions" => upstream_url <> path}
          })

        eventually(fn -> ready_revision(host.id, service.id) == 2 end)
      end

      assert {:ok, response} =
               Backplane.HTTPClient.post("http://127.0.0.1:#{port}/v1/chat/completions",
                 headers: [{"authorization", "Bearer #{c.token}"}],
                 json: %{model: model, stream: true},
                 retry: false,
                 decode_body: false,
                 receive_timeout: 5_000
               )

      assert response.status == 200
      assert response.body =~ "\"model\":\"#{model}\""
      assert response.body =~ String.duplicate("x", 100_000)
      assert String.ends_with?(response.body, "data: [DONE]\n\n")
      assert_receive {:upstream, ^path, "", _, %{"model" => "local-chat"}}
    end
  end

  defp ready_revision(host, service),
    do: get_in(:sys.get_state(Transport), [:connections, host, :ready, service])

  defp eventually(check, attempts \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end

  defp upstream(response) do
    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {Upstream, {self(), response}}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_, port}}} = Gaoxy.info(server, :http)
    "http://127.0.0.1:#{port}"
  end

  defp service(c, endpoints) do
    {:ok, service} =
      HostServices.create(%{host_id: c.host.id, name: "local-api", endpoints: endpoints})

    assert_push("api_services", inventory)
    register(c.socket, c.forwarder, inventory)
    service
  end

  defp register(socket, forwarder, inventory) do
    :ok = ApiForwarder.configure(forwarder, inventory)
    registrations = Enum.map(inventory["services"], &Map.take(&1, ["id", "revision"]))

    ref =
      push(socket, "api_services_registered", %{
        "protocol" => "host_api.v1",
        "services" => registrations
      })

    assert_reply(ref, :ok, _)
  end

  defp llm_model(service, api, family) do
    {:ok, provider} = Provider.create(%{name: "host-inference", host_service_id: service.id})

    {:ok, surface} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: family,
        native_protocols: [api]
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "local-chat", enabled: true})

    {:ok, _} =
      ProviderModelSurface.create(%{provider_model_id: model.id, provider_api_id: surface.id})

    ModelResolver.clear_cache()
    "host-inference/local-chat"
  end

  defp request(c, path, body, opts \\ []) do
    Task.async(fn ->
      Plug.Test.conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> then(fn conn ->
        if path == "/v1/messages",
          do: put_req_header(conn, "x-api-key", c.token),
          else: put_req_header(conn, "authorization", "Bearer #{c.token}")
      end)
      |> put_req_header("cookie", "client-cookie-must-not-leak")
      |> then(fn conn ->
        if opts[:closed_downstream],
          do: %{conn | adapter: {ClosedDownstream, elem(conn.adapter, 1)}},
          else: conn
      end)
      |> ProxyPlug.call([])
    end)
  end

  defp complete(task, c, pending \\ %{}) do
    receive do
      %Phoenix.Socket.Message{event: "api_request", payload: payload} ->
        assert :ok = ApiForwarder.request(c.forwarder, payload)
        complete(task, c, pending)

      {:frame, worker, worker_ref, frame} ->
        ref = push(c.socket, "api_response", frame)
        complete(task, c, Map.put(pending, ref, {worker, worker_ref}))

      %Phoenix.Socket.Reply{ref: ref, status: status, payload: payload}
      when is_map_key(pending, ref) ->
        {worker, worker_ref} = pending[ref]
        send(worker, {worker_ref, {status, payload}})
        complete(task, c, Map.delete(pending, ref))

      %Phoenix.Socket.Message{event: "api_cancel", payload: %{"request_id" => id}} ->
        :ok = ApiForwarder.cancel(c.forwarder, id)
        send(self(), {:cancelled, id})
        complete(task, c, pending)

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      10_000 -> flunk("host API integration call did not finish")
    end
  end
end
