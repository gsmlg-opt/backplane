defmodule Backplane.LLM.ResponseCapability do
  @moduledoc """
  Explicit operator attestation of native OpenAI Responses lifecycle semantics.

  An OpenAI-compatible URL or protocol declaration alone does not enable this
  capability. Codex OAuth and other unverified credential types are excluded.
  """

  alias Backplane.LLM.{Provider, ProviderApi}
  alias Backplane.Repo
  alias Backplane.Settings.Credential

  @doc "Whether the provider API has an eligible explicit lifecycle opt-in."
  def enabled?(%Provider{} = provider, %ProviderApi{} = api) do
    api.responses_lifecycle == true and api.api_surface == :openai and
      :openai_responses in api.native_protocols and api.enabled and provider.enabled and
      is_nil(provider.deleted_at) and provider.preset_key != "openai-codex"
  end

  @doc "Check the opt-in and actual credential type without resolving a secret."
  def validate(%Provider{} = provider, %ProviderApi{} = api) do
    if enabled?(provider, api) and api_key_credential?(provider.credential),
      do: :ok,
      else: {:error, :responses_lifecycle_unsupported}
  end

  defp api_key_credential?(name) do
    case Repo.get_by(Credential, name: name) do
      %Credential{metadata: metadata} ->
        Map.get(metadata || %{}, "auth_type") in [nil, "api_key"]

      nil ->
        false
    end
  end
end
