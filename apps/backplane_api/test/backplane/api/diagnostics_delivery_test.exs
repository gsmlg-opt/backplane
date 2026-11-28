defmodule Backplane.Api.DiagnosticsDeliveryTest do
  use Backplane.Api.ChannelCase, async: false

  alias Backplane.Diagnostics.{
    Events,
    Issues,
    Outbox,
    Projector,
    Queries,
    ReportScheduler,
    Sources
  }

  alias Backplane.DiagnosticsClient.{Envelope, Receipt, Reporter}
  alias Backplane.HostAgent.{Channel, HttpRouter}
  alias Backplane.HostAgent.Diagnostics.{Spool, Uploader}
  alias Backplane.Repo
  alias Backplane.Skills.Hosts

  @moduletag :tmp_dir
  @source_id "diagnostics-delivery"
  @reporter Backplane.Api.DiagnosticsDeliveryTest.Reporter
  @token_env "BACKPLANE_TEST_TWO_HOP_DIAGNOSTICS_TOKEN"

  defmodule PreviousSocket do
    use Phoenix.Socket

    channel("host_agent:*", Backplane.Api.DiagnosticsDeliveryTest.PreviousChannel)

    @impl true
    defdelegate connect(params, socket, info), to: Backplane.Api.HostAgentSocket

    @impl true
    defdelegate id(socket), to: Backplane.Api.HostAgentSocket
  end

  defmodule PreviousEndpoint do
    use Phoenix.Endpoint, otp_app: :backplane_api

    Phoenix.Endpoint.socket("/host-agent/socket", PreviousSocket,
      websocket: [connect_info: [:x_headers, :peer_data], check_origin: false],
      longpoll: false
    )
  end

  defmodule CrashPlug do
    def init(opts), do: opts
    def call(_conn, _opts), do: raise("controlled Phoenix failure")
  end

  defmodule CrashRouter do
    use Phoenix.Router
    get("/fixture-crash", CrashPlug, [])
  end

  defmodule LoseLocalAcknowledgement do
    import Plug.Conn

    def init(opts), do: {HttpRouter.init(opts), opts[:count]}

    def call(conn, {router, count}) do
      conn =
        register_before_send(conn, fn response ->
          if response.status == 200 and :atomics.add_get(count, 1, 1) == 1 do
            %{response | status: 503, resp_body: "{}"}
          else
            response
          end
        end)

      HttpRouter.call(conn, router)
    end
  end

  defmodule LoseRemoteAcknowledgement do
    def push(channel, "diagnostics_sync" = method, data, timeout) do
      case Channel.push(channel, method, data, timeout) do
        {:ok, %{"receipts" => [%{"status" => "stored"}]}} -> {:error, :timeout}
        other -> other
      end
    end
  end

  setup do
    old_scopes = Application.fetch_env(:backplane_api, :host_agent_scopes)

    Application.put_env(:backplane_api, :host_agent_scopes, [
      "host_agent.capture",
      "host_agent.diagnostics.write"
    ])

    System.put_env(@token_env, "diagnostics-synthetic-token-0000")

    on_exit(fn ->
      case old_scopes do
        {:ok, scopes} -> Application.put_env(:backplane_api, :host_agent_scopes, scopes)
        :error -> Application.delete_env(:backplane_api, :host_agent_scopes)
      end

      System.delete_env(@token_env)
    end)

    {:ok, host, _, token} = Hosts.create_agent_with_token(%{"name" => "diagnostics-delivery"})
    {:ok, _} = Sources.register(host.id, %{id: @source_id, application: "diagnostics-test"})
    endpoint_port = http_server(:api, Backplane.Api.Endpoint, [])

    socket =
      start_supervised!(
        {Phoenix.SocketClient,
         name: __MODULE__.Socket,
         url: "ws://127.0.0.1:#{endpoint_port}/host-agent/socket/websocket?host_id=#{host.id}",
         headers: [{"X-Backplane-Host-Token", token}],
         reconnect?: false,
         default_channel_module: Backplane.HostAgent.AgentChannel}
      )

    eventually(fn -> Phoenix.SocketClient.connected?(socket) end)
    assert {:ok, _, channel} = Channel.join(socket, host.id)

    assert {:ok, %{"protocol" => "host_diagnostics.v1", "max_bytes" => 524_288}} =
             Channel.push(channel, "diagnostics_capabilities", %{})

    %{channel: channel, host: host}
  end

  if previous_ref = System.get_env("BACKPLANE_DIAGNOSTICS_PREVIOUS_REF") do
    @previous_ref previous_ref
    @repository Path.expand("../../../../..", __DIR__)

    test "negotiates compatibility with the previous gateway without disrupting legacy delivery",
         %{tmp_dir: dir, channel: current, host: host} do
      previous = start_previous_gateway()
      assert_legacy_delivery(previous.channel, previous.host)
      assert_legacy_delivery(current, host)

      source = %{id: @source_id, application: "diagnostics-test"}
      {:ok, spool} = Spool.start_link(path: Path.join(dir, "mixed-version.db"))
      saved = large_event(1, %{"module" => "Compat", "function" => "run", "line" => 1})

      assert %{"receipts" => [%{"status" => "stored"}]} =
               Spool.ingest(spool, source, "local", [saved])

      uploader =
        start_supervised!(
          {Uploader,
           spool: spool, interval_ms: 60_000, channel_provider: fn -> previous.channel end}
        )

      send(uploader, :drain)
      assert Uploader.status(uploader) == :unsupported_capability
      assert {:ok, [%{"state" => "pending", "count" => 1}]} = Spool.health(spool)
      assert_legacy_delivery(previous.channel, previous.host, 2)

      assert {:ok, :connected} = Uploader.drain_once(spool, Channel, current, {100, 524_288})
      assert {:ok, [%{"state" => "confirmed", "count" => 1}]} = Spool.health(spool)
      assert_legacy_delivery(current, host, 2)
    end

    defp start_previous_gateway do
      path = "apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex"
      {source, 0} = System.cmd("git", ["-C", @repository, "show", "#{@previous_ref}:#{path}"])

      source
      |> String.replace(
        "defmodule Backplane.Api.HostAgentChannel do",
        "defmodule #{inspect(__MODULE__)}.PreviousChannel do",
        global: false
      )
      |> Code.compile_string("previous-host-agent-channel.ex")

      Application.put_env(:backplane_api, PreviousEndpoint,
        server: false,
        pubsub_server: Backplane.PubSub
      )

      on_exit(fn -> Application.delete_env(:backplane_api, PreviousEndpoint) end)
      start_supervised!(PreviousEndpoint)
      port = http_server(:previous_api, PreviousEndpoint, [])

      {:ok, host, _, token} =
        Hosts.create_agent_with_token(%{"name" => "diagnostics-previous-gateway"})

      socket =
        start_supervised!(
          {Phoenix.SocketClient,
           name: __MODULE__.PreviousClient,
           url: "ws://127.0.0.1:#{port}/host-agent/socket/websocket?host_id=#{host.id}",
           headers: [{"X-Backplane-Host-Token", token}],
           reconnect?: false,
           default_channel_module: Backplane.HostAgent.AgentChannel},
          id: :previous_host_client
        )

      eventually(fn -> Phoenix.SocketClient.connected?(socket) end)
      assert {:ok, _, channel} = Channel.join(socket, host.id)
      %{channel: channel, host: host}
    end

    defp assert_legacy_delivery(channel, host, sequence \\ 1) do
      trace = %{
        "seq" => sequence,
        "trace_id" => "0123456789abcdef0123456789abcdef",
        "span_id" => "0123456789abcdef",
        "event" => "agent.started",
        "measurements" => %{"duration_ms" => 1},
        "metadata" => %{"tool" => "compatibility"},
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      assert {:ok, %{"result" => %{"items" => [%{"seq" => ^sequence, "status" => "ok"}]}}} =
               Channel.push(channel, "trace_sync", %{
                 "protocol" => "host_trace.v1",
                 "items" => [trace]
               })

      assert {:ok, _ack} =
               Channel.push(channel, "memory_events", %{
                 "protocol" => "host_events.v1",
                 "batch_id" => "compat-#{sequence}",
                 "host_id" => host.id,
                 "events" => []
               })
    end
  end

  if sigma_adapter = System.get_env("BACKPLANE_DIAGNOSTICS_SIGMA_ADAPTER") do
    @sigma_adapter sigma_adapter

    test "Sigma facts traverse the independent Host and authenticated Backplane boundary", %{
      tmp_dir: dir,
      channel: channel,
      host: host
    } do
      Code.require_file(Path.expand(@sigma_adapter))
      source_id = "sigma-pilot"
      {:ok, _source} = Sources.register(host.id, %{id: source_id, application: "sigma"})

      sources =
        Backplane.HostAgent.Diagnostics.Sources.parse([
          %{"id" => source_id, "application" => "sigma", "token_env" => @token_env}
        ])

      {:ok, spool} = Spool.start_link(path: Path.join(dir, "sigma-spool.db"))

      port =
        http_server(:host, HttpRouter,
          spool: spool,
          diagnostics: %{enabled: true, sources: sources}
        )

      start_supervised!(
        {Reporter,
         [
           source_id: source_id,
           application: "sigma",
           host_url: "http://127.0.0.1:#{port}",
           token_env: @token_env,
           interval_ms: 10
         ]}
      )

      adapter = Sigma.Agent.Backplane.Diagnostics

      for fact <- [
            {:metrics, :request_finished,
             %{
               session_id: "s1",
               turn_id: "t1",
               request_id: "p1",
               revision: 1,
               status: :failed,
               usage_status: :unknown
             }},
            {:metrics, :request_finished,
             %{
               session_id: "s1",
               turn_id: "t1",
               request_id: "p2",
               retry_of: "p1",
               revision: 1,
               status: :completed
             }},
            {:metrics, :turn_finished,
             %{session_id: "s1", turn_id: "t1", revision: 1, status: :completed}}
          ] do
        assert :ok = apply(adapter, :observe, [fact])
      end

      eventually(fn ->
        match?({:ok, [%{"state" => "pending", "count" => 3}]}, Spool.health(spool))
      end)

      assert {:ok, :connected} = Uploader.drain_once(spool, Channel, channel, {100, 524_288})

      rows = Repo.all(Events.Event)
      assert length(rows) == 3
      assert Enum.any?(rows, &(get_in(&1.body, ["quality", "usage_status"]) == "unknown"))
      assert Enum.any?(rows, &(get_in(&1.body, ["correlation", "causation_id"]) == "p1"))

      assert Enum.any?(
               rows,
               &(&1.event_type == "run_finished" and
                   get_in(&1.body, ["result", "outcome"]) == "success")
             )
    end
  end

  test "captures an actual Phoenix router exception with the original stack and request ID" do
    parent = self()

    transport = fn %{"batch_id" => id, "events" => entries} ->
      send(parent, {:report, entries})
      {:ok, Receipt.response(:local, id, Enum.map(entries, &Receipt.result(&1, "stored")))}
    end

    start_supervised!(
      {Reporter,
       name: @reporter,
       application: "diagnostics-test",
       source_id: @source_id,
       send_batch: transport,
       interval_ms: 10}
    )

    integration = Backplane.DiagnosticsClient.Integrations.Phoenix
    assert :ok = integration.attach(__MODULE__, reporter: @reporter)
    on_exit(fn -> integration.detach(__MODULE__) end)

    conn =
      Plug.Test.conn(:get, "/fixture-crash")
      |> Plug.Conn.put_resp_header("x-request-id", "diagnostics-request-fixture")

    assert catch_error(CrashRouter.call(conn, []))

    assert_receive {:report,
                    [
                      %{
                        "event" => %{
                          "event_type" => "exception",
                          "correlation" => %{"request_id" => "diagnostics-request-fixture"},
                          "evidence" => %{
                            "exception" => %{
                              "type" => "RuntimeError",
                              "stack" => [%{"function" => "call"} | _]
                            }
                          }
                        }
                      }
                    ]},
                   1_000
  end

  test "retries stable events across both lost acknowledgements and Host spool restart", %{
    tmp_dir: dir,
    channel: channel
  } do
    sources =
      Backplane.HostAgent.Diagnostics.Sources.parse([
        %{"id" => @source_id, "application" => "diagnostics-test", "token_env" => @token_env}
      ])

    now = :atomics.new(1, [])
    :atomics.put(now, 1, 100)
    spool_opts = [path: Path.join(dir, "host-spool.db"), clock: fn -> :atomics.get(now, 1) end]
    {:ok, spool} = Spool.start_link(spool_opts)
    counter = :atomics.new(1, [])

    http_port =
      http_server(:host, LoseLocalAcknowledgement,
        spool: spool,
        count: counter,
        diagnostics: %{enabled: true, sources: sources}
      )

    start_supervised!(
      {Reporter,
       [
         name: @reporter,
         application: "diagnostics-test",
         source_id: @source_id,
         host_url: "http://127.0.0.1:#{http_port}",
         token_env: @token_env,
         interval_ms: 10
       ]}
    )

    assert :enqueued =
             Reporter.report(
               %{
                 "event_type" => "exception",
                 "subject" => %{"run_id" => "two-hop-run"},
                 "evidence" => %{
                   "exception" => %{
                     "type" => "FixtureError",
                     "message" => "Bearer synthetic-secret"
                   }
                 }
               },
               @reporter
             )

    eventually(fn ->
      :atomics.get(counter, 1) >= 2 and Reporter.health(@reporter).pending == 0
    end)

    assert {:ok, [%{"state" => "pending", "count" => 1}]} = Spool.health(spool)

    assert {:ok, :transport_unavailable} =
             Uploader.drain_once(spool, LoseRemoteAcknowledgement, channel, {100, 524_288})

    assert %Events.Event{id: id, body: original} =
             Repo.get_by!(Events.Event, source_id: @source_id)

    assert get_in(original, ["evidence", "exception", "message"]) == "[REDACTED]"
    assert Repo.get!(Outbox.Entry, id).event_key == id
    GenServer.stop(spool)

    :atomics.put(now, 1, 200)
    {:ok, restarted} = Spool.start_link(spool_opts)
    assert {:ok, :connected} = Uploader.drain_once(restarted, Channel, channel, {100, 524_288})

    assert {:ok, [%{"state" => "confirmed", "count" => 1, "bytes" => 0}]} =
             Spool.health(restarted)

    assert %Events.Event{id: ^id, body: ^original} =
             Repo.get_by!(Events.Event, source_id: @source_id)

    assert Repo.get!(Outbox.Entry, id).event_key == id
    assert {:ok, :processed} = Projector.project(id)
    assert {:ok, :already_processed} = Projector.project(id)
    [issue] = Issues.list()
    assert %{events: 1, occurrences: 1, runs: 1} = Issues.counts(issue.id)
    assert {:ok, :refreshed} = ReportScheduler.drain_once()
    assert {:ok, report} = Queries.get_report(issue.id)
    assert {:ok, evidence} = Queries.get_evidence(report["evidence_bundle_id"], "event:#{id}")
    refute Formata.JSON.encode!([report, evidence]) =~ "synthetic-secret"
  end

  test "real Host Channel accepts a near-limit encoded payload and rejects one over its logical limit",
       %{channel: channel} do
    frame = %{
      "module" => "Example",
      "function" => "decode",
      "arity" => 2,
      "line" => 42,
      "file" => "lib/" <> String.duplicate("a", 500)
    }

    entries = for seq <- 1..36, do: large_event(seq, frame)
    {batch, bytes} = largest_batch(entries)
    assert byte_size(bytes) in 500_000..524_288
    assert {:ok, %{"receipts" => rows}} = Channel.push(channel, "diagnostics_sync", batch, 10_000)
    assert length(rows) == length(batch["events"])
    assert Enum.all?(rows, &(&1["status"] == "stored"))

    oversize = Receipt.batch(:remote, "oversize", batch["events"] ++ [List.last(entries)])
    assert {:error, :batch_too_large} = Receipt.encode_batch(oversize)

    assert {:error, %{"code" => "batch_too_large"}} =
             Channel.push(channel, "diagnostics_sync", oversize)
  end

  defp largest_batch(entries) do
    Enum.reduce_while(1..length(entries), nil, fn count, previous ->
      batch = Receipt.batch(:remote, "near-limit", Enum.take(entries, count))

      case Receipt.encode_batch(batch) do
        {:ok, bytes} -> {:cont, {batch, bytes}}
        {:error, :batch_too_large} -> {:halt, previous}
      end
    end)
  end

  defp large_event(seq, frame) do
    event = %{
      "schema_version" => 1,
      "event_type" => "handled_error",
      "event_id" => "event-#{seq}",
      "source_id" => @source_id,
      "application" => "diagnostics-test",
      "producer_epoch" => "boot",
      "source_sequence" => seq,
      "occurred_at" => "2026-11-28T03:04:05Z",
      "quality" => %{"redaction_policy_version" => 1},
      "evidence" => %{
        "exception" => %{
          "stack" => List.duplicate(frame, 24),
          "message" => String.duplicate("a", 1024)
        }
      }
    }

    {:ok, _, digest} = Envelope.seal(event)
    Receipt.entry(event, digest)
  end

  defp http_server(id, module, opts) do
    listener =
      start_supervised!({Gaoxy.HTTP, plug: {module, opts}, ip: {127, 0, 0, 1}, port: 0}, id: id)

    %{local: {:ok, {_, port}}} = Gaoxy.info(listener, :http)
    port
  end

  defp eventually(check, left \\ 250)

  defp eventually(check, left) do
    if check.() do
      :ok
    else
      assert left > 0, "timed out waiting for diagnostics transport"
      Process.sleep(20)
      eventually(check, left - 1)
    end
  end
end
