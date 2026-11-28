defmodule Backplane.CDP.CLI do
  @moduledoc """
  Command-line entry point shared by `mix cdp` and `bin/host_agent cdp`.
  """

  alias Backplane.CDP

  def main(argv) do
    case run(argv) do
      {:ok, output} ->
        IO.puts(output)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  def run(argv) when argv in [[], ["help"], ["--help"], ["-h"]] do
    lines =
      for tool <- CDP.tools() do
        command = String.replace_prefix(tool["name"], "cdp::", "")
        Enum.join([command | tool["inputSchema"]["required"]], " ") <> "  " <> tool["description"]
      end

    {:ok, Enum.join(["Usage: cdp COMMAND [ARG ...]", "" | lines], "\n")}
  end

  def run([name | values]) do
    case Enum.find(CDP.tools(), &(&1["name"] == "cdp::" <> name)) do
      nil -> {:error, "Unknown CDP command #{name}. Run cdp --help."}
      tool -> invoke(name, values, tool["inputSchema"])
    end
  end

  defp invoke(name, values, schema) do
    fields = schema["required"]

    if length(values) == length(fields) do
      args =
        Map.new(Enum.zip(fields, values), fn {key, value} ->
          {key, cli_value(value, schema["properties"][key]["type"])}
        end)

      with {:ok, _} <- Application.ensure_all_started(:backplane_cdp),
           {:ok, result} <- CDP.call(name, args) do
        {:ok, Formata.JSON.encode!(result)}
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, "Could not start CDP: #{inspect(reason)}"}
      end
    else
      {:error, "Usage: cdp " <> Enum.join([name | fields], " ")}
    end
  end

  defp cli_value(value, "number") do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp cli_value(value, _), do: value
end
