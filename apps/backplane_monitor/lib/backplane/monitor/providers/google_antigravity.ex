defmodule Backplane.Monitor.Providers.GoogleAntigravity do
  @moduledoc """
  Fetches Google Antigravity usage with a Google OAuth access token.

  The response is normalized into prompt, flow, and flex credit buckets.
  """

  import Bitwise

  @provider "google_ai"
  @default_url "https://cloudcode-pa.googleapis.com/google.internal.cloud.code.v1internal.PredictionService/RetrieveUserQuota"
  @default_user_agent "antigravity-cli"
  @default_receive_timeout 15_000
  @credits_url "https://antigravity.google/g1-credits"
  @activity_url "https://antigravity.google/g1-activity"

  @doc "Fetch Google Antigravity usage with an OAuth access token."
  @spec fetch(String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def fetch(access_token, config \\ %{})

  def fetch(access_token, config) when is_map(config) do
    with {:ok, access_token} <- required_string(access_token, :missing_access_token) do
      request_usage(access_token, config)
    end
  end

  @doc "Normalize the raw Google Antigravity usage response."
  @spec normalize_usage_response(map()) :: map() | {:error, :invalid_usage_response}
  def normalize_usage_response(%{} = raw) do
    plan_status =
      first_map(raw, ["plan_status", "planStatus", "quota_status", "quotaStatus"]) || raw

    user_status = first_map(raw, ["user_status", "userStatus"]) || raw

    plan_info =
      first_map(plan_status, ["plan_info", "planInfo"]) ||
        first_map(user_status, ["plan_info", "planInfo"]) ||
        first_map(raw, ["plan_info", "planInfo"]) ||
        %{}

    user_tier =
      first_map(raw, ["user_tier", "userTier"]) ||
        first_map(plan_status, ["user_tier", "userTier"]) ||
        %{}

    credits = normalized_credits(raw, plan_status, plan_info, user_status, user_tier)
    period = normalized_period(raw, plan_status)
    plan_type = plan_type(raw, plan_status, plan_info)
    status = first_nonblank([value(raw, "status"), value(plan_status, "status")]) || "ok"

    if response_has_usage?(plan_type, credits, period) do
      %{
        provider: @provider,
        status: status,
        plan_type: plan_type,
        credits: credits,
        period: period,
        links: %{
          credits: @credits_url,
          activity: @activity_url
        }
      }
    else
      {:error, :invalid_usage_response}
    end
  end

  def normalize_usage_response(_), do: {:error, :invalid_usage_response}

  defp request_usage(access_token, config) do
    with {:ok, body} <- request_body(config) do
      url = config_value(config, "api_url") || @default_url

      case Req.post(
             url,
             [
               headers: request_headers(access_token, config),
               body: body,
               receive_timeout: receive_timeout(config),
               retry: false
             ] ++ req_options(url)
           ) do
        {:ok, %Req.Response{status: 200} = response} ->
          case decode_response_body(response) do
            {:ok, body} ->
              case normalize_usage_response(body) do
                {:error, reason} -> {:error, reason}
                normalized -> {:ok, normalized}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, %Req.Response{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %Req.Response{status: 429} = response} ->
          {:error, {:rate_limited, retry_after(response)}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp request_headers(access_token, config) do
    [
      {"authorization", "Bearer #{access_token}"},
      {"user-agent", config_value(config, "user_agent") || @default_user_agent},
      {"content-type", "application/grpc"},
      {"accept", "application/grpc"}
    ]
  end

  defp request_body(config) do
    with {:ok, project} <-
           required_string(
             config_value(config, "project") || config_value(config, "cloudaicompanion_project"),
             :missing_project
           ) do
      {:ok, grpc_frame(encode_string_field(1, project))}
    end
  end

  defp normalized_credits(raw, plan_status, plan_info, user_status, user_tier) do
    direct_credits =
      [
        direct_credit_buckets(value(raw, "credits")),
        direct_credit_buckets(value(raw, "available_credits")),
        direct_credit_buckets(value(plan_status, "available_credits")),
        direct_credit_buckets(value(user_tier, "available_credits"))
      ]
      |> Enum.find(&(&1 != []))
      |> Kernel.||([])

    quota_credits = quota_credit_buckets(value(raw, "buckets"))

    cond do
      direct_credits != [] ->
        direct_credits

      quota_credits != [] ->
        quota_credits

      true ->
        [
          credit_bucket(
            "prompt",
            "Prompt Credits",
            value(plan_status, "available_prompt_credits"),
            first_non_nil([
              value(user_status, "user_used_prompt_credits"),
              value(plan_status, "used_prompt_credits")
            ]),
            value(plan_info, "monthly_prompt_credits")
          ),
          credit_bucket(
            "flow",
            "Flow Credits",
            value(plan_status, "available_flow_credits"),
            first_non_nil([
              value(user_status, "user_used_flow_credits"),
              value(plan_status, "used_flow_credits")
            ]),
            value(plan_info, "monthly_flow_credits")
          ),
          credit_bucket(
            "flex",
            "Flex Credits",
            value(plan_status, "available_flex_credits"),
            value(plan_status, "used_flex_credits"),
            value(plan_info, "monthly_flex_credit_purchase_amount")
          )
        ]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp direct_credit_buckets(credits) when is_list(credits) do
    credits
    |> Enum.with_index(1)
    |> Enum.map(fn {credit, index} -> direct_credit_bucket(credit, index) end)
    |> Enum.reject(&is_nil/1)
  end

  defp direct_credit_buckets(%{} = credits) do
    credits
    |> Enum.map(fn {id, payload} ->
      payload =
        case payload do
          %{} = map -> Map.put_new(map, "id", to_string(id))
          value -> %{"id" => to_string(id), "available" => value}
        end

      direct_credit_bucket(payload, nil)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp direct_credit_buckets(_), do: []

  defp direct_credit_bucket(%{} = credit, index) do
    id =
      [value(credit, "id"), value(credit, "type"), value(credit, "credit_type")]
      |> first_nonblank()
      |> normalize_credit_id()

    id = id || "credit_#{index || System.unique_integer([:positive])}"
    label = first_nonblank([value(credit, "label"), value(credit, "name")]) || credit_label(id)

    credit_bucket(
      id,
      label,
      first_non_nil([
        value(credit, "available"),
        value(credit, "remaining"),
        value(credit, "credit_amount"),
        value(credit, "amount")
      ]),
      value(credit, "used"),
      first_non_nil([value(credit, "monthly"), value(credit, "limit"), value(credit, "total")])
    )
  end

  defp direct_credit_bucket(_, _index), do: nil

  defp quota_credit_buckets(buckets) when is_list(buckets) do
    buckets
    |> Enum.with_index(1)
    |> Enum.map(fn {bucket, index} -> quota_credit_bucket(bucket, index) end)
    |> Enum.reject(&is_nil/1)
  end

  defp quota_credit_buckets(_), do: []

  defp quota_credit_bucket(%{} = bucket, index) do
    model = value(bucket, "model")
    model_id = value(model, "model_id")
    display_name = value(model, "display_name")
    token_type = value(bucket, "token_type")
    remaining_fraction = number_or_nil(value(bucket, "remaining_fraction"))
    used_percent = used_percent_from_remaining_fraction(remaining_fraction)
    id = model_id || token_type || "quota_#{index}"

    %{
      id: to_string(id),
      label: first_nonblank([display_name]) || titleize(token_type || id),
      available: number_or_nil(value(bucket, "remaining_amount")),
      used: nil,
      monthly: nil,
      used_percent: used_percent,
      remaining_fraction: remaining_fraction,
      reset_time: value(bucket, "reset_time")
    }
  end

  defp quota_credit_bucket(_, _index), do: nil

  defp credit_bucket(id, label, available, used, monthly) do
    bucket = %{
      id: to_string(id),
      label: label,
      available: number_or_nil(available),
      used: number_or_nil(used),
      monthly: number_or_nil(monthly),
      remaining_fraction: nil,
      reset_time: nil
    }

    if Enum.any?([bucket.available, bucket.used, bucket.monthly], &(!is_nil(&1))) do
      Map.put(bucket, :used_percent, used_percent(bucket))
    end
  end

  defp used_percent(%{used: used, available: available, monthly: monthly}) do
    total =
      cond do
        number_positive?(monthly) ->
          monthly

        is_number(used) and is_number(available) and used + available > 0 ->
          used + available

        true ->
          nil
      end

    if is_number(used) and number_positive?(total) do
      round(used / total * 100)
      |> max(0)
      |> min(100)
    end
  end

  defp used_percent_from_remaining_fraction(value) when is_number(value) do
    value
    |> then(&(100 - &1 * 100))
    |> round()
    |> max(0)
    |> min(100)
  end

  defp used_percent_from_remaining_fraction(_), do: nil

  defp normalized_period(raw, plan_status) do
    %{
      start: first_non_nil([value(plan_status, "plan_start"), value(raw, "plan_start")]),
      end: first_non_nil([value(plan_status, "plan_end"), value(raw, "plan_end")])
    }
  end

  defp plan_type(raw, plan_status, plan_info) do
    first_nonblank([
      value(plan_info, "plan_name"),
      value(raw, "plan_name"),
      value(plan_status, "plan_name"),
      value(raw, "plan_type"),
      value(raw, "tier")
    ])
  end

  defp response_has_usage?(plan_type, credits, period) do
    is_binary(plan_type) or credits != [] or not is_nil(period.start) or not is_nil(period.end)
  end

  defp first_map(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case value(map, key) do
        %{} = found -> found
        _ -> nil
      end
    end)
  end

  defp first_map(_, _), do: nil

  defp first_nonblank(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when not is_nil(value) ->
        to_string(value)

      _ ->
        nil
    end)
  end

  defp first_non_nil(values), do: Enum.find(values, &(!is_nil(&1)))

  defp value(map, key) when is_map(map) and is_binary(key) do
    key
    |> key_variants()
    |> Enum.reduce_while(nil, fn variant, _acc ->
      case fetch_key(map, variant) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp value(_, _), do: nil

  defp key_variants(key) do
    camelized =
      key
      |> String.split("_", trim: true)
      |> case do
        [] -> key
        [head | rest] -> head <> Enum.map_join(rest, "", &String.capitalize/1)
      end

    [key, camelized]
    |> Enum.uniq()
  end

  defp fetch_key(map, key) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.get(map, key)}

      is_binary(key) ->
        atom_key = String.to_existing_atom(key)

        if Map.has_key?(map, atom_key) do
          {:ok, Map.get(map, atom_key)}
        else
          :error
        end

      true ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp number_or_nil(value) when is_integer(value) or is_float(value), do: value

  defp number_or_nil(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} ->
        if parsed == trunc(parsed), do: trunc(parsed), else: parsed

      _ ->
        nil
    end
  end

  defp number_or_nil(_), do: nil

  defp number_positive?(value) when is_number(value), do: value > 0
  defp number_positive?(_), do: false

  defp normalize_credit_id(nil), do: nil

  defp normalize_credit_id(value) do
    normalized =
      value
      |> to_string()
      |> String.downcase()

    cond do
      String.contains?(normalized, "prompt") -> "prompt"
      String.contains?(normalized, "flow") -> "flow"
      String.contains?(normalized, "flex") -> "flex"
      String.contains?(normalized, "fca") -> "flex"
      true -> normalized
    end
  end

  defp credit_label("prompt"), do: "Prompt Credits"
  defp credit_label("flow"), do: "Flow Credits"
  defp credit_label("flex"), do: "Flex Credits"
  defp credit_label(id), do: titleize(id)

  defp titleize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp required_string(value, reason) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, reason}, else: {:ok, value}
  end

  defp required_string(_, reason), do: {:error, reason}

  defp decode_response_body(%Req.Response{} = response) do
    case grpc_status(response) do
      "0" ->
        decode_success_body(response.body)

      "16" ->
        {:error, :unauthorized}

      status when is_binary(status) ->
        {:error, {:grpc_error, status, grpc_message(response)}}

      nil ->
        decode_success_body(response.body)
    end
  end

  defp decode_success_body(%{} = body), do: {:ok, body}
  defp decode_success_body(body) when is_binary(body), do: decode_grpc_body(body)
  defp decode_success_body(_), do: {:error, :invalid_usage_response}

  defp decode_grpc_body(body) do
    with {:ok, messages} <- decode_grpc_frames(body),
         [_ | _] <- messages do
      messages
      |> Enum.map(&decode_retrieve_user_quota_response/1)
      |> merge_quota_responses()
    else
      [] -> {:error, :invalid_usage_response}
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_usage_response}
    end
  end

  defp decode_grpc_frames(body), do: decode_grpc_frames(body, [])

  defp decode_grpc_frames(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_grpc_frames(<<compressed, size::unsigned-big-integer-size(32), rest::binary>>, acc)
       when byte_size(rest) >= size do
    <<message::binary-size(size), next::binary>> = rest

    if compressed == 0 do
      decode_grpc_frames(next, [message | acc])
    else
      {:error, :compressed_grpc_response}
    end
  end

  defp decode_grpc_frames(_body, _acc), do: {:error, :invalid_grpc_response}

  defp decode_retrieve_user_quota_response(message) do
    with {:ok, fields} <- decode_protobuf_fields(message) do
      buckets =
        fields
        |> Enum.filter(fn {field, wire, _value} -> field == 1 and wire == 2 end)
        |> Enum.map(fn {_field, _wire, value} -> decode_quota_bucket(value) end)
        |> Enum.reject(&is_nil/1)

      {:ok, %{"buckets" => buckets}}
    end
  end

  defp merge_quota_responses(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, %{"buckets" => buckets}}, {:ok, acc} -> {:cont, {:ok, acc ++ buckets}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, buckets} -> {:ok, %{"buckets" => buckets}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_quota_bucket(message) do
    with {:ok, fields} <- decode_protobuf_fields(message) do
      fields
      |> Enum.reduce(%{}, fn
        {1, 0, value}, acc ->
          Map.put(acc, "remaining_amount", value)

        {5, 5, value}, acc ->
          Map.put(acc, "remaining_fraction", decode_float32(value))

        {2, 2, value}, acc ->
          Map.put(acc, "reset_time", decode_timestamp(value))

        {3, 0, value}, acc ->
          Map.put(acc, "token_type", token_type(value))

        {4, 2, value}, acc ->
          Map.put(acc, "model", decode_model_id_or_message(value))

        _field, acc ->
          acc
      end)
    else
      _ -> nil
    end
  end

  defp decode_model(message) do
    with {:ok, fields} <- decode_protobuf_fields(message) do
      Enum.reduce(fields, %{}, fn
        {1, 2, value}, acc -> Map.put(acc, "model_id", value)
        {2, 2, value}, acc -> Map.put(acc, "display_name", value)
        {3, 2, value}, acc -> Map.put(acc, "description", value)
        _field, acc -> acc
      end)
    else
      _ -> %{}
    end
  end

  defp decode_model_id_or_message(value) do
    case decode_model(value) do
      model when map_size(model) > 0 -> model
      _ -> %{"model_id" => value}
    end
  end

  defp decode_timestamp(message) do
    with {:ok, fields} <- decode_protobuf_fields(message),
         seconds when is_integer(seconds) <- field_value(fields, 1, 0) do
      nanos = field_value(fields, 2, 0) || 0

      seconds
      |> DateTime.from_unix!()
      |> add_nanoseconds(nanos)
      |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end

  defp add_nanoseconds(datetime, 0), do: datetime
  defp add_nanoseconds(datetime, nanos), do: DateTime.add(datetime, nanos, :nanosecond)

  defp field_value(fields, field, wire) do
    Enum.find_value(fields, fn
      {^field, ^wire, value} -> value
      _ -> nil
    end)
  end

  defp decode_protobuf_fields(binary), do: decode_protobuf_fields(binary, [])

  defp decode_protobuf_fields(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_protobuf_fields(binary, acc) do
    with {:ok, key, rest} <- decode_varint(binary),
         field when field > 0 <- div(key, 8),
         wire <- rem(key, 8),
         {:ok, value, next} <- decode_protobuf_value(wire, rest) do
      decode_protobuf_fields(next, [{field, wire, value} | acc])
    else
      _ -> {:error, :invalid_protobuf}
    end
  end

  defp decode_protobuf_value(0, binary) do
    with {:ok, value, rest} <- decode_varint(binary), do: {:ok, value, rest}
  end

  defp decode_protobuf_value(1, <<value::unsigned-little-integer-size(64), rest::binary>>),
    do: {:ok, value, rest}

  defp decode_protobuf_value(2, binary) do
    with {:ok, size, rest} <- decode_varint(binary),
         true <- byte_size(rest) >= size do
      <<value::binary-size(size), next::binary>> = rest
      {:ok, value, next}
    else
      _ -> {:error, :invalid_protobuf}
    end
  end

  defp decode_protobuf_value(5, <<value::unsigned-little-integer-size(32), rest::binary>>),
    do: {:ok, value, rest}

  defp decode_protobuf_value(_wire, _binary), do: {:error, :unsupported_protobuf_wire_type}

  defp decode_varint(binary), do: decode_varint(binary, 0, 0)

  defp decode_varint(<<byte, rest::binary>>, shift, acc) when shift < 64 do
    value = acc ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {:ok, value, rest}
    else
      decode_varint(rest, shift + 7, value)
    end
  end

  defp decode_varint(_binary, _shift, _acc), do: {:error, :invalid_varint}

  defp decode_float32(value) when is_integer(value) do
    <<float::little-float-32>> = <<value::unsigned-little-integer-size(32)>>
    float
  end

  defp token_type(1), do: "requests"
  defp token_type(2), do: "wtus"
  defp token_type(value), do: "token_type_#{value}"

  defp grpc_frame(message) when is_binary(message) do
    <<0, byte_size(message)::unsigned-big-integer-size(32), message::binary>>
  end

  defp encode_string_field(field, value) do
    encoded = to_string(value)
    encode_varint(field <<< 3 ||| 2) <> encode_varint(byte_size(encoded)) <> encoded
  end

  defp encode_varint(value) when is_integer(value) and value >= 0 do
    do_encode_varint(value, [])
  end

  defp do_encode_varint(value, acc) when value < 0x80 do
    acc
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> Kernel.<>(<<value>>)
  end

  defp do_encode_varint(value, acc) do
    do_encode_varint(value >>> 7, [<<(value &&& 0x7F) ||| 0x80>> | acc])
  end

  defp grpc_status(response), do: response_header(response, "grpc-status")
  defp grpc_message(response), do: response_header(response, "grpc-message")

  defp config_value(map, key) when is_map(map) do
    map
    |> value(key)
    |> normalize_optional_string()
  end

  defp receive_timeout(config) do
    case value(config, "receive_timeout_ms") do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      timeout when is_binary(timeout) -> parse_positive_integer(timeout, @default_receive_timeout)
      _ -> @default_receive_timeout
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp retry_after(%Req.Response{} = response) do
    response
    |> response_header("retry-after")
    |> parse_retry_after()
  end

  defp response_header(%Req.Response{headers: headers}, name) do
    normalized = String.downcase(name)

    Enum.find_value(headers || [], fn
      {key, [value | _]} when is_binary(value) ->
        if String.downcase(to_string(key)) == normalized, do: value

      {key, value} when is_binary(value) ->
        if String.downcase(to_string(key)) == normalized, do: value

      _ ->
        nil
    end)
  end

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> nil
    end
  end

  defp req_options(url) do
    case Application.fetch_env(:backplane, :google_antigravity_monitor_req_options) do
      {:ok, opts} -> opts
      :error -> default_req_options(url)
    end
  end

  defp default_req_options(url) do
    case proxy_connect_options(url) do
      [] -> [inet6: true]
      connect_options -> [connect_options: connect_options]
    end
  end

  defp proxy_connect_options(url) do
    uri = URI.parse(url)

    if proxy_bypassed?(uri.host) do
      []
    else
      uri.scheme
      |> proxy_url_from_env()
      |> proxy_connect_options_from_url()
    end
  end

  defp proxy_url_from_env("https") do
    env("HTTPS_PROXY") || env("https_proxy") ||
      env("HTTP_PROXY") || env("http_proxy") ||
      env("ALL_PROXY") || env("all_proxy")
  end

  defp proxy_url_from_env("http") do
    env("HTTP_PROXY") || env("http_proxy") ||
      env("ALL_PROXY") || env("all_proxy")
  end

  defp proxy_url_from_env(_scheme), do: nil

  defp proxy_connect_options_from_url(nil), do: []

  defp proxy_connect_options_from_url(proxy_url) do
    uri = URI.parse(proxy_url)
    scheme = proxy_scheme(uri.scheme)

    cond do
      is_nil(scheme) or is_nil(uri.host) ->
        []

      is_binary(uri.userinfo) and uri.userinfo != "" ->
        [
          proxy: {scheme, uri.host, uri.port || default_proxy_port(scheme), []},
          proxy_headers: [{"proxy-authorization", "Basic " <> Base.encode64(uri.userinfo)}]
        ]

      true ->
        [proxy: {scheme, uri.host, uri.port || default_proxy_port(scheme), []}]
    end
  end

  defp proxy_scheme("http"), do: :http
  defp proxy_scheme("https"), do: :https
  defp proxy_scheme(_), do: nil

  defp default_proxy_port(:http), do: 80
  defp default_proxy_port(:https), do: 443

  defp proxy_bypassed?(nil), do: false

  defp proxy_bypassed?(host) do
    no_proxy = env("NO_PROXY") || env("no_proxy")
    no_proxy && no_proxy_match?(String.downcase(host), no_proxy)
  end

  defp no_proxy_match?(host, no_proxy) do
    no_proxy
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&no_proxy_entry_match?(host, String.downcase(&1)))
  end

  defp no_proxy_entry_match?(_host, "*"), do: true
  defp no_proxy_entry_match?(_host, ""), do: false

  defp no_proxy_entry_match?(host, "*." <> domain) do
    host == domain or String.ends_with?(host, "." <> domain)
  end

  defp no_proxy_entry_match?(host, "." <> domain) do
    host == domain or String.ends_with?(host, "." <> domain)
  end

  defp no_proxy_entry_match?(host, entry), do: host == entry

  defp env(name) do
    name
    |> System.get_env()
    |> normalize_optional_string()
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil
end
