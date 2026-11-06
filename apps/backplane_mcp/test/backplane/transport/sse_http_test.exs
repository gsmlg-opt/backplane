defmodule Backplane.Transport.SSEHttpTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Services.Day
  alias Backplane.Transport.McpPlug

  setup do
    previous_tools = :ets.tab2list(:backplane_tools)
    previous_enabled = :ets.lookup(:backplane_settings, "services.day.enabled")
    :ets.insert(:backplane_settings, {"services.day.enabled", true})
    ToolRegistry.register_managed("day", Day.tools())

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, previous_tools)
      :ets.delete(:backplane_settings, "services.day.enabled")
      :ets.insert(:backplane_settings, previous_enabled)
    end)

    server =
      start_supervised!(
        {Gaoxy.HTTP,
         plug: {McpPlug, []},
         ip: {127, 0, 0, 1},
         port: 0,
         protocols: [:http2, :http1],
         h2c: :prior_knowledge}
      )

    %{local: {:ok, {_, port}}} = Gaoxy.info(server, :http)
    %{port: port}
  end

  for protocol <- [:http1, :http2] do
    @protocol protocol

    test "#{protocol} delivers a tool result over SSE", %{port: port} do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "day::now", "arguments" => %{}}
        })

      promise =
        HTTP.fetch("http://127.0.0.1:#{port}/",
          method: "POST",
          headers: [
            {"content-type", "application/json"},
            {"accept", "application/json, text/event-stream"}
          ],
          body: body,
          http_version: if(@protocol == :http2, do: :h2c, else: :http1),
          stream_response: true
        )

      response = HTTP.Promise.await(promise)
      assert response.status == 200
      assert HTTP.Headers.get(response.headers, "content-type") =~ "text/event-stream"

      data = read_all_chunks(response.body)
      assert data =~ "event: message\n"
      [_, json] = String.split(data, "data: ", parts: 2)
      assert %{"id" => 1, "result" => %{"content" => [%{"text" => text}]}} = Jason.decode!(json)
      assert %{"timezone" => "Etc/UTC", "unix" => unix} = Jason.decode!(text)
      assert is_integer(unix)
    end

    test "#{protocol} opens the SSE notification stream", %{port: port} do
      promise =
        HTTP.fetch("http://127.0.0.1:#{port}/",
          method: "GET",
          headers: [{"accept", "text/event-stream"}],
          http_version: if(@protocol == :http2, do: :h2c, else: :http1),
          stream_response: true
        )

      response = HTTP.Promise.await(promise)
      assert response.status == 200

      data = read_first_chunk(response.body)
      assert data =~ ": connected\n\n"
    end
  end

  defp read_first_chunk(stream_pid) do
    send(stream_pid, {:read_chunk, self()})

    receive do
      {:stream_chunk, ^stream_pid, chunk} -> chunk
    after
      5_000 -> ""
    end
  end

  defp read_all_chunks(stream_pid, acc \\ "") do
    send(stream_pid, {:read_chunk, self()})

    receive do
      {:stream_chunk, ^stream_pid, chunk} ->
        read_all_chunks(stream_pid, acc <> chunk)

      {:stream_end, ^stream_pid} ->
        acc

      {:stream_error, ^stream_pid, reason} ->
        {:error, reason}
    after
      5_000 ->
        acc
    end
  end
end
