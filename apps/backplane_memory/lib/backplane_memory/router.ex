defmodule BackplaneMemory.Router do
  @moduledoc "HTTP REST endpoints for the memory app."

  use Plug.Router

  alias BackplaneMemory.Graph
  alias BackplaneMemory.Memories.Profiles

  plug(:match)
  plug(:fetch_query_params)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
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

  post "/api/memory/query/expand" do
    query = conn.body_params["query"]

    if is_binary(query) and query != "" do
      llm_module =
        Application.get_env(:backplane_memory, :llm_module, BackplaneMemory.LLM)

      body =
        case llm_module.expand_query(query) do
          {:ok, expansions} ->
            Jason.encode!(%{query: query, expansions: expansions})

          {:skip, _} ->
            Jason.encode!(%{query: query, expansions: [query], note: "LLM not configured"})
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "query is required"}))
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
