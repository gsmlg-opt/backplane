defmodule BackplaneMemory.Router do
  @moduledoc "HTTP REST endpoints for the memory app."

  use Plug.Router

  alias BackplaneMemory.Graph

  plug(:match)
  plug(:dispatch)

  get "/api/memory/graph/stats" do
    stats = Graph.stats()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(stats))
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
