defmodule Backplane.LLM.Google.Resolution do
  @moduledoc false

  alias Backplane.LLM.{AutoModelRoute, ModelAlias, ModelResolver, ProviderApi}

  def resolve(model) when is_binary(model) do
    case resolve_surface(:google, model) do
      {:ok, provider, raw_model, api} ->
        {:ok, provider, raw_model, api, :native}

      {:error, :no_provider} ->
        if disabled_google_route?(model),
          do: {:error, :no_provider},
          else: resolve_antigravity(model)

      error ->
        error
    end
  end

  defp disabled_google_route?(model) do
    names = [model, ModelAlias.target_for(model)] |> Enum.filter(&is_binary/1) |> Enum.uniq()

    Enum.any?(names, fn name ->
      case AutoModelRoute.get_by_model_and_surface(name, :google) do
        %{enabled: false} -> true
        _ -> false
      end
    end)
  end

  defp resolve_antigravity(model) do
    case resolve_surface(:antigravity, model) do
      {:ok, provider, raw_model, api} ->
        {:ok, provider, raw_model, api, {:translate, :google_to_antigravity}}

      error ->
        error
    end
  end

  defp resolve_surface(surface, model) do
    with {:ok, provider, raw_model} <- ModelResolver.resolve(surface, model),
         %ProviderApi{} = api <-
           Enum.find(ProviderApi.list_for_provider(provider.id), fn api ->
             api.enabled and api.api_surface == surface
           end) do
      {:ok, provider, raw_model, api}
    else
      nil -> {:error, :no_provider}
      error -> error
    end
  end
end
