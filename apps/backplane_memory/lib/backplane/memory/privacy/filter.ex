defmodule Backplane.Memory.Privacy.Filter do
  @sensitive ~r/(^|_)(authorization|cookie|set_cookie|password|secret|token|api_key|access_key|access_key_id)(_|$)/i

  def apply(content) when is_binary(content),
    do: {:ok, content |> strip_private_tags() |> redact_secrets()}

  def apply(_), do: {:ok, ""}

  def apply_event(event) when is_map(event) do
    clean = sanitize(event)
    {content, cmeta} = content_meta(get(clean, :content, ""))
    payload = get(clean, :payload, %{})
    {payload, pmeta} = payload_meta(payload)
    full_content = get(clean, :content, "")
    full_payload = get(clean, :payload, %{})

    fp_payload =
      if is_map(full_payload),
        do: full_payload |> Map.delete("_backplane") |> Map.delete(:_backplane),
        else: full_payload

    fp_data = %{
      stream_id: Map.get(clean, :stream_id),
      event_type: Map.get(clean, :event_type),
      content: full_content,
      payload: fp_payload
    }

    fp = digest(Jason.encode!(fp_data))
    payload = if pmeta == %{}, do: payload, else: put_payload_meta(payload, pmeta, fp)
    bp = %{"content" => cmeta, "event_fingerprint" => fp}
    bp = if pmeta == %{}, do: bp, else: Map.put(bp, "payload", pmeta)
    payload =
      Map.update(payload, "_backplane", bp, fn
        existing when is_map(existing) -> Map.merge(existing, bp)
        _ -> bp
      end)

    {:ok,
     clean
     |> Map.put(:content, content)
     |> Map.put(:payload, payload)
     |> Map.put(:fingerprint, fp)}
  end

  defp get(m, key, default), do: Map.get(m, key, Map.get(m, Atom.to_string(key), default))

  defp content_meta(content) when is_binary(content) do
    bytes = byte_size(content)

    if bytes <= 65_536,
      do:
        {content,
         %{
           "truncated" => false,
           "original_bytes" => bytes,
           "sha256" => digest(content),
           "preview" => preview(content)
         }},
      else:
        {truncate(content, 65_536),
         %{
           "truncated" => true,
           "original_bytes" => bytes,
           "sha256" => digest(content),
           "preview" => preview(content)
         }}
  end

  defp content_meta(v), do: content_meta(to_string(v))

  defp payload_meta(payload) do
    enc = Jason.encode!(payload)
    bytes = byte_size(enc)

    if bytes <= 262_144,
      do: {payload, %{}},
      else:
        {%{},
         %{
           "truncated" => true,
           "original_bytes" => bytes,
           "sha256" => digest(enc),
           "preview" => truncate(enc, 512)
         }}
  end

  defp put_payload_meta(payload, meta, fp),
    do: Map.put(payload, "_backplane", %{"payload" => meta, "event_fingerprint" => fp})

  defp truncate(s, max),
    do:
      Enum.reduce_while(String.graphemes(s), {[], 0}, fn g, {acc, n} ->
        b = byte_size(g)
        if n + b <= max, do: {:cont, {[g | acc], n + b}}, else: {:halt, {acc, n}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

  defp preview(s), do: truncate(s, 512)
  defp digest(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  defp strip_private_tags(s), do: Regex.replace(~r/<private>.*?<\/private>/s, s, "[REDACTED]")

  defp redact_secrets(s) do
    Enum.reduce(
      [
        ~r/sk-[A-Za-z0-9_-]{20,}/,
        ~r/AKIA[0-9A-Z]{16}/,
        ~r/gh[pohur]_[A-Za-z0-9]{36,}/,
        ~r/(?i)(?:api[_-]?key|access[_-]?token)\s*[:=]\s*["']?[A-Za-z0-9+\/_-]{20,}["']?/,
        ~r/(?i)Authorization\s*:\s*Bearer\s+[A-Za-z0-9._~+\/-]+=*/
      ],
      s,
      fn pattern, acc -> Regex.replace(pattern, acc, "[REDACTED]") end
    )
  end

  defp sanitize(v) when is_struct(v), do: v

  defp sanitize(%{} = m),
    do:
      Enum.reduce(m, %{}, fn {k, v}, acc ->
        key = sanitize_key(k)
        value = if(sensitive?(key), do: "[REDACTED]", else: sanitize(v))
        Map.put(acc, key, value)
      end)

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(v) when is_binary(v), do: redact_secrets(String.replace(v, <<0>>, ""))
  defp sanitize(v), do: v
  defp sanitize_key(k) when is_binary(k), do: String.replace(k, <<0>>, "")
  defp sanitize_key(k), do: k

  defp sensitive?(k) when is_binary(k),
    do: Regex.match?(@sensitive, k |> String.replace("-", "_") |> String.downcase())

  defp sensitive?(k) when is_atom(k), do: k |> Atom.to_string() |> sensitive?()

  defp sensitive?(_), do: false
end
