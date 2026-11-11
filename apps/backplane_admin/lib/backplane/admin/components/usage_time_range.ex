defmodule Backplane.Admin.Components.UsageTimeRange do
  @moduledoc "Shared UTC calendar-day presets for usage dashboards."

  use Backplane.Admin, :html

  @ranges [
    {"today", 0},
    {"yesterday", 1},
    {"week", 7},
    {"fortnight", 14},
    {"month", 30}
  ]

  defp range_label("today"), do: dgettext("common", "Today")
  defp range_label("yesterday"), do: dgettext("common", "Yesterday")
  defp range_label("week"), do: dgettext("common", "Last 7 days")
  defp range_label("fortnight"), do: dgettext("common", "Last 14 days")
  defp range_label("month"), do: dgettext("common", "Last 30 days")

  attr(:id, :string, required: true)
  attr(:action, :string, required: true)
  attr(:selected, :string, required: true)

  def usage_time_range(assigns) do
    assigns = assign(assigns, :ranges, @ranges)

    ~H"""
    <nav id={@id} aria-label={dgettext("common", "Usage time range")} class="flex flex-wrap items-center gap-2">
      <.dm_link
        :for={{value, _days} <- @ranges}
        patch={@action <> "?" <> URI.encode_query(%{"range" => value})}
        aria-current={if @selected == value, do: "true"}
        class={[
          "rounded-lg px-4 py-2 text-sm font-medium transition-colors",
          if(@selected == value,
            do: "bg-primary text-primary-content",
            else: "bg-surface-container text-on-surface hover:bg-surface-container-high"
          )
        ]}
      >
        {range_label(value)}
      </.dm_link>
      <span class="text-xs text-on-surface-variant">{dgettext("common", "UTC · historical ranges exclude today")}</span>
    </nav>
    """
  end

  @doc "Returns the selected preset and inclusive query bounds; historical presets exclude today."
  def parse(selected_range) do
    {range, days} =
      Enum.find(@ranges, &(elem(&1, 0) == selected_range)) || hd(@ranges)

    now = DateTime.utc_now()
    midnight = DateTime.new!(DateTime.to_date(now), ~T[00:00:00.000000], "Etc/UTC")

    since = DateTime.add(midnight, -days, :day)
    until = if days == 0, do: now, else: DateTime.add(midnight, -1, :microsecond)

    {range, %{since: since, until: until}}
  end
end
