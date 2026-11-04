defmodule Backplane.LLM.ResponsesLifecycleMapper do
  @moduledoc """
  Fail-closed ID binding before response bytes become visible. SSE frames retain
  their original bytes; only an incomplete frame and the pre-ID prefix are held.
  This is deliberately separate from the best-effort usage observer and terminal
  response codec. Native queued/in_progress objects do not pass through a codec.
  """

  alias Backplane.LLM.ResponseRoute

  @max_frame_bytes 1_048_576
  @max_json_bytes 50_000_000
  @statuses ~w(queued in_progress completed failed cancelled incomplete)

  def init(status, headers, {route, operation}) do
    encoding = header(headers, "content-encoding")

    cond do
      status not in 200..299 ->
        {:ok, %{mode: :passthrough}}

      encoding not in [nil, "", "identity"] ->
        {:error, :responses_encoding_unsupported}

      true ->
        {:ok,
         %{
           mode:
             if(String.starts_with?(header(headers, "content-type") || "", "text/event-stream"),
               do: :sse,
               else: :json
             ),
           route: route,
           operation: operation,
           bound: operation != :create,
           error_seen: false,
           status: nil,
           buffer: "",
           prefix: ""
         }}
    end
  end

  def feed(%{mode: :passthrough} = state, bytes), do: {:ok, state, [bytes]}

  def feed(%{mode: :json} = state, bytes) do
    buffer = state.buffer <> bytes

    if byte_size(buffer) > @max_json_bytes,
      do: fail(state, :response_too_large),
      else: {:ok, %{state | buffer: buffer}, []}
  end

  def feed(%{mode: :sse} = state, bytes) do
    frames(%{state | buffer: state.buffer <> bytes}, [])
  end

  def finish(%{mode: :passthrough} = state, _reason), do: {:ok, state, []}

  def finish(%{mode: :json} = state, :eof) do
    case record_body(state.route, state.operation, state.buffer) do
      :ok -> {:ok, %{state | buffer: ""}, [state.buffer]}
      {:error, code} -> fail(state, code)
    end
  end

  def finish(%{mode: :sse, bound: true, buffer: ""} = state, :eof),
    do: {:ok, state, []}

  def finish(%{mode: :sse, error_seen: true, buffer: ""} = state, :eof),
    do: {:ok, state, []}

  def finish(%{mode: :sse, bound: true} = state, :eof) do
    # An unterminated final frame is preserved only if the ID is already durable.
    {:ok, %{state | buffer: ""}, [state.buffer]}
  end

  def finish(state, reason) do
    if state.operation == :create, do: ResponseRoute.uncertain(state.route)

    if reason == :cancelled,
      do: {:ok, state, []},
      else: fail(state, :response_outcome_uncertain)
  end

  def body(route, operation, previous, status, headers, bytes) when status in 200..299 do
    with true <- header(headers, "content-encoding") in [nil, "", "identity"],
         :ok <- record_body(route, operation, bytes) do
      if is_function(previous, 1), do: previous.(bytes), else: bytes
    else
      false -> body_error(:responses_encoding_unsupported, headers)
      {:error, code} -> body_error(code, headers)
    end
  end

  def body(_route, _operation, _previous, _status, _headers, bytes), do: bytes

  defp record_body(route, :delete, bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"id" => id, "deleted" => true}} when id == route.response_id ->
        ResponseRoute.mark(route, "deleted")

      _ ->
        {:error, :responses_invalid_upstream_response}
    end
  end

  defp record_body(route, operation, bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"id" => id} = document} -> record(route, operation, id, document["status"])
      _ -> {:error, :responses_invalid_upstream_response}
    end
  end

  defp record(route, :create, id, status), do: ResponseRoute.bind(route, id, status)

  defp record(route, _operation, id, status) when id == route.response_id,
    do: ResponseRoute.mark(route, safe_status(status))

  defp record(_route, _operation, _id, _status), do: {:error, :response_route_changed}

  defp frames(state, output) do
    case Regex.run(~r/\r?\n\r?\n/, state.buffer, return: :index) do
      [{position, length}] ->
        size = position + length

        if size + byte_size(state.prefix) > @max_frame_bytes do
          fail(state, :responses_frame_too_large, output)
        else
          <<frame::binary-size(size), rest::binary>> = state.buffer

          case frame_record(state, frame) do
            {:ok, next_state} ->
              {next_state, emitted} = release_frame(next_state, frame)
              frames(%{next_state | buffer: rest}, [emitted | output])

            {:error, code} ->
              fail(state, code, output)
          end
        end

      nil ->
        if byte_size(state.buffer) + byte_size(state.prefix) > @max_frame_bytes,
          do: fail(state, :responses_frame_too_large, output),
          else: {:ok, state, Enum.reverse(output)}
    end
  end

  defp frame_record(state, frame) do
    data =
      frame
      |> String.split(~r/\r?\n/)
      |> Enum.flat_map(fn
        "data: " <> value -> [value]
        "data:" <> value -> [value]
        _ -> []
      end)
      |> Enum.join("\n")

    case Jason.decode(data) do
      {:ok, %{"response" => %{"id" => id} = response, "type" => "response." <> _}} ->
        update_record(state, id, response["status"])

      {:ok, %{"type" => "error"}} ->
        # An upstream stream error is diagnostic data, not a recoverable ID.
        # Keep the original frame, including its sequence number and error body.
        {:ok, %{state | error_seen: true}}

      _ ->
        {:ok, state}
    end
  end

  defp update_record(%{bound: false} = state, id, status) do
    case ResponseRoute.bind(state.route, id, safe_status(status)) do
      :ok ->
        {:ok, %{state | bound: true, route: %{state.route | response_id: id}, status: status}}

      {:error, code} ->
        {:error, code}
    end
  end

  defp update_record(%{bound: true} = state, id, status) do
    cond do
      id != state.route.response_id ->
        {:error, :response_route_changed}

      status == state.status ->
        {:ok, state}

      true ->
        case ResponseRoute.mark(state.route, safe_status(status)) do
          :ok -> {:ok, %{state | status: status}}
          {:error, code} -> {:error, code}
        end
    end
  end

  defp release_frame(%{bound: true} = state, frame),
    do: {%{state | prefix: ""}, state.prefix <> frame}

  defp release_frame(%{error_seen: true} = state, frame),
    do: {%{state | prefix: ""}, state.prefix <> frame}

  defp release_frame(state, frame), do: {%{state | prefix: state.prefix <> frame}, ""}

  defp safe_status(status) when status in @statuses, do: status
  defp safe_status(_), do: "in_progress"

  defp fail(state, code, output \\ []) do
    if state[:operation] == :create, do: ResponseRoute.uncertain(state.route)

    body =
      Jason.encode!(%{
        type: "error",
        code: code,
        message:
          "Responses recovery unavailable; reconcile the same response, do not resubmit generation"
      })

    bytes = if state.mode == :sse, do: "event: error\ndata: " <> body <> "\n\n", else: body
    {:error, code, %{state | buffer: "", prefix: ""}, Enum.reverse(output) ++ [bytes]}
  end

  defp body_error(code, headers) do
    status =
      case code do
        :response_id_conflict -> 409
        :response_route_changed -> 409
        :response_expired -> 410
        :responses_index_unavailable -> 503
        _ -> 502
      end

    headers =
      Enum.reject(headers, fn {name, _} ->
        String.downcase(name) in ~w(content-type content-length content-encoding x-should-retry)
      end)

    {:error, code, status,
     [{"content-type", "application/json"}, {"x-should-retry", "false"} | headers],
     Jason.encode!(%{
       error: %{
         code: code,
         message:
           "Responses ID could not be persisted; submission outcome may be uncertain; do not resubmit generation"
       }
     })}
  end

  defp header(headers, name),
    do:
      Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)
end
