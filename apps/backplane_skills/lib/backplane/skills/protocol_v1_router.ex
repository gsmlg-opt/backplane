defmodule Backplane.Skills.ProtocolV1Router do
  @moduledoc "Skill Protocol v1 discovery, creation, resolution, and artifact surface."

  use Plug.Router

  import Plug.Conn

  alias Backplane.SkillProtocol.{Error, Telemetry, Wire}
  alias Backplane.Skills.Publication
  alias Backplane.Skills.Sources.Database

  plug(:match)
  plug(:observe)
  plug(:enabled)
  plug(:dispatch)

  post "/skills" do
    with [type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.content_type(type),
         :ok <- Wire.validate_creation(conn.body_params),
         {:ok, manifest} <- Database.create_manifest(conn.body_params) do
      json(conn, 201, manifest)
    else
      {:error, %Error{code: code, message: message}} ->
        error(conn, 422, code, message)

      {:error, :already_exists} ->
        error(conn, 409, :already_exists, "skill slug already exists")

      {:error, :invalid_document} ->
        error(conn, 422, :invalid_document, "skill document is invalid")

      {:error, _} ->
        error(conn, 503, :temporarily_unavailable, "publication unavailable")

      _ ->
        error(conn, 415, :invalid_request, "expected application/json")
    end
  end

  get "/catalog" do
    discovery_page(conn, :catalog)
  end

  get "/catalog/entry" do
    conn = fetch_query_params(conn)

    with {:ok, %{"skill_id" => skill_id}} <-
           scalar_params(conn.query_params, ~w(skill_id)),
         true <- Map.keys(conn.query_params) == ["skill_id"],
         true <- is_binary(skill_id) and skill_id != "",
         {:ok, catalog} <- Publication.always_entry(skill_id) do
      json(conn, 200, catalog)
    else
      _ -> error(conn, 400, :invalid_request, "skill_id is required")
    end
  end

  get "/search" do
    discovery_page(conn, :search)
  end

  get "/resolve" do
    conn = fetch_query_params(conn)
    skill_id = conn.query_params["skill_id"]
    revision = conn.query_params["revision"]

    valid = valid_query_shape?(conn.query_params, ~w(skill_id revision))
    valid = valid and is_binary(skill_id) and skill_id != ""
    valid = valid and (is_nil(revision) or is_binary(revision)) and revision != ""

    if valid do
      case Publication.resolve(skill_id, revision) do
        {:ok, published} ->
          json(conn, 200, published.manifest)

        {:error, :not_found} ->
          error(conn, 404, :not_found, "skill was not found")

        {:error, :revision_unavailable} ->
          error(conn, 410, :revision_unavailable, "skill revision is unavailable")
      end
    else
      error(conn, 400, :invalid_request, "skill_id and revision parameters are invalid")
    end
  end

  get "/artifact" do
    conn = fetch_query_params(conn)
    skill_id = conn.query_params["skill_id"]
    revision = conn.query_params["revision"]

    if valid_query_shape?(conn.query_params, ~w(skill_id revision)) and is_binary(skill_id) and
         skill_id != "" and is_binary(revision) and revision != "" do
      serve_artifact(conn, skill_id, revision)
    else
      error(conn, 400, :invalid_request, "skill_id and revision are required")
    end
  end

  match _ do
    error(conn, 404, :not_found, "route was not found")
  end

  defp discovery_page(conn, operation) do
    conn = fetch_query_params(conn)

    with {:ok, params} <- scalar_params(conn.query_params, ~w(limit cursor q tag fields view)),
         {:ok, view} <- discovery_view(operation, params),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, fields} <- parse_fields(params["fields"]),
         {:ok, after_id} <- decode_cursor(params["cursor"], conn, params) do
      opts = [
        view: view,
        limit: limit,
        after: after_id,
        q: params["q"],
        tag: params["tag"],
        fields: fields
      ]

      result =
        if operation == :search, do: Publication.search(opts), else: Publication.catalog(opts)

      body = %{
        protocol_version: "1",
        data: result.data,
        next_cursor: encode_cursor(result.next_cursor, conn, params)
      }

      json(conn, 200, if(view, do: Map.put(body, :view, view), else: body))
    else
      {:error, :invalid_request} ->
        error(conn, 400, :invalid_request, "invalid discovery parameters")
    end
  end

  defp discovery_view(:catalog, %{"view" => "always"}), do: {:ok, "always"}
  defp discovery_view(:catalog, params) when not is_map_key(params, "view"), do: {:ok, nil}

  defp discovery_view(:search, %{"q" => q} = params)
       when is_binary(q) and byte_size(q) <= 500 and not is_map_key(params, "view") do
    if String.trim(q) != "" and not String.contains?(q, <<0>>),
      do: {:ok, "search"},
      else: {:error, :invalid_request}
  end

  defp discovery_view(_, _), do: {:error, :invalid_request}

  defp serve_artifact(conn, skill_id, revision) do
    with {:ok, published} <- Publication.resolve(skill_id, revision) do
      etag = ~s("#{published.artifact_digest}")

      if etag in get_req_header(conn, "if-none-match") do
        conn
        |> put_resp_header("etag", etag)
        |> send_resp(304, "")
      else
        case Publication.artifact(skill_id, revision) do
          {:ok, bytes} ->
            conn
            |> put_resp_content_type("application/x-tar+gzip", nil)
            |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
            |> put_resp_header("etag", etag)
            |> send_resp(200, bytes)

          {:error, :integrity_mismatch} ->
            error(conn, 409, :integrity_mismatch, "artifact integrity check failed")

          {:error, _reason} ->
            error(
              conn,
              503,
              :temporarily_unavailable,
              "artifact is temporarily unavailable",
              true
            )
        end
      end
    else
      {:error, :revision_unavailable} ->
        error(conn, 410, :revision_unavailable, "skill revision is unavailable")

      {:error, :not_found} ->
        error(conn, 404, :not_found, "skill was not found")
    end
  end

  defp enabled(conn, _opts) do
    if Application.get_env(:backplane_skills, :skill_protocol_v1_enabled, true) do
      conn
    else
      conn
      |> put_private(:skill_protocol_error_code, :not_found)
      |> send_resp(404, "not found")
      |> halt()
    end
  end

  defp observe(conn, _opts) do
    started_at = Telemetry.start()
    operation = operation(conn.path_info)

    register_before_send(conn, fn sent ->
      params = query_params(sent)
      error_code = sent.private[:skill_protocol_error_code]

      result =
        case error_code do
          nil -> :ok
          code when is_atom(code) or is_binary(code) -> {:error, code}
          _other -> :ok
        end

      _ =
        Telemetry.emit(:server, operation, result, started_at,
          metadata: %{
            source_id: "backplane",
            skill_id: params["skill_id"],
            revision: params["revision"],
            artifact_digest: response_digest(sent),
            http_status: sent.status
          },
          measurements: %{request_bytes: 0, response_bytes: response_bytes(sent.resp_body)}
        )

      sent
    end)
  end

  defp operation(["search"]), do: :search
  defp operation(["skills"]), do: :create
  defp operation(["catalog"]), do: :catalog
  defp operation(["catalog", "entry"]), do: :catalog_entry
  defp operation(["resolve"]), do: :resolve
  defp operation(["artifact"]), do: :artifact
  defp operation(_path), do: :unknown

  defp query_params(%{query_params: %Plug.Conn.Unfetched{}, query_string: query_string}),
    do: URI.decode_query(query_string)

  defp query_params(%{query_params: params}) when is_map(params), do: params

  defp response_digest(conn) do
    case get_resp_header(conn, "etag") do
      [etag] -> String.trim(etag, "\"")
      _ -> nil
    end
  end

  defp response_bytes(body) when is_binary(body), do: byte_size(body)
  defp response_bytes(body) when is_list(body), do: body |> IO.iodata_length()
  defp response_bytes(_body), do: 0

  defp parse_limit(nil), do: {:ok, 20}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit >= 1 and limit <= 100 -> {:ok, limit}
      _ -> {:error, :invalid_request}
    end
  end

  defp parse_limit(_value), do: {:error, :invalid_request}

  defp parse_fields(nil), do: {:ok, []}
  defp parse_fields("argument_hint"), do: {:ok, [:argument_hint]}
  defp parse_fields(_value), do: {:error, :invalid_request}

  defp scalar_params(params, keys) do
    if valid_query_shape?(params, keys) and
         Enum.all?(keys, fn key -> is_nil(params[key]) or is_binary(params[key]) end),
       do: {:ok, params},
       else: {:error, :invalid_request}
  end

  defp valid_query_shape?(params, keys) do
    Enum.all?(Map.keys(params), fn key ->
      not Enum.any?(keys, fn allowed -> String.starts_with?(key, allowed <> "[") end)
    end)
  end

  defp encode_cursor(nil, _conn, _params), do: nil

  defp encode_cursor(after_id, conn, params) do
    payload = %{
      "after" => after_id,
      "view" => params["view"],
      "operation" => to_string(operation(conn.path_info)),
      "access" => access_context(conn),
      "fields" => params["fields"],
      "q" => params["q"],
      "tag" => params["tag"]
    }

    encoded = payload |> JSON.encode!() |> Base.url_encode64(padding: false)
    encoded <> "." <> signature(encoded)
  end

  defp decode_cursor(nil, _conn, _params), do: {:ok, nil}

  defp decode_cursor(cursor, conn, params) when is_binary(cursor) do
    with [encoded, supplied] <- String.split(cursor, ".", parts: 2),
         expected <- signature(encoded),
         true <- secure_compare(supplied, expected),
         {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- JSON.decode(bytes),
         true <- Map.get(payload, "operation", "catalog") == to_string(operation(conn.path_info)),
         true <- payload["view"] == params["view"],
         true <- payload["access"] == access_context(conn),
         true <- payload["fields"] == params["fields"],
         true <- payload["q"] == params["q"],
         true <- payload["tag"] == params["tag"],
         after_id = payload["after"],
         true <- valid_position?(operation(conn.path_info), after_id) do
      {:ok, after_id}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp valid_position?(:search, [score, id]), do: is_integer(score) and is_binary(id) and id != ""
  defp valid_position?(:catalog, id), do: is_binary(id) and id != ""
  defp valid_position?(_, _), do: false

  defp access_context(conn) do
    auth = conn.assigns.resource_auth

    [auth.kind, auth.subject, auth.client_id, Enum.sort(auth.scopes)]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp signature(encoded) do
    key = Application.fetch_env!(:backplane, :secret_key_base)
    :crypto.mac(:hmac, :sha256, key, encoded) |> Base.url_encode64(padding: false)
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_left, _right), do: false

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp error(conn, status, code, message, retryable \\ false) do
    conn
    |> put_private(:skill_protocol_error_code, code)
    |> json(status, %{
      protocol_version: "1",
      error: %{code: to_string(code), message: message, retryable: retryable}
    })
  end
end
