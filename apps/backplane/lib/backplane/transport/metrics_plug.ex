defmodule Backplane.Transport.MetricsPlug do
  @moduledoc """
  Metrics endpoints:
  - GET /metrics — JSON snapshot
  - GET /metrics/prometheus — Prometheus text exposition format
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/prometheus" do
    body = Backplane.Metrics.Prometheus.render()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  match _ do
    metrics = Backplane.Metrics.snapshot()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(metrics))
  end
end
