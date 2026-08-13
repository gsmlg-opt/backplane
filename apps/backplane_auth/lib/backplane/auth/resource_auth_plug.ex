defmodule Backplane.Auth.ResourceAuthPlug do
  @moduledoc """
  Authenticates OAuth, database client, and legacy bearer credentials for a
  canonical protected resource.
  """

  @behaviour Plug

  import Plug.Conn

  alias Backplane.Auth.{BearerChallenge, OAuth, Resources, Tokens}
  alias Backplane.Clients

  @type resource_auth :: %{
          kind: :oauth | :client_token | :legacy | :open,
          subject: String.t() | nil,
          client_id: String.t() | nil,
          principal_metadata: map(),
          resource: Resources.key(),
          scopes: [String.t()]
        }

  @impl true
  def init(opts) do
    resource = Keyword.fetch!(opts, :resource)
    true = resource in [:mcp, :v1]

    %{
      resource: resource,
      required_scope: Keyword.get(opts, :required_scope)
    }
  end

  @impl true
  def call(conn, %{resource: resource} = opts) do
    case bearer_credential(conn) do
      :missing -> authenticate_missing(conn, resource, opts)
      :invalid -> reject_supplied(conn, resource, opts)
      {:ok, token} -> authenticate(conn, resource, token, opts)
    end
  end

  defp authenticate(conn, resource, token, opts) do
    case Tokens.verify_resource_access_token(token, resource) do
      {:ok, oauth} -> oauth_success(conn, resource, oauth)
      {:error, :invalid_token} -> oauth_reject(conn, resource, opts, "invalid_token")
      :not_oauth -> authenticate_opaque(conn, resource, token, opts)
    end
  end

  defp authenticate_opaque(conn, resource, token, opts) do
    case Clients.verify_token(token) do
      {:ok, client} ->
        client_token_success(conn, resource, client)

      :error ->
        if valid_legacy_token?(token) do
          unrestricted_success(conn, resource, :legacy)
        else
          reject_supplied(conn, resource, opts)
        end
    end
  end

  defp authenticate_missing(conn, resource, opts) do
    cond do
      OAuth.enabled_client_for_resource?(resource) ->
        oauth_reject(conn, resource, opts, nil)

      Clients.any_clients?() or legacy_configured?() ->
        compatibility_reject(conn)

      true ->
        unrestricted_success(conn, resource, :open)
    end
  end

  defp reject_supplied(conn, resource, opts) do
    if OAuth.enabled_client_for_resource?(resource) do
      oauth_reject(conn, resource, opts, "invalid_token")
    else
      compatibility_reject(conn)
    end
  end

  defp oauth_success(conn, resource, oauth) do
    auth = %{
      kind: :oauth,
      subject: oauth.token.sub,
      client_id: oauth.token.client_id,
      principal_metadata: memory_principal_metadata(oauth.client.metadata),
      resource: resource,
      scopes: oauth.scopes
    }

    assign_success(conn, resource, auth)
  end

  defp client_token_success(conn, resource, client) do
    auth = %{
      kind: :client_token,
      subject: nil,
      client_id: client.id,
      principal_metadata: memory_principal_metadata(client.metadata),
      resource: resource,
      scopes: client.scopes
    }

    conn
    |> assign(:client, client)
    |> assign_success(resource, auth)
  end

  defp unrestricted_success(conn, resource, kind) do
    assign_success(conn, resource, %{
      kind: kind,
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

  defp assign_success(conn, :v1, auth), do: assign(conn, :resource_auth, auth)

  defp oauth_reject(conn, resource, opts, challenge_error) do
    challenge_opts =
      []
      |> maybe_put(:error, challenge_error)
      |> maybe_put(:scope, required_scope(conn, opts))

    conn
    |> BearerChallenge.put(resource, challenge_opts)
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "invalid_token"}))
    |> halt()
  end

  defp compatibility_reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
    |> halt()
  end

  defp required_scope(conn, %{required_scope: {module, function, args}})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: apply(module, function, [conn | args])

  defp required_scope(_conn, _opts), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp memory_principal_metadata(metadata) when is_map(metadata) do
    case Map.get(metadata, "memory_partition_id", Map.get(metadata, :memory_partition_id)) do
      partition_id when is_binary(partition_id) ->
        %{"memory_partition_id" => partition_id}

      _other ->
        %{}
    end
  end

  defp memory_principal_metadata(_metadata), do: %{}

  defp bearer_credential(conn) do
    case get_req_header(conn, "authorization") do
      [] -> :missing
      [header] -> parse_bearer(header)
      _headers -> :invalid
    end
  end

  defp parse_bearer(header) when is_binary(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] ->
        token = String.trim(token)

        if String.downcase(scheme) == "bearer" and token != "" do
          {:ok, token}
        else
          :invalid
        end

      _parts ->
        :invalid
    end
  end

  defp legacy_configured?, do: configured_legacy_tokens() != []

  defp valid_legacy_token?(token) do
    Enum.any?(configured_legacy_tokens(), fn
      candidate when is_binary(candidate) and byte_size(candidate) == byte_size(token) ->
        Plug.Crypto.secure_compare(token, candidate)

      _candidate ->
        false
    end)
  end

  defp configured_legacy_tokens do
    tokens = Application.get_env(:backplane, :auth_tokens, [])
    single = Application.get_env(:backplane, :auth_token)

    case {tokens, single} do
      {list, _single} when is_list(list) and list != [] -> list
      {_list, token} when is_binary(token) -> [token]
      _configuration -> []
    end
  end
end
