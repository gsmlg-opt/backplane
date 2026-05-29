defmodule Backplane.Services.WebSearch do
  @moduledoc """
  Web search implementation used by `Backplane.Services.Web`.

  Searches the web through a configured provider backend and returns a normalized
  result shape. Called via `handle_search/1`.
  """

  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  @backends ~w(ollama minimax z_ai bigmodel)
  @default_max_results 5
  @max_results 10

  def handle_search(%{"query" => query} = params) when is_binary(query) do
    with :ok <- ensure_enabled(),
         {:ok, query} <- validate_query(query),
         {:ok, backend} <- resolve_backend(params),
         {:ok, credential_name} <- resolve_credential(params, backend),
         {:ok, api_key} <- fetch_credential(credential_name),
         {:ok, response} <- request_search(backend, query, params, api_key) do
      {:ok, normalize_response(backend, query, response, max_results(params))}
    else
      {:error, %{code: _, message: _} = error} -> {:error, error}
      {:error, reason} -> error(reason)
    end
  rescue
    exception -> error(Exception.message(exception))
  end

  def handle_search(_args), do: error("missing query")

  defp ensure_enabled do
    if Settings.get("services.web.enabled") == true, do: :ok, else: {:error, "web::search is disabled"}
  end

  defp validate_query(query) do
    case String.trim(query) do
      "" -> {:error, "query cannot be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp resolve_backend(params) do
    backend = params["backend"] || Settings.get("services.web_search.default_backend") || "ollama"

    case normalize_backend(backend) do
      backend when backend in @backends -> {:ok, backend}
      _ -> {:error, "unsupported web search backend: #{backend}"}
    end
  end

  defp normalize_backend(backend) when is_binary(backend) do
    backend
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "zai" -> "z_ai"
      "z_ai" -> "z_ai"
      "bigmodel_cn" -> "bigmodel"
      other -> other
    end
  end

  defp normalize_backend(other), do: other

  defp resolve_credential(params, backend) do
    credential_name =
      params["credential"] ||
        Settings.get("services.web_search.#{backend}.credential")

    if present?(credential_name) do
      {:ok, credential_name}
    else
      {:error, "#{backend} web search credential is not configured"}
    end
  end

  defp fetch_credential(credential_name) do
    case Credentials.fetch(credential_name) do
      {:ok, api_key} when is_binary(api_key) and api_key != "" ->
        {:ok, api_key}

      {:ok, _} ->
        {:error, "credential #{credential_name} is empty"}

      {:error, _reason} ->
        {:error, "credential #{credential_name} is unavailable"}
    end
  end

  defp request_search(backend, query, params, api_key) do
    %{base_url: base_url, path: path} = backend_config(backend)

    options =
      [
        url: base_url <> path,
        headers: [
          {"authorization", "Bearer " <> api_key},
          {"accept", "application/json"}
        ],
        json: request_body(backend, query, params),
        receive_timeout: 30_000
      ]
      |> Keyword.merge(Application.get_env(:backplane, :web_search_req_options, []))

    case Req.post(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{response_message(body)}"}

      {:error, reason} ->
        {:error, exception_message(reason)}
    end
  end

  defp backend_config("ollama") do
    %{
      base_url: setting("services.web_search.ollama.base_url", "https://ollama.com"),
      path: "/api/web_search"
    }
  end

  defp backend_config("minimax") do
    %{
      base_url: setting("services.web_search.minimax.base_url", "https://api.minimax.io"),
      path: "/v1/coding_plan/search"
    }
  end

  defp backend_config("z_ai") do
    %{
      base_url: setting("services.web_search.z_ai.base_url", "https://api.z.ai"),
      path: "/api/paas/v4/web_search"
    }
  end

  defp backend_config("bigmodel") do
    %{
      base_url: setting("services.web_search.bigmodel.base_url", "https://open.bigmodel.cn"),
      path: "/api/paas/v4/web_search"
    }
  end

  defp request_body("ollama", query, params) do
    %{"query" => query, "max_results" => max_results(params)}
  end

  defp request_body("minimax", query, _params), do: %{"q" => query}

  defp request_body(backend, query, params) when backend in ["z_ai", "bigmodel"] do
    %{
      "search_engine" => params["search_engine"] || default_search_engine(backend),
      "search_query" => query,
      "count" => max_results(params)
    }
  end

  defp default_search_engine("z_ai"), do: "search_std"
  defp default_search_engine("bigmodel"), do: "search_std"

  defp normalize_response(backend, query, body, limit) do
    %{
      "backend" => backend,
      "query" => query,
      "results" => body |> result_items() |> Enum.take(limit) |> Enum.map(&normalize_result/1),
      "related_searches" => related_searches(body)
    }
  end

  defp result_items(body) when is_map(body) do
    cond do
      is_list(body["results"]) ->
        body["results"]

      is_list(body["organic_results"]) ->
        body["organic_results"]

      is_list(body["search_result"]) ->
        body["search_result"]

      is_list(get_in(body, ["data", "results"])) ->
        get_in(body, ["data", "results"])

      is_list(get_in(body, ["data", "organic_results"])) ->
        get_in(body, ["data", "organic_results"])

      is_list(get_in(body, ["data", "search_result"])) ->
        get_in(body, ["data", "search_result"])

      true ->
        []
    end
  end

  defp result_items(_body), do: []

  defp normalize_result(item) when is_map(item) do
    %{
      "title" => first_present(item, ~w(title name)) || "",
      "url" => first_present(item, ~w(url link source_url sourceUrl)) || "",
      "snippet" => first_present(item, ~w(snippet content description text)) || ""
    }
    |> maybe_put("published_at", first_present(item, ~w(published_at publishedAt date)))
  end

  defp normalize_result(item) when is_binary(item) do
    %{"title" => item, "url" => "", "snippet" => item}
  end

  defp normalize_result(item) do
    text = inspect(item)
    %{"title" => text, "url" => "", "snippet" => text}
  end

  defp related_searches(body) when is_map(body) do
    related =
      cond do
        is_list(body["related_searches"]) ->
          body["related_searches"]

        is_list(get_in(body, ["data", "related_searches"])) ->
          get_in(body, ["data", "related_searches"])

        is_list(body["suggestions"]) ->
          body["suggestions"]

        true ->
          []
      end

    Enum.flat_map(related, fn
      value when is_binary(value) -> [value]
      %{"query" => value} when is_binary(value) -> [value]
      %{"text" => value} when is_binary(value) -> [value]
      _ -> []
    end)
  end

  defp related_searches(_body), do: []

  defp max_results(%{"max_results" => value}) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_results)
  end

  defp max_results(%{"max_results" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> max_results(%{"max_results" => parsed})
      _ -> @default_max_results
    end
  end

  defp max_results(_params), do: @default_max_results

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      value = map[key]
      if present?(value), do: value
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp setting(key, fallback) do
    case Settings.get(key) do
      value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
      _ -> fallback
    end
  end

  defp response_message(body) when is_binary(body), do: body
  defp response_message(body), do: inspect(body)

  defp exception_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp exception_message(reason) when is_binary(reason), do: reason
  defp exception_message(reason), do: inspect(reason)

  defp error(reason), do: {:error, %{code: "web_search_error", message: to_string(reason)}}
end
