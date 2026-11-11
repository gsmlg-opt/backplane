defmodule Backplane.Admin.SkillBrowseLive do
  @moduledoc """
  Browse, search, filter, and view skills in a paginated table.
  Supports bulk tag/category actions and a detail panel.
  """

  use Backplane.Admin, :live_view

  alias Backplane.Skills

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/skills/browse",
       loading: true,
       skills: [],
       total: 0,
       page: 1,
       q: "",
       source_kind: "",
       category: "",
       tag: "",
       selected: MapSet.new(),
       selected_skill: nil,
       categories: [],
       tags: [],
       bulk_action: nil,
       bulk_tags: "",
       bulk_category: ""
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_int(params["page"], 1)
    q = params["q"] || ""
    source_kind = params["source_kind"] || ""
    category = params["category"] || ""
    tag = params["tag"] || ""

    socket =
      socket
      |> assign(page: page, q: q, source_kind: source_kind, category: category, tag: tag)
      |> load_skills()
      |> load_filter_options()

    case socket.assigns.live_action do
      :show ->
        skill_id = params["id"]

        case Skills.get(skill_id) do
          {:ok, skill} ->
            {:noreply,
             assign(socket,
               selected_skill: skill,
               current_path: "/skills/browse/#{skill_id}"
             )}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, dgettext("errors", "Skill not found"))
             |> push_patch(to: browse_path(socket.assigns))}
        end

      _ ->
        {:noreply, assign(socket, selected_skill: nil)}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         browse_path(%{
           q: params["q"] || "",
           source_kind: params["source_kind"] || "",
           category: params["category"] || "",
           tag: params["tag"] || "",
           page: 1
         })
     )}
  end

  def handle_event("search", %{"q" => q}, socket) do
    assigns = Map.put(socket.assigns, :q, q) |> Map.put(:page, 1)
    {:noreply, push_patch(socket, to: browse_path(assigns))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    assigns = Map.put(socket.assigns, :page, parse_int(page, 1))
    {:noreply, push_patch(socket, to: browse_path(assigns))}
  end

  def handle_event("toggle-select", %{"id" => id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected, id) do
        MapSet.delete(socket.assigns.selected, id)
      else
        MapSet.put(socket.assigns.selected, id)
      end

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("select-all", _params, socket) do
    all_ids = Enum.map(socket.assigns.skills, & &1.id) |> MapSet.new()
    {:noreply, assign(socket, selected: all_ids)}
  end

  def handle_event("toggle-select-all", _params, socket) do
    all_ids = Enum.map(socket.assigns.skills, & &1.id) |> MapSet.new()

    selected =
      if MapSet.equal?(socket.assigns.selected, all_ids) do
        MapSet.new()
      else
        all_ids
      end

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("clear-selection", _params, socket) do
    {:noreply, assign(socket, selected: MapSet.new())}
  end

  def handle_event("bulk-set-tags", %{"tags" => tags_str}, socket) do
    tags = tags_str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    ids = MapSet.to_list(socket.assigns.selected)

    if ids != [] do
      {count, _} = Skills.bulk_update_tags(ids, tags)
      if count > 0, do: Backplane.Admin.Audit.record("skill.bulk_update_tags", "skill")
      Skills.Registry.refresh()

      {:noreply,
       socket
       |> put_flash(
         :info,
         dngettext(
           "admin",
           "Updated tags for %{count} skill",
           "Updated tags for %{count} skills",
           length(ids)
         )
       )
       |> assign(selected: MapSet.new(), bulk_action: nil)
       |> load_skills()
       |> load_filter_options()}
    else
      {:noreply, put_flash(socket, :error, dgettext("errors", "No skills selected"))}
    end
  end

  def handle_event("bulk-set-category", %{"category" => category}, socket) do
    ids = MapSet.to_list(socket.assigns.selected)
    cat = if category == "", do: nil, else: category

    if ids != [] do
      {count, _} = Skills.bulk_update_category(ids, cat)
      if count > 0, do: Backplane.Admin.Audit.record("skill.bulk_update_category", "skill")

      {:noreply,
       socket
       |> put_flash(
         :info,
         dngettext(
           "admin",
           "Updated category for %{count} skill",
           "Updated category for %{count} skills",
           length(ids)
         )
       )
       |> assign(selected: MapSet.new(), bulk_action: nil)
       |> load_skills()
       |> load_filter_options()}
    else
      {:noreply, put_flash(socket, :error, dgettext("errors", "No skills selected"))}
    end
  end

  def handle_event("show-bulk", %{"action" => action}, socket) do
    {:noreply, assign(socket, bulk_action: action)}
  end

  def handle_event("cancel-bulk", _params, socket) do
    {:noreply, assign(socket, bulk_action: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Skills.delete(id) do
      {:ok, deleted} ->
        Backplane.Admin.Audit.record("skill.delete", "skill", deleted.id)

        {:noreply,
         socket
         |> put_flash(:info, dgettext("admin", "Deleted %{name}", name: deleted.name))
         |> load_skills()
         |> load_filter_options()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Failed to delete skill"))}
    end
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, push_patch(socket, to: browse_path(socket.assigns))}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp load_skills(socket) do
    %{skills: skills, total: total} =
      Skills.paginated_list(
        page: socket.assigns.page,
        per_page: @per_page,
        q: socket.assigns.q,
        source_kind: socket.assigns.source_kind,
        category: socket.assigns.category,
        tag: socket.assigns.tag,
        include_disabled: true
      )

    assign(socket, skills: skills, total: total, loading: false)
  end

  defp load_filter_options(socket) do
    categories = safe_call(fn -> Skills.list_categories() end, [])
    tags = safe_call(fn -> Skills.list_tags() end, [])
    assign(socket, categories: categories, tags: tags)
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp browse_path(assigns) do
    params =
      %{}
      |> maybe_put("q", assigns[:q] || assigns["q"])
      |> maybe_put("source_kind", assigns[:source_kind] || assigns["source_kind"])
      |> maybe_put("category", assigns[:category] || assigns["category"])
      |> maybe_put("tag", assigns[:tag] || assigns["tag"])
      |> maybe_put_int("page", assigns[:page] || assigns["page"])

    ~p"/skills/browse?#{params}"
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp maybe_put_int(params, _key, 1), do: params
  defp maybe_put_int(params, _key, nil), do: params
  defp maybe_put_int(params, key, value), do: Map.put(params, key, value)

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_int(_, default), do: default

  defp total_pages(total), do: max(1, div(total + @per_page - 1, @per_page))

  defp all_selected?(skills, selected) do
    skills != [] and MapSet.equal?(MapSet.new(Enum.map(skills, & &1.id)), selected)
  end

  defp source_kind_label(nil), do: "-"
  defp source_kind_label("archive"), do: dgettext("admin", "Archive")
  defp source_kind_label("database"), do: dgettext("admin", "Database")
  defp source_kind_label("github"), do: "GitHub"
  defp source_kind_label(other), do: other

  defp source_kind_variant("archive"), do: "primary"
  defp source_kind_variant("database"), do: "info"
  defp source_kind_variant("github"), do: "success"
  defp source_kind_variant(_), do: "ghost"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KiB"
  end

  defp format_size(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / 1_048_576, 1)} MiB"
  end

  defp format_size(_), do: "-"

  # ── Template ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
        <div>
          <div class="flex items-center gap-3">
            <h1 class="text-2xl font-bold">{dgettext("navigation", "Skills")}</h1>
            <.dm_badge variant="neutral" size="sm">{dgettext("admin", "%{count} total", count: @total)}</.dm_badge>
          </div>
          <p class="mt-1 text-sm text-on-surface-variant">
            {dgettext("admin", "Browse, search, and manage all skills across sources.")}
          </p>
        </div>
      </div>

      <%!-- Filters --%>
      <.dm_card variant="bordered" class="mb-4">
        <.form for={%{}} as={:filters} phx-change="filter" phx-submit="filter" class="space-y-3">
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div>
              <label class="block text-xs font-medium mb-1">{dgettext("common", "Search")}</label>
              <input
                type="text"
                name="q"
                value={@q}
                placeholder={dgettext("admin", "Name, slug, or content")}
                class="input input-bordered w-full"
                phx-debounce="400"
              />
            </div>
            <div>
              <label class="block text-xs font-medium mb-1">{dgettext("admin", "Source")}</label>
              <select name="source_kind" class="select select-bordered w-full">
                <option value="" selected={@source_kind == ""}>{dgettext("admin", "All sources")}</option>
                <option value="archive" selected={@source_kind == "archive"}>{dgettext("admin", "Archive")}</option>
                <option value="database" selected={@source_kind == "database"}>{dgettext("admin", "Database")}</option>
                <option value="github" selected={@source_kind == "github"}>GitHub</option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium mb-1">{dgettext("admin", "Category")}</label>
              <select name="category" class="select select-bordered w-full">
                <option value="" selected={@category == ""}>{dgettext("admin", "All categories")}</option>
                <option
                  :for={cat <- @categories}
                  value={cat.category}
                  selected={@category == cat.category}
                >
                  {cat.category} ({cat.count})
                </option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium mb-1">{dgettext("admin", "Tag")}</label>
              <select name="tag" class="select select-bordered w-full">
                <option value="" selected={@tag == ""}>{dgettext("admin", "All tags")}</option>
                <option
                  :for={t <- Enum.take(@tags, 50)}
                  value={t.tag}
                  selected={@tag == t.tag}
                >
                  {t.tag} ({t.count})
                </option>
              </select>
            </div>
          </div>
        </.form>
      </.dm_card>

      <%!-- Bulk actions bar --%>
      <div
        :if={MapSet.size(@selected) > 0}
        class="mb-4 flex items-center gap-3 rounded-lg border border-primary/30 bg-primary/5 px-4 py-2"
      >
        <span class="text-sm font-medium">{dgettext("admin", "%{count} selected", count: MapSet.size(@selected))}</span>
        <.dm_tooltip :let={tooltip_attrs} content={dgettext("admin", "Set tags")} position="bottom">
          <.dm_btn {tooltip_attrs}
            type="button"
            size="xs"
            shape="circle"
            aria-label={dgettext("admin", "Set tags on selected skills")}
            phx-click="show-bulk"
            phx-value-action="tags"
          >
            <.dm_mdi name="tag-multiple" class="w-4 h-4" />
          </.dm_btn>
        </.dm_tooltip>
        <.dm_tooltip :let={tooltip_attrs} content={dgettext("admin", "Set category")} position="bottom">
          <.dm_btn {tooltip_attrs}
            type="button"
            size="xs"
            shape="circle"
            aria-label={dgettext("admin", "Set category on selected skills")}
            phx-click="show-bulk"
            phx-value-action="category"
          >
            <.dm_mdi name="shape" class="w-4 h-4" />
          </.dm_btn>
        </.dm_tooltip>
        <.dm_tooltip :let={tooltip_attrs} content={dgettext("admin", "Clear selection")} position="bottom">
          <.dm_btn {tooltip_attrs}
            type="button"
            size="xs"
            shape="circle"
            variant="ghost"
            aria-label={dgettext("admin", "Clear skill selection")}
            phx-click="clear-selection"
          >
            <.dm_mdi name="close" class="w-4 h-4" />
          </.dm_btn>
        </.dm_tooltip>
      </div>

      <%!-- Bulk tag modal --%>
      <.dm_card :if={@bulk_action == "tags"} variant="bordered" class="mb-4">
        <:title>{dgettext("admin", "Bulk Set Tags")}</:title>
        <.form for={%{}} as={:bulk} phx-submit="bulk-set-tags" class="flex items-end gap-3">
          <div class="flex-1">
            <label class="block text-xs font-medium mb-1">{dgettext("admin", "Tags (comma-separated)")}</label>
            <input
              type="text"
              name="tags"
              value={@bulk_tags}
              placeholder="tag1, tag2, tag3"
              class="input input-bordered w-full"
            />
          </div>
          <.dm_btn type="submit" variant="primary" size="sm">{dgettext("common", "Apply")}</.dm_btn>
          <.dm_btn type="button" size="sm" phx-click="cancel-bulk">{dgettext("common", "Cancel")}</.dm_btn>
        </.form>
      </.dm_card>

      <%!-- Bulk category modal --%>
      <.dm_card :if={@bulk_action == "category"} variant="bordered" class="mb-4">
        <:title>{dgettext("admin", "Bulk Set Category")}</:title>
        <.form for={%{}} as={:bulk} phx-submit="bulk-set-category" class="flex items-end gap-3">
          <div class="flex-1">
            <label class="block text-xs font-medium mb-1">{dgettext("admin", "Category")}</label>
            <input
              type="text"
              name="category"
              value={@bulk_category}
              placeholder={dgettext("admin", "Enter category")}
              class="input input-bordered w-full"
            />
          </div>
          <.dm_btn type="submit" variant="primary" size="sm">{dgettext("common", "Apply")}</.dm_btn>
          <.dm_btn type="button" size="sm" phx-click="cancel-bulk">{dgettext("common", "Cancel")}</.dm_btn>
        </.form>
      </.dm_card>

      <%!-- Skills table --%>
      <div :if={@skills == [] and not @loading} class="text-on-surface-variant py-12 text-center">
        {dgettext("admin", "No skills match the current filters.")}
      </div>

      <table :if={@skills != []} role="table" id="skills-browse-table" class={["table", "table-hover", "table-zebra"]}>
        <caption class="text-left text-base font-semibold py-2">{dgettext("admin", "Skills Library")}</caption>
        <thead role="row-group" class="hidden md:table-header-group sticky top-0">
          <tr role="row">
            <th role="columnheader" scope="col">
              <input
                type="checkbox"
                checked={all_selected?(@skills, @selected)}
                phx-click="toggle-select-all"
                class="checkbox checkbox-sm"
                title={dgettext("admin", "Select all")}
              />
            </th>
            <th role="columnheader" scope="col">{dgettext("common", "Name")}</th>
            <th role="columnheader" scope="col">{dgettext("common", "Description")}</th>
            <th role="columnheader" scope="col">{dgettext("admin", "Slug")}</th>
            <th role="columnheader" scope="col">{dgettext("admin", "Source")}</th>
            <th role="columnheader" scope="col">{dgettext("admin", "Category")}</th>
            <th role="columnheader" scope="col">{dgettext("admin", "Tags")}</th>
            <th role="columnheader" scope="col">{dgettext("admin", "Size")}</th>
            <th role="columnheader" scope="col">{dgettext("common", "Actions")}</th>
          </tr>
        </thead>
        <tbody role="row-group">
          <tr :for={skill <- @skills} role="row">
            <td role="cell">
              <input
                type="checkbox"
                checked={MapSet.member?(@selected, skill.id)}
                phx-click="toggle-select"
                phx-value-id={skill.id}
                class="checkbox checkbox-sm"
              />
            </td>
            <td role="cell">
              <.link
                patch={~p"/skills/browse/#{skill.id}"}
                class="font-medium text-primary hover:underline no-underline whitespace-nowrap"
              >
                {skill.name}
              </.link>
            </td>
            <td role="cell" class="max-w-[200px]">
              <div :if={skill.description && skill.description != ""} class="desc-tooltip-wrap max-w-[200px]">
                <span class="block truncate text-xs text-on-surface-variant cursor-default">
                  {skill.description}
                </span>
                <div class="desc-tooltip-content">
                  {skill.description}
                </div>
              </div>
              <span :if={!skill.description || skill.description == ""} class="text-xs text-on-surface-variant">-</span>
            </td>
            <td role="cell">
              <code class="text-xs">{skill.slug}</code>
            </td>
            <td role="cell">
              <.dm_badge variant={source_kind_variant(skill.source_kind)} size="sm">
                {source_kind_label(skill.source_kind)}
              </.dm_badge>
            </td>
            <td role="cell">
              <span :if={skill.category} class="text-sm">{skill.category}</span>
              <span :if={!skill.category} class="text-xs text-on-surface-variant">-</span>
            </td>
            <td role="cell">
              <div class="flex flex-wrap gap-1">
                <.dm_badge :for={tag <- skill.tags} variant="ghost" size="sm">{tag}</.dm_badge>
                <span :if={skill.tags == []} class="text-xs text-on-surface-variant">-</span>
              </div>
            </td>
            <td role="cell">
              <span class="text-sm">{format_size(skill.size_bytes)}</span>
            </td>
            <td role="cell">
              <div class="flex gap-2">
                <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Delete")} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="error"
                    aria-label={dgettext("admin", "Delete %{name} skill", name: skill.name)}
                    data-confirm={dgettext("admin", "Delete skill %{name}?", name: skill.name)}
                    phx-click="delete"
                    phx-value-id={skill.id}
                  >
                    <.dm_mdi name="delete" class="w-4 h-4" />
                  </.dm_btn>
                </.dm_tooltip>
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <%!-- Pagination --%>
      <div :if={@total > 0} class="flex items-center justify-between mt-4 text-sm">
        <div class="flex items-center gap-2 text-on-surface-variant">
          <span>{dgettext("admin", "Page %{page} of %{total}", page: @page, total: total_pages(@total))}</span>
          <.dm_tooltip :if={MapSet.size(@selected) == 0} :let={tooltip_attrs} content={dgettext("admin", "Select page")} position="bottom">
            <.dm_btn {tooltip_attrs}
              type="button"
              size="xs"
              shape="circle"
              aria-label={dgettext("admin", "Select all skills on this page")}
              phx-click="select-all"
            >
              <.dm_mdi name="checkbox-multiple-marked-outline" class="w-4 h-4" />
            </.dm_btn>
          </.dm_tooltip>
        </div>
        <div class="flex items-center gap-2">
          <.dm_tooltip :if={@page > 1} :let={tooltip_attrs} content={dgettext("common", "Previous")} position="bottom">
            <.dm_btn {tooltip_attrs}
              type="button"
              size="xs"
              shape="circle"
              aria-label={dgettext("admin", "Previous skills page")}
              phx-click="page"
              phx-value-page={@page - 1}
            >
              <.dm_mdi name="chevron-left" class="w-4 h-4" />
            </.dm_btn>
          </.dm_tooltip>
          <.dm_tooltip :if={@page < total_pages(@total)} :let={tooltip_attrs} content={dgettext("common", "Next")} position="bottom">
            <.dm_btn {tooltip_attrs}
              type="button"
              size="xs"
              shape="circle"
              aria-label={dgettext("admin", "Next skills page")}
              phx-click="page"
              phx-value-page={@page + 1}
            >
              <.dm_mdi name="chevron-right" class="w-4 h-4" />
            </.dm_btn>
          </.dm_tooltip>
        </div>
      </div>

      <%!-- Detail panel (shown when :show action) --%>
      <div
        :if={@selected_skill}
        class="fixed inset-0 z-50 flex justify-end bg-black/30"
        phx-click="close-detail"
      >
        <div
          class="w-full max-w-2xl bg-surface shadow-xl overflow-y-auto"
          phx-click-away="close-detail"
          phx-window-keydown="close-detail"
          phx-key="Escape"
        >
          <div class="sticky top-0 z-10 flex items-center justify-between border-b border-outline-variant bg-surface px-6 py-4">
            <h2 class="text-lg font-bold">{@selected_skill.name}</h2>
            <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Close")} position="bottom">
              <.dm_btn {tooltip_attrs}
                type="button"
                size="xs"
                shape="circle"
                aria-label={dgettext("admin", "Close %{name} skill details", name: @selected_skill.name)}
                phx-click="close-detail"
              >
                <.dm_mdi name="close" class="w-4 h-4" />
              </.dm_btn>
            </.dm_tooltip>
          </div>

          <div class="p-6 space-y-4">
            <div class="grid grid-cols-2 gap-3 text-sm">
              <div>
                <span class="text-on-surface-variant">{dgettext("admin", "Slug:")}</span>
                <code class="ml-1">{@selected_skill.slug}</code>
              </div>
              <div>
                <span class="text-on-surface-variant">{dgettext("admin", "Source:")}</span>
                <.dm_badge variant={source_kind_variant(@selected_skill.source_kind)} size="sm" class="ml-1">
                  {source_kind_label(@selected_skill.source_kind)}
                </.dm_badge>
              </div>
              <div :if={@selected_skill.category}>
                <span class="text-on-surface-variant">{dgettext("admin", "Category:")}</span>
                <span class="ml-1">{@selected_skill.category}</span>
              </div>
              <div :if={@selected_skill.version}>
                <span class="text-on-surface-variant">{dgettext("admin", "Version:")}</span>
                <span class="ml-1">{@selected_skill.version}</span>
              </div>
              <div :if={@selected_skill.author}>
                <span class="text-on-surface-variant">{dgettext("admin", "Author:")}</span>
                <span class="ml-1">{@selected_skill.author}</span>
              </div>
              <div :if={@selected_skill.license}>
                <span class="text-on-surface-variant">{dgettext("admin", "License:")}</span>
                <span class="ml-1">{@selected_skill.license}</span>
              </div>
            </div>

            <div :if={@selected_skill.tags != []}>
              <span class="text-sm text-on-surface-variant">{dgettext("admin", "Tags:")}</span>
              <div class="flex flex-wrap gap-1 mt-1">
                <.dm_badge :for={tag <- @selected_skill.tags} variant="ghost" size="sm">
                  {tag}
                </.dm_badge>
              </div>
            </div>

            <div :if={@selected_skill.description && @selected_skill.description != ""}>
              <h3 class="text-sm font-medium text-on-surface-variant mb-1">{dgettext("common", "Description")}</h3>
              <p class="text-sm">{@selected_skill.description}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-on-surface-variant mb-1">{dgettext("admin", "Content")}</h3>
              <pre class="max-h-96 overflow-auto whitespace-pre-wrap break-words rounded bg-surface-container p-4 text-xs">{@selected_skill.content}</pre>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
