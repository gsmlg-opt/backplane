defmodule Backplane.AiProtocol.Antigravity.Google do
  @moduledoc """
  Directed Google GenerateContent to Antigravity wire translation.

  Google request content remains opaque inside Antigravity's native `request`
  envelope. Provider-owned routing fields are intentionally excluded.
  """

  alias Backplane.AiProtocol.{Antigravity, Error, Serialization, Validation}

  defstruct native: nil, terminal?: false

  @allowed_request_fields ~w(
    cachedContent contents generationConfig labels safetySettings sessionId
    systemInstruction toolConfig tools
  )

  @type t :: %__MODULE__{}

  @spec encode_request(map()) :: {:ok, map()} | {:error, Error.t()}
  def encode_request(body) when is_map(body) do
    with :ok <- Validation.bounded_map(body),
         :ok <- validate_request_fields(body),
         :ok <- validate_contents(body) do
      {:ok, %{"request" => body}}
    end
  end

  def encode_request(_body),
    do: {:error, Error.invalid!("Google GenerateContent request body must be a map")}

  @spec encode_count_request(map(), binary(), binary()) ::
          {:ok, map()} | {:error, Error.t()}
  def encode_count_request(body, requested_model, resolved_model)
      when is_map(body) and is_binary(requested_model) and is_binary(resolved_model) do
    with :ok <- Validation.bounded_map(body),
         {:ok, request} <- count_request(body),
         :ok <- validate_count_model(request["model"], requested_model, resolved_model),
         {:ok, contents} <- validate_count_contents(request["contents"]) do
      {:ok, %{"request" => %{"model" => resolved_model, "contents" => contents}}}
    end
  end

  def encode_count_request(_body, _requested_model, _resolved_model),
    do: {:error, Error.invalid!("Google countTokens request body must be a map")}

  @spec map_response(non_neg_integer(), binary()) :: {:ok, binary()} | {:error, Error.t()}
  def map_response(status, body) when status not in 200..299 and is_binary(body), do: {:ok, body}

  def map_response(status, body) when status in 200..299 and is_binary(body) do
    with {:ok, document} <- decode_document(body),
         {:ok, response} <- unwrap_document(document) do
      {:ok, Jason.encode!(response)}
    end
  end

  def map_response(_status, _body),
    do: {:error, Error.invalid!("Antigravity response must be a JSON string")}

  @spec map_count_response(non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, Error.t()}
  def map_count_response(status, body) when status not in 200..299 and is_binary(body),
    do: {:ok, body}

  def map_count_response(status, body) when status in 200..299 and is_binary(body) do
    with {:ok, document} <- decode_document(body) do
      case document do
        empty when map_size(empty) == 0 ->
          {:ok, Jason.encode!(%{"totalTokens" => 0})}

        %{"totalTokens" => total_tokens}
        when is_integer(total_tokens) and total_tokens >= 0 ->
          {:ok, body}

        _document ->
          {:error, Error.invalid!("Antigravity countTokens response has no valid totalTokens")}
      end
    else
      _ -> {:error, Error.invalid!("Antigravity countTokens response has no valid totalTokens")}
    end
  end

  def map_count_response(_status, _body),
    do: {:error, Error.invalid!("Antigravity countTokens response must be a JSON string")}

  @spec stream_new(keyword()) :: t()
  def stream_new(opts \\ []), do: %__MODULE__{native: Antigravity.stream_new(opts)}

  @spec stream_feed(t(), binary()) ::
          {:ok, t(), [binary()]} | {:error, Error.t(), t()}
  def stream_feed(%__MODULE__{} = state, chunk) do
    case Antigravity.stream_feed(state.native, chunk) do
      {:ok, native, documents} -> map_documents(%{state | native: native}, documents)
      {:error, error, native} -> {:error, error, %{state | native: native}}
    end
  end

  @spec stream_finish(t(), atom()) ::
          {:ok, t(), [binary()]} | {:error, Error.t(), t()}
  def stream_finish(%__MODULE__{} = state, reason) do
    case Antigravity.stream_finish(state.native, reason) do
      {:ok, native, documents} ->
        state = %{state | native: native}

        case map_documents(state, documents) do
          {:ok, %{terminal?: true} = state, chunks} ->
            {:ok, state, chunks}

          {:ok, state, _chunks} when reason == :eof ->
            {:error, Error.invalid!("Antigravity stream ended before Gemini completion"), state}

          result ->
            result
        end

      {:error, error, native} ->
        {:error, error, %{state | native: native}}
    end
  end

  defp validate_request_fields(body) do
    case Map.keys(body) -- @allowed_request_fields do
      [] -> :ok
      fields -> {:error, Error.invalid!("Unsupported Google request field: #{Enum.min(fields)}")}
    end
  end

  defp validate_contents(%{"contents" => contents}) when is_list(contents), do: :ok

  defp validate_contents(_body),
    do: {:error, Error.invalid!("Google GenerateContent contents must be a list")}

  defp count_request(body) do
    cond do
      Map.has_key?(body, "contents") and Map.has_key?(body, "generateContentRequest") ->
        {:error, Error.invalid!("Google countTokens request shapes are mutually exclusive")}

      Map.has_key?(body, "contents") ->
        with :ok <- reject_provider_count_fields(body),
             :ok <- reject_unsupported_count_fields(body, ["contents"]) do
          {:ok, body}
        end

      Map.has_key?(body, "generateContentRequest") ->
        with :ok <- reject_provider_count_fields(body),
             :ok <- reject_unsupported_count_fields(body, ["generateContentRequest"]) do
          case body["generateContentRequest"] do
            request when is_map(request) ->
              with :ok <- reject_provider_count_fields(request, ["model"]),
                   :ok <- reject_unsupported_count_fields(request, ["model", "contents"]) do
                {:ok, request}
              end

            _request ->
              {:error, Error.invalid!("Google generateContentRequest must be a map")}
          end
        end

      true ->
        {:error, Error.invalid!("Google countTokens contents are required")}
    end
  end

  defp reject_provider_count_fields(body, allowed \\ []) do
    fields =
      Map.keys(body)
      |> Enum.filter(
        &(&1 in ~w(project model authorization apiKey x-api-key x-goog-api-key) and
            &1 not in allowed)
      )

    case fields do
      [] -> :ok
      _ -> {:error, Error.invalid!("Google countTokens contains a provider-owned field")}
    end
  end

  defp reject_unsupported_count_fields(body, allowed) do
    case Map.keys(body) -- allowed do
      [] -> :ok
      _ -> Error.incompatible("Antigravity countTokens supports text contents only")
    end
  end

  defp validate_count_model(nil, _requested, _resolved), do: :ok

  defp validate_count_model(model, requested, resolved) when is_binary(model) do
    accepted = [requested, "models/" <> requested, resolved, "models/" <> resolved]

    if model in accepted,
      do: :ok,
      else: {:error, Error.invalid!("Google countTokens model conflicts with the URL model")}
  end

  defp validate_count_model(_model, _requested, _resolved),
    do: {:error, Error.invalid!("Google countTokens model must be a string")}

  defp validate_count_contents(contents) when is_list(contents) do
    contents
    |> Enum.reduce_while(:ok, fn content, :ok ->
      case validate_count_content(content) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> {:ok, contents}
      error -> error
    end
  end

  defp validate_count_contents(_contents),
    do: {:error, Error.invalid!("Google countTokens contents must be a list")}

  defp validate_count_content(content) when is_map(content) do
    with :ok <- reject_unsupported_count_fields(content, ["role", "parts"]),
         :ok <- validate_count_role(content["role"]),
         parts when is_list(parts) <- content["parts"],
         :ok <- validate_count_parts(parts) do
      :ok
    else
      {:error, %Error{}} = error ->
        error

      parts when not is_list(parts) ->
        {:error, Error.invalid!("Google countTokens content parts must be a list")}
    end
  end

  defp validate_count_content(_content),
    do: {:error, Error.invalid!("Google countTokens content must be a map")}

  defp validate_count_role(nil), do: :ok

  defp validate_count_role(role) when is_binary(role) do
    if role != "" and String.valid?(role),
      do: :ok,
      else: {:error, Error.invalid!("Google countTokens role must be a valid string")}
  end

  defp validate_count_role(_role),
    do: {:error, Error.invalid!("Google countTokens role must be a valid string")}

  defp validate_count_parts(parts) do
    Enum.reduce_while(parts, :ok, fn
      %{"text" => text} = part, :ok when is_binary(text) ->
        case Map.keys(part) do
          ["text"] -> {:cont, :ok}
          _ -> {:halt, Error.incompatible("Antigravity countTokens supports text parts only")}
        end

      %{"text" => _text}, :ok ->
        {:halt, {:error, Error.invalid!("Google countTokens text part must be a string")}}

      part, :ok when is_map(part) ->
        {:halt, Error.incompatible("Antigravity countTokens supports text parts only")}

      _part, :ok ->
        {:halt, {:error, Error.invalid!("Google countTokens part must be a map")}}
    end)
  end

  defp decode_document(body) do
    case Serialization.from_json(body) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _ -> {:error, Error.invalid!("Antigravity response is not a JSON object")}
    end
  end

  defp map_documents(state, documents) do
    Enum.reduce_while(documents, {:ok, [], state.terminal?}, fn document,
                                                                {:ok, frames, terminal?} ->
      case unwrap_document(document) do
        {:ok, response} ->
          frame = "data: " <> Jason.encode!(response) <> "\n\n"
          {:cont, {:ok, [frame | frames], terminal? or terminal_document?(document)}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, frames, terminal?} ->
        {:ok, %{state | terminal?: terminal?}, Enum.reverse(frames)}

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp terminal_document?(%{"error" => error}) when is_map(error), do: true

  defp terminal_document?(%{"response" => response}) when is_map(response) do
    prompt_blocked? =
      match?(
        %{"blockReason" => reason} when is_binary(reason) and reason != "",
        response["promptFeedback"]
      )

    candidate_finished? =
      Enum.any?(List.wrap(response["candidates"]), fn
        %{"finishReason" => reason} when is_binary(reason) and reason != "" -> true
        _ -> false
      end)

    prompt_blocked? or candidate_finished?
  end

  defp terminal_document?(_document), do: false

  defp unwrap_document(%{"response" => response}) when is_map(response), do: {:ok, response}
  defp unwrap_document(%{"error" => error} = document) when is_map(error), do: {:ok, document}

  defp unwrap_document(_document),
    do: {:error, Error.invalid!("Antigravity response envelope is missing response")}
end
