defmodule Backplane.LLM.Google.Catalog do
  @moduledoc false

  alias Backplane.LLM.{ModelAlias, ProviderModelSurface}
  alias Backplane.LLM.Google.{RequestTarget, Resolution}

  @default_page_size 50
  @max_page_size 1_000

  def list(params \\ %{}) do
    with {:ok, page_size} <- page_size(params["pageSize"]),
         {:ok, offset} <- page_offset(params["pageToken"]) do
      models = resolvable_entries()
      page = Enum.slice(models, offset, page_size)
      next_offset = offset + length(page)

      response = %{"models" => Enum.map(page, &elem(&1, 1))}

      if next_offset < length(models) do
        Map.put(response, "nextPageToken", encode_offset(next_offset))
      else
        response
      end
      |> then(&{:ok, &1})
    end
  end

  def get(alias_name) when is_binary(alias_name) do
    case Enum.find(resolvable_entries(), &(elem(&1, 0) == alias_name)) do
      {_alias, descriptor} -> {:ok, descriptor}
      nil -> {:error, :not_found}
    end
  end

  defp resolvable_entries do
    surfaces =
      ProviderModelSurface.list_enabled(:google) ++
        ProviderModelSurface.list_enabled(:antigravity)

    aliases =
      surfaces
      |> Enum.map(& &1.provider_model.model)
      |> Kernel.++(Enum.map(ModelAlias.list(), & &1.alias))
      |> Enum.uniq()

    aliases
    |> Enum.filter(&RequestTarget.valid_model?/1)
    |> Enum.flat_map(fn alias_name ->
      with {:ok, provider, raw_model, api, _route} <- Resolution.resolve(alias_name),
           {:ok, raw_model} <- RequestTarget.normalize_model(raw_model),
           surface when not is_nil(surface) <-
             Enum.find(surfaces, fn surface ->
               surface.provider_model.provider_id == provider.id and
                 surface.provider_model.model == raw_model and surface.provider_api_id == api.id
             end) do
        [{alias_name, descriptor(surface, alias_name)}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp descriptor(surface, alias_name) do
    model = surface.provider_model
    metadata = Map.merge(model.metadata || %{}, surface.metadata || %{})
    resource_name = normalize_resource_name(metadata["name"] || model.model)

    %{
      "name" => "models/#{alias_name}",
      "displayName" => metadata["displayName"] || model.display_name || model.model,
      "description" => metadata["description"],
      "inputTokenLimit" => metadata["inputTokenLimit"],
      "outputTokenLimit" => metadata["outputTokenLimit"],
      "supportedGenerationMethods" => metadata["supportedGenerationMethods"],
      "backplaneProvenance" => %{
        "source" => metadata["provenance"] || Atom.to_string(model.source),
        "providerApiId" => surface.provider_api_id,
        "upstreamName" => resource_name
      }
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_resource_name("models/" <> model), do: "models/" <> model
  defp normalize_resource_name(model), do: "models/" <> model

  defp page_size(nil), do: {:ok, @default_page_size}

  defp page_size(value) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size > 0 -> {:ok, min(size, @max_page_size)}
      _ -> {:error, :invalid_page_size}
    end
  end

  defp page_size(_value), do: {:error, :invalid_page_size}
  defp page_offset(nil), do: {:ok, 0}
  defp page_offset(""), do: {:ok, 0}

  defp page_offset(token) when is_binary(token) do
    with {:ok, encoded} <- Base.url_decode64(token, padding: false),
         {offset, ""} when offset >= 0 <- Integer.parse(encoded) do
      {:ok, offset}
    else
      _ -> {:error, :invalid_page_token}
    end
  end

  defp page_offset(_token), do: {:error, :invalid_page_token}

  defp encode_offset(offset),
    do: offset |> Integer.to_string() |> Base.url_encode64(padding: false)
end
