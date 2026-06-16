defmodule Backplane.McpProtocol.Sse do
  @moduledoc """
  Pure helpers for Server-Sent Events frames.
  """

  defmodule Event do
    @moduledoc """
    Parsed Server-Sent Events frame.
    """

    @type t :: %__MODULE__{
            event: String.t(),
            data: String.t(),
            id: String.t() | nil,
            retry: non_neg_integer() | nil
          }

    defstruct event: "message", data: "", id: nil, retry: nil
  end

  @spec encode(String.t(), term()) :: String.t()
  def encode(event, data) when is_binary(event) do
    encoded_data = if is_binary(data), do: data, else: Jason.encode!(data)

    "event: #{event}\n" <>
      "data: #{encoded_data}\n\n"
  end

  @spec parse(String.t(), String.t()) :: {[Event.t()], String.t()}
  def parse(chunk, buffer \\ "") when is_binary(chunk) and is_binary(buffer) do
    input =
      (buffer <> chunk)
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")

    {frames, rest} = split_complete_frames(input)

    events =
      frames
      |> Enum.map(&parse_frame/1)
      |> Enum.reject(&is_nil/1)

    {events, rest}
  end

  defp split_complete_frames(buffer) do
    parts = String.split(buffer, "\n\n")

    case String.ends_with?(buffer, "\n\n") do
      true -> {Enum.reject(parts, &(&1 == "")), ""}
      false -> {Enum.drop(parts, -1), List.last(parts) || ""}
    end
  end

  defp parse_frame(frame) do
    parsed =
      frame
      |> String.split("\n")
      |> Enum.reduce(%{event: "message", data: [], id: nil, retry: nil}, &parse_line/2)

    case parsed.data do
      [] ->
        nil

      data ->
        %Event{
          event: parsed.event,
          data: data |> Enum.reverse() |> Enum.join("\n"),
          id: parsed.id,
          retry: parsed.retry
        }
    end
  end

  defp parse_line(":" <> _comment, event), do: event
  defp parse_line("", event), do: event

  defp parse_line(line, event) do
    case String.split(line, ":", parts: 2) do
      [field, value] -> apply_field(field, strip_leading_space(value), event)
      [_field_without_value] -> event
    end
  end

  defp strip_leading_space(" " <> value), do: value
  defp strip_leading_space(value), do: value

  defp apply_field("event", value, event), do: %{event | event: value}
  defp apply_field("data", value, event), do: %{event | data: [value | event.data]}
  defp apply_field("id", value, event), do: %{event | id: value}

  defp apply_field("retry", value, event) do
    case Integer.parse(value) do
      {retry, ""} -> %{event | retry: retry}
      _other -> event
    end
  end

  defp apply_field(_field, _value, event), do: event
end
