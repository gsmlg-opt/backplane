defmodule Mix.Tasks.Backplane.Codex.Smoke do
  @shortdoc "Run an opt-in OpenAI Codex proxy smoke test without printing credentials"

  @moduledoc """
  Verifies provider configuration and transparent Responses proxy behavior.

  The task runs only when `BACKPLANE_CODEX_SMOKE=true` is set so real upstream
  requests never run by default.
  """

  use Mix.Task

  alias Backplane.LLM.{OpenAICodex, Provider, ProviderApi}
  alias Backplane.Repo
  alias Backplane.WebOrigins

  import Ecto.Query

  @usage "mix backplane.codex.smoke --provider openai-codex --model gpt-5.6-sol"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start", [])

    unless System.get_env("BACKPLANE_CODEX_SMOKE") == "true" do
      Mix.raise("Real Codex smoke is disabled. Set BACKPLANE_CODEX_SMOKE=true to enable it.")
    end

    with {opts, [], []} <-
           OptionParser.parse(args, strict: [provider: :string, model: :string]),
         {:ok, provider} <- Keyword.fetch(opts, :provider),
         {:ok, model} <- Keyword.fetch(opts, :model) do
      run_smoke(provider, model)
    else
      _ -> Mix.raise("Usage: " <> @usage)
    end
  end

  defp run_smoke(provider_name, model) do
    provider =
      Provider
      |> where([p], p.name == ^provider_name and p.enabled == true and is_nil(p.deleted_at))
      |> Repo.one()

    if is_nil(provider), do: Mix.raise("Provider #{provider_name} not found or disabled")

    api = find_api(provider)

    if not OpenAICodex.enabled?(provider, api),
      do: Mix.raise("Provider is not a Codex OAuth provider")

    headers = client_headers()
    base_url = proxy_base_url(provider.name)
    client_version = System.get_env("OPENAI_CODEX_CLIENT_VERSION")

    models_path =
      if client_version,
        do: "/models?client_version=#{URI.encode_www_form(client_version)}",
        else: "/models"

    models_response = Req.get(base_url <> models_path, request_options(headers))
    print_result("models", models_response)

    models_response
    |> require_success!("models")
    |> require_model!(model)

    responses_response =
      Req.post(
        base_url <> "/responses",
        request_options(stream_headers(headers),
          json: responses_request(model, "Respond with the word: ok")
        )
      )

    print_response_result(responses_response)

    responses_response
    |> require_success!("responses")
    |> require_stream_events!()

    tool_response =
      Req.post(
        base_url <> "/responses",
        request_options(stream_headers(headers),
          json:
            responses_request(model, "Call the smoke_probe tool exactly once.", %{
              tools: [
                %{
                  type: "function",
                  name: "smoke_probe",
                  description: "A no-argument tool used only to verify tool calling.",
                  parameters: %{type: "object", properties: %{}, additionalProperties: false},
                  strict: true
                }
              ],
              tool_choice: "required"
            })
        )
      )

    print_tool_result(tool_response)

    tool_response
    |> require_success!("tool_call")
    |> require_tool_call!()

    stream_body =
      Jason.encode!(responses_request(model, "Respond with the word: streamed-ok"))

    stream_response =
      Req.post(
        base_url <> "/responses",
        request_options(stream_headers(headers), body: stream_body)
      )

    print_stream_result(stream_response)

    stream_response
    |> require_success!("stream")
    |> require_stream_events!()

    compact_response =
      Req.post(
        base_url <> "/responses",
        request_options(
          compact_v2_headers(headers),
          json: compact_v2_request(model)
        )
      )

    print_compact_result(compact_response)

    compact_response
    |> require_success!("compact")
    |> require_stream_events!()

    compact_response
    |> require_success!("compact")
    |> require_compact_output!()
  end

  defp find_api(provider) do
    case ProviderApi.list_for_provider(provider.id)
         |> Enum.find(&(&1.api_surface == :openai and &1.enabled)) do
      nil -> Mix.raise("OpenAI API surface is not enabled")
      api -> api
    end
  end

  defp proxy_base_url(provider_name) do
    base_url =
      System.get_env("BACKPLANE_CODEX_BASE_URL") ||
        WebOrigins.api_base_url()

    String.trim_trailing(base_url, "/") <> "/v1/providers/" <> provider_name
  end

  defp client_headers do
    case System.get_env("BACKPLANE_API_KEY") do
      token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token}]
      _ -> []
    end
  end

  defp request_options(headers, options \\ []) do
    [headers: headers, receive_timeout: 300_000]
    |> Keyword.merge(Application.get_env(:backplane, :codex_smoke_req_options, []))
    |> Keyword.merge(options)
  end

  defp input_message(text) do
    %{
      type: "message",
      role: "user",
      content: [%{type: "input_text", text: text}]
    }
  end

  defp responses_request(model, text, overrides \\ %{}) do
    Map.merge(
      %{
        model: model,
        instructions: "Complete this small proxy verification request briefly.",
        input: [input_message(text)],
        tools: [],
        tool_choice: "auto",
        parallel_tool_calls: false,
        reasoning: %{effort: "low", summary: "auto"},
        store: false,
        stream: true,
        include: ["reasoning.encrypted_content"]
      },
      overrides
    )
  end

  defp compact_v2_request(model) do
    responses_request(model, "A short conversation to compact.", %{
      instructions: "Compact the conversation while preserving its meaning.",
      input: [input_message("A short conversation to compact."), %{type: "compaction_trigger"}]
    })
  end

  defp stream_headers(headers) do
    headers
    |> Keyword.reject(fn {key, _value} -> String.downcase(key) == "accept" end)
    |> then(&[{"accept", "text/event-stream"} | &1])
  end

  defp compact_v2_headers(headers) do
    headers
    |> stream_headers()
    |> Keyword.reject(fn {key, _value} -> String.downcase(key) == "x-codex-beta-features" end)
    |> then(&[{"x-codex-beta-features", "remote_compaction_v2"} | &1])
  end

  defp event_count(body) when is_binary(body),
    do: body |> String.split("\n\n", trim: true) |> length()

  defp event_count(_body), do: 0

  defp print_result(label, {:ok, response}) do
    Mix.shell().info(
      "#{label} status=#{response.status} request_id=#{inspect(request_id(response))}"
    )
  end

  defp print_result(label, {:error, reason}),
    do: Mix.shell().info("#{label} error=#{Exception.message(reason)}")

  defp print_response_result({:ok, response}) do
    error = if response.status in 200..299, do: "", else: " error=#{error_detail(response.body)}"

    Mix.shell().info(
      "responses status=#{response.status} request_id=#{inspect(request_id(response))} " <>
        "event_count=#{event_count(response.body)}#{error}"
    )
  end

  defp print_response_result({:error, reason}),
    do: Mix.shell().info("responses error=#{Exception.message(reason)}")

  defp print_tool_result({:ok, response}) do
    error = if response.status in 200..299, do: "", else: " error=#{error_detail(response.body)}"

    Mix.shell().info(
      "tool_call status=#{response.status} request_id=#{inspect(request_id(response))} " <>
        "tool_calls=#{tool_call_count(response.body)}#{error}"
    )
  end

  defp print_tool_result({:error, reason}),
    do: Mix.shell().info("tool_call error=#{Exception.message(reason)}")

  defp print_stream_result({:ok, response}) do
    error = if response.status in 200..299, do: "", else: " error=#{error_detail(response.body)}"

    Mix.shell().info(
      "stream status=#{response.status} request_id=#{inspect(request_id(response))} " <>
        "event_count=#{event_count(response.body)}#{error}"
    )
  end

  defp print_stream_result({:error, reason}),
    do: Mix.shell().info("stream error=#{Exception.message(reason)}")

  defp print_compact_result({:ok, response}) do
    error = if response.status in 200..299, do: "", else: " error=#{error_detail(response.body)}"

    Mix.shell().info(
      "compact_v2 status=#{response.status} request_id=#{inspect(request_id(response))} " <>
        "output_items=#{compaction_item_count(response.body)}#{error}"
    )
  end

  defp print_compact_result({:error, reason}),
    do: Mix.shell().info("compact_v2 error=#{Exception.message(reason)}")

  defp tool_call_count(%{"output" => output}) when is_list(output) do
    Enum.count(output, &match?(%{"type" => "function_call"}, &1))
  end

  defp tool_call_count(body) when is_binary(body) do
    body
    |> sse_events()
    |> Enum.count(fn
      %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"}} ->
        true

      _event ->
        false
    end)
  end

  defp tool_call_count(_body), do: 0

  defp compaction_item_count(%{"output" => output}) when is_list(output) do
    Enum.count(output, &match?(%{"type" => "compaction"}, &1))
  end

  defp compaction_item_count(body) when is_binary(body) do
    body
    |> sse_events()
    |> Enum.count(fn
      %{"type" => "response.output_item.done", "item" => %{"type" => "compaction"}} -> true
      _event -> false
    end)
  end

  defp compaction_item_count(_body), do: 0

  defp require_success!({:ok, %{status: status} = response}, _label)
       when status >= 200 and status < 300,
       do: response

  defp require_success!({:ok, %{status: status}}, label),
    do: Mix.raise("#{label} failed with status #{status}")

  defp require_success!({:error, reason}, label),
    do: Mix.raise("#{label} request failed: #{Exception.message(reason)}")

  defp require_model!(%{body: %{"models" => models}}, model) when is_list(models) do
    if Enum.any?(models, &(&1["slug"] == model)) do
      :ok
    else
      Mix.raise("models response did not include requested model #{model}")
    end
  end

  defp require_model!(_response, _model),
    do: Mix.raise("models response did not contain a models list")

  defp require_tool_call!(%{body: body}) do
    if tool_call_count(body) > 0,
      do: :ok,
      else: Mix.raise("tool_call response did not contain a function call")
  end

  defp require_stream_events!(%{body: body}) do
    if Enum.any?(sse_events(body), &match?(%{"type" => "response.completed"}, &1)),
      do: :ok,
      else: Mix.raise("stream response did not contain response.completed")
  end

  defp require_compact_output!(%{body: body}) do
    if compaction_item_count(body) > 0,
      do: :ok,
      else: Mix.raise("compact response did not contain a compaction output item")
  end

  defp request_id(response) do
    Enum.find_value(response.headers, fn {key, value} ->
      if String.downcase(key) == "x-request-id", do: value
    end)
  end

  defp sse_events(body) when is_binary(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      data =
        frame
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &(&1 |> String.replace_prefix("data:", "") |> String.trim_leading()))

      case Jason.decode(data) do
        {:ok, event} when is_map(event) -> [event]
        _other -> []
      end
    end)
  end

  defp sse_events(_body), do: []

  defp error_detail(%{"error" => %{"code" => code}}) when is_binary(code), do: code

  defp error_detail(%{"error" => %{"type" => type}}) when is_binary(type), do: type

  defp error_detail(%{"detail" => detail}) when is_binary(detail),
    do: inspect(String.slice(detail, 0, 160))

  defp error_detail(_body), do: "unavailable"
end
