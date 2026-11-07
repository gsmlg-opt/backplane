defmodule Backplane.LLM.ResponsesWebSocket.Policy do
  @moduledoc """
  Pins one native Responses upstream and checks each creation before submission.
  Only the model field is rewritten; response events remain upstream-owned bytes.
  """
  import Ecto.Query
  alias Backplane.AiProtocol.OpenAIResponsesWebSocket, as: Codec

  alias Backplane.LLM.{
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    RateLimiter
  }

  alias Backplane.Repo
  alias Backplane.Settings.Credential

  @max_bytes 2_097_152

  def resolve(model) when is_binary(model) and byte_size(model) in 1..1024 do
    with {:ok, provider, raw} <- ModelResolver.resolve(:openai, model),
         %Provider{enabled: true} = provider <- Repo.get(Provider, provider.id),
         %ProviderApi{enabled: true} = api <-
           Repo.get_by(ProviderApi, provider_id: provider.id, api_surface: :openai),
         true <- is_nil(provider.deleted_at),
         true <- :openai_responses in api.native_protocols,
         true <- api.responses_websocket do
      {:ok, %{provider: provider, api: api, requested: model, raw: raw}}
    else
      %ProviderApi{responses_websocket: false} -> {:error, :disabled}
      false -> {:error, :disabled}
      _ -> {:error, :model_unavailable}
    end
  end

  def resolve(_), do: {:error, :invalid_model}

  def pin(route, conn, snapshot) do
    route = Map.put(route, :principal, principal(conn))

    case Repo.get_by(Credential, name: route.provider.credential) do
      %Credential{} = credential when credential == snapshot ->
        {:ok, Map.put(route, :fingerprint, fingerprint(route.provider, route.api, credential))}

      _ ->
        {:error, :credential_unavailable}
    end
  end

  def prepare(policy, text) do
    with {:ok, %{"type" => "response.create", "model" => model} = params} <-
           Codec.decode_event(text),
         true <- model in [policy.requested, policy.raw],
         :ok <- authorize(policy.principal),
         :ok <- current?(policy),
         {:ok, encoded} <- Codec.encode_create(Map.put(params, "model", policy.raw)),
         :ok <- rate_limit(policy.provider.id) do
      {:ok, encoded}
    else
      false -> {:error, :model_mismatch}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
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

  defp authorize(%{token: token, auth: auth}) when is_binary(token) do
    case Backplane.Auth.Tokens.verify_resource_access_token(token, :v1) do
      {:ok, oauth} ->
        if auth.kind == :oauth and oauth.token.client_id == auth.client_id and
             oauth.token.sub == auth.subject and
             Backplane.Clients.scope_matches?(oauth.scopes, "llm::invoke"),
           do: :ok,
           else: {:error, :principal_changed}

      :not_oauth ->
        case Backplane.Clients.verify_token(token) do
          {:ok, client} ->
            if auth.kind == :client_token and client.id == auth.client_id and
                 Backplane.Clients.scope_matches?(client.scopes, "llm::invoke"),
               do: :ok,
               else: {:error, :principal_changed}

          _ ->
            {:error, :principal_changed}
        end

      _ ->
        {:error, :principal_changed}
    end
  end

  defp authorize(_), do: {:error, :principal_changed}

  def max_bytes, do: @max_bytes

  defp current?(policy) do
    provider = Repo.get(Provider, policy.provider.id)
    api = Repo.get(ProviderApi, policy.api.id)
    credential = Repo.get_by(Credential, name: policy.provider.credential)

    with %Provider{enabled: true, deleted_at: nil} <- provider,
         %ProviderApi{enabled: true, responses_websocket: true} <- api,
         %Credential{} <- credential,
         true <- fingerprint(provider, api, credential) == policy.fingerprint,
         true <- model_enabled?(provider.id, api.id, policy.raw),
         {:ok, resolved, raw} <- ModelResolver.resolve(:openai, policy.requested),
         true <- resolved.id == provider.id and raw == policy.raw do
      :ok
    else
      _ -> {:error, :route_changed}
    end
  end

  defp model_enabled?(provider_id, api_id, raw) do
    Repo.exists?(
      from m in ProviderModel,
        join: s in ProviderModelSurface,
        on: s.provider_model_id == m.id,
        where:
          m.provider_id == ^provider_id and m.model == ^raw and m.enabled and
            s.provider_api_id == ^api_id and s.enabled
    )
  end

  defp fingerprint(provider, api, credential) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        Map.take(provider, [:id, :credential, :preset_key, :default_headers]),
        Map.take(api, [:id, :base_url, :native_protocols, :default_headers, :backend_config]),
        Map.take(credential, [:id, :name, :encrypted_value, :metadata])
      })
    )
  end

  defp rate_limit(id) do
    case Repo.get(Provider, id) do
      %Provider{rpm_limit: limit} ->
        case RateLimiter.check(id, limit) do
          :ok -> :ok
          _ -> {:error, :rate_limited}
        end

      _ ->
        {:error, :route_changed}
    end
  end
end
