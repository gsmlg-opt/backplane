defmodule Backplane.Observability.Error do
  @moduledoc false

  @max_message_bytes 512
  @redacted "[REDACTED]"

  @doc "Normalizes an error into the shared observability error map."
  @spec normalize(term(), keyword()) :: map()
  def normalize(reason, opts \\ []) do
    kind = Keyword.get(opts, :kind, classify_kind(reason))
    code = Keyword.get(opts, :code, classify_code(reason))
    source = Keyword.get(opts, :source, "backplane")
    retryable = Keyword.get(opts, :retryable, classify_retryable(kind))

    %{
      kind: to_string(kind),
      code: code && to_string(code),
      message: normalize_message(reason),
      source: to_string(source),
      retryable: retryable
    }
  end

  defp classify_kind({:error, :not_found}), do: :routing
  defp classify_kind({:error, :rate_limited}), do: :rate_limit
  defp classify_kind({:error, :timeout}), do: :timeout
  defp classify_kind({:error, :unauthorized}), do: :auth
  defp classify_kind({:error, :forbidden}), do: :auth
  defp classify_kind({:error, _}), do: :internal
  defp classify_kind(%Plug.Conn{}), do: :internal
  defp classify_kind(%{__struct__: _} = exception) when is_exception(exception), do: :internal
  defp classify_kind(_), do: :internal

  defp classify_code({:error, code}) when is_atom(code), do: code
  defp classify_code(%{__struct__: _} = exception) when is_exception(exception), do: exception.__struct__
  defp classify_code(%Plug.Conn{status: status}) when is_integer(status), do: status
  defp classify_code(_), do: nil

  defp classify_retryable(kind) when kind in [:timeout, :upstream, :rate_limit], do: true
  defp classify_retryable(_), do: false

  defp normalize_message(reason) do
    reason
    |> message_for(reason)
    |> Backplane.Observability.Redaction.redact()
    |> truncate_message()
  end

  defp message_for(%{__struct__: _} = exception, _) when is_exception(exception),
    do: Exception.message(exception)

  defp message_for(%Plug.Conn{status: status, resp_body: body}, _) when is_integer(status),
    do: "HTTP #{status}: #{inspect(body)}"

  defp message_for({:error, reason}, _), do: inspect(reason)
  defp message_for(reason, _) when is_binary(reason), do: reason
  defp message_for(reason, _), do: inspect(reason)

  defp truncate_message(message) when is_binary(message) do
    if byte_size(message) > @max_message_bytes do
      binary_part(message, 0, @max_message_bytes) <> "…"
    else
      message
    end
  end

  defp truncate_message(_), do: @redacted
end
