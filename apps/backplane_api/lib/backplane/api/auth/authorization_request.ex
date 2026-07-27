defmodule Backplane.Api.Auth.AuthorizationRequest do
  @moduledoc false

  alias Backplane.Auth.{OAuth, RBAC, Resources}
  alias Backplane.Auth.Schemas.User
  alias Boruta.Ecto.Client

  @spec preflight(Client.t(), map(), nil | Resources.key()) ::
          {:ok, map()} | {:error, atom()}
  def preflight(client, params, resource) do
    client_scopes = Enum.map(client.authorized_scopes, & &1.name)

    with :ok <- validate_state(params),
         {:ok, requested} <- scopes(params),
         :ok <- validate_response_type(params),
         :ok <- validate_pkce(params),
         :ok <- validate_resource_assignment(client, resource),
         :ok <- validate_client_scopes(requested, client_scopes),
         :ok <- validate_resource_vocabulary(requested, resource),
         :ok <- require_resource_for_operations(client, requested, resource) do
      {:ok, params}
    end
  end

  @spec for_user(Client.t(), User.t(), map(), nil | Resources.key()) ::
          {:ok, map()} | {:error, :invalid_scope}
  def for_user(client, user, params, resource) do
    client_scopes = Enum.map(client.authorized_scopes, & &1.name)
    user_scopes = RBAC.effective_scope_names(user)

    with {:ok, requested} <- scopes(params) do
      effective =
        cond do
          resource && requested == [] ->
            Resources.default_scopes(resource, client_scopes, user_scopes)

          Enum.all?(requested, &(&1 in user_scopes)) ->
            {:ok, requested}

          true ->
            {:error, :invalid_scope}
        end

      case effective do
        {:ok, scopes} -> {:ok, Map.put(params, "scope", Enum.join(scopes, " "))}
        {:error, :invalid_scope} -> {:error, :invalid_scope}
      end
    end
  end

  defp scopes(%{"scope" => scope}) when is_binary(scope),
    do: {:ok, String.split(scope, " ", trim: true)}

  defp scopes(params) when is_map(params) do
    if Map.has_key?(params, "scope"),
      do: {:error, :invalid_scope},
      else: {:ok, []}
  end

  defp validate_state(%{"state" => state}) when is_binary(state), do: :ok

  defp validate_state(params) when is_map(params) do
    if Map.has_key?(params, "state"),
      do: {:error, :invalid_request},
      else: :ok
  end

  defp validate_response_type(%{"response_type" => "code"}), do: :ok
  defp validate_response_type(_params), do: {:error, :unsupported_response_type}

  defp validate_pkce(%{"code_challenge" => value, "code_challenge_method" => "S256"})
       when is_binary(value) and value != "",
       do: :ok

  defp validate_pkce(%{"code_challenge_method" => "plain"}),
    do: {:error, :unsupported_code_challenge_method}

  defp validate_pkce(_params), do: {:error, :invalid_request}

  defp validate_resource_assignment(_client, nil), do: :ok

  defp validate_resource_assignment(client, resource) do
    if OAuth.client_allows_resource?(client, resource),
      do: :ok,
      else: {:error, :invalid_target}
  end

  defp validate_client_scopes(requested, allowed) do
    if Enum.all?(requested, &(&1 in allowed)),
      do: :ok,
      else: {:error, :invalid_scope}
  end

  defp validate_resource_vocabulary(_requested, nil), do: :ok

  defp validate_resource_vocabulary(requested, resource) do
    if Enum.all?(requested, &Resources.valid_scope?(resource, &1)),
      do: :ok,
      else: {:error, :invalid_scope}
  end

  defp require_resource_for_operations(client, requested, nil) do
    if OAuth.client_resources(client) != [] and
         Enum.any?(requested, &Resources.protected_operation_scope?/1),
       do: {:error, :invalid_target},
       else: :ok
  end

  defp require_resource_for_operations(_client, _requested, _resource), do: :ok
end
