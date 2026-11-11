defmodule Backplane.Admin.SkillOverviewLive do
  @moduledoc "Skills hub overview: aggregate stats, source breakdown, recent activity."

  use Backplane.Admin, :live_view

  alias Backplane.Skills
  alias Backplane.Skills.SkillSources

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/skills",
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

  defp source_kind_label(nil), do: dgettext("admin", "Unknown")
  defp source_kind_label("archive"), do: dgettext("admin", "Archive")
  defp source_kind_label("database"), do: dgettext("admin", "Database")
  defp source_kind_label("github"), do: "GitHub"
  defp source_kind_label(other), do: other

  defp source_kind_variant("archive"), do: "primary"
  defp source_kind_variant("database"), do: "info"
  defp source_kind_variant("github"), do: "success"
  defp source_kind_variant(_), do: "ghost"

  defp format_dt(nil), do: ""
  defp format_dt(dt) do
    assigns = %{dt: dt}
    ~H"""
    <.local_time datetime={@dt} />
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">{dgettext("admin", "Skills Overview")}</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          {dgettext("admin", "Dashboard for the skills hub — browse, manage, and sync skills from all sources.")}
        </p>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">{dgettext("admin", "Total Skills")}</div>
          <div class="text-3xl font-bold">{@total_skills}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">{dgettext("admin", "Archive Skills")}</div>
          <div class="text-3xl font-bold">{Map.get(@source_counts, "archive", 0)}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">{dgettext("admin", "Database Skills")}</div>
          <div class="text-3xl font-bold">{Map.get(@source_counts, "database", 0)}</div>
        </.dm_card>
        <.dm_card variant="bordered" class="p-4">
          <div class="text-xs text-on-surface-variant uppercase font-medium mb-1">{dgettext("admin", "Upstream Sources")}</div>
          <div class="text-3xl font-bold">{@source_count}</div>
        </.dm_card>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-6">
        <.dm_card variant="bordered">
          <:title>{dgettext("admin", "Source Breakdown")}</:title>
          <div :if={@source_counts == %{}} class="text-on-surface-variant text-sm py-4">
            {dgettext("admin", "No skills yet.")}
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
          <:title>{dgettext("admin", "Categories")}</:title>
          <div :if={@category_counts == %{}} class="text-on-surface-variant text-sm py-4">
            {dgettext("admin", "No categories defined.")}
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
        <:title>{dgettext("admin", "Tags")}</:title>
        <div class="flex flex-wrap gap-2">
          <.dm_badge :for={tag_info <- Enum.take(@tags, 30)} variant="ghost" size="sm">
            {tag_info.tag}
            <span class="ml-1 opacity-60">({tag_info.count})</span>
          </.dm_badge>
        </div>
      </.dm_card>

      <.dm_card variant="bordered" class="mb-6">
        <:title>{dgettext("admin", "Recent Activity")}</:title>
        <div :if={@recent_skills == []} class="text-on-surface-variant text-sm py-4">
          {dgettext("admin", "No skills yet.")}
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
        <.link navigate={~p"/skills/browse"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">{dgettext("admin", "Browse")}</div>
            <div class="text-xs text-on-surface-variant mt-1">{dgettext("admin", "Search and filter all skills")}</div>
          </.dm_card>
        </.link>
        <.link navigate={~p"/skills/metadata"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">{dgettext("admin", "Metadata")}</div>
            <div class="text-xs text-on-surface-variant mt-1">{dgettext("admin", "Manage tags & categories")}</div>
          </.dm_card>
        </.link>
        <.link navigate={~p"/skills/upstream"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">{dgettext("admin", "Upstream")}</div>
            <div class="text-xs text-on-surface-variant mt-1">{dgettext("admin", "Sync skills from GitHub")}</div>
          </.dm_card>
        </.link>
        <.link navigate={~p"/skills/draft"}>
          <.dm_card variant="bordered" class="p-4 hover:bg-surface-container cursor-pointer">
            <div class="font-medium">{dgettext("admin", "Draft")}</div>
            <div class="text-xs text-on-surface-variant mt-1">{dgettext("admin", "Create & edit skills")}</div>
          </.dm_card>
        </.link>
      </div>
    </div>
    """
  end
end
