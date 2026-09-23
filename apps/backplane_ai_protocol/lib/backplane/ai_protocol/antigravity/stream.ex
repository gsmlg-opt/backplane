defmodule Backplane.AiProtocol.Antigravity.Stream do
  @moduledoc "Bounded native SSE document decoder for Antigravity streaming responses."

  alias Backplane.AiProtocol.{Error, Serialization, SSE}

  defstruct sse: nil,
            max_total_bytes: 8_388_608,
            bytes_seen: 0,
            events_seen: 0,
            max_events: 10_000,
            protocol_terminal: nil,
            terminal: nil

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      sse: SSE.new(opts),
      max_total_bytes: positive(opts[:max_total_bytes], 8_388_608),
      max_events: positive(opts[:max_events], 10_000)
    }
  end

  @spec feed(t(), term()) :: {:ok, t(), [map()]} | {:error, Error.t(), t()}
  def feed(%__MODULE__{terminal: terminal} = state, _chunk) when not is_nil(terminal),
    do: {:error, Error.invalid!("Antigravity stream is closed"), state}

  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    bytes_seen = state.bytes_seen + byte_size(chunk)

    if bytes_seen > state.max_total_bytes do
      error = Error.invalid!("Antigravity stream exceeds #{state.max_total_bytes} bytes")
      {:error, error, %{state | bytes_seen: bytes_seen, terminal: :incomplete}}
    else
      case SSE.feed(state.sse, chunk) do
        {:ok, sse, events} -> decode_events(%{state | sse: sse, bytes_seen: bytes_seen}, events)
        {:error, error, sse} -> {:error, error, %{state | sse: sse, terminal: :incomplete}}
      end
    end
  end

  def feed(%__MODULE__{} = state, _chunk),
    do:
      {:error, Error.invalid!("Antigravity stream chunk must be binary"),
       %{state | terminal: :incomplete}}

  @spec finish(t(), atom()) :: {:ok, t(), [map()]} | {:error, Error.t(), t()}
  def finish(%__MODULE__{terminal: terminal} = state, _reason) when not is_nil(terminal),
    do: {:error, Error.invalid!("Antigravity stream is closed"), state}

  def finish(%__MODULE__{} = state, :eof) do
    case SSE.finish(state.sse) do
      {:ok, sse, events} ->
        case decode_events(%{state | sse: sse}, events) do
          {:ok, state, documents} -> {:ok, %{state | terminal: :eof}, documents}
          error -> error
        end

      {:error, error, sse} ->
        {:error, error, %{state | sse: sse, terminal: :incomplete}}
    end
  end

  def finish(%__MODULE__{} = state, :cancelled) do
    error = %Error{kind: :cancelled, stage: :response, message: "Antigravity stream cancelled"}
    {:error, error, %{state | terminal: :cancelled}}
  end

  def finish(%__MODULE__{} = state, _reason) do
    error = %Error{
      kind: :upstream_error,
      stage: :response,
      message: "Antigravity stream incomplete"
    }

    {:error, error, %{state | terminal: :incomplete}}
  end

  defp decode_events(state, events) do
    if state.events_seen + length(events) > state.max_events do
      error = Error.invalid!("Antigravity stream exceeds #{state.max_events} events")
      {:error, error, %{state | terminal: :incomplete}}
    else
      Enum.reduce_while(events, {:ok, []}, fn event, {:ok, documents} ->
        case decode_event(event) do
          {:ok, document} -> {:cont, {:ok, [document | documents]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, documents} ->
          documents = Enum.reverse(documents)

          state = %{
            state
            | events_seen: state.events_seen + length(events),
              protocol_terminal:
                if(Enum.any?(documents, &error_document?/1),
                  do: :failed,
                  else: state.protocol_terminal
                )
          }

          {:ok, state, documents}

        {:error, error} ->
          {:error, error, %{state | terminal: :incomplete}}
      end
    end
  end

  defp decode_event(%{data: "[DONE]"}),
    do: {:error, Error.invalid!("Antigravity stream emitted an unsupported DONE marker")}

  defp decode_event(%{data: data}) do
    case Serialization.from_json(data) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _ -> {:error, Error.invalid!("Antigravity SSE data is not a JSON object")}
    end
  end

  defp error_document?(%{"error" => error}) when is_map(error), do: true
  defp error_document?(_document), do: false

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
