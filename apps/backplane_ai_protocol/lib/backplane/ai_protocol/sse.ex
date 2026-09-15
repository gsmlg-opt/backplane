defmodule Backplane.AiProtocol.SSE do
  @moduledoc "Bounded incremental Server-Sent Events framing."

  alias Backplane.AiProtocol.Error

  defstruct buffer: "", max_frame_bytes: 262_144, max_buffer_bytes: 524_288, closed?: false

  @type event :: %{event: String.t() | nil, data: String.t()}
  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_frame_bytes: Keyword.get(opts, :max_frame_bytes, 262_144),
      max_buffer_bytes: Keyword.get(opts, :max_buffer_bytes, 524_288)
    }
  end

  @spec feed(t(), binary()) :: {:ok, t(), [event()]} | {:error, Error.t(), t()}
  def feed(%__MODULE__{closed?: true} = state, _chunk),
    do: {:error, Error.invalid!("SSE framer is closed"), state}

  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    buffer = state.buffer <> chunk

    if byte_size(buffer) > state.max_buffer_bytes do
      {:error, Error.invalid!("SSE buffer exceeds #{state.max_buffer_bytes} bytes"),
       %{state | buffer: "", closed?: true}}
    else
      frame_buffer(%{state | buffer: buffer}, [])
    end
  end

  def feed(%__MODULE__{} = state, _),
    do: {:error, Error.invalid!("SSE chunk must be a binary"), %{state | closed?: true}}

  @spec finish(t()) :: {:ok, t(), [event()]} | {:error, Error.t(), t()}
  def finish(%__MODULE__{closed?: true} = state), do: {:ok, state, []}

  def finish(%__MODULE__{} = state) do
    case String.trim(state.buffer) do
      "" ->
        {:ok, %{state | buffer: "", closed?: true}, []}

      _ ->
        case parse_frame(state.buffer, state.max_frame_bytes) do
          {:ok, nil} -> {:ok, %{state | buffer: "", closed?: true}, []}
          {:ok, event} -> {:ok, %{state | buffer: "", closed?: true}, [event]}
          {:error, error} -> {:error, error, %{state | buffer: "", closed?: true}}
        end
    end
  end

  defp frame_buffer(state, acc) do
    case next_delimiter(state.buffer) do
      nil ->
        {:ok, state, Enum.reverse(acc)}

      {index, length} ->
        <<frame::binary-size(^index), _delimiter::binary-size(^length), rest::binary>> =
          state.buffer

        case parse_frame(frame, state.max_frame_bytes) do
          {:ok, nil} -> frame_buffer(%{state | buffer: rest}, acc)
          {:ok, event} -> frame_buffer(%{state | buffer: rest}, [event | acc])
          {:error, error} -> {:error, error, %{state | buffer: rest, closed?: true}}
        end
    end
  end

  defp next_delimiter(buffer) do
    ["\r\n\r\n", "\n\n", "\r\r"]
    |> Enum.flat_map(fn delimiter ->
      case :binary.match(buffer, delimiter) do
        {index, length} -> [{index, length}]
        :nomatch -> []
      end
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
  end

  defp parse_frame(frame, max) when byte_size(frame) > max,
    do: {:error, Error.invalid!("SSE frame exceeds #{max} bytes")}

  defp parse_frame(frame, _max) do
    lines = String.split(frame, ~r/\r\n|\r|\n/, trim: false)

    {event, data} =
      Enum.reduce(lines, {nil, []}, fn
        ":" <> _, acc -> acc
        "event:" <> value, {_event, data} -> {trim_optional_space(value), data}
        "data:" <> value, {event, data} -> {event, [trim_optional_space(value) | data]}
        _line, acc -> acc
      end)

    case Enum.reverse(data) do
      [] -> {:ok, nil}
      values -> {:ok, %{event: event, data: Enum.join(values, "\n")}}
    end
  rescue
    _ -> {:error, Error.invalid!("Invalid SSE frame")}
  end

  defp trim_optional_space(" " <> value), do: value
  defp trim_optional_space(value), do: value
end
