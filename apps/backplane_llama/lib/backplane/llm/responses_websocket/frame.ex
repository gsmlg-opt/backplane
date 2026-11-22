defmodule Backplane.LLM.ResponsesWebSocket.Frame do
  @moduledoc false

  # Early rejections bypass the worker that decodes full messages. Keep error
  # correlation on the session process bounded independently of the frame limit.
  @early_correlation_bytes 16_384

  def context(%{"type" => "response.create", "stream_id" => lane}) do
    case stream_id(lane) do
      nil -> nil
      id -> {:stream_id, id}
    end
  end

  def context(%{"type" => "response.steer", "previous_response_id" => id})
      when is_binary(id) and byte_size(id) in 1..128,
      do: {:steer, :binary.copy(id)}

  def context(%{"type" => "response.steer"}), do: {:steer, nil}
  def context(_event), do: nil

  def early_context(bytes) when byte_size(bytes) <= @early_correlation_bytes do
    case Formata.JSON.decode(bytes) do
      {:ok, event} -> context(event)
      _ -> nil
    end
  end

  def early_context(_bytes), do: nil

  def stream_id(id) when is_binary(id) and byte_size(id) in 1..256 do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, id), do: :binary.copy(id)
  end

  def stream_id(_id), do: nil

  def error_event(status, code, metadata) do
    event = %{type: "error", status: status, error: error_details(status, code, metadata)}

    event =
      case metadata do
        %{stream_id: id} when is_binary(id) -> Map.put(event, :stream_id, id)
        _ -> event
      end

    with %{headers: headers} <- metadata,
         retry_after when is_binary(retry_after) and byte_size(retry_after) <= 128 <-
           HTTP.Headers.get(headers, "retry-after") do
      Map.put(event, :headers, %{"retry-after" => retry_after})
    else
      _ -> event
    end
  end

  defp error_details(status, code, %{steer?: true}),
    do: %{type: error_type(status), code: code, message: code, param: nil}

  defp error_details(_status, code, _metadata), do: %{code: code, message: code}

  defp error_type(429), do: "rate_limit_error"
  defp error_type(_status), do: "invalid_request_error"
end
