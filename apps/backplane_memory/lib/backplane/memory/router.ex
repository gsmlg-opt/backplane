defmodule Backplane.Memory.Router do
  @moduledoc "HTTP REST endpoints for the memory app."

  use Plug.Router

  alias Backplane.Memory.Graph
  alias Backplane.Memory.Profiles

  @event_params [
    {"event_type", :event_type},
    {"payload", :payload},
    {"stream_id", :stream_id},
    {"project", :project},
    {"agent_id", :agent_id},
    {"host_id", :host_id},
    {"client_id", :client_id},
    {"run_id", :run_id},
    {"correlation_id", :correlation_id},
    {"causation_id", :causation_id},
    {"occurred_at", :occurred_at},
    {"idempotency_key", :idempotency_key}
  ]

  plug(:match)
  plug(:fetch_query_params)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/graph/stats" do
    stats = Graph.stats()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(stats))
  end

  get "/profile" do
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

  post "/query/expand" do
    query = conn.body_params["query"]

    if is_binary(query) and query != "" do
      llm_module =
        Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)

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

  post "/session/start" do
    case conn.body_params do
      %{"session_id" => session_id, "project" => project}
      when is_binary(session_id) and is_binary(project) ->
        case Backplane.Memory.Observations.register_session(session_id, project) do
          {:ok, _session} ->
            context = Backplane.Memory.Context.build(project, session_id)
            response = %{session_id: session_id}
            response = if context, do: Map.put(response, :context, context), else: response

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(response))

          {:error, _reason} ->
            persistence_unavailable(conn)
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "session_id and project are required"}))
    end
  end

  post "/session/end" do
    case conn.body_params do
      %{"session_id" => session_id} when is_binary(session_id) ->
        case Backplane.Memory.Observations.end_session(session_id) do
          {count, nil} when count in [0, 1] ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{session_id: session_id, status: "ended"}))

          {:error, _reason} ->
            persistence_unavailable(conn)
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "session_id is required"}))
    end
  end

  post "/observations" do
    session_id = Map.get(conn.body_params, "session_id", "")
    content = Map.get(conn.body_params, "content", "")

    if content == "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "content is required"}))
    else
      opts = observation_opts(conn.body_params)

      case Backplane.Memory.Observations.record(session_id, content, opts) do
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

  get "/file-history" do
    files = String.split(conn.query_params["files"] || "", ",", trim: true)
    exclude = conn.query_params["exclude_session"]
    opts = [exclude_session: exclude, limit: 50]
    rows = Backplane.Memory.Observations.file_history(files, opts)

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

  get "/audit" do
    limit = parse_int(conn.query_params["limit"], 50)
    offset = parse_int(conn.query_params["offset"], 0)
    operation = conn.query_params["operation"]
    actor = conn.query_params["actor"]

    opts = [limit: limit, offset: offset]
    opts = if operation && operation != "", do: opts ++ [operation: operation], else: opts
    opts = if actor && actor != "", do: opts ++ [actor: actor], else: opts

    entries = Backplane.Memory.Audit.list(opts) |> Enum.map(&serialize_audit_entry/1)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{results: entries}))
  end

  get "/diagnose" do
    alias Backplane.Memory.Embedding.CircuitBreaker

    stats = Backplane.Memory.Memories.stats()
    cb_state = CircuitBreaker.state()

    repo = Application.fetch_env!(:backplane_memory, :repo)
    lease_count = repo.aggregate(Backplane.Memory.Coordination.Lease, :count, :id)

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

  post "/heal" do
    alias Backplane.Memory.Embedding.CircuitBreaker
    import Ecto.Query

    repo = Application.fetch_env!(:backplane_memory, :repo)
    now = DateTime.utc_now()

    {deleted, _} =
      repo.delete_all(from(l in Backplane.Memory.Coordination.Lease, where: l.expires_at < ^now))

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

  defp observation_opts(params) do
    base = [tool_name: params["tool_name"], is_error: params["is_error"] == true]

    Enum.reduce(@event_params, base, fn {param, option}, opts ->
      case Map.fetch(params, param) do
        {:ok, value} -> Keyword.put(opts, option, value)
        :error -> opts
      end
    end)
  end

  defp serialize_audit_entry(%{id: id} = entry) when is_binary(id) and byte_size(id) == 16 do
    case Ecto.UUID.load(id) do
      {:ok, canonical_id} -> %{entry | id: canonical_id}
      :error -> entry
    end
  end

  defp serialize_audit_entry(entry), do: entry

  defp persistence_unavailable(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "memory persistence unavailable"}))
  end
end
