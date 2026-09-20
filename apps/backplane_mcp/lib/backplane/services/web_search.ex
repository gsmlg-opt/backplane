defmodule Backplane.Services.WebSearch do
  @moduledoc """
  Web search implementation used by `Backplane.Services.Web`.

  Exa and Tavily expose their native search controls through a strict, normalized
  contract. Ollama and MiniMax remain explicitly enabled basic-search backups.
  """

  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  @backends ~w(exa tavily ollama minimax)
  @legacy_backends ~w(ollama minimax)
  @top_level_keys ~w(query backend credential max_results include_domains exclude_domains include_content max_content_chars exa tavily)
  @exa_keys ~w(type category start_published_date end_published_date summary summary_query max_age_hours)
  @tavily_keys ~w(search_depth topic time_range start_date end_date include_answer chunks_per_source include_published_date filter_by_published_date)
  @exa_types ~w(auto instant fast deep-lite deep deep-reasoning)
  @exa_categories [
    "company",
    "publication",
    "news",
    "personal site",
    "financial report",
    "people"
  ]
  @tavily_depths ~w(basic advanced fast ultra-fast)
  @tavily_topics ~w(general news finance)
  @tavily_time_ranges ~w(day week month year)
  @default_max_results 5
  @default_max_content_chars 5_000
  @snippet_chars 1_500

  def handle_search(%{"query" => query} = params) when is_binary(query) do
    with :ok <- ensure_enabled(),
         {:ok, query} <- validate_query(query),
         {:ok, backend} <- resolve_backend(params),
         {:ok, options} <- validate_options(params, backend),
         :ok <- ensure_backend_enabled(backend),
         {:ok, credential_name} <- resolve_credential(params, backend),
         {:ok, api_key} <- fetch_credential(credential_name),
         {:ok, response} <- request_search(backend, query, options, api_key) do
      {:ok, normalize_response(backend, query, response, options)}
    else
      {:error, reason} -> error(reason)
    end
  rescue
    _exception -> error("web search failed")
  end

  def handle_search(_args), do: error("missing query")

  defp ensure_enabled do
    if Settings.get("services.web.enabled") == true,
      do: :ok,
      else: {:error, "web::search is disabled"}
  end

  defp validate_query(query) do
    case String.trim(query) do
      "" -> {:error, "query cannot be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp resolve_backend(params) do
    backend =
      case Map.fetch(params, "backend") do
        {:ok, value} -> value
        :error -> Settings.get("services.web_search.default_backend") || "exa"
      end

    case normalize_backend(backend) do
      backend when backend in @backends -> {:ok, backend}
      _ -> {:error, "unsupported web search backend"}
    end
  end

  defp normalize_backend(backend) when is_binary(backend) do
    backend |> String.downcase() |> String.replace("-", "_")
  end

  defp normalize_backend(other), do: other

  defp validate_options(params, backend) do
    with :ok <- reject_unknown_keys(params, @top_level_keys, "web search"),
         :ok <- validate_credential_name(params),
         {:ok, max_results} <- validate_max_results(params, backend),
         {:ok, include_domains} <- validate_domains(params, "include_domains", backend),
         {:ok, exclude_domains} <- validate_domains(params, "exclude_domains", backend),
         {:ok, include_content} <- optional_boolean(params, "include_content", false),
         {:ok, max_content_chars} <-
           optional_integer(
             params,
             "max_content_chars",
             1,
             10_000,
             @default_max_content_chars
           ),
         {:ok, exa} <- validate_provider_map(params, "exa", @exa_keys),
         {:ok, tavily} <- validate_provider_map(params, "tavily", @tavily_keys),
         :ok <- validate_provider_ownership(backend, exa, tavily),
         :ok <-
           validate_legacy_features(
             backend,
             include_domains,
             exclude_domains,
             include_content
           ),
         {:ok, exa} <- validate_exa_options(exa, exclude_domains),
         {:ok, tavily} <- validate_tavily_options(tavily) do
      {:ok,
       %{
         max_results: max_results,
         include_domains: include_domains,
         exclude_domains: exclude_domains,
         include_content: include_content,
         max_content_chars: max_content_chars,
         exa: exa,
         tavily: tavily
       }}
    end
  end

  defp validate_credential_name(params) do
    case Map.fetch(params, "credential") do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, "credential must be a nonblank string"},
          else: :ok

      {:ok, _value} ->
        {:error, "credential must be a nonblank string"}
    end
  end

  defp reject_unknown_keys(map, allowed, label) do
    case Map.keys(map) |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _] when is_binary(key) -> {:error, "unknown #{label} option: #{key}"}
      [_key | _] -> {:error, "unknown #{label} option"}
    end
  end

  defp validate_max_results(params, backend) do
    value = Map.get(params, "max_results", @default_max_results)
    maximum = backend_max_results(backend)

    if is_integer(value) and value >= 1 and value <= maximum,
      do: {:ok, value},
      else: {:error, "max_results must be between 1 and #{maximum} for #{backend}"}
  end

  defp backend_max_results("exa"), do: 100
  defp backend_max_results("tavily"), do: 20
  defp backend_max_results(backend) when backend in @legacy_backends, do: 10

  defp validate_domains(params, key, backend) do
    maximum =
      cond do
        backend == "exa" -> 1_200
        backend == "tavily" -> domain_limit(key)
        true -> 1_200
      end

    value = Map.get(params, key, [])

    cond do
      not is_list(value) ->
        {:error, "#{key} must be an array of nonblank strings"}

      length(value) > maximum ->
        {:error, "#{key} supports at most #{maximum} entries for #{backend}"}

      Enum.any?(value, &(not is_binary(&1) or String.trim(&1) == "")) ->
        {:error, "#{key} must contain nonblank strings"}

      true ->
        {:ok, Enum.map(value, &String.trim/1)}
    end
  end

  defp domain_limit("include_domains"), do: 300
  defp domain_limit("exclude_domains"), do: 150

  defp optional_boolean(params, key, default) do
    value = Map.get(params, key, default)
    if is_boolean(value), do: {:ok, value}, else: {:error, "#{key} must be a boolean"}
  end

  defp optional_integer(params, key, minimum, maximum, default) do
    value = Map.get(params, key, default)

    if is_integer(value) and value >= minimum and value <= maximum,
      do: {:ok, value},
      else: {:error, "#{key} must be an integer between #{minimum} and #{maximum}"}
  end

  defp validate_provider_map(params, key, allowed) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, %{}}

      {:ok, value} when is_map(value) ->
        case reject_unknown_keys(value, allowed, key) do
          :ok -> {:ok, value}
          error -> error
        end

      {:ok, _value} ->
        {:error, "#{key} must be an object"}
    end
  end

  defp validate_provider_ownership("exa", _exa, tavily) when map_size(tavily) > 0,
    do: {:error, "tavily options are only supported by the tavily backend"}

  defp validate_provider_ownership("tavily", exa, _tavily) when map_size(exa) > 0,
    do: {:error, "exa options are only supported by the exa backend"}

  defp validate_provider_ownership(backend, exa, _tavily)
       when backend in @legacy_backends and map_size(exa) > 0,
       do: {:error, "exa options are only supported by the exa backend"}

  defp validate_provider_ownership(backend, _exa, tavily)
       when backend in @legacy_backends and map_size(tavily) > 0,
       do: {:error, "tavily options are only supported by the tavily backend"}

  defp validate_provider_ownership(_backend, _exa, _tavily), do: :ok

  defp validate_legacy_features(backend, _include, _exclude, true)
       when backend in @legacy_backends,
       do: {:error, "include_content is not supported by #{backend}"}

  defp validate_legacy_features(backend, include, exclude, _content)
       when backend in @legacy_backends and (include != [] or exclude != []),
       do: {:error, "domain filters are not supported by #{backend}"}

  defp validate_legacy_features(_backend, _include, _exclude, _content), do: :ok

  defp validate_exa_options(options, exclude_domains) do
    with {:ok, type} <- enum_option(options, "type", @exa_types, "auto", "exa.type"),
         {:ok, category} <- optional_enum(options, "category", @exa_categories, "exa.category"),
         {:ok, start_date} <-
           optional_datetime(
             options,
             "start_published_date",
             "exa.start_published_date"
           ),
         {:ok, end_date} <-
           optional_datetime(options, "end_published_date", "exa.end_published_date"),
         :ok <- validate_datetime_order(start_date, end_date),
         {:ok, summary} <- boolean_option(options, "summary", false, "exa.summary"),
         {:ok, summary_query} <-
           optional_nonblank(options, "summary_query", "exa.summary_query"),
         :ok <- require_summary(summary_query, summary),
         {:ok, max_age_hours} <-
           optional_ranged_integer(
             options,
             "max_age_hours",
             -1,
             720,
             "exa.max_age_hours"
           ),
         :ok <- validate_exa_category(category, start_date, end_date, exclude_domains) do
      {:ok,
       %{
         type: type,
         category: category,
         start_published_date: datetime_string(start_date),
         end_published_date: datetime_string(end_date),
         summary: summary,
         summary_query: summary_query,
         max_age_hours: max_age_hours
       }}
    end
  end

  defp validate_tavily_options(options) do
    with {:ok, depth} <-
           enum_option(
             options,
             "search_depth",
             @tavily_depths,
             "basic",
             "tavily.search_depth"
           ),
         {:ok, topic} <-
           enum_option(options, "topic", @tavily_topics, "general", "tavily.topic"),
         {:ok, time_range} <-
           optional_enum(options, "time_range", @tavily_time_ranges, "tavily.time_range"),
         {:ok, start_date} <- optional_date(options, "start_date", "tavily.start_date"),
         {:ok, end_date} <- optional_date(options, "end_date", "tavily.end_date"),
         :ok <- validate_date_order(start_date, end_date),
         :ok <- reject_mixed_tavily_dates(time_range, start_date, end_date),
         {:ok, include_answer} <- include_answer_option(options),
         {:ok, chunks} <-
           optional_ranged_integer(
             options,
             "chunks_per_source",
             1,
             3,
             "tavily.chunks_per_source"
           ),
         :ok <- validate_chunks(depth, chunks),
         {:ok, include_published_date} <-
           boolean_option(
             options,
             "include_published_date",
             false,
             "tavily.include_published_date"
           ),
         {:ok, filter_by_published_date} <-
           boolean_option(
             options,
             "filter_by_published_date",
             false,
             "tavily.filter_by_published_date"
           ) do
      {:ok,
       %{
         search_depth: depth,
         topic: topic,
         time_range: time_range,
         start_date: date_string(start_date),
         end_date: date_string(end_date),
         include_answer: include_answer,
         chunks_per_source: chunks,
         include_published_date: include_published_date,
         filter_by_published_date: filter_by_published_date
       }}
    end
  end

  defp enum_option(map, key, values, default, label) do
    value = Map.get(map, key, default)
    if value in values, do: {:ok, value}, else: {:error, "#{label} is invalid"}
  end

  defp optional_enum(map, key, values, label) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        if value in values, do: {:ok, value}, else: {:error, "#{label} is invalid"}
    end
  end

  defp boolean_option(map, key, default, label) do
    value = Map.get(map, key, default)
    if is_boolean(value), do: {:ok, value}, else: {:error, "#{label} must be a boolean"}
  end

  defp optional_nonblank(map, key, label) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, "#{label} cannot be blank"},
          else: {:ok, String.trim(value)}

      {:ok, _value} ->
        {:error, "#{label} must be a string"}
    end
  end

  defp optional_ranged_integer(map, key, minimum, maximum, label) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_integer(value) and value >= minimum and value <= maximum ->
        {:ok, value}

      {:ok, _value} ->
        {:error, "#{label} must be an integer between #{minimum} and #{maximum}"}
    end
  end

  defp optional_datetime(map, key, label) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, {datetime, value}}
          _ -> {:error, "#{label} must be an ISO8601 datetime"}
        end

      {:ok, _value} ->
        {:error, "#{label} must be an ISO8601 datetime"}
    end
  end

  defp optional_date(map, key, label) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, {date, value}}
          _ -> {:error, "#{label} must be a YYYY-MM-DD date"}
        end

      {:ok, _value} ->
        {:error, "#{label} must be a YYYY-MM-DD date"}
    end
  end

  defp validate_datetime_order({start_date, _}, {end_date, _}) do
    if DateTime.compare(start_date, end_date) == :gt,
      do: {:error, "exa.start_published_date must not be after exa.end_published_date"},
      else: :ok
  end

  defp validate_datetime_order(_start_date, _end_date), do: :ok

  defp validate_date_order({start_date, _}, {end_date, _}) do
    if Date.compare(start_date, end_date) == :gt,
      do: {:error, "tavily.start_date must not be after tavily.end_date"},
      else: :ok
  end

  defp validate_date_order(_start_date, _end_date), do: :ok

  defp require_summary(nil, _summary), do: :ok
  defp require_summary(_query, true), do: :ok
  defp require_summary(_query, false), do: {:error, "exa.summary_query requires exa.summary=true"}

  defp validate_exa_category(category, start_date, end_date, exclude_domains)
       when category in ["company", "people"] do
    cond do
      start_date != nil or end_date != nil ->
        {:error, "exa category #{category} does not support published date filters"}

      exclude_domains != [] ->
        {:error, "exa category #{category} does not support exclude_domains"}

      true ->
        :ok
    end
  end

  defp validate_exa_category(_category, _start_date, _end_date, _exclude_domains), do: :ok

  defp reject_mixed_tavily_dates(nil, _start_date, _end_date), do: :ok
  defp reject_mixed_tavily_dates(_range, nil, nil), do: :ok

  defp reject_mixed_tavily_dates(_range, _start_date, _end_date),
    do: {:error, "tavily.time_range cannot be combined with explicit dates"}

  defp include_answer_option(map) do
    value = Map.get(map, "include_answer", false)

    if value in [true, false, "basic", "advanced"],
      do: {:ok, value},
      else: {:error, "tavily.include_answer is invalid"}
  end

  defp validate_chunks("ultra-fast", chunks) when not is_nil(chunks),
    do: {:error, "tavily.chunks_per_source is not supported with ultra-fast search_depth"}

  defp validate_chunks(_depth, _chunks), do: :ok

  defp datetime_string(nil), do: nil
  defp datetime_string({_datetime, original}), do: original
  defp date_string(nil), do: nil
  defp date_string({_date, original}), do: original

  defp ensure_backend_enabled(backend) do
    default = backend in ~w(exa tavily)

    case Settings.get("services.web_search.#{backend}.enabled") do
      nil when default -> :ok
      true -> :ok
      _ -> {:error, "#{backend} web search backend is disabled"}
    end
  end

  defp resolve_credential(params, backend) do
    credential_name =
      params["credential"] || Settings.get("services.web_search.#{backend}.credential")

    if present?(credential_name),
      do: {:ok, credential_name},
      else: {:error, "#{backend} web search credential is not configured"}
  end

  defp fetch_credential(credential_name) do
    case Credentials.fetch(credential_name) do
      {:ok, api_key} when is_binary(api_key) and api_key != "" ->
        {:ok, api_key}

      {:ok, _} ->
        {:error, "configured web search credential is empty"}

      {:error, _reason} ->
        {:error, "configured web search credential is unavailable"}
    end
  end

  defp request_search(backend, query, options, api_key) do
    %{base_url: base_url, path: path} = backend_config(backend)

    request_options =
      [
        url: base_url <> path,
        headers: request_headers(backend, api_key),
        json: request_body(backend, query, options),
        receive_timeout: receive_timeout(backend, options)
      ]
      |> Keyword.merge(Application.get_env(:backplane, :web_search_req_options, []))

    case Req.post(request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body = decode_response_body(body)

        case provider_error(backend, body) do
          nil -> validate_response(backend, body)
          _message -> {:error, "#{backend_label(backend)} API request failed"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status} from #{backend_label(backend)}"}

      {:error, _reason} ->
        {:error, "#{backend_label(backend)} request failed"}
    end
  end

  defp receive_timeout("exa", %{exa: %{type: type}})
       when type in ~w(deep-lite deep deep-reasoning),
       do: 120_000

  defp receive_timeout(_backend, _options), do: 30_000

  defp backend_config("exa"),
    do: %{
      base_url: setting("services.web_search.exa.base_url", "https://api.exa.ai"),
      path: "/search"
    }

  defp backend_config("tavily"),
    do: %{
      base_url: setting("services.web_search.tavily.base_url", "https://api.tavily.com"),
      path: "/search"
    }

  defp backend_config("ollama"),
    do: %{
      base_url: setting("services.web_search.ollama.base_url", "https://ollama.com"),
      path: "/api/web_search"
    }

  defp backend_config("minimax"),
    do: %{
      base_url: setting("services.web_search.minimax.base_url", "https://api.minimaxi.com"),
      path: "/v1/coding_plan/search"
    }

  defp request_body("exa", query, options) do
    exa = options.exa

    %{
      "query" => query,
      "numResults" => options.max_results,
      "type" => exa.type,
      "contents" => exa_contents(options)
    }
    |> maybe_put_nonempty("includeDomains", options.include_domains)
    |> maybe_put_nonempty("excludeDomains", options.exclude_domains)
    |> maybe_put("category", exa.category)
    |> maybe_put("startPublishedDate", exa.start_published_date)
    |> maybe_put("endPublishedDate", exa.end_published_date)
  end

  defp request_body("tavily", query, options) do
    tavily = options.tavily

    %{
      "query" => query,
      "max_results" => options.max_results,
      "include_domains" => options.include_domains,
      "exclude_domains" => options.exclude_domains,
      "include_raw_content" => if(options.include_content, do: "markdown", else: false),
      "search_depth" => tavily.search_depth,
      "topic" => tavily.topic,
      "include_answer" => tavily.include_answer,
      "include_published_date" => tavily.include_published_date,
      "filter_by_published_date" => tavily.filter_by_published_date,
      "include_usage" => true
    }
    |> maybe_put("time_range", tavily.time_range)
    |> maybe_put("start_date", tavily.start_date)
    |> maybe_put("end_date", tavily.end_date)
    |> maybe_put("chunks_per_source", tavily.chunks_per_source)
  end

  defp request_body("ollama", query, options),
    do: %{"query" => query, "max_results" => options.max_results}

  defp request_body("minimax", query, _options), do: %{"q" => query}

  defp exa_contents(options) do
    %{
      "highlights" => %{"maxCharacters" => @snippet_chars},
      "text" =>
        if(options.include_content,
          do: %{"maxCharacters" => options.max_content_chars},
          else: false
        )
    }
    |> maybe_put("summary", exa_summary(options.exa))
    |> maybe_put("maxAgeHours", options.exa.max_age_hours)
  end

  defp exa_summary(%{summary: false}), do: nil
  defp exa_summary(%{summary_query: nil}), do: %{}
  defp exa_summary(%{summary_query: query}), do: %{"query" => query}

  defp request_headers("exa", api_key),
    do: [{"x-api-key", api_key}, {"accept", "application/json"}]

  defp request_headers("minimax", api_key),
    do: request_headers(nil, api_key) ++ [{"MM-API-Source", "Minimax-MCP"}]

  defp request_headers(_backend, api_key),
    do: [{"authorization", "Bearer " <> api_key}, {"accept", "application/json"}]

  defp decode_response_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_response_body(body), do: body

  defp provider_error("minimax", %{"base_resp" => %{"status_code" => code}})
       when code not in [0, "0", nil],
       do: "MiniMax API error"

  defp provider_error("tavily", %{"error" => _error}), do: "Tavily API error"
  defp provider_error("exa", %{"error" => _error}), do: "Exa API error"
  defp provider_error(_backend, _body), do: nil

  defp validate_response(backend, %{"results" => results} = body)
       when backend in ~w(exa tavily) and is_list(results) do
    if valid_modern_response?(backend, body, results),
      do: {:ok, body},
      else: {:error, "#{backend_label(backend)} returned a malformed response"}
  end

  defp validate_response(backend, body) when backend in @legacy_backends and is_map(body) do
    if has_result_list?(body),
      do: {:ok, body},
      else: {:error, "#{backend_label(backend)} returned a malformed response"}
  end

  defp validate_response(backend, _body),
    do: {:error, "#{backend_label(backend)} returned a malformed response"}

  defp valid_modern_response?(backend, body, results) do
    Enum.all?(results, &valid_modern_result?(backend, &1)) and valid_metadata?(backend, body)
  end

  defp valid_modern_result?(backend, %{"title" => title, "url" => url} = item)
       when is_binary(title) and is_binary(url) do
    present?(title) and present?(url) and
      optional_string_fields?(item, modern_string_fields(backend)) and
      optional_number?(item["score"]) and optional_highlights?(item["highlights"])
  end

  defp valid_modern_result?(_backend, _item), do: false

  defp modern_string_fields("exa"),
    do: ~w(text description summary author publishedDate)

  defp modern_string_fields("tavily"),
    do: ~w(content raw_content description summary author published_date publishedDate)

  defp optional_string_fields?(item, keys),
    do: Enum.all?(keys, &(is_nil(item[&1]) or is_binary(item[&1])))

  defp optional_number?(nil), do: true
  defp optional_number?(value), do: is_number(value)
  defp optional_highlights?(nil), do: true
  defp optional_highlights?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp optional_highlights?(_value), do: false

  defp valid_metadata?("exa", body) do
    optional_string_fields?(body, ~w(requestId resolvedSearchType)) and
      optional_number?(body["searchTime"]) and valid_cost_dollars?(body["costDollars"])
  end

  defp valid_metadata?("tavily", body) do
    optional_string_fields?(body, ~w(request_id answer)) and
      optional_number?(body["response_time"]) and valid_usage?(body["usage"])
  end

  defp valid_cost_dollars?(nil), do: true

  defp valid_cost_dollars?(value) when is_map(value) do
    optional_number?(value["total"]) and optional_number?(value["summary"]) and
      valid_cost_section?(value["search"], ~w(neural)) and
      valid_cost_section?(value["contents"], ~w(text highlights summary))
  end

  defp valid_cost_dollars?(_value), do: false

  defp valid_cost_section?(nil, _keys), do: true

  defp valid_cost_section?(value, keys) when is_map(value) do
    Enum.all?(Map.keys(value), &(&1 in keys)) and Enum.all?(Map.values(value), &is_number/1)
  end

  defp valid_cost_section?(_value, _keys), do: false

  defp valid_usage?(nil), do: true

  defp valid_usage?(%{"credits" => credits} = usage),
    do: is_number(credits) and Enum.all?(Map.keys(usage), &(&1 == "credits"))

  defp valid_usage?(_value), do: false

  defp has_result_list?(body), do: Enum.any?(result_lists(body), &is_list/1)

  defp result_lists(body) do
    [
      body["results"],
      body["organic_results"],
      body["organic"],
      body["search_result"],
      get_in(body, ["data", "results"]),
      get_in(body, ["data", "organic_results"]),
      get_in(body, ["data", "organic"]),
      get_in(body, ["data", "search_result"])
    ]
  end

  defp normalize_response(backend, query, body, options) do
    %{
      "backend" => backend,
      "query" => query,
      "results" =>
        body
        |> result_items()
        |> Enum.take(options.max_results)
        |> Enum.map(&normalize_result(backend, &1, options)),
      "related_searches" => related_searches(body)
    }
    |> add_response_metadata(backend, body, options)
  end

  defp add_response_metadata(result, "exa", body, _options) do
    result
    |> maybe_put("request_id", body["requestId"])
    |> maybe_put("resolved_search_type", body["resolvedSearchType"])
    |> maybe_put("search_time_ms", body["searchTime"])
    |> maybe_put("cost_dollars", normalize_cost_dollars(body["costDollars"]))
  end

  defp add_response_metadata(result, "tavily", body, options) do
    result
    |> maybe_put("request_id", body["request_id"])
    |> maybe_put("response_time_seconds", body["response_time"])
    |> maybe_put("usage", normalize_usage(body["usage"]))
    |> maybe_put(
      "answer",
      if(options.tavily.include_answer != false, do: body["answer"])
    )
  end

  defp add_response_metadata(result, _backend, _body, _options), do: result

  defp result_items(body) when is_map(body), do: Enum.find(result_lists(body), [], &is_list/1)
  defp result_items(_body), do: []

  defp normalize_result(backend, item, options) when is_map(item) do
    {snippet, snippet_truncated} = truncate(snippet_for(backend, item), @snippet_chars)

    %{
      "title" => first_present(item, ~w(title name)) || "",
      "url" => first_present(item, ~w(url link source_url sourceUrl)) || "",
      "snippet" => snippet
    }
    |> maybe_put("snippet_truncated", if(snippet_truncated, do: true))
    |> maybe_put(
      "published_at",
      first_present(item, ~w(published_at publishedAt published_date publishedDate date))
    )
    |> maybe_put("score", numeric_value(item["score"]))
    |> maybe_put("author", string_value(item["author"]))
    |> maybe_put("highlights", highlights_value(item["highlights"]))
    |> maybe_put("summary", string_value(item["summary"]))
    |> add_content(backend, item, options)
  end

  defp normalize_result(_backend, item, _options) when is_binary(item) do
    {snippet, truncated} = truncate(item, @snippet_chars)

    %{"title" => item, "url" => "", "snippet" => snippet}
    |> maybe_put("snippet_truncated", if(truncated, do: true))
  end

  defp normalize_result(_backend, _item, _options),
    do: %{"title" => "", "url" => "", "snippet" => ""}

  defp snippet_for("exa", item) do
    highlights = highlights_value(item["highlights"])

    if highlights in [nil, []],
      do: first_present(item, ~w(summary description text)) || "",
      else: Enum.join(highlights, "\n")
  end

  defp snippet_for(_backend, item),
    do: first_present(item, ~w(snippet content description text)) || ""

  defp add_content(result, _backend, _item, %{include_content: false}), do: result

  defp add_content(result, backend, item, options) do
    field = if backend == "tavily", do: "raw_content", else: "text"

    case string_value(item[field]) do
      nil ->
        result

      content ->
        {content, truncated} = truncate(content, options.max_content_chars)

        result
        |> Map.put("content", content)
        |> maybe_put("content_truncated", if(truncated, do: true))
    end
  end

  defp truncate(value, maximum) when is_binary(value) do
    if String.length(value) > maximum,
      do: {String.slice(value, 0, maximum), true},
      else: {value, false}
  end

  defp truncate(_value, _maximum), do: {"", false}

  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_value), do: nil
  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: nil
  defp highlights_value(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp highlights_value(_value), do: nil

  defp normalize_cost_dollars(nil), do: nil

  defp normalize_cost_dollars(costs) do
    %{}
    |> maybe_put("total", numeric_value(costs["total"]))
    |> maybe_put("summary", numeric_value(costs["summary"]))
    |> maybe_put("search", normalize_cost_section(costs["search"], ~w(neural)))
    |> maybe_put(
      "contents",
      normalize_cost_section(costs["contents"], ~w(text highlights summary))
    )
  end

  defp normalize_cost_section(nil, _keys), do: nil

  defp normalize_cost_section(section, keys) do
    Enum.reduce(keys, %{}, fn key, result ->
      maybe_put(result, key, numeric_value(section[key]))
    end)
  end

  defp normalize_usage(nil), do: nil
  defp normalize_usage(usage), do: %{"credits" => usage["credits"]}

  defp related_searches(body) when is_map(body) do
    related =
      body["related_searches"] || get_in(body, ["data", "related_searches"]) ||
        body["suggestions"] || []

    if(is_list(related), do: related, else: [])
    |> Enum.flat_map(fn
      value when is_binary(value) -> [value]
      %{"query" => value} when is_binary(value) -> [value]
      %{"text" => value} when is_binary(value) -> [value]
      _ -> []
    end)
  end

  defp related_searches(_body), do: []

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
  defp maybe_put_nonempty(map, _key, []), do: map
  defp maybe_put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp setting(key, fallback) do
    case Settings.get(key) do
      value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
      _ -> fallback
    end
  end

  defp backend_label("exa"), do: "Exa"
  defp backend_label("tavily"), do: "Tavily"
  defp backend_label("ollama"), do: "Ollama"
  defp backend_label("minimax"), do: "MiniMax"

  defp error(reason), do: {:error, %{code: "web_search_error", message: to_string(reason)}}
end
