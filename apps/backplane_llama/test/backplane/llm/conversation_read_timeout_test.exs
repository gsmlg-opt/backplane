defmodule Backplane.LLM.ConversationReadTimeoutTest do
  use ExUnit.Case, async: false

  defmodule RecordingAdapter do
    def read_req_body(payload, opts) do
      send(self(), {:read_timeout, Keyword.get(opts, :read_timeout, 15_000)})
      Plug.Adapters.Test.Conn.read_req_body(payload, opts)
    end
  end

  test "conversation parsing uses the current API read timeout and preserves the raw body" do
    config = Application.fetch_env!(:backplane_api, Backplane.Api.Endpoint)
    on_exit(fn -> Application.put_env(:backplane_api, Backplane.Api.Endpoint, config) end)

    for timeout <- [120_000, 240_000] do
      http = Keyword.fetch!(config, :http)
      limits = http |> Keyword.fetch!(:http_limits) |> Map.put(:read_timeout, timeout)
      updated = Keyword.put(config, :http, Keyword.put(http, :http_limits, limits))
      Application.put_env(:backplane_api, Backplane.Api.Endpoint, updated)

      body = ~s({"model":"codex","input":"hello"})
      conn = Plug.Test.conn(:post, "/v1/responses", body)
      {_, payload} = conn.adapter

      parsed =
        %{conn | adapter: {RecordingAdapter, payload}}
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Backplane.Audio.RouteParser.call([])

      assert_receive {:read_timeout, ^timeout}
      assert parsed.body_params == %{"model" => "codex", "input" => "hello"}
      assert parsed.assigns.raw_body == body
    end
  end
end
