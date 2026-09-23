defmodule Backplane.AiProtocol.Antigravity do
  @moduledoc """
  Pure descriptors and native wire handling for the Antigravity Cloud Code API.

  This module does not perform HTTP requests or manage OAuth credentials. A host
  supplies trusted routing bindings and injects authentication after building a
  request descriptor.
  """

  alias Backplane.AiProtocol.{Antigravity.Stream, Error, Serialization, Validation}

  @default_metadata %{"ideType" => 9, "pluginType" => 2, "platform" => 0}
  @operations [
    %{
      operation: :load_code_assist,
      rpc: "loadCodeAssist",
      method: :post,
      path: "/v1internal:loadCodeAssist",
      streaming?: false
    },
    %{
      operation: :onboard_user,
      rpc: "onboardUser",
      method: :post,
      path: "/v1internal:onboardUser",
      streaming?: false
    },
    %{
      operation: :fetch_available_models,
      rpc: "fetchAvailableModels",
      method: :post,
      path: "/v1internal:fetchAvailableModels",
      streaming?: false
    },
    %{
      operation: :generate_content,
      rpc: "generateContent",
      method: :post,
      path: "/v1internal:generateContent",
      streaming?: false
    },
    %{
      operation: :stream_generate_content,
      rpc: "streamGenerateContent",
      method: :post,
      path: "/v1internal:streamGenerateContent",
      streaming?: true
    }
  ]
  @operation_atoms Enum.map(@operations, & &1.operation)
  @max_identifier_bytes 256
  @safe_model ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$/

  @type operation ::
          :load_code_assist
          | :onboard_user
          | :fetch_available_models
          | :generate_content
          | :stream_generate_content

  @spec operations() :: [map()]
  def operations, do: @operations

  @spec operation(String.t()) :: {:ok, operation()} | {:error, Error.t()}
  def operation(rpc) when is_binary(rpc) do
    case Enum.find(@operations, &(&1.rpc == rpc)) do
      nil -> {:error, Error.invalid!("Unsupported Antigravity operation")}
      descriptor -> {:ok, descriptor.operation}
    end
  end

  def operation(_rpc), do: {:error, Error.invalid!("Antigravity operation must be a string")}

  @spec build_request(operation() | String.t(), map(), keyword()) ::
          {:ok, %{method: :post, path: binary(), query: binary(), headers: list(), body: map()}}
          | {:error, Error.t()}
  def build_request(operation, native_body, opts \\ [])

  def build_request(operation, native_body, opts)
      when is_map(native_body) and is_list(opts) do
    with {:ok, operation} <- normalize_operation(operation),
         :ok <- Validation.bounded_map(native_body),
         {:ok, body} <- bind_body(operation, native_body, opts),
         {:ok, headers} <- headers(operation, body, opts) do
      descriptor = descriptor(operation)

      {:ok,
       %{
         method: :post,
         path: descriptor.path,
         query: if(descriptor.streaming?, do: "alt=sse", else: ""),
         headers: headers,
         body: body
       }}
    end
  end

  def build_request(_operation, _native_body, _opts),
    do: {:error, Error.invalid!("Antigravity request body must be a map")}

  @spec decode_response(operation() | String.t(), non_neg_integer(), list(), binary(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def decode_response(operation, status, headers, body, opts \\ [])

  def decode_response(operation, status, headers, body, opts)
      when is_integer(status) and status >= 0 and is_list(headers) and is_binary(body) and
             is_list(opts) do
    with {:ok, _operation} <- normalize_operation(operation) do
      case Serialization.from_json(body,
             max_encoded_bytes: Keyword.get(opts, :max_response_bytes, 8_388_608)
           ) do
        {:ok, document} when is_map(document) ->
          if status in 200..299 and not error_document?(document) do
            {:ok, document}
          else
            {:error, response_error(status, headers, document, opts)}
          end

        _ when status not in 200..299 ->
          {:error, response_error(status, headers, %{}, opts)}

        _ ->
          {:error, Error.invalid!("Antigravity response is not a JSON object")}
      end
    end
  end

  def decode_response(_operation, _status, _headers, _body, _opts),
    do: {:error, Error.invalid!("Antigravity response must be a JSON string")}

  @spec project(map()) :: binary() | nil
  def project(document) when is_map(document) do
    project_value(document["cloudaicompanionProject"]) ||
      response_project(document["response"])
  end

  def project(_document), do: nil

  @spec models(map()) :: map() | nil
  def models(%{"models" => models}) when is_map(models), do: models
  def models(_document), do: nil

  @spec onboarding_status(map()) :: :pending | {:complete, binary()} | {:error, Error.t()}
  def onboarding_status(%{"error" => error}) when is_map(error),
    do: {:error, response_error(200, [], %{"error" => error}, [])}

  def onboarding_status(%{"done" => true} = document) do
    case project(document) do
      project when is_binary(project) -> {:complete, project}
      nil -> {:error, Error.invalid!("Completed Antigravity onboarding response has no project")}
    end
  end

  def onboarding_status(%{"done" => false}), do: :pending
  def onboarding_status(%{}), do: :pending

  def onboarding_status(_document),
    do: {:error, Error.invalid!("Antigravity onboarding response must be a map")}

  @spec stream_new(keyword()) :: Stream.t()
  defdelegate stream_new(opts \\ []), to: Stream, as: :new

  @spec stream_feed(Stream.t(), term()) ::
          {:ok, Stream.t(), [map()]} | {:error, Error.t(), Stream.t()}
  defdelegate stream_feed(state, chunk), to: Stream, as: :feed

  @spec stream_finish(Stream.t(), atom()) ::
          {:ok, Stream.t(), [map()]} | {:error, Error.t(), Stream.t()}
  defdelegate stream_finish(state, reason), to: Stream, as: :finish

  defp normalize_operation(operation) when operation in @operation_atoms, do: {:ok, operation}
  defp normalize_operation(operation) when is_binary(operation), do: operation(operation)

  defp normalize_operation(_operation),
    do: {:error, Error.invalid!("Unsupported Antigravity operation")}

  defp descriptor(operation), do: Enum.find(@operations, &(&1.operation == operation))

  defp bind_body(:load_code_assist, body, opts) do
    with {:ok, metadata} <- metadata(body),
         {:ok, metadata} <-
           bind_optional_or_validate(metadata, "duetProject", opts[:project], :project) do
      {:ok, body |> Map.put("metadata", metadata) |> Map.put_new("mode", 1)}
    end
  end

  defp bind_body(:onboard_user, body, opts) do
    with {:ok, tier_id} <- required_string(body, "tierId", "Antigravity onboarding tierId"),
         {:ok, metadata} <- metadata(body),
         {:ok, metadata} <-
           bind_optional_or_validate(metadata, "duetProject", opts[:project], :project) do
      {:ok, body |> Map.put("tierId", tier_id) |> Map.put("metadata", metadata)}
    end
  end

  defp bind_body(:fetch_available_models, body, opts),
    do: bind_optional_or_validate(body, "project", opts[:project], :project)

  defp bind_body(operation, body, opts)
       when operation in [:generate_content, :stream_generate_content] do
    with {:ok, project} <- trusted_required(opts, :project),
         {:ok, body} <- bind_required(body, "project", project, :project),
         {:ok, model} <- bind_model(body, opts[:model]),
         {:ok, request} <- request_map(body),
         {:ok, request} <-
           bind_optional_or_validate(request, "sessionId", opts[:session_id], :session_id),
         {:ok, body} <-
           bind_optional_or_validate(body, "requestId", opts[:request_id], :request_id) do
      {:ok,
       body
       |> Map.put("model", model)
       |> Map.put("request", request)
       |> Map.put_new("userAgent", "antigravity")
       |> Map.put_new("requestType", "agent")}
    end
  end

  defp metadata(body) do
    case Map.get(body, "metadata", %{}) do
      metadata when is_map(metadata) -> {:ok, Map.merge(@default_metadata, metadata)}
      _ -> {:error, Error.invalid!("Antigravity metadata must be a map")}
    end
  end

  defp request_map(%{"request" => request}) when is_map(request), do: {:ok, request}

  defp request_map(_body),
    do: {:error, Error.invalid!("Antigravity generation request is required")}

  defp bind_model(body, trusted_model) do
    value = trusted_model || body["model"]

    with {:ok, value} <- valid_model(value),
         {:ok, body} <- bind_required(body, "model", value, :model) do
      {:ok, body["model"] || value}
    end
  end

  defp valid_model(value) when is_binary(value) do
    if Regex.match?(@safe_model, value) and not String.contains?(value, ["/", "\\", "\r", "\n"]),
      do: {:ok, value},
      else: {:error, Error.invalid!("Antigravity model must be a safe single segment")}
  end

  defp valid_model(_value),
    do: {:error, Error.invalid!("Antigravity model must be a safe single segment")}

  defp trusted_required(opts, key) do
    case opts[key] do
      value when is_binary(value) -> valid_identifier(value, key)
      _ -> {:error, Error.invalid!("Trusted Antigravity #{key} is required")}
    end
  end

  defp bind_required(map, key, value, label) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, Map.put(map, key, value)}

      {:ok, ^value} ->
        {:ok, map}

      {:ok, _other} ->
        {:error, Error.invalid!("Antigravity #{label} conflicts with trusted binding")}
    end
  end

  defp bind_optional(map, key, value, label) do
    with {:ok, value} <- valid_identifier(value, label), do: bind_required(map, key, value, label)
  end

  defp bind_optional_or_validate(map, key, nil, label) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, map}

      {:ok, value} ->
        with {:ok, _value} <- valid_identifier(value, label), do: {:ok, map}
    end
  end

  defp bind_optional_or_validate(map, key, value, label),
    do: bind_optional(map, key, value, label)

  defp valid_identifier(value, label) when is_binary(value) do
    cond do
      value == "" ->
        {:error, Error.invalid!("Antigravity #{label} cannot be empty")}

      byte_size(value) > @max_identifier_bytes ->
        {:error, Error.invalid!("Antigravity #{label} is too long")}

      not String.valid?(value) ->
        {:error, Error.invalid!("Antigravity #{label} is not valid UTF-8")}

      String.contains?(value, ["\r", "\n"]) ->
        {:error, Error.invalid!("Antigravity #{label} contains unsafe characters")}

      true ->
        {:ok, value}
    end
  end

  defp valid_identifier(_value, label),
    do: {:error, Error.invalid!("Antigravity #{label} must be a string")}

  defp required_string(body, key, label) do
    case body[key] do
      value when is_binary(value) -> valid_identifier(value, label)
      _ -> {:error, Error.invalid!("#{label} is required")}
    end
  end

  defp headers(operation, body, opts) do
    accept =
      if operation == :stream_generate_content,
        do: "text/event-stream",
        else: "application/json"

    headers = [
      {"content-type", "application/json"},
      {"accept", accept},
      {"x-client-name", "antigravity"}
    ]

    with {:ok, headers} <- optional_header(headers, "user-agent", opts[:user_agent], :user_agent),
         {:ok, headers} <-
           optional_header(headers, "x-client-version", opts[:client_version], :client_version),
         {:ok, headers} <-
           optional_header(
             headers,
             "x-machine-session-id",
             request_session_id(body),
             :session_id
           ) do
      {:ok, headers}
    end
  end

  defp request_session_id(%{"request" => %{"sessionId" => session_id}}), do: session_id
  defp request_session_id(_body), do: nil

  defp optional_header(headers, _name, nil, _label), do: {:ok, headers}

  defp optional_header(headers, name, value, label) do
    with {:ok, value} <- valid_identifier(value, label), do: {:ok, headers ++ [{name, value}]}
  end

  defp error_document?(%{"error" => error}) when is_map(error), do: true
  defp error_document?(_document), do: false

  defp response_error(status, headers, document, opts) do
    error = if is_map(document["error"]), do: document["error"], else: %{}

    %Error{
      kind: error_kind(status),
      stage: :response,
      http_status: status,
      provider_code: safe_code(error["status"] || error["type"] || error["code"]),
      message: "Antigravity provider request failed",
      retry_hint: if(status in [408, 429] or status >= 500, do: :retryable, else: :not_retryable),
      retry_after_ms: retry_after_ms(headers, opts),
      upstream_outcome: :known
    }
  end

  defp error_kind(400), do: :invalid_request
  defp error_kind(401), do: :authentication
  defp error_kind(403), do: :authorization
  defp error_kind(404), do: :not_found
  defp error_kind(429), do: :rate_limited
  defp error_kind(_status), do: :upstream_error

  defp safe_code(value) when is_integer(value), do: Integer.to_string(value)

  defp safe_code(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Z][A-Z0-9_]{0,127}$/), do: value
  end

  defp safe_code(_value), do: nil

  defp retry_after_ms(headers, opts) do
    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "retry-after", do: value

      _ ->
        nil
    end)
    |> parse_retry_after(Keyword.get(opts, :now_unix, System.system_time(:second)))
  end

  defp parse_retry_after(nil, _now), do: nil

  defp parse_retry_after(value, now) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> parse_retry_date(value, now)
    end
  end

  defp parse_retry_date(value, now) do
    with [day, month, year, hour, minute, second] <- retry_date_parts(value),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      max(DateTime.to_unix(datetime) - now, 0) * 1_000
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp retry_date_parts(value) do
    case Regex.run(
           ~r/^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), (\d{2}) ([A-Z][a-z]{2}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
           String.trim(value),
           capture: :all_but_first
         ) do
      [day, month, year, hour, minute, second] ->
        with {day, ""} <- Integer.parse(day),
             month when is_integer(month) <- month_number(month),
             {year, ""} <- Integer.parse(year),
             {hour, ""} <- Integer.parse(hour),
             {minute, ""} <- Integer.parse(minute),
             {second, ""} <- Integer.parse(second) do
          [day, month, year, hour, minute, second]
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp month_number(month),
    do:
      %{
        "Jan" => 1,
        "Feb" => 2,
        "Mar" => 3,
        "Apr" => 4,
        "May" => 5,
        "Jun" => 6,
        "Jul" => 7,
        "Aug" => 8,
        "Sep" => 9,
        "Oct" => 10,
        "Nov" => 11,
        "Dec" => 12
      }[month]

  defp project_value(value) when is_binary(value) and value != "", do: value
  defp project_value(%{"id" => value}) when is_binary(value) and value != "", do: value
  defp project_value(_value), do: nil

  defp response_project(%{"cloudaicompanionProject" => value}), do: project_value(value)
  defp response_project(_response), do: nil
end
