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
      {:ok, conn} = connect(@protocol, port)

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "day::now", "arguments" => %{}}
        })

      {:ok, conn, ref} =
        Mint.HTTP.request(
          conn,
          "POST",
          "/",
          [
            {"content-type", "application/json"},
            {"accept", "application/json, text/event-stream"}
          ],
          body
        )

      {conn, events} = receive_until(conn, &match?({:done, ^ref}, &1))
      Mint.HTTP.close(conn)

      assert {:status, ref, 200} in events
      headers = for {:headers, ^ref, headers} <- events, header <- headers, do: header
      assert {"content-type", "text/event-stream; charset=utf-8"} in headers

      data = for {:data, ^ref, data} <- events, into: "", do: data
      assert data =~ "event: message\n"
      [_, json] = String.split(data, "data: ", parts: 2)
      assert %{"id" => 1, "result" => %{"content" => [%{"text" => text}]}} = Jason.decode!(json)
      assert %{"timezone" => "Etc/UTC", "unix" => unix} = Jason.decode!(text)
      assert is_integer(unix)
    end

    test "#{protocol} opens the SSE notification stream", %{port: port} do
      {:ok, conn} = connect(@protocol, port)

      {:ok, conn, ref} =
        Mint.HTTP.request(conn, "GET", "/", [{"accept", "text/event-stream"}], nil)

      {conn, events} = receive_until(conn, &match?({:data, ^ref, _}, &1))
      Mint.HTTP.close(conn)

      assert {:status, ref, 200} in events
      data = for {:data, ^ref, data} <- events, into: "", do: data
      assert data =~ ": connected\n\n"
    end
  end

  defp connect(:http1, port),
    do: Mint.HTTP1.connect(:http, "127.0.0.1", port, mode: :passive)

  defp connect(:http2, port),
    do: Mint.HTTP2.connect(:http, "127.0.0.1", port, mode: :passive)

  defp receive_until(conn, complete?, events \\ []) do
    {:ok, conn, received} = Mint.HTTP.recv(conn, 0, 5_000)
    events = events ++ received

    cond do
      Enum.any?(events, complete?) ->
        {conn, events}

      Enum.any?(received, &match?({:done, _}, &1)) ->
        flunk("SSE stream ended early: #{inspect(events)}")

      true ->
        receive_until(conn, complete?, events)
    end
  end
end
