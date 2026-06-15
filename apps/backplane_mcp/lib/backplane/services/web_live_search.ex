defmodule Backplane.Services.WebLiveSearch do
  @moduledoc """
  Live web search implementation used by `Backplane.Services.Web`.

  Calls an OpenAI-compatible LLM Responses API surface with the provider-hosted
  `web_search` tool enabled. The model is resolved through Backplane's LLM
  provider registry, so callers can use auto models, aliases, or
  `provider/model` names.
  """

  alias Backplane.LLM.{
    CredentialPlug,
    ModelResolver,
    OpenAICodexCompat,
    Provider,
    ProviderApi,
    RateLimiter
  }

  alias Backplane.Settings
  alias Backplane.Settings.OAuthRefresher

  @default_model "smart"
  @models_setting "services.web_live_search.models"
  @legacy_model_setting "services.web_live_search.model"
  @hosted_web_search_provider_presets ~w(openai openai-codex x-ai)
  @hosted_web_search_hosts ~w(api.openai.com api.x.ai chatgpt.com)
  @default_openai_models ~w(gpt-5.5)
  @default_openai_codex_models ~w(gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex)
  @default_xai_models ~w(grok-4.3)
  @default_tool_type "web_search"
  @default_codex_instructions "Answer the user's query using hosted web search. Include citations when available."

  def supports_hosted_web_search?(%Provider{} = provider, %ProviderApi{} = provider_api) do
    provider.preset_key in @hosted_web_search_provider_presets or
      hosted_web_search_host?(provider_api.base_url)
  end

  def supports_hosted_web_search?(_provider, _provider_api), do: false

  def supports_hosted_web_search_model?(
        %Provider{} = provider,
        %ProviderApi{} = provider_api,
        model
      )
      when is_binary(model) do
    model in default_supported_models(provider, provider_api)
  end

  def supports_hosted_web_search_model?(_provider, _provider_api, _model), do: false

  def default_supported_models(%Provider{} = provider, %ProviderApi{} = provider_api) do
    cond do
      not supports_hosted_web_search?(provider, provider_api) ->
        []

      provider.preset_key == "openai-codex" or base_host(provider_api.base_url) == "chatgpt.com" ->
        configured_model_catalog(
          :web_live_search_openai_codex_models,
          Application.get_env(:backplane, :openai_codex_model_catalog) ||
            @default_openai_codex_models
        )

      provider.preset_key == "x-ai" or base_host(provider_api.base_url) == "api.x.ai" ->
        configured_model_catalog(:web_live_search_xai_models, @default_xai_models)

      provider.preset_key == "openai" or base_host(provider_api.base_url) == "api.openai.com" ->
        configured_model_catalog(:web_live_search_openai_models, @default_openai_models)

      true ->
        []
    end
  end

  def default_supported_models(_provider, _provider_api), do: []

  def handle_live_search(%{"query" => query}) when is_binary(query) do
    with :ok <- ensure_enabled(),
         {:ok, query} <- validate_query(query),
         {:ok, models} <- resolve_models(),
         {:ok, targets} <- resolve_search_targets(models),
         {:ok, responses} <- request_live_searches(targets, query) do
      {:ok, normalize_response(responses, query)}
    else
      {:error, %{code: _, message: _} = error} ->
        {:error, error}

      {:error, :no_provider} ->
        error("no OpenAI-compatible LLM provider is configured for the requested model")

      {:error, retry_after} when is_integer(retry_after) ->
        error("rate limited; retry after #{retry_after} seconds")

      {:error, reason} ->
        error(reason)
    end
  rescue
    exception -> error(Exception.message(exception))
  end

  def handle_live_search(_args), do: error("missing query")

  defp ensure_enabled do
    if Settings.get("services.web.enabled") == true,
      do: :ok,
      else: {:error, "web::live_search is disabled"}
  end

  defp validate_query(query) do
    case String.trim(query) do
      "" -> {:error, "query cannot be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp resolve_models do
    configured_models = configured_models()

    cond do
      configured_models != [] ->
        {:ok, configured_models}

      true ->
        [
          Settings.get(@legacy_model_setting),
          @default_model
        ]
        |> Enum.find_value(&present_string/1)
        |> case do
          nil -> {:error, "live search model is not configured"}
          model -> {:ok, [model]}
        end
    end
  end

  defp resolve_search_targets(models) do
    models
    |> Enum.reduce_while({:ok, []}, fn model, {:ok, targets} ->
      with {:ok, provider, raw_model} <- resolve_llm_model(model),
           {:ok, provider_api} <- fetch_provider_api(provider),
           :ok <- ensure_hosted_web_search_supported(provider, provider_api, raw_model),
           :ok <- RateLimiter.check(provider.id, provider.rpm_limit),
           {:ok, auth_headers} <- CredentialPlug.build_auth_headers(provider, :openai) do
        target = %{
          provider: provider,
          provider_api: provider_api,
          raw_model: raw_model,
          auth_headers: auth_headers
        }

        {:cont, {:ok, [target | targets]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp resolve_llm_model(model) do
    case ModelResolver.resolve(:openai, model) do
      {:error, :no_provider} -> resolve_supported_provider_model(model)
      result -> result
    end
  end

  defp resolve_supported_provider_model(model) do
    with [provider_name, raw_model] <- String.split(model, "/", parts: 2),
         %Provider{} = provider <- find_active_provider(provider_name),
         {:ok, provider_api} <- fetch_provider_api(provider),
         true <- supports_hosted_web_search_model?(provider, provider_api, raw_model) do
      {:ok, provider, raw_model}
    else
      _ -> {:error, :no_provider}
    end
  end

  defp find_active_provider(provider_name) do
    Provider.list()
    |> Enum.find(&(&1.name == provider_name and &1.enabled))
  end

  defp fetch_provider_api(%Provider{} = provider) do
    case Enum.find(
           ProviderApi.list_for_provider(provider.id),
           &(&1.api_surface == :openai and &1.enabled)
         ) do
      %ProviderApi{} = provider_api -> {:ok, provider_api}
      nil -> {:error, :no_provider}
    end
  end

  defp ensure_hosted_web_search_supported(
         %Provider{} = provider,
         %ProviderApi{} = provider_api,
         raw_model
       ) do
    cond do
      not supports_hosted_web_search?(provider, provider_api) ->
        {:error, "#{provider.name} does not support hosted web_search for web::live_search"}

      not supports_hosted_web_search_model?(provider, provider_api, raw_model) ->
        {:error, "#{provider.name}/#{raw_model} does not support hosted web_search"}

      true ->
        :ok
    end
  end

  defp configured_model_catalog(env_key, defaults) do
    env_key
    |> Application.get_env(:backplane, defaults)
    |> normalize_model_list()
  end

  defp request_live_searches(targets, query) do
    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, responses} ->
      with {:ok, response} <-
             request_live_search(
               target.provider,
               target.provider_api,
               target.raw_model,
               query,
               target.auth_headers
             ) do
        item = %{
          provider: target.provider.name,
          model: target.raw_model,
          response: response
        }

        {:cont, {:ok, [item | responses]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, responses} -> {:ok, Enum.reverse(responses)}
      error -> error
    end
  end

  defp request_live_search(
         provider,
         provider_api,
         raw_model,
         query,
         auth_headers
       ) do
    codex_backend? = OpenAICodexCompat.enabled?(provider, provider_api)

    provider_api =
      provider_api
      |> OpenAICodexCompat.effective_api(codex_backend?)

    body =
      %{
        "model" => raw_model,
        "input" => [%{"role" => "user", "content" => query}],
        "tools" => [%{"type" => @default_tool_type}],
        "store" => false
      }
      |> put_if(codex_backend?, "stream", true)
      |> put_present(
        "instructions",
        live_search_instructions(codex_backend?)
      )

    url = responses_url(provider_api)

    options =
      url
      |> OAuthRefresher.request_options()
      |> Keyword.merge(
        url: url,
        headers: [{"accept", accept_header(codex_backend?)} | auth_headers],
        json: body,
        receive_timeout: 120_000
      )
      |> Keyword.merge(Application.get_env(:backplane, :web_live_search_req_options, []))

    case Req.post(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_response_body(body, codex_backend?)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{response_message(body)}"}

      {:error, reason} ->
        {:error, exception_message(reason)}
    end
  end

  defp accept_header(true), do: "application/json, text/event-stream"
  defp accept_header(false), do: "application/json"

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp live_search_instructions(true), do: @default_codex_instructions
  defp live_search_instructions(false), do: nil

  defp parse_response_body(body, true) when is_binary(body), do: parse_sse_response(body)
  defp parse_response_body(body, _codex_backend?), do: {:ok, body}

  defp parse_sse_response(body) do
    body
    |> sse_events()
    |> Enum.reduce({[], nil}, &collect_stream_event/2)
    |> then(fn {deltas, completed_response} ->
      text =
        deltas
        |> Enum.reverse()
        |> Enum.join("")

      completed_response = completed_response || %{}

      response =
        completed_response
        |> put_present("output_text", text)
        |> Map.put_new("usage", %{})

      {:ok, response}
    end)
  end

  defp sse_events(body) do
    body
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.flat_map(&sse_event_data/1)
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.flat_map(fn data ->
      case Jason.decode(data) do
        {:ok, %{} = event} -> [event]
        _ -> []
      end
    end)
  end

  defp sse_event_data(block) do
    block
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.flat_map(fn
      "data:" <> data -> [String.trim_leading(data)]
      _line -> []
    end)
    |> case do
      [] -> []
      data_lines -> [Enum.join(data_lines, "\n")]
    end
  end

  defp collect_stream_event(
         %{"type" => "response.output_text.delta", "delta" => delta},
         {deltas, completed_response}
       )
       when is_binary(delta) do
    {[delta | deltas], completed_response}
  end

  defp collect_stream_event(
         %{"type" => "response.completed", "response" => response},
         {deltas, _}
       )
       when is_map(response) do
    {deltas, response}
  end

  defp collect_stream_event(_event, acc), do: acc

  defp responses_url(%ProviderApi{base_url: base_url}) when is_binary(base_url) do
    base_url = String.trim_trailing(base_url, "/")
    uri = URI.parse(base_url)

    suffix =
      case uri.path do
        nil -> "/v1/responses"
        "" -> "/v1/responses"
        "/" -> "/v1/responses"
        _path -> "/responses"
      end

    base_url <> suffix
  end

  defp normalize_response(responses, query) do
    %{
      "query" => query,
      "results" => Enum.map(responses, &result_item/1),
      "usage" => Enum.map(responses, &usage_item/1)
    }
  end

  defp result_item(%{provider: provider, model: model, response: body}) do
    %{
      "provider" => provider,
      "model" => model,
      "title" => "Live search answer",
      "url" => "",
      "snippet" => output_text(body)
    }
  end

  defp usage_item(%{provider: provider, model: model, response: body}) do
    body
    |> usage()
    |> Map.merge(%{"provider" => provider, "model" => model})
  end

  defp output_text(%{"output_text" => text}) when is_binary(text), do: text

  defp output_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(&output_texts_from_output/1)
    |> Enum.join("\n\n")
  end

  defp output_text(_body), do: ""

  defp output_texts_from_output(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, &output_texts_from_content/1)
  end

  defp output_texts_from_output(_item), do: []

  defp output_texts_from_content(%{"type" => "output_text", "text" => text})
       when is_binary(text),
       do: [text]

  defp output_texts_from_content(%{"text" => text}) when is_binary(text), do: [text]
  defp output_texts_from_content(_content), do: []

  defp usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp usage(_body), do: %{}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map

  defp put_present(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  defp base_host(base_url) when is_binary(base_url) do
    case URI.parse(base_url).host do
      host when is_binary(host) -> String.downcase(host)
      _host -> nil
    end
  end

  defp base_host(_base_url), do: nil

  defp hosted_web_search_host?(base_url) when is_binary(base_url) do
    base_host(base_url) in @hosted_web_search_hosts
  end

  defp hosted_web_search_host?(_base_url), do: false

  defp configured_models do
    @models_setting
    |> Settings.get()
    |> normalize_model_list()
  end

  defp normalize_model_list(values) when is_list(values) do
    values
    |> Enum.map(&present_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_model_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_model_list()
  end

  defp normalize_model_list(_value), do: []

  defp response_message(%{"error" => %{"message" => message}}), do: message
  defp response_message(%{"error" => message}) when is_binary(message), do: message
  defp response_message(body) when is_binary(body), do: body
  defp response_message(body), do: inspect(body)

  defp exception_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp exception_message(reason) when is_binary(reason), do: reason
  defp exception_message(reason), do: inspect(reason)

  defp error(reason),
    do: {:error, %{code: "web_live_search_error", message: to_string(reason)}}
end
