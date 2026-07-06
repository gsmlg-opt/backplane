defmodule Backplane.HostAgent.Services.Day do
  @moduledoc """
  Local MCP service providing date/time tools via day_ex.
  """

  @behaviour Backplane.HostAgent.LocalService

  @impl true
  def prefix, do: "day"

  @impl true
  def tools do
    [
      %{
        "name" => "day::now",
        "description" => "Get the current date and time in a given timezone",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "timezone" => %{"type" => "string", "description" => "IANA timezone (default: UTC)"}
          }
        }
      },
      %{
        "name" => "day::format",
        "description" => "Format a date/time string with a given pattern",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "datetime" => %{"type" => "string", "description" => "ISO 8601 datetime string"},
            "format" => %{"type" => "string", "description" => "Format pattern (e.g. YYYY-MM-DD)"},
            "timezone" => %{"type" => "string", "description" => "IANA timezone (default: UTC)"}
          },
          "required" => ["datetime"]
        }
      },
      %{
        "name" => "day::parse",
        "description" => "Parse a date/time string",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "input" => %{"type" => "string", "description" => "Date/time string to parse"},
            "format" => %{"type" => "string", "description" => "Expected format pattern"}
          },
          "required" => ["input"]
        }
      },
      %{
        "name" => "day::diff",
        "description" => "Calculate the difference between two dates",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "from" => %{"type" => "string", "description" => "Start datetime (ISO 8601)"},
            "to" => %{"type" => "string", "description" => "End datetime (ISO 8601)"},
            "unit" => %{
              "type" => "string",
              "description" => "Unit: year, month, day, hour, minute, second, millisecond"
            }
          },
          "required" => ["from", "to"]
        }
      }
    ]
  end

  @impl true
  def call("now", args, _ctx) when is_map(args), do: handle_now(args)
  def call("format", args, _ctx) when is_map(args), do: handle_format(args)
  def call("parse", args, _ctx) when is_map(args), do: handle_parse(args)
  def call("diff", args, _ctx) when is_map(args), do: handle_diff(args)
  def call(method, _args, _ctx) when is_binary(method), do: {:error, {:unknown_method, method}}

  def handle_now(args) do
    tz = args["timezone"] || "Etc/UTC"
    day = DayEx.utc() |> DayEx.tz(tz)
    {:ok, %{iso: to_string(day), timezone: tz, unix: DayEx.to_unix(day)}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def handle_format(args) do
    format = args["format"] || "YYYY-MM-DDTHH:mm:ssZ"

    with {:ok, day} <- DayEx.parse(args["datetime"]) do
      day =
        if tz = args["timezone"] do
          DayEx.tz(day, tz)
        else
          day
        end

      {:ok, %{formatted: DayEx.format(day, format)}}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def handle_parse(args) do
    result =
      case args["format"] do
        nil -> DayEx.parse(args["input"])
        fmt -> DayEx.parse(args["input"], fmt)
      end

    case result do
      {:ok, day} -> {:ok, %{iso: to_string(day), unix: DayEx.to_unix(day)}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def handle_diff(args) do
    unit_str = args["unit"] || "day"
    unit = string_to_unit(unit_str)

    with {:ok, from} <- DayEx.parse(args["from"]),
         {:ok, to} <- DayEx.parse(args["to"]) do
      diff = DayEx.diff(to, from, unit)
      {:ok, %{diff: diff, unit: unit_str}}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp string_to_unit("year"), do: :year
  defp string_to_unit("years"), do: :year
  defp string_to_unit("month"), do: :month
  defp string_to_unit("months"), do: :month
  defp string_to_unit("week"), do: :week
  defp string_to_unit("weeks"), do: :week
  defp string_to_unit("day"), do: :day
  defp string_to_unit("days"), do: :day
  defp string_to_unit("hour"), do: :hour
  defp string_to_unit("hours"), do: :hour
  defp string_to_unit("minute"), do: :minute
  defp string_to_unit("minutes"), do: :minute
  defp string_to_unit("second"), do: :second
  defp string_to_unit("seconds"), do: :second
  defp string_to_unit("millisecond"), do: :millisecond
  defp string_to_unit("milliseconds"), do: :millisecond
  defp string_to_unit(_), do: :day
end
