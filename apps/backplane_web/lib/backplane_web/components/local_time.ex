defmodule BackplaneWeb.Components.LocalTime do
  use Phoenix.Component

  attr :id, :string, default: nil
  attr :datetime, :any, required: true
  attr :format, :string, default: nil
  attr :class, :string, default: nil

  def local_time(assigns) do
    if is_nil(assigns.datetime) or assigns.datetime == "" do
      ~H"""
      {fallback_text(@datetime, @format)}
      """
    else
      id = assigns[:id] || "lt-#{to_iso8601(assigns.datetime) |> String.replace(~r/[^a-zA-Z0-9]/, "-")}"
      assigns = assign(assigns, :id, id)

      ~H"""
      <local-time id={@id} datetime={to_iso8601(@datetime)} format={@format} class={@class} phx-update="ignore">
        {fallback_text(@datetime, @format)}
      </local-time>
      """
    end
  end

  defp to_iso8601(nil), do: ""
  defp to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp to_iso8601(str) when is_binary(str), do: str
  defp to_iso8601(_), do: ""

  defp fallback_text(nil, _), do: "-"

  defp fallback_text(%DateTime{} = dt, "time") do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp fallback_text(%NaiveDateTime{} = dt, "time") do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp fallback_text(%DateTime{} = dt, "short") do
    Calendar.strftime(dt, "%m/%d %H:%M UTC")
  end

  defp fallback_text(%NaiveDateTime{} = dt, "short") do
    Calendar.strftime(dt, "%m/%d %H:%M UTC")
  end

  defp fallback_text(%DateTime{} = dt, _) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp fallback_text(%NaiveDateTime{} = dt, _) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp fallback_text(str, _) when is_binary(str), do: str
  defp fallback_text(_, _), do: "-"
end
