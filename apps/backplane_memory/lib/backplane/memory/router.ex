defmodule Backplane.Memory.Router do
  @moduledoc "HTTP REST endpoints for the memory app."

  use Plug.Router

  alias Backplane.Memory.{Authorization, Service}

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
  plug(:authorize_request)
  plug(:dispatch)

  get "/graph/stats" do
    tool_response(conn, "memory::graph_stats", conn.query_params)
  end

  get "/profile" do
    project = conn.query_params["project"] || ""

    if project == "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "project param required"}))
    else
      tool_response(conn, "memory::profile", conn.query_params)
    end
  end

  post "/query/expand" do
    tool_response(conn, "memory::expand_query", conn.body_params)
  end

  post "/lessons" do
    tool_response(conn, "memory::lesson_save", conn.body_params)
  end

  post "/lessons/recall" do
    tool_response(conn, "memory::lesson_recall", conn.body_params)
  end

  post "/lessons/strengthen" do
    tool_response(conn, "memory::lesson_strengthen", conn.body_params)
  end

  post "/lessons/promote" do
    tool_response(conn, "memory::lesson_promote", conn.body_params)
  end

  post "/lessons/archive" do
    tool_response(conn, "memory::lesson_archive", conn.body_params)
  end

  post "/crystals/crystallize" do
    tool_response(conn, "memory::crystallize", conn.body_params)
  end

  get "/crystals" do
    tool_response(conn, "memory::crystal_list", conn.query_params)
  end

  get "/crystals/:id" do
    tool_response(conn, "memory::crystal_get", %{"crystal_id" => id})
  end

  post "/crystals/search" do
    tool_response(conn, "memory::crystal_search", conn.body_params)
  end

  get "/activity/summary" do
    tool_response(conn, "memory::activity_summary", conn.query_params)
  end

  get "/replay/sessions" do
    tool_response(conn, "memory::replay_sessions", conn.query_params)
  end

  get "/replay/sessions/:session_id" do
    tool_response(
      conn,
      "memory::replay_load",
      Map.put(conn.query_params, "session_id", session_id)
    )
  end

  get "/recall/:recall_run_id/trace" do
    tool_response(
      conn,
      "memory::recall_explain",
      Map.put(conn.query_params, "recall_run_id", recall_run_id)
    )
  end

  get "/sessions/:session_id/handoff" do
    if conn.query_params == %{} do
      resource_response(conn, "memory://session/#{URI.encode(session_id)}/handoff")
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "invalid_arguments"}))
    end
  end

  get "/sessions/:session_id" do
    if conn.query_params == %{} do
      partition = conn.assigns.memory_partition

      case Backplane.Memory.Projections.SessionDetail.get(
             %{
               host_id: partition.host_id,
               client_id: partition.partition_id,
               scope: partition.scope,
               namespace: partition.namespace
             },
             session_id
           ) do
        {:ok, detail} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(detail))

        {:error, :not_found} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, Jason.encode!(%{error: "not found"}))

        {:error, reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{error: format_error(reason)}))
      end
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "invalid_arguments"}))
    end
  end

  post "/replay/import" do
    tool_response(conn, "memory::replay_import", conn.body_params)
  end

  post "/session/start" do
    case conn.body_params do
      %{"session_id" => session_id, "project" => project}
      when is_binary(session_id) and is_binary(project) ->
        opts = partition_opts(conn.assigns.memory_partition)

        case Backplane.Memory.Observations.register_session(session_id, project, opts) do
          {:ok, _session} ->
            context = Backplane.Memory.Context.build(project, session_id, opts)
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
        case Backplane.Memory.Observations.end_session(
               session_id,
               partition_opts(conn.assigns.memory_partition)
             ) do
          {count, nil} when count in [0, 1] ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{session_id: session_id, status: "ended"}))

          {:error, :not_found} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(404, Jason.encode!(%{error: "session not found"}))

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
      opts = observation_opts(conn.body_params, conn.assigns.memory_partition)

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
    args = Map.put(conn.query_params, "files", files)
    tool_response(conn, "memory::file_history", args)
  end

  get "/audit" do
    tool_response(conn, "memory::audit", conn.query_params)
  end

  get "/diagnose" do
    tool_response(conn, "memory::diagnose", conn.query_params)
  end

  post "/heal" do
    tool_response(conn, "memory::heal", conn.body_params)
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end

  defp authorize_request(conn, _opts) do
    case request_tool(conn.method, conn.path_info) do
      nil ->
        conn

      tool ->
        auth = Map.get(conn.assigns, :resource_auth, %{})
        args = Map.merge(conn.query_params, conn.body_params)

        case Authorization.authorize_tool(tool, args, auth) do
          {:ok, _trusted_args, partition} ->
            conn
            |> assign(:memory_auth, auth)
            |> assign(:memory_partition, partition)

          {:error, _reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(403, Jason.encode!(%{error: "Forbidden"}))
            |> halt()
        end
    end
  end

  defp request_tool("GET", ["graph", "stats"]), do: "memory::graph_stats"
  defp request_tool("GET", ["profile"]), do: "memory::profile"
  defp request_tool("POST", ["query", "expand"]), do: "memory::expand_query"
  defp request_tool("POST", ["lessons"]), do: "memory::lesson_save"
  defp request_tool("POST", ["lessons", "recall"]), do: "memory::lesson_recall"
  defp request_tool("POST", ["lessons", "strengthen"]), do: "memory::lesson_strengthen"
  defp request_tool("POST", ["lessons", "promote"]), do: "memory::lesson_promote"
  defp request_tool("POST", ["lessons", "archive"]), do: "memory::lesson_archive"
  defp request_tool("POST", ["crystals", "crystallize"]), do: "memory::crystallize"
  defp request_tool("GET", ["crystals"]), do: "memory::crystal_list"
  defp request_tool("GET", ["crystals", _id]), do: "memory::crystal_get"
  defp request_tool("POST", ["crystals", "search"]), do: "memory::crystal_search"
  defp request_tool("GET", ["activity", "summary"]), do: "memory::activity_summary"
  defp request_tool("GET", ["replay", "sessions"]), do: "memory::replay_sessions"
  defp request_tool("GET", ["replay", "sessions", _session_id]), do: "memory::replay_load"

  defp request_tool("GET", ["recall", _recall_run_id, "trace"]),
    do: "memory::recall_explain"

  defp request_tool("GET", ["sessions", _session_id, "handoff"]), do: "memory::sessions"
  defp request_tool("GET", ["sessions", _session_id]), do: "memory::sessions"
  defp request_tool("POST", ["replay", "import"]), do: "memory::replay_import"
  defp request_tool("POST", ["session", "start"]), do: "memory::remember"
  defp request_tool("POST", ["session", "end"]), do: "memory::forget"
  defp request_tool("POST", ["observations"]), do: "memory::remember"
  defp request_tool("GET", ["file-history"]), do: "memory::file_history"
  defp request_tool("GET", ["audit"]), do: "memory::audit"
  defp request_tool("GET", ["diagnose"]), do: "memory::diagnose"
  defp request_tool("POST", ["heal"]), do: "memory::heal"
  defp request_tool(_method, _path), do: nil

  defp tool_response(conn, tool, args) do
    case Service.call(tool, normalize_tool_args(tool, args), conn.assigns.memory_auth) do
      {:ok, result} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(rest_result(tool, result)))

      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "Forbidden"}))

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "not found"}))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: format_error(reason)}))
    end
  end

  defp resource_response(conn, uri) do
    case Service.read_resource(uri, conn.assigns.memory_auth) do
      {:ok, json} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, json)

      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "Forbidden"}))

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "not found"}))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: format_error(reason)}))
    end
  end

  defp normalize_tool_args("memory::replay_sessions", args) do
    args
    |> normalize_integer("limit")
    |> normalize_integer("offset")
  end

  defp normalize_tool_args("memory::replay_load", args), do: normalize_integer(args, "limit")
  defp normalize_tool_args("memory::crystal_list", args), do: normalize_integer(args, "limit")
  defp normalize_tool_args(_tool, args), do: args

  defp normalize_integer(args, key) do
    case args[key] do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> Map.put(args, key, integer)
          _invalid -> args
        end

      _value ->
        args
    end
  end

  defp observation_opts(params, partition) do
    base = [tool_name: params["tool_name"], is_error: params["is_error"] == true]

    @event_params
    |> Enum.reject(fn {_param, option} -> option in [:host_id, :client_id] end)
    |> Enum.reduce(base, fn {param, option}, opts ->
      case Map.fetch(params, param) do
        {:ok, value} -> Keyword.put(opts, option, value)
        :error -> opts
      end
    end)
    |> Keyword.merge(partition_opts(partition))
  end

  defp partition_opts(partition) do
    [
      host_id: partition.host_id,
      client_id: partition.partition_id,
      scope: partition.scope,
      namespace: partition.namespace,
      trusted_partition: %{
        host_id: partition.host_id,
        client_id: partition.partition_id,
        scope: partition.scope,
        namespace: partition.namespace
      }
    ]
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  defp rest_result("memory::audit", %{entries: entries}), do: %{results: entries}
  defp rest_result(_tool, result), do: result

  defp persistence_unavailable(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "memory persistence unavailable"}))
  end
end
