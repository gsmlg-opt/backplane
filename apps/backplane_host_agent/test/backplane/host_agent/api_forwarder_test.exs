defmodule Backplane.HostAgent.ApiForwarderTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.{ApiForwarder, ApiRequest}

  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn, length: 512 * 1024)

      send(owner, {
        :upstream_request,
        self(),
        conn.request_path,
        body,
        conn.req_headers
      })

      case conn.request_path do
        "/stream" ->
          conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
          {:ok, conn} = chunk(conn, "data: first\n\n")

          receive do
            :continue -> chunk(conn, "data: second\n\ndata: [DONE]\n\n") |> elem(1)
          after
            5_000 -> conn
          end

        "/large" ->
          send_resp(conn, 200, String.duplicate("x", 900_000))

        "/empty" ->
          send_resp(conn, 204, "")

        "/redirect" ->
          conn |> put_resp_header("location", "/never-follow") |> send_resp(307, "moved")

        "/error" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(422, ~s({"error":"invalid input"}))

        _path ->
          conn |> put_resp_content_type("application/json") |> send_resp(200, body)
      end
    end
  end

  setup do
    owner = self()
    channel = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(channel), do: Process.exit(channel, :kill) end)

    server = start_supervised!({Gaoxy.HTTP, plug: {Upstream, owner}, port: 0})
    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)

    push = fn frame ->
      send(owner, {:api_frame, self(), frame})
      {:ok, %{}}
    end

    forwarder = start_supervised!({ApiForwarder, channel: channel, push: push})
    %{forwarder: forwarder, channel: channel, port: port}
  end

  test "POSTs only the declared endpoint and preserves opaque response bytes", ctx do
    configure(ctx, "/echo", "openai_embeddings")
    body = ~s({"model":"embed","input":["hello"]})

    assert :ok = ApiForwarder.request(ctx.forwarder, payload(body: body))

    assert_receive {:upstream_request, _pid, "/echo", ^body, headers}, 2_000
    assert {"authorization", "Bearer api-request-secret"} in headers
    assert {"accept-encoding", "identity"} in headers
    assert {"x-custom-provider", "custom-provider-value"} in headers
    refute Enum.any?(headers, fn {key, _value} -> key == "x-forwarded-for" end)

    frames = collect_frames()
    assert [%{"type" => "headers", "status" => 200} | _rest] = frames
    assert body_from_frames(frames) == body
    assert List.last(frames) == %{"request_id" => "request-1", "type" => "done"}
  end

  test "streams before completion and waits for downstream acknowledgement", ctx do
    owner = self()

    push = fn frame ->
      send(owner, {:api_frame, self(), frame})

      if frame["type"] == "chunk" do
        receive do
          :ack -> {:ok, %{}}
        after
          2_000 -> {:error, :timeout}
        end
      else
        {:ok, %{}}
      end
    end

    forwarder =
      start_supervised!({ApiForwarder, channel: ctx.channel, push: push}, id: :stream_forwarder)

    configure(%{ctx | forwarder: forwarder}, "/stream", "openai_chat_completions")
    assert :ok = ApiForwarder.request(forwarder, payload(api: "openai_chat_completions"))
    assert_receive {:upstream_request, upstream, "/stream", _, _}, 2_000
    assert_receive {:api_frame, worker, %{"type" => "headers", "status" => 200}}, 2_000
    assert_receive {:api_frame, ^worker, %{"type" => "chunk", "sequence" => 0} = first}, 2_000
    assert Base.decode64!(first["data"]) == "data: first\n\n"
    send(upstream, :continue)
    refute_receive {:api_frame, ^worker, %{"type" => "chunk"}}, 100
    send(worker, :ack)
    assert_receive {:api_frame, ^worker, %{"type" => "chunk", "sequence" => 1} = second}, 2_000
    assert Base.decode64!(second["data"]) == "data: second\n\ndata: [DONE]\n\n"
    send(worker, :ack)
    assert_receive {:api_frame, ^worker, %{"type" => "done"}}, 2_000
  end

  test "bounds chunk frames for a response larger than a channel frame", ctx do
    configure(ctx, "/large", "openai_responses")
    assert :ok = ApiForwarder.request(ctx.forwarder, payload(api: "openai_responses"))
    frames = collect_frames()
    chunks = Enum.filter(frames, &(&1["type"] == "chunk"))
    assert chunks != []
    assert Enum.all?(chunks, &(byte_size(Base.decode64!(&1["data"])) <= ApiRequest.chunk_bytes()))
    assert Enum.map(chunks, & &1["sequence"]) == Enum.to_list(0..(length(chunks) - 1))
    assert body_from_frames(frames) == String.duplicate("x", 900_000)
  end

  test "returns status and headers for an empty response", ctx do
    configure(ctx, "/empty", "anthropic_messages")
    assert :ok = ApiForwarder.request(ctx.forwarder, payload(api: "anthropic_messages"))

    assert [
             %{"type" => "headers", "status" => 204},
             %{"type" => "done"}
           ] = collect_frames()
  end

  test "preserves API error responses and never follows redirects", ctx do
    configure(ctx, "/error", "openai_embeddings")
    assert :ok = ApiForwarder.request(ctx.forwarder, payload())
    assert [%{"type" => "headers", "status" => 422} | _] = frames = collect_frames()
    assert body_from_frames(frames) == ~s({"error":"invalid input"})

    configure(ctx, "/redirect", "openai_embeddings")
    assert :ok = ApiForwarder.request(ctx.forwarder, payload(id: "request-2"))
    assert [%{"type" => "headers", "status" => 307} | _] = frames = collect_frames()
    assert body_from_frames(frames) == "moved"
    refute_receive {:upstream_request, _pid, "/never-follow", _, _}
  end

  test "undeclared APIs, stale revisions and request URLs cannot select an endpoint", ctx do
    configure(ctx, "/echo", "openai_embeddings")

    assert {:error, :unsupported_api} =
             ApiForwarder.request(ctx.forwarder, payload(api: "anthropic_messages"))

    assert {:error, :service_unavailable} =
             ApiForwarder.request(ctx.forwarder, Map.put(payload(), "service_revision", 0))

    assert {:error, :service_unavailable} =
             ApiForwarder.request(ctx.forwarder, Map.put(payload(), "service_id", "other-host"))

    assert :ok =
             ApiForwarder.request(
               ctx.forwarder,
               Map.put(payload(), "endpoint_url", "http://127.0.0.1:1/forbidden")
             )

    assert_receive {:upstream_request, _pid, "/echo", _, _}, 2_000
    assert Enum.any?(collect_frames(), &(&1["type"] == "done"))
  end

  test "rejects oversized bodies before making an upstream request", ctx do
    configure(ctx, "/echo", "openai_embeddings")
    body = String.duplicate("x", ApiRequest.max_request_bytes() + 1)
    assert {:error, :invalid_request} = ApiForwarder.request(ctx.forwarder, payload(body: body))
    refute_receive {:upstream_request, _, _, _, _}
  end

  test "invalid service snapshots clear earlier declarations", ctx do
    configure(ctx, "/echo", "openai_embeddings")

    assert {:error, :invalid_services} =
             ApiForwarder.configure(ctx.forwarder, %{
               "protocol" => "host_api.v1",
               "services" => [
                 %{
                   "id" => "service-1",
                   "revision" => 2,
                   "endpoints" => %{"openai_embeddings" => "file:///etc/passwd"}
                 }
               ]
             })

    assert {:error, :service_unavailable} = ApiForwarder.request(ctx.forwarder, payload())
    refute_receive {:upstream_request, _, _, _, _}
  end

  test "request diagnostics omit the body, endpoint and credentials", ctx do
    configure(ctx, "/echo", "openai_embeddings")
    services = :sys.get_state(ctx.forwarder).services
    assert {:ok, request} = ApiRequest.prepare(payload(body: "private-body-marker"), services)
    diagnostic = inspect(request)
    refute diagnostic =~ "private-body-marker"
    refute diagnostic =~ "api-request-secret"
    refute diagnostic =~ "127.0.0.1"
    assert diagnostic =~ "request-1"
  end

  test "cancellation terminates the HTTP worker and releases its concurrency slot", ctx do
    forwarder =
      start_supervised!(
        {ApiForwarder,
         channel: ctx.channel,
         max_concurrency: 1,
         push: fn frame ->
           send(self(), frame)
           {:ok, %{}}
         end},
        id: :single_forwarder
      )

    configure(%{ctx | forwarder: forwarder}, "/stream", "openai_chat_completions")
    assert :ok = ApiForwarder.request(forwarder, payload(api: "openai_chat_completions"))
    assert_receive {:upstream_request, upstream, "/stream", _, _}, 2_000

    assert {:error, :too_many_requests} =
             ApiForwarder.request(
               forwarder,
               payload(id: "request-2", api: "openai_chat_completions")
             )

    state = :sys.get_state(forwarder)
    worker = state.requests["request-1"].pid
    ref = Process.monitor(worker)
    assert :ok = ApiForwarder.cancel(forwarder, "request-1")
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 2_000
    send(upstream, :continue)

    assert :ok =
             ApiForwarder.request(
               forwarder,
               payload(id: "request-2", api: "openai_chat_completions")
             )

    assert :ok = ApiForwarder.cancel(forwarder, "request-2")
  end

  test "changing a service cancels its requests, while an identical snapshot preserves them",
       ctx do
    configure(ctx, "/stream", "openai_chat_completions")
    assert :ok = ApiForwarder.request(ctx.forwarder, payload(api: "openai_chat_completions"))
    assert_receive {:upstream_request, upstream, "/stream", _, _}, 2_000
    worker = :sys.get_state(ctx.forwarder).requests["request-1"].pid
    ref = Process.monitor(worker)

    configure(ctx, "/stream", "openai_chat_completions")
    assert Process.alive?(worker)
    configure(ctx, "/echo", "openai_chat_completions")
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 2_000
    send(upstream, :continue)
  end

  test "channel death and forwarder death both stop owned HTTP tasks", ctx do
    configure(ctx, "/stream", "openai_chat_completions")
    assert :ok = ApiForwarder.request(ctx.forwarder, payload(api: "openai_chat_completions"))
    assert_receive {:upstream_request, upstream, "/stream", _, _}, 2_000
    worker = :sys.get_state(ctx.forwarder).requests["request-1"].pid
    worker_ref = Process.monitor(worker)
    forwarder_ref = Process.monitor(ctx.forwarder)
    Process.exit(ctx.channel, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000
    assert_receive {:DOWN, ^forwarder_ref, :process, _forwarder, :normal}, 2_000
    send(upstream, :continue)

    channel = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(channel), do: Process.exit(channel, :kill) end)
    forwarder = start_supervised!({ApiForwarder, channel: channel}, id: :doomed_forwarder)
    configure(%{ctx | forwarder: forwarder}, "/stream", "openai_chat_completions")
    assert :ok = ApiForwarder.request(forwarder, payload(api: "openai_chat_completions"))
    assert_receive {:upstream_request, upstream, "/stream", _, _}, 2_000
    worker = :sys.get_state(forwarder).requests["request-1"].pid
    ref = Process.monitor(worker)

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(forwarder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 2_000
    end)

    send(upstream, :continue)
  end

  defp configure(ctx, path, api) do
    ApiForwarder.configure(ctx.forwarder, %{
      "protocol" => "host_api.v1",
      "services" => [
        %{
          "id" => "service-1",
          "revision" => 1,
          "enabled" => true,
          "endpoints" => %{api => "http://127.0.0.1:#{ctx.port}#{path}"}
        }
      ]
    })
  end

  defp payload(opts \\ []) do
    %{
      "protocol" => "host_api.v1",
      "request_id" => Keyword.get(opts, :id, "request-1"),
      "service_id" => "service-1",
      "service_revision" => 1,
      "api" => Keyword.get(opts, :api, "openai_embeddings"),
      "headers" => [
        ["content-type", "application/json"],
        ["authorization", "Bearer api-request-secret"],
        ["x-custom-provider", "custom-provider-value"],
        ["x-forwarded-for", "untrusted"]
      ],
      "body_base64" => Base.encode64(Keyword.get(opts, :body, ~s({"model":"test"}))),
      "timeout_ms" => 10_000
    }
  end

  defp collect_frames(acc \\ []) do
    receive do
      {:api_frame, _worker, %{"type" => type} = frame} when type in ["done", "error"] ->
        Enum.reverse([frame | acc])

      {:api_frame, _worker, frame} ->
        collect_frames([frame | acc])
    after
      3_000 -> flunk("host API request did not complete")
    end
  end

  defp body_from_frames(frames) do
    frames
    |> Enum.filter(&(&1["type"] == "chunk"))
    |> Enum.map(&Base.decode64!(&1["data"]))
    |> IO.iodata_to_binary()
  end
end
