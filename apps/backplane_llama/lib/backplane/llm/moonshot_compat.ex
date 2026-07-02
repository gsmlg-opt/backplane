defmodule Backplane.LLM.MoonshotCompat do
  @moduledoc """
  Compatibility helpers for Moonshot/Kimi provider requests.
  """

  alias Backplane.LLM.{Provider, ProviderApi}

  @k27_code_models ["kimi-k2.7-code", "kimi-k2.7-code-highspeed"]

  @doc """
  Normalize request fields that are valid in generic clients but rejected by
  specific Moonshot models.
  """
  @spec normalize_request_body(Provider.t(), ProviderApi.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, :invalid_json}
  def normalize_request_body(
        %Provider{} = provider,
        %ProviderApi{api_surface: api_surface} = provider_api,
        model,
        body
      )
      when api_surface in [:openai, :anthropic] and model in @k27_code_models and is_binary(body) do
    if moonshot?(provider, provider_api) do
      drop_thinking(body)
    else
      {:ok, body}
    end
  end

  def normalize_request_body(_provider, _provider_api, _model, body) when is_binary(body) do
    {:ok, body}
  end

  defp moonshot?(%Provider{preset_key: "moonshot-cn"}, _provider_api), do: true
  defp moonshot?(%Provider{name: "moonshot-cn"}, _provider_api), do: true

  defp moonshot?(_provider, %ProviderApi{base_url: base_url}) when is_binary(base_url) do
    case URI.parse(base_url).host do
      host when host in ["api.moonshot.cn", "api.moonshot.ai"] -> true
      _host -> false
    end
  end

  defp moonshot?(_provider, _provider_api), do: false

  defp drop_thinking(body) do
    case Jason.decode(body) do
      {:ok, %{} = request} ->
        sanitized = Map.delete(request, "thinking")

        if sanitized == request do
          {:ok, body}
        else
          {:ok, Jason.encode!(sanitized)}
        end

      {:ok, _request} ->
        {:error, :invalid_json}

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end
end
