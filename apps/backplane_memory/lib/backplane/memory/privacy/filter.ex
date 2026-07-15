defmodule Backplane.Memory.Privacy.Filter do
  @content_max_bytes 65_536
  @payload_max_bytes 262_144
  @sensitive ~r/(^|_)(authorization|cookie|set_cookie|password|secret|token|api_key|access_key|access_key_id)(_|$)/i

  def apply(content) when is_binary(content), do: {:ok, sanitize_string(content)}

  def apply(_), do: {:ok, ""}

  def apply_event(event) when is_map(event) do
    with :ok <- validate_utf8(event) do
      filter_event(event)
    end
  end

  defp filter_event(event) do
    clean = sanitize(event)
    full_content = normalize_content(get(clean, :content, ""))
    {content, cmeta} = content_meta(full_content)
    full_payload = normalize_payload(get(clean, :payload, %{}))

    fp_payload =
      full_payload
      |> Map.delete("_backplane")
      |> Map.delete(:_backplane)

    fp_data = %{
      stream_id: get(clean, :stream_id, nil),
      event_type: get(clean, :event_type, nil),
      content: full_content,
      payload: fp_payload
    }

    fp =
      if is_nil(get(clean, :idempotency_key, nil)),
        do: nil,
        else: digest(Jason.encode!(canonical_json(fp_data)))

    bp = %{"content" => cmeta}
    bp = if is_nil(fp), do: bp, else: Map.put(bp, "event_fingerprint", fp)
    payload = bound_payload(full_payload, bp)

    {:ok,
     clean
     |> Map.put(:content, content)
     |> Map.put(:payload, payload)}
  end

  defp validate_utf8(value), do: if(valid_utf8?(value), do: :ok, else: {:error, :invalid_utf8})

  defp valid_utf8?(value) when is_binary(value), do: String.valid?(value)
  defp valid_utf8?(value) when is_struct(value), do: true

  defp valid_utf8?(value) when is_map(value),
    do: Enum.all?(value, fn {key, nested} -> valid_utf8?(key) and valid_utf8?(nested) end)

  defp valid_utf8?([]), do: true
  defp valid_utf8?([head | tail]), do: valid_utf8?(head) and valid_utf8?(tail)
  defp valid_utf8?(_), do: true

  defp get(m, key, default), do: Map.get(m, key, Map.get(m, Atom.to_string(key), default))

  defp content_meta(content) when is_binary(content) do
    bytes = byte_size(content)

    if bytes <= @content_max_bytes,
      do:
        {content,
         %{
           "truncated" => false,
           "original_bytes" => bytes,
           "sha256" => digest(content),
           "preview" => preview(content)
         }},
      else:
        {truncate(content, @content_max_bytes),
         %{
           "truncated" => true,
           "original_bytes" => bytes,
           "sha256" => digest(content),
           "preview" => preview(content)
         }}
  end

  defp content_meta(_), do: content_meta("")

  defp bound_payload(full_payload, backplane) do
    candidate = put_backplane(full_payload, backplane)

    if byte_size(Jason.encode!(candidate)) <= @payload_max_bytes do
      candidate
    else
      encoded = Jason.encode!(full_payload)

      payload_meta = %{
        "truncated" => true,
        "original_bytes" => byte_size(encoded),
        "sha256" => digest(encoded),
        "preview" => preview(encoded)
      }

      %{"_backplane" => Map.put(backplane, "payload", payload_meta)}
    end
  end

  defp put_backplane(payload, backplane) do
    payload
    |> Map.delete(:_backplane)
    |> Map.update("_backplane", backplane, fn
      existing when is_map(existing) -> Map.merge(existing, backplane)
      _ -> backplane
    end)
  end

  defp truncate(s, max),
    do:
      Enum.reduce_while(String.graphemes(s), {[], 0}, fn g, {acc, n} ->
        b = byte_size(g)
        if n + b <= max, do: {:cont, {[g | acc], n + b}}, else: {:halt, {acc, n}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

  defp preview(s) do
    s
    |> String.graphemes()
    |> Enum.take(512)
    |> Enum.join()
    |> truncate(@content_max_bytes)
  end

  defp digest(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(_), do: ""
  defp normalize_payload(payload) when is_map(payload) and not is_struct(payload), do: payload
  defp normalize_payload(_), do: %{}

  defp canonical_json(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical_json(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value

  defp strip_null_bytes(s), do: String.replace(s, <<0>>, "")
  defp strip_private_tags(s), do: Regex.replace(~r/<private>.*?<\/private>/s, s, "[REDACTED]")

  defp redact_secrets(s) do
    Enum.reduce(
      [
        ~r/sk-[A-Za-z0-9_-]{20,}/,
        ~r/AKIA[0-9A-Z]{16}/,
        ~r/gh[pohur]_[A-Za-z0-9]{36,}/,
        ~r/(?i)(?:api[_-]?key|access[_-]?token)\s*[:=]\s*["']?[A-Za-z0-9+\/_-]{20,}["']?/,
        ~r/(?i)Authorization\s*:\s*Bearer\s+[A-Za-z0-9._~+\/-]+=*/,
        ~r/(?i)\b(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|access[_-]?token)\b\s*[:=]\s*(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}\]]+)/
      ],
      s,
      fn pattern, acc -> Regex.replace(pattern, acc, "[REDACTED]") end
    )
  end

  defp sanitize_string(s),
    do: s |> strip_null_bytes() |> strip_private_tags() |> redact_secrets()

  defp sanitize(v) when is_struct(v), do: v

  defp sanitize(%{} = m),
    do:
      Enum.reduce(m, %{}, fn {k, v}, acc ->
        sensitive = sensitive?(k)
        key = sanitize_key(k)
        sensitive = sensitive or sensitive?(key)
        value = if(sensitive, do: "[REDACTED]", else: sanitize(v))
        Map.put(acc, key, value)
      end)

  defp sanitize([key, value]) when is_binary(key) do
    sensitive = sensitive?(key)
    key = sanitize_key(key)
    sensitive = sensitive or sensitive?(key)
    value = if(sensitive, do: "[REDACTED]", else: sanitize(value))
    [key, value]
  end

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(v) when is_binary(v), do: sanitize_string(v)
  defp sanitize(v), do: v
  defp sanitize_key(k) when is_binary(k), do: sanitize_string(k)
  defp sanitize_key(k), do: k

  defp sensitive?(k) when is_binary(k),
    do: Regex.match?(@sensitive, normalize_sensitive_key(k))

  defp sensitive?(k) when is_atom(k), do: k |> Atom.to_string() |> sensitive?()

  defp sensitive?(_), do: false

  defp normalize_sensitive_key(key) do
    key
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.replace(~r/[^A-Za-z0-9]+/u, "_")
    |> String.downcase()
  end
end
