defmodule Backplane.LLM.ResponsesWebSocket.Policy do
  @moduledoc """
  Pins one native Responses upstream and checks each submission.
  Rewrites the model and normalizes Codex's redundant stream flag.
  Response events remain upstream-owned bytes.

  Because upstream WebSocket authentication happens only during the HTTP Upgrade
  handshake, any change to the underlying credential record—including a normal
  same-account OAuth token refresh—fails closed so the caller reconnects with
  fresh credentials. Same-account OAuth refresh is distinguished from credential
  rotation or account changes in the error reason (`:credential_refreshed` vs
  `:route_changed`) for accurate close diagnostics.
  """
  import Ecto.Query
  alias Backplane.AiProtocol.{Error, OpenAIResponsesWebSocket}

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

  @doc false
  def decode_create(bytes, codec_options) when is_binary(bytes) do
    bytes |> OpenAIResponsesWebSocket.decode_event(codec_options) |> create_event()
  end

  def decode_create(_, _), do: {:error, :invalid_request}

  defp create_event({:ok, %{"type" => "response.create", "model" => model} = params})
       when is_binary(model) and byte_size(model) in 1..1024,
       do: {:ok, params, model}

  defp create_event({:ok, %{"type" => "response.create"}}), do: {:error, :invalid_model}

  defp create_event({:error, %Error{message: "Encoded JSON exceeds " <> _}}),
    do: {:error, :message_too_big}

  defp create_event(_), do: {:error, :invalid_request}

  def request_model(bytes, codec_options) do
    case decode_create(bytes, codec_options) do
      {:ok, _params, model} -> {:ok, model}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def validate_create_params(params, route) when is_map(params) do
    rewritten = upstream_params(params, route)

    cond do
      Map.has_key?(rewritten, "stream") or Map.has_key?(rewritten, "background") ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  def authorize_request(conn), do: conn |> principal() |> authorize()

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
        {:ok,
         route
         |> Map.put(:fingerprint, fingerprint(route.provider, route.api, credential))
         |> Map.put(:identity_fingerprint, identity_fingerprint(route.provider, route.api, credential))}

      _ ->
        {:error, :credential_unavailable}
    end
  end

  def prepare(policy, bytes, codec_options) when is_binary(bytes) do
    case OpenAIResponsesWebSocket.decode_event(bytes, codec_options) do
      {:ok, %{"type" => "response.interrupt"} = params} ->
        prepare_interrupt(policy, params)

      event ->
        with {:ok, params, _model} <- create_event(event) do
          prepare_decoded(policy, params, codec_options)
        end
    end
  end

  defp prepare_interrupt(
         %{provider: %{preset_key: "openai-codex"}} = policy,
         %{"response_id" => id, "mode" => "discard_partial_items"} = params
       )
       when map_size(params) == 3 and is_binary(id) and byte_size(id) in 1..128 do
    with :ok <- authorize_current(policy) do
      {:ok, Formata.JSON.encode!(params), {:interrupt, id}}
    end
  end

  defp prepare_interrupt(_policy, _params), do: {:error, :invalid_request}

  @doc false
  def prepare_decoded(
        policy,
        %{"type" => "response.create", "model" => model} = params,
        codec_options
      ) do
    with true <- model in [policy.requested, policy.raw],
         :ok <- authorize_current(policy),
         {:ok, encoded} <- encode_create(params, policy, codec_options),
         :ok <- rate_limit(policy.provider.id) do
      {:ok, encoded}
    else
      false -> {:error, :model_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare_decoded(_policy, _params, _codec_options), do: {:error, :invalid_request}

  defp encode_create(params, policy, codec_options) do
    case params |> upstream_params(policy) |> OpenAIResponsesWebSocket.encode_create(codec_options) do
      {:ok, encoded} ->
        {:ok, encoded}

      {:error, %Error{message: "Encoded JSON exceeds " <> _}} ->
        {:error, :message_too_big}

      {:error, _} ->
        {:error, :invalid_request}
    end
  end

  defp upstream_params(params, policy) do
    params = Map.put(params, "model", policy.raw)

    case {policy.provider.preset_key, params} do
      {"openai-codex", %{"stream" => true}} -> Map.delete(params, "stream")
      _ -> params
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

  defp authorize_current(policy) do
    with :ok <- authorize(policy.principal), do: current?(policy)
  end

  defp current?(policy) do
    provider = Repo.get(Provider, policy.provider.id)
    api = Repo.get(ProviderApi, policy.api.id)
    credential = Repo.get_by(Credential, name: policy.provider.credential)

    with %Provider{enabled: true, deleted_at: nil} <- provider,
         %ProviderApi{enabled: true, responses_websocket: true} <- api,
         %Credential{} <- credential,
         true <- model_enabled?(provider.id, api.id, policy.raw),
         {:ok, resolved, raw} <- ModelResolver.resolve(:openai, policy.requested),
         true <- resolved.id == provider.id and raw == policy.raw do
      cond do
        fingerprint(provider, api, credential) == policy.fingerprint ->
          :ok

        same_account_oauth_refresh?(policy, provider, api, credential) ->
          {:error, :credential_refreshed}

        true ->
          {:error, :route_changed}
      end
    else
      _ -> {:error, :route_changed}
    end
  end

  defp same_account_oauth_refresh?(policy, provider, api, credential) do
    meta = credential.metadata || %{}

    Map.get(meta, "auth_type") == "openai_oauth" and
      is_binary(meta["account_id"]) and meta["account_id"] != "" and
      Map.get(policy, :identity_fingerprint) != nil and
      identity_fingerprint(provider, api, credential) == policy.identity_fingerprint
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

  defp identity_fingerprint(provider, api, credential) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        Map.take(provider, [:id, :credential, :preset_key, :default_headers]),
        Map.take(api, [:id, :base_url, :native_protocols, :default_headers, :backend_config]),
        Map.take(credential, [:id, :name, :metadata])
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
