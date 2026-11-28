defmodule Backplane.Diagnostics.Analyses.Proxy do
  @moduledoc false

  alias Backplane.Diagnostics.Analyses.Output
  alias Backplane.HTTPClient

  @headers [
    {"x-backplane-diagnostics-origin", "analysis"},
    {"x-backplane-memory-capture", "skip"}
  ]
  @max_response_bytes 48 * 1024

  def complete(payload, model, policy) do
    with {:ok, url} <- proxy_url(),
         {:ok, auth} <- authorization(),
         token when is_binary(token) and byte_size(token) in 24..256 <-
           System.get_env("BACKPLANE_DIAGNOSTICS_ORIGIN_TOKEN"),
         json <- JSON.encode!(payload),
         prompt <- Output.prompt(payload),
         true <- byte_size(json) + byte_size(prompt) + 512 <= policy.max_input_tokens do
      headers = [{"x-backplane-diagnostics-origin-token", token} | @headers]
      messages = [%{role: "system", content: prompt}, %{role: "user", content: json}]
      request(url, headers, auth, messages, model, policy)
    else
      false -> {:error, :invalid_response}
      _ -> {:error, :not_dispatched}
    end
  end

  def usage(usage) when is_map(usage) do
    values = %{
      "input_tokens" => positive(usage["prompt_tokens"] || usage["input_tokens"]),
      "output_tokens" => positive(usage["completion_tokens"] || usage["output_tokens"]),
      "cost_micros" => positive(usage["cost_micros"])
    }

    if Enum.any?(values, fn {_, value} -> not is_nil(value) end),
      do: Map.put(values, "source", "model_response")
  end

  def usage(_), do: nil

  defp request(url, headers, auth, messages, model, policy) do
    opts =
      [
        headers: headers,
        json: %{
          model: model,
          messages: messages,
          max_tokens: policy.max_output_tokens,
          response_format: %{type: "json_object"},
          stream: false
        },
        max_body_bytes: @max_response_bytes,
        receive_timeout: policy.timeout_ms,
        retry: false,
        redirect: false
      ] ++ auth

    case HTTPClient.post(url, opts) do
      {:ok,
       %{
         status: 200,
         body: %{"choices" => [%{"message" => %{"content" => content} = message} | _]} = body
       }} ->
        if is_binary(content) and message["tool_calls"] in [nil, []],
          do: {:ok, content, body["usage"]},
          else: {:error, :invalid_response}

      {:ok, %{status: 200}} ->
        {:error, :invalid_response}

      _ ->
        {:error, :model_unavailable}
    end
  end

  defp proxy_url do
    with value when is_binary(value) <-
           Application.get_env(:backplane_diagnostics, :llm_proxy_url),
         %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: root} =
           uri <- URI.parse(value),
         true <-
           scheme in ~w(http https) and host in ["127.0.0.1", "localhost", "::1"] and
             root in [nil, "", "/"] do
      {:ok, URI.to_string(%{uri | path: "/v1/chat/completions"})}
    else
      _ -> {:error, :proxy_not_configured}
    end
  end

  defp authorization do
    case Application.get_env(:backplane_diagnostics, :proxy_token_env) do
      nil ->
        {:ok, []}

      env when is_binary(env) ->
        case System.get_env(env) do
          token when is_binary(token) and byte_size(token) in 1..4_096 ->
            {:ok, [auth: {:bearer, token}]}

          _ ->
            {:error, :credential_unavailable}
        end
    end
  end

  defp positive(value) when is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991,
    do: value

  defp positive(_), do: nil
end
