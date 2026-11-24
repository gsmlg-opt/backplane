defmodule Backplane.Auth.ResourceAuthPlug do
  @moduledoc """
  Authenticates OAuth and indexed database client bearer credentials for a
  canonical protected resource.
  """

  @behaviour Plug

  import Plug.Conn

  alias Backplane.Auth.{BearerChallenge, OAuth, Resources, Tokens}
  alias Backplane.Clients
  alias Backplane.Endpoints
  alias Backplane.Endpoints.Endpoint

  @credential_headers ~w(authorization x-api-key api-key x-goog-api-key)

  @type resource_auth :: %{
          kind: :oauth | :client_token | :open,
          subject: String.t() | nil,
          client_id: String.t() | nil,
          principal_metadata: map(),
          resource: Resources.key(),
          scopes: [String.t()]
        }

  @impl true
  def init(opts) do
    resource = Keyword.fetch!(opts, :resource)
    true = resource in Resources.keys()

    %{
      resource: resource,
      allow_client_bypass: Keyword.get(opts, :allow_client_bypass, false),
      required_scope: Keyword.get(opts, :required_scope),
      error_format: Keyword.get(opts, :error_format, :default)
    }
  end

  @impl true
  def call(%Plug.Conn{private: %{backplane_endpoint: %Endpoint{} = endpoint}} = conn, opts),
    do: call_endpoint(conn, endpoint, opts)

  def call(conn, %{resource: resource} = opts) do
    case bearer_credential(conn) do
      :missing -> resolve_anonymous_access(conn, resource, opts, :missing)
      :invalid -> resolve_anonymous_access(conn, resource, opts, :invalid)
      {:ok, token} -> authenticate(conn, resource, token, opts)
    end
  end

  # Endpoint mode: each endpoint feature is its own protected resource. It never
  # falls back to open access and re-reads the endpoint so disablement applies
  # immediately.
  defp call_endpoint(conn, %Endpoint{name: name}, %{resource: base} = opts) do
    with {:ok, feature} <- endpoint_feature(base),
         {:ok, endpoint} <- Endpoints.active(name, feature) do
      key = Resources.endpoint_key(name, base)

      case bearer_credential(conn) do
        :missing -> oauth_reject(conn, key, opts, nil)
        :invalid -> oauth_reject(conn, key, opts, "invalid_token")
        {:ok, token} -> authenticate_endpoint(conn, endpoint, key, token, opts)
      end
    else
      :error -> send_auth_error(conn, opts, 404, "Not Found")
    end
  end

  defp endpoint_feature(:mcp), do: {:ok, :mcp}
  defp endpoint_feature(:v1), do: {:ok, :llm}
  defp endpoint_feature(_base), do: :error

  defp authenticate_endpoint(conn, endpoint, key, token, opts) do
    case Tokens.verify_resource_access_token(token, key) do
      {:ok, oauth} ->
        oauth_success(conn, key, %{oauth | scopes: endpoint_scopes(endpoint, key, oauth.scopes)})

      {:error, :invalid_token} ->
        oauth_reject(conn, key, opts, "invalid_token")

      :not_oauth ->
        authenticate_endpoint_opaque(conn, endpoint, key, token, opts)
    end
  end

  defp authenticate_endpoint_opaque(conn, endpoint, key, token, opts) do
    case Clients.verify_token(token) do
      {:ok, client} ->
        if Endpoints.client_allowed?(endpoint, :client_token, client.id) do
          scopes = endpoint_scopes(endpoint, key, client.scopes)
          client_token_success(conn, key, client, scopes)
        else
          send_auth_error(conn, opts, 403, "Forbidden")
        end

      :error ->
        oauth_reject(conn, key, opts, "invalid_token")

      {:error, reason} when reason in [:unavailable, :overloaded] ->
        unavailable(conn, opts)
    end
  end

  defp endpoint_scopes(endpoint, {:endpoint, _name, :mcp}, scopes),
    do: Endpoints.restrict_tool_scopes(endpoint, scopes)

  defp endpoint_scopes(_endpoint, {:endpoint, _name, :v1}, scopes), do: scopes

  defp authenticate(conn, resource, token, opts) do
    case Tokens.verify_resource_access_token(token, resource) do
      {:ok, oauth} -> oauth_success(conn, resource, oauth)
      {:error, :invalid_token} -> resolve_anonymous_access(conn, resource, opts, :invalid_oauth)
      :not_oauth -> authenticate_opaque(conn, resource, token, opts)
    end
  end

  defp authenticate_opaque(conn, resource, token, opts) do
    case Clients.verify_token(token) do
      {:ok, client} ->
        client_token_success(conn, resource, client)

      :error ->
        resolve_anonymous_access(conn, resource, opts, :invalid)

      {:error, reason} when reason in [:unavailable, :overloaded] ->
        unavailable(conn, opts)
    end
  end

  defp resolve_anonymous_access(conn, resource, opts, failure) do
    case anonymous_access(resource, Map.get(opts, :allow_client_bypass, false)) do
      :open ->
        open_success(conn, resource)

      :oauth_required ->
        challenge_error = if failure == :missing, do: nil, else: "invalid_token"
        oauth_reject(conn, resource, opts, challenge_error)

      :client_required when failure == :invalid_oauth ->
        oauth_reject(conn, resource, opts, "invalid_token")

      :client_required ->
        compatibility_reject(conn, opts)

      :unavailable ->
        unavailable(conn, opts)
    end
  end

  @doc "Check current anonymous access for request admission and revalidation."
  @spec anonymous_access(Resources.key(), boolean()) ::
          :open | :oauth_required | :client_required | :unavailable
  def anonymous_access(resource, allow_client_bypass \\ false) do
    cond do
      OAuth.enabled_client_for_resource?(resource) ->
        :oauth_required

      (resource == :v1 or allow_client_bypass) and Clients.auth_bypass_enabled?() ->
        :open

      true ->
        case Clients.fetch_any_clients() do
          {:ok, false} -> :open
          {:ok, true} -> :client_required
          {:error, :unavailable} -> :unavailable
        end
    end
  end

  defp oauth_success(conn, resource, oauth) do
    auth = %{
      kind: :oauth,
      subject: oauth.token.sub,
      client_id: oauth.token.client_id,
      principal_metadata: %{},
      resource: resource,
      scopes: oauth.scopes
    }

    assign_success(conn, resource, auth)
  end

  defp client_token_success(conn, resource, client, scopes \\ nil) do
    auth = %{
      kind: :client_token,
      subject: nil,
      client_id: client.id,
      principal_metadata: %{},
      resource: resource,
      scopes: scopes || client.scopes
    }

    conn
    |> assign(:client, client)
    |> assign_success(resource, auth)
  end

  defp open_success(conn, resource) do
    headers = Enum.reject(conn.req_headers, fn {name, _} -> name in @credential_headers end)

    assign_success(%{conn | req_headers: headers}, resource, %{
      kind: :open,
      subject: nil,
      client_id: nil,
      principal_metadata: %{},
      resource: resource,
      scopes: ["*"]
    })
  end

  defp assign_success(conn, :mcp, auth) do
    conn
    |> assign(:resource_auth, auth)
    |> assign(:tool_scopes, auth.scopes)
  end

  defp assign_success(conn, resource, auth) when resource in [:skill_protocol, :v1],
    do: assign(conn, :resource_auth, auth)

  defp assign_success(conn, {:endpoint, _name, :mcp}, auth), do: assign_success(conn, :mcp, auth)
  defp assign_success(conn, {:endpoint, _name, :v1}, auth), do: assign_success(conn, :v1, auth)

  defp oauth_reject(conn, resource, opts, challenge_error) do
    challenge_opts =
      []
      |> maybe_put(:error, challenge_error)
      |> maybe_put(:scope, required_scope(conn, opts))

    conn = BearerChallenge.put(conn, resource, challenge_opts)
    send_auth_error(conn, opts, 401, "invalid_token")
  end

  defp compatibility_reject(conn, opts), do: send_auth_error(conn, opts, 401, "Unauthorized")

  defp unavailable(conn, opts) do
    conn
    |> put_resp_header("retry-after", "1")
    |> send_auth_error(opts, 503, "Authentication temporarily unavailable")
  end

  defp send_auth_error(conn, %{error_format: :google}, status, message) do
    body = %{
      "error" => %{
        "code" => status,
        "message" => message,
        "status" => google_status(status)
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Formata.JSON.encode!(body))
    |> halt()
  end

  defp send_auth_error(conn, _opts, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Formata.JSON.encode!(%{error: message}))
    |> halt()
  end

  defp google_status(503), do: "UNAVAILABLE"
  defp google_status(403), do: "PERMISSION_DENIED"
  defp google_status(404), do: "NOT_FOUND"
  defp google_status(_status), do: "UNAUTHENTICATED"

  defp required_scope(conn, %{required_scope: {module, function, args}})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: apply(module, function, [conn | args])

  defp required_scope(_conn, _opts), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp bearer_credential(conn) do
    authorization = get_req_header(conn, "authorization")
    api_key = get_req_header(conn, "x-api-key")

    cond do
      length(authorization) > 1 or length(api_key) > 1 ->
        :invalid

      authorization != [] and api_key != [] ->
        :invalid

      authorization != [] ->
        case authorization do
          [header] -> parse_bearer(header)
          _ -> :invalid
        end

      api_key != [] ->
        case api_key do
          [token] when is_binary(token) ->
            if Clients.token_size_valid?(token), do: {:ok, token}, else: :invalid

          _ ->
            :invalid
        end

      true ->
        :missing
    end
  end

  defp parse_bearer(header) when is_binary(header) do
    if byte_size(header) <= Backplane.Clients.AuthCache.options()[:max_token_bytes] + 7 do
      parse_bounded_bearer(header)
    else
      :invalid
    end
  end

  defp parse_bounded_bearer(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] ->
        token = String.trim(token)

        if String.downcase(scheme) == "bearer" and Clients.token_size_valid?(token) do
          {:ok, token}
        else
          :invalid
        end

      _parts ->
        :invalid
    end
  end
end
