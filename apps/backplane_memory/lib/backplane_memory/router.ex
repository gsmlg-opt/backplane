defmodule BackplaneMemory.Router do
  @moduledoc "HTTP REST endpoints for the memory app."

  use Plug.Router

  alias BackplaneMemory.Graph
  alias BackplaneMemory.Memories.Profiles

  plug(:match)
  plug(:fetch_query_params)
  plug(:dispatch)

  get "/api/memory/graph/stats" do
    stats = Graph.stats()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(stats))
  end

  get "/api/memory/profile" do
    project = conn.query_params["project"] || ""

    if project == "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "project param required"}))
    else
      case Profiles.get_or_build(project) do
        {:ok, profile} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              project: profile.project,
              top_concepts: profile.top_concepts,
              top_files: profile.top_files,
              patterns: profile.patterns,
              session_count: profile.session_count,
              total_observations: profile.total_observations,
              updated_at: profile.updated_at
            })
          )

        {:building, nil} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            202,
            Jason.encode!(%{
              status: "building",
              message: "Profile is being built, retry shortly"
            })
          )
      end
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
