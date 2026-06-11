defmodule Backplane.Services.WebXSearch do
  @moduledoc """
  xAI X Search implementation used by `Backplane.Services.Web`.

  Calls the xAI Responses API with the built-in `x_search` server-side tool and
  returns a normalized response for MCP callers.
  """

  alias Backplane.Settings
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.OAuthRefresher

  @default_base_url "https://api.x.ai"
  @default_model "grok-4.3"
  @default_credential_name "xai-grok"

  def handle_x_search(%{"query" => query}) when is_binary(query) do
    with :ok <- ensure_enabled(),
         {:ok, query} <- validate_query(query),
         {:ok, credential_name} <- resolve_credential(),
         {:ok, api_key} <- fetch_credential(credential_name),
         {:ok, request} <- build_request(query),
         {:ok, response} <- request_x_search(request, api_key) do
      {:ok, normalize_response(response, query)}
    else
      {:error, %{code: _, message: _} = error} -> {:error, error}
      {:error, reason} -> error(reason)
    end
  rescue
    exception -> error(Exception.message(exception))
  end

  def handle_x_search(_args), do: error("missing query")

  defp ensure_enabled do
    if Settings.get("services.web.enabled") == true,
      do: :ok,
      else: {:error, "web::x_search is disabled"}
  end

  defp validate_query(query) do
    case String.trim(query) do
      "" -> {:error, "query cannot be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp resolve_credential do
    credential_name =
      [
        Settings.get("services.web_x_search.credential"),
        default_named_credential(),
        first_xai_oauth_credential()
      ]
      |> Enum.find(&present?/1)

    if credential_name do
      {:ok, credential_name}
    else
      {:error, "xAI X Search credential is not configured"}
    end
  end

  defp default_named_credential do
    if Credentials.exists?(@default_credential_name), do: @default_credential_name
  end

  defp first_xai_oauth_credential do
    Credentials.list()
    |> Enum.find_value(fn
      %{name: name, metadata: %{"auth_type" => "xai_oauth"}} -> name
      %{name: name, metadata: %{auth_type: "xai_oauth"}} -> name
      _ -> nil
    end)
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

  defp build_request(query) do
    {:ok,
     %{
       "model" => resolve_model(),
       "input" => [%{"role" => "user", "content" => query}],
       "tools" => [%{"type" => "x_search"}],
       "store" => false
     }}
  end

  defp resolve_model do
    [Settings.get("services.web_x_search.model"), @default_model]
    |> Enum.find_value(fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end)
  end

  defp request_x_search(body, api_key) do
    url = base_url() <> "/v1/responses"

    options =
      url
      |> OAuthRefresher.request_options()
      |> Keyword.merge(
        url: url,
        headers: [
          {"authorization", "Bearer " <> api_key},
          {"accept", "application/json"}
        ],
        json: body,
        receive_timeout: 60_000
      )
      |> Keyword.merge(Application.get_env(:backplane, :web_x_search_req_options, []))

    case Req.post(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{response_message(body)}"}

      {:error, reason} ->
        {:error, exception_message(reason)}
    end
  end

  defp base_url do
    case Settings.get("services.web_x_search.base_url") do
      value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
      _ -> @default_base_url
    end
  end

  defp normalize_response(body, query) do
    %{
      "query" => query,
      "result" => output_text(body),
      "citations" => citations(body)
    }
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

  defp output_texts_from_content(%{"type" => "output_text", "text" => text}) when is_binary(text),
    do: [text]

  defp output_texts_from_content(%{"text" => text}) when is_binary(text), do: [text]
  defp output_texts_from_content(_content), do: []

  defp citations(body) do
    (top_level_citations(body) ++ annotation_citations(body))
    |> Enum.uniq()
  end

  defp top_level_citations(%{"citations" => citations}) when is_list(citations) do
    Enum.flat_map(citations, &normalize_citation/1)
  end

  defp top_level_citations(_body), do: []

  defp annotation_citations(%{"output" => output}) when is_list(output) do
    Enum.flat_map(output, fn
      %{"content" => content} when is_list(content) ->
        content
        |> Enum.flat_map(fn
          %{"annotations" => annotations} when is_list(annotations) ->
            Enum.flat_map(annotations, &normalize_citation/1)

          _ ->
            []
        end)

      _ ->
        []
    end)
  end

  defp annotation_citations(_body), do: []

  defp normalize_citation(value) when is_binary(value) do
    if present?(value), do: [value], else: []
  end

  defp normalize_citation(%{"url" => url}) when is_binary(url), do: normalize_citation(url)

  defp normalize_citation(%{"source" => source}) when is_binary(source),
    do: normalize_citation(source)

  defp normalize_citation(_value), do: []

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp response_message(%{"error" => %{"message" => message}}), do: message
  defp response_message(%{"error" => message}) when is_binary(message), do: message
  defp response_message(body) when is_binary(body), do: body
  defp response_message(body), do: inspect(body)

  defp exception_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp exception_message(reason) when is_binary(reason), do: reason
  defp exception_message(reason), do: inspect(reason)

  defp error(reason), do: {:error, %{code: "web_x_search_error", message: to_string(reason)}}
end
