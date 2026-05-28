defmodule BackplaneWeb.SkillOverviewLive do
  @moduledoc "Skills hub overview: aggregate stats, source breakdown, recent activity."

  use BackplaneWeb, :live_view

  alias Backplane.Skills
  alias Backplane.Skills.SkillSources

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/skills",
       loading: true,
       total_skills: 0,
       source_counts: %{},
       category_counts: %{},
       tags: [],
       recent_skills: [],
       source_count: 0
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_stats(socket)}
  end

  defp load_stats(socket) do
    total = safe_call(fn -> Skills.count(include_disabled: true) end, 0)
    source_counts = safe_call(fn -> Skills.count_by_source_kind() end, %{})
    category_counts = safe_call(fn -> Skills.count_by_category() end, %{})
    tags = safe_call(fn -> Skills.list_tags() end, [])
    recent = safe_call(fn -> Skills.recent(5) end, [])
    source_count = safe_call(fn -> SkillSources.count() end, 0)

    assign(socket,
      loading: false,
      total_skills: total,
      source_counts: source_counts,
      category_counts: category_counts,
      tags: tags,
      recent_skills: recent,
      source_count: source_count
    )
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp source_kind_label(nil), do: "Unknown"
  defp source_kind_label("archive"), do: "Archive"
  defp source_kind_label("database"), do: "Database"
  defp source_kind_label("github"), do: "GitHub"
  defp source_kind_label(other), do: other

  defp source_kind_variant("archive"), do: "primary"
  defp source_kind_variant("database"), do: "info"
  defp source_kind_variant("github"), do: "success"
  defp source_kind_variant(_), do: "ghost"

  defp format_dt(nil), do: ""

  defp format_dt(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_dt(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Skills Overview</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Dashboard for the skills hub — browse, manage, and sync skills from all sources.
        </p>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Total Skills</div>
          <div class="text-3xl font-bold">{@total_skills}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Archive Skills</div>
          <div class="text-3xl font-bold">{Map.get(@source_counts, "archive", 0)}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Database Skills</div>
          <div class="text-3xl font-bold">{Map.get(@source_counts, "database", 0)}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">Upstream Sources</div>
          <div class="text-3xl font-bold">{@source_count}</div>
        </.dm_card>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-6">
        <.dm_card variant="bordered">
          <:title>Source Breakdown</:title>
          <div :if={@source_counts == %{}} class="text-on-surface-variant text-sm py-4">
            No skills yet.
          </div>
          <div :if={@source_counts != %{}} class="space-y-2">
            <div :for={{kind, count} <- @source_counts} class="flex items-center justify-between py-1">
              <div class="flex items-center gap-2">
                <.dm_badge variant={source_kind_variant(kind)} size="sm">
                  {source_kind_label(kind)}
                </.dm_badge>
              </div>
              <span class="text-sm font-medium">{count}</span>
            </div>
          </div>
        </.dm_card>

        <.dm_card variant="bordered">
          <:title>Categories</:title>
          <div :if={@category_counts == %{}} class="text-on-surface-variant text-sm py-4">
            No categories defined.
          </div>
          <div :if={@category_counts != %{}} class="space-y-2">
            <div
              :for={{cat, count} <- @category_counts}
              class="flex items-center justify-between py-1"
            >
              <span class="text-sm">{cat}</span>
              <span class="text-sm font-medium">{count}</span>
            </div>
          </div>
        </.dm_card>
      </div>

      <.dm_card :if={@tags != []} variant="bordered" class="mb-6">
        <:title>Tags</:title>
        <div class="flex flex-wrap gap-2">
          <.dm_badge :for={tag_info <- Enum.take(@tags, 30)} variant="ghost" size="sm">
            {tag_info.tag}
            <span class="ml-1 opacity-60">({tag_info.count})</span>
          </.dm_badge>
        </div>
      </.dm_card>

      <.dm_card variant="bordered" class="mb-6">
        <:title>Recent Activity</:title>
        <div :if={@recent_skills == []} class="text-on-surface-variant text-sm py-4">
          No skills yet.
        </div>
        <div :if={@recent_skills != []} class="divide-y divide-outline-variant/40">
          <div :for={skill <- @recent_skills} class="flex items-center justify-between py-2">
            <div class="min-w-0 flex-1">
              <div class="font-medium text-sm">{skill.name}</div>
              <div class="text-xs text-on-surface-variant truncate">
                {skill.slug} · {source_kind_label(skill.source_kind)}
              </div>
            </div>
            <div class="text-xs text-on-surface-variant ml-4 shrink-0">
              {format_dt(skill.updated_at)}
            </div>
          </div>
        </div>
      </.dm_card>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <.link navigate={~p"/admin/skills/browse"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">Browse</div>
            <div class="text-xs text-on-surface-variant mt-1">Search and filter all skills</div>
          </.dm_card>
        </.link>
        <.link navigate={~p"/admin/skills/metadata"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">Metadata</div>
            <div class="text-xs text-on-surface-variant mt-1">Manage tags & categories</div>
          </.dm_card>
        </.link>
        <.link navigate={~p"/admin/skills/upstream"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">Upstream</div>
            <div class="text-xs text-on-surface-variant mt-1">Sync skills from GitHub</div>
          </.dm_card>
        </.link>
        <.link navigate={~p"/admin/skills/draft"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">Draft</div>
            <div class="text-xs text-on-surface-variant mt-1">Create & edit skills</div>
          </.dm_card>
        </.link>
      </div>
    </div>
    """
  end
end
