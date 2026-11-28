defmodule Backplane.AiProtocol.HostedSearch do
  @moduledoc """
  Provider-hosted search declarations and historical evidence.

  Hosts pass negotiated Runtime declarations in
  `Request.extensions["backplane::hosted_tools"]`. Anthropic additionally requires
  the explicit codec option `:anthropic_web_search_version`. Search observations
  use `:provider_hosted_event`, never the local tool-call lifecycle.

  `:hosted_search` content retains native evidence with its source protocol and
  status. Both codecs replay it as labeled assistant evidence text. Opaque native
  encrypted source fields stay in canonical history and are omitted from the text
  projection. The projection grants no authority to execute a historical search.
  """

  alias Backplane.AiProtocol.{ContentBlock, Error, Serialization, StreamEvent, Validation}

  @versions ~w(web_search_20250305 web_search_20260209)
  @fields ~w(source_protocol id status call result)

  @doc "Encodes negotiated declarations for the selected provider."
  def declarations(request, protocol, opts) do
    with {:ok, json} <-
           Serialization.to_json(Map.get(request.extensions, "backplane::hosted_tools", [])),
         {:ok, declarations} <- Serialization.from_json(json),
         true <- is_list(declarations) and length(declarations) <= 1 do
      Enum.reduce_while(declarations, {:ok, []}, fn declaration, {:ok, acc} ->
        case declaration(declaration, protocol, opts) do
          {:ok, wire} -> {:cont, {:ok, acc ++ [wire]}}
          error -> {:halt, error}
        end
      end)
    else
      false -> incompatible("Hosted tools must contain at most one web search declaration")
      error -> error
    end
  end

  defp declaration(%{"type" => "web_search"} = declaration, :openai_responses, _opts) do
    allowed = ~w(type external_web_access filters user_location search_context_size)

    with true <- Enum.all?(Map.keys(declaration), &(&1 in allowed)),
         true <- is_boolean(Map.get(declaration, "external_web_access", true)),
         true <- Map.get(declaration, "search_context_size", "medium") in ~w(low medium high),
         {:ok, _} <- search_filters(Map.get(declaration, "filters", %{}), ~w(allowed_domains)),
         {:ok, _} <- approximate_location(Map.get(declaration, "user_location")) do
      {:ok, declaration}
    else
      false -> incompatible("Responses cannot represent a requested hosted search option")
      error -> error
    end
  end

  defp declaration(%{"type" => "web_search"} = declaration, :anthropic, opts) do
    allowed = ~w(type external_web_access filters user_location)
    version = Keyword.get(opts, :anthropic_web_search_version)

    with true <- version in @versions,
         true <- Enum.all?(Map.keys(declaration), &(&1 in allowed)),
         true <- Map.get(declaration, "external_web_access", true) == true,
         {:ok, filters} <-
           search_filters(
             Map.get(declaration, "filters", %{}),
             ~w(allowed_domains blocked_domains)
           ),
         {:ok, location} <- approximate_location(Map.get(declaration, "user_location")) do
      wire = Map.merge(%{"type" => version, "name" => "web_search"}, filters)
      {:ok, if(location, do: Map.put(wire, "user_location", location), else: wire)}
    else
      false ->
        incompatible(
          "Anthropic hosted search requires a supported version and live representable options"
        )

      error ->
        error
    end
  end

  defp declaration(_, _, _), do: incompatible("Unsupported hosted search declaration")

  defp search_filters(filters, allowed) when is_map(filters) do
    if Enum.all?(Map.keys(filters), &(&1 in allowed)) and
         map_size(filters) <= 1 and
         Enum.all?(filters, fn {_key, domains} ->
           is_list(domains) and Enum.all?(domains, &(is_binary(&1) and &1 != ""))
         end),
       do: {:ok, filters},
       else: incompatible("Hosted search domain filters are invalid")
  end

  defp search_filters(_, _), do: incompatible("Hosted search filters must be an object")

  defp approximate_location(nil), do: {:ok, nil}

  defp approximate_location(%{"type" => "approximate"} = location) do
    if Enum.all?(Map.keys(location), &(&1 in ~w(type city region country timezone))) and
         Enum.all?(location, fn {_key, value} -> is_binary(value) and value != "" end),
       do: {:ok, location},
       else: incompatible("Hosted search location is invalid")
  end

  defp approximate_location(_), do: incompatible("Hosted search requires an approximate location")

  @doc false
  def validate(data, opts) when is_map(data) do
    with :ok <- Validation.term(data, Keyword.get(opts, :limits, %{})),
         true <- Enum.all?(Map.keys(data), &(&1 in @fields)),
         true <- data["source_protocol"] in ~w(anthropic openai_responses),
         true <- is_binary(data["id"]) and byte_size(data["id"]) in 1..256,
         true <- data["status"] in ~w(unresolved completed error),
         true <- is_map(data["call"]),
         :ok <- valid_evidence(data) do
      {:ok, data}
    else
      false ->
        invalid("Hosted search evidence requires a source, identity, status and native call")

      error ->
        error
    end
  end

  def validate(_, _), do: invalid("Hosted search evidence must be an object")

  defp valid_evidence(%{"source_protocol" => "anthropic", "call" => call} = data) do
    result = data["result"]

    cond do
      call["type"] != "server_tool_use" or call["name"] != "web_search" or
        call["id"] != data["id"] or not is_map(call["input"]) ->
        invalid("Anthropic hosted search call is invalid")

      data["status"] == "unresolved" and not Map.has_key?(data, "result") ->
        :ok

      is_map(result) and result["type"] == "web_search_tool_result" and
        result["tool_use_id"] == data["id"] and result_status(result) == data["status"] ->
        :ok

      true ->
        invalid("Anthropic hosted search result has no matching call or status")
    end
  end

  defp valid_evidence(%{"source_protocol" => "openai_responses", "call" => call} = data) do
    if call["type"] == "web_search_call" and call["id"] == data["id"] and
         responses_status(call) == data["status"] and not Map.has_key?(data, "result"),
       do: :ok,
       else: invalid("Responses hosted search evidence has an invalid identity or status")
  end

  @doc false
  def anthropic_call(call, opts \\ []) do
    ContentBlock.new(
      %{
        type: :hosted_search,
        data: %{
          "source_protocol" => "anthropic",
          "id" => call["id"],
          "status" => "unresolved",
          "call" => call
        }
      },
      opts
    )
  end

  @doc false
  def anthropic_result(%ContentBlock{type: :hosted_search, data: evidence}, result, opts \\ []) do
    ContentBlock.new(
      %{
        type: :hosted_search,
        data: Map.merge(evidence, %{"status" => result_status(result), "result" => result})
      },
      opts
    )
  end

  @doc false
  def responses_call(call, opts \\ []) do
    ContentBlock.new(
      %{
        type: :hosted_search,
        data: %{
          "source_protocol" => "openai_responses",
          "id" => call["id"],
          "status" => responses_status(call),
          "call" => call
        }
      },
      opts
    )
  end

  defp result_status(%{"content" => content}) when is_list(content) do
    if Enum.all?(
         content,
         &match?(%{"type" => "web_search_result", "url" => url} when is_binary(url), &1)
       ),
       do: "completed"
  end

  defp result_status(%{
         "content" => %{"type" => "web_search_tool_result_error", "error_code" => code}
       })
       when is_binary(code),
       do: "error"

  defp result_status(_), do: nil

  defp responses_status(%{"status" => "completed"}), do: "completed"
  defp responses_status(%{"status" => "failed"}), do: "error"

  defp responses_status(%{"status" => status})
       when status in ~w(in_progress searching incomplete),
       do: "unresolved"

  defp responses_status(_), do: nil

  @doc false
  def text(text, citations, protocol, opts \\ []) do
    extensions =
      if citations in [nil, []],
        do: %{},
        else: %{
          "backplane::citations" => %{"source_protocol" => protocol, "citations" => citations}
        }

    if citations == nil or (is_list(citations) and Enum.all?(citations, &is_map/1)),
      do: ContentBlock.new(%{type: :text, text: text, extensions: extensions}, opts),
      else: invalid("Provider search citations must be a list of objects")
  end

  @doc false
  def projected_text(
        %ContentBlock{type: :hosted_search, data: evidence, extensions: extensions},
        opts
      ) do
    projection =
      if extensions == %{}, do: evidence, else: Map.put(evidence, "extensions", extensions)

    with {:ok, _} <- validate(evidence, opts),
         {:ok, json} <- Serialization.to_json(readable(projection)) do
      {:ok, "Historical provider-hosted web search evidence\n" <> json}
    end
  end

  def projected_text(%ContentBlock{type: :text, text: text, extensions: extensions}, _opts) do
    case Map.get(extensions, "backplane::citations") do
      nil ->
        {:ok, text}

      citations ->
        with {:ok, json} <- Serialization.to_json(readable(citations)),
             do: {:ok, text <> "\nHistorical provider search citations\n" <> json}
    end
  end

  defp readable(value) when is_map(value) do
    value
    |> Map.drop(~w(encrypted_content encrypted_index))
    |> Map.new(fn {key, value} -> {key, readable(value)} end)
  end

  defp readable(value) when is_list(value), do: Enum.map(value, &readable/1)
  defp readable(value), do: value

  @doc false
  def event(block, index),
    do: %StreamEvent{
      type: :provider_hosted_event,
      index: index,
      call_id: block.data["id"],
      native_id: block.data["id"],
      name: "web_search",
      content: block
    }

  @doc "Maps a codec search observation into Runtime's provider-hosted event boundary."
  def runtime_event(%StreamEvent{
        type: :provider_hosted_event,
        content: %ContentBlock{type: :hosted_search, data: data}
      }),
      do: %{type: :provider_hosted_event, capability: "web_search", event: data}

  defp invalid(message), do: {:error, Error.invalid!(message)}
  defp incompatible(message), do: {:error, Error.incompatible!(message)}
end
