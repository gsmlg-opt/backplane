defmodule Backplane.McpProtocol.Sse do
  @moduledoc """
  Pure helpers for Server-Sent Events frames.
  """

  @spec encode(String.t(), term()) :: String.t()
  def encode(event, data) when is_binary(event) do
    encoded_data = if is_binary(data), do: data, else: Jason.encode!(data)

    "event: #{event}\n" <>
      "data: #{encoded_data}\n\n"
  end

  @spec parse(String.t()) :: {[%{event: String.t(), data: String.t()}], String.t()}
  def parse(buffer) when is_binary(buffer) do
    {frames, rest} = split_complete_frames(buffer)

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
    lines = String.split(frame, "\n", trim: true)
    event = field_value(lines, "event")
    data = field_value(lines, "data")

    if event && data do
      %{event: event, data: data}
    end
  end

  defp field_value(lines, field) do
    prefix = field <> ": "

    lines
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, "")
    end)
  end
end
