defmodule Backplane.LLM.OpenAI.RealtimeWebSocket.Policy do
  @moduledoc """
  Pins a native Realtime model and credential context for one connection.

  Realtime events are opaque JSON objects. Only model identifiers are rewritten;
  all other valid events retain their original bytes, including future events.
  """

  alias Backplane.LLM.OpenAI.Service
  alias Backplane.LLM.RateLimiter
  alias Backplane.Repo
  alias Backplane.Settings.Credential

  @max_bytes 2_097_152

  def pin(route, conn) do
    with %Credential{} = credential <- Repo.get_by(Credential, name: route.provider.credential),
         {:ok, headers} <- Service.auth_headers(route),
         true <- Repo.get(Credential, credential.id) == credential do
      policy =
        route
        |> Map.put(:principal, principal(conn))
        |> Map.put(:fingerprint, fingerprint(route, credential))

      with :ok <- current?(policy),
           do:
             {:ok, Map.put(policy, :revalidated_at, System.monotonic_time(:millisecond)), headers}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :credential_unavailable}
    end
  end

  def prepare(policy, bytes) do
    with true <- is_binary(bytes) and byte_size(bytes) <= max_bytes(policy),
         {:ok, %{"type" => type} = event} when is_binary(type) and type != "" <- decode(bytes),
         {:ok, policy} <- revalidate(policy, type),
         {:ok, rewritten} <- rewrite_models(event, policy),
         :ok <- response_rate_limit(type, policy.provider),
         {:ok, encoded} <- if(rewritten == event, do: {:ok, bytes}, else: Jason.encode(rewritten)) do
      {:ok, encoded, policy}
    else
      false -> {:error, :message_too_big}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_event}
    end
  end

  def max_bytes(policy), do: min(@max_bytes, policy.service.max_request_bytes)

  defp revalidate(policy, type) do
    now = System.monotonic_time(:millisecond)

    # Audio append events arrive many times per second. Check current authority
    # at most once per second for those events; state changes and explicit
    # generation always check immediately before upstream admission.
    if type in ["session.update", "response.create"] or now - policy.revalidated_at >= 1_000 do
      with :ok <- authorize(policy.principal),
           :ok <- current?(policy),
           do: {:ok, %{policy | revalidated_at: now}}
    else
      {:ok, policy}
    end
  end

  defp response_rate_limit("response.create", provider), do: rate_limit(provider)
  defp response_rate_limit(_type, _provider), do: :ok

  defp decode(bytes) do
    with {:ok, object} <- Jason.decode(bytes, objects: :ordered_objects),
         do: unique_object(object)
  end

  defp unique_object(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
        case unique_object(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(map, key, value)}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_parameter}
    end
  end

  defp unique_object(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, values} ->
      case unique_object(value) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp unique_object(value), do: {:ok, value}

  defp rewrite_models(event, policy) do
    with {:ok, event} <- rewrite_model(event, policy),
         {:ok, event} <- rewrite_nested(event, "session", policy),
         {:ok, event} <- rewrite_nested(event, "response", policy) do
      {:ok, event}
    end
  end

  defp rewrite_nested(event, key, policy) do
    case event do
      %{^key => nested} when is_map(nested) ->
        with {:ok, nested} <- rewrite_model(nested, policy),
             do: {:ok, Map.put(event, key, nested)}

      _ ->
        {:ok, event}
    end
  end

  defp rewrite_model(%{"model" => model} = object, policy) do
    canonical = policy.provider.name <> "/" <> policy.raw_model

    if model in [policy.requested_model, policy.raw_model, canonical],
      do: {:ok, Map.put(object, "model", policy.raw_model)},
      else: {:error, :model_mismatch}
  end

  defp rewrite_model(object, _policy), do: {:ok, object}

  defp current?(policy) do
    with {:ok, route} <- Service.resolve(:realtime, policy.requested_model),
         %Credential{} = credential <- Repo.get_by(Credential, name: route.provider.credential),
         true <- route.raw_model == policy.raw_model,
         true <- fingerprint(route, credential) == policy.fingerprint do
      :ok
    else
      _ -> {:error, :route_changed}
    end
  end

  defp fingerprint(route, credential) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        Map.from_struct(route.service)
        |> Map.drop([:__meta__, :provider, :inserted_at, :updated_at]),
        Map.take(route.provider, [:id, :credential, :preset_key, :default_headers, :rpm_limit]),
        Map.take(route.api, [:id, :base_url, :default_headers]),
        Map.take(credential, [:id, :name, :encrypted_value, :metadata])
      })
    )
  end

  defp principal(conn) do
    token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        [header] -> header |> String.split(" ", parts: 2) |> List.last()
        _ -> conn |> Plug.Conn.get_req_header("x-api-key") |> List.first()
      end

    %{token: token, auth: conn.assigns[:resource_auth]}
  end

  defp authorize(%{token: nil, auth: %{kind: :open}}) do
    if not Backplane.Auth.OAuth.enabled_client_for_resource?(:v1) and
         Backplane.Clients.fetch_any_clients() == {:ok, false},
       do: :ok,
       else: {:error, :principal_changed}
  end

  defp authorize(%{token: token, auth: %{kind: :oauth} = auth}) when is_binary(token) do
    case Backplane.Auth.Tokens.verify_resource_access_token(token, :v1) do
      {:ok, oauth} ->
        if oauth.token.client_id == auth.client_id and oauth.token.sub == auth.subject and
             Backplane.Clients.scope_matches?(oauth.scopes, "llm::invoke"),
           do: :ok,
           else: {:error, :principal_changed}

      _ ->
        {:error, :principal_changed}
    end
  end

  defp authorize(%{token: token, auth: %{kind: :client_token} = auth}) when is_binary(token) do
    case Backplane.Clients.verify_token(token) do
      {:ok, client} ->
        if client.id == auth.client_id and
             Backplane.Clients.scope_matches?(client.scopes, "llm::invoke"),
           do: :ok,
           else: {:error, :principal_changed}

      _ ->
        {:error, :principal_changed}
    end
  end

  defp authorize(_), do: {:error, :principal_changed}

  defp rate_limit(provider) do
    case RateLimiter.check(provider.id, provider.rpm_limit) do
      :ok -> :ok
      _ -> {:error, :rate_limited}
    end
  end
end
