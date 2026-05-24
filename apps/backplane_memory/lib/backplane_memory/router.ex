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

  post "/api/memory/session/start" do
    case conn.body_params do
      %{"session_id" => session_id, "project" => project}
      when is_binary(session_id) and is_binary(project) ->
        BackplaneMemory.Observations.register_session(session_id, project)
        context = BackplaneMemory.Context.build(project, session_id)
        response = %{session_id: session_id}
        response = if context, do: Map.put(response, :context, context), else: response

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "session_id and project are required"}))
    end
  end

  post "/api/memory/session/end" do
    case conn.body_params do
      %{"session_id" => session_id} when is_binary(session_id) ->
        BackplaneMemory.Observations.end_session(session_id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{session_id: session_id, status: "ended"}))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "session_id is required"}))
    end
  end

  post "/api/memory/observations" do
    session_id = Map.get(conn.body_params, "session_id", "")
    content = Map.get(conn.body_params, "content", "")

    if content == "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "content is required"}))
    else
      opts = [
        tool_name: conn.body_params["tool_name"],
        is_error: conn.body_params["is_error"] == true
      ]

      case BackplaneMemory.Observations.record(session_id, content, opts) do
        {:ok, obs} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, Jason.encode!(%{id: obs.id}))

        {:error, :filtered} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(204, "")

        {:error, changeset} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(422, Jason.encode!(%{error: inspect(changeset)}))
      end
    end
  end

  get "/api/memory/file-history" do
    files = String.split(conn.query_params["files"] || "", ",", trim: true)
    exclude = conn.query_params["exclude_session"]
    opts = [exclude_session: exclude, limit: 50]
    rows = BackplaneMemory.Observations.file_history(files, opts)

    result =
      Enum.map(rows, fn o ->
        %{
          id: o.id,
          session_id: o.session_id,
          tool_name: o.tool_name,
          content: o.content,
          created_at: o.created_at
        }
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{results: result}))
  end

  get "/api/memory/audit" do
    limit = parse_int(conn.query_params["limit"], 50)
    offset = parse_int(conn.query_params["offset"], 0)
    operation = conn.query_params["operation"]
    actor = conn.query_params["actor"]

    opts = [limit: limit, offset: offset]
    opts = if operation && operation != "", do: opts ++ [operation: operation], else: opts
    opts = if actor && actor != "", do: opts ++ [actor: actor], else: opts

    entries = BackplaneMemory.Audit.list(opts)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{results: entries}))
  end

  get "/api/memory/diagnose" do
    alias BackplaneMemory.Embedding.CircuitBreaker

    stats = BackplaneMemory.Memory.stats()
    cb_state = CircuitBreaker.state()

    repo = Application.fetch_env!(:backplane_memory, :repo)
    lease_count = repo.aggregate(BackplaneMemory.Coordination.Lease, :count, :id)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        status: "ok",
        circuit_breaker: to_string(cb_state),
        memory_stats: stats,
        active_leases: lease_count
      })
    )
  end

  post "/api/memory/heal" do
    alias BackplaneMemory.Embedding.CircuitBreaker
    import Ecto.Query

    repo = Application.fetch_env!(:backplane_memory, :repo)
    now = DateTime.utc_now()

    {deleted, _} =
      repo.delete_all(from(l in BackplaneMemory.Coordination.Lease, where: l.expires_at < ^now))

    CircuitBreaker.reset()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        status: "healed",
        expired_leases_cleared: deleted,
        circuit_breaker: "closed"
      })
    )
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end
end
