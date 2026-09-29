defmodule Backplane.AgentRuntime.Codex.Permissions do
  @moduledoc """
  Host-mediated permission requests and capability grants.
  """

  alias Backplane.AgentRuntime.Error

  @spec request_permissions(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def request_permissions(request, auth) when is_map(request) and is_map(auth) do
    with :ok <- require_auth(auth),
         :ok <- validate_scope(request) do
      id = "permission_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

      {:ok,
       %{
         decision_request: %{
           permission_id: id,
           run_id: auth.run_id,
           owner: auth.owner,
           scope: request.scope,
           lifetime: Map.get(request, :lifetime, :run),
           capability: request.capability
         },
         side_effects: :none
       }}
    end
  end

  @spec decide(map(), atom(), map()) :: {:ok, map()} | {:error, Error.t()}
  def decide(request, decision, resolver)
      when is_map(request) and decision in [:allow, :deny] and is_map(resolver) do
    with :ok <- require_resolver(resolver, request),
         :ok <- same_request(request, resolver) do
      if decision == :deny do
        {:ok, %{status: :denied, capability: nil, side_effects: :none}}
      else
        grant = %{
          capability: request.capability,
          scope: request.scope,
          lifetime: Map.get(request, :lifetime, :run),
          permission_id: request.permission_id,
          run_id: request.run_id,
          owner: request.owner,
          resolver: resolver.owner
        }

        {:ok, %{status: :granted, grant: grant, side_effects: :none}}
      end
    end
  end

  defp require_auth(auth) do
    if Enum.all?([:run_id, :owner], &(is_binary(Map.get(auth, &1)) and Map.get(auth, &1) != "")),
      do: :ok,
      else: {:error, Error.new(:forbidden, "host identity is required")}
  end

  # The marker is supplied by the host adapter, never inferred from a model
  # permission request. A resolver also needs a distinct identity so the
  # requesting owner cannot approve its own capability.
  defp require_resolver(resolver, request) do
    with :ok <- require_auth(resolver) do
      resolver_id = Map.get(resolver, :resolver_id)

      cond do
        Map.get(resolver, :host_authorized) != true ->
          {:error, Error.new(:forbidden, "permission resolver is not host-authorized")}

        not (is_binary(resolver_id) and resolver_id != "") ->
          {:error, Error.new(:forbidden, "permission resolver identity is required")}

        resolver_id == Map.get(request, :owner) ->
          {:error, Error.new(:forbidden, "requester cannot self-approve permissions")}

        true ->
          :ok
      end
    end
  end

  defp validate_scope(request) do
    if is_binary(Map.get(request, :capability)) and Map.get(request, :capability) != "" and
         not is_nil(Map.get(request, :scope)),
       do: :ok,
       else: {:error, Error.new(:validation, "capability and exact scope are required")}
  end

  defp same_request(request, resolver) do
    if Map.get(request, :run_id) == Map.get(resolver, :run_id) and
         Map.get(request, :permission_id) == Map.get(resolver, :permission_id),
       do: :ok,
       else: {:error, Error.new(:forbidden, "permission decision does not match request")}
  end
end
