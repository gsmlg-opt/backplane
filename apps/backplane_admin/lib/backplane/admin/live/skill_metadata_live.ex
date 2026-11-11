defmodule Backplane.Admin.SkillMetadataLive do
  @moduledoc """
  Manage skill metadata: tags and categories as first-class entities.
  Supports rename and delete operations across all skills.
  """

  use Backplane.Admin, :live_view

  alias Backplane.Skills

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/skills/metadata",
       loading: true,
       tags: [],
       categories: [],
       editing_tag: nil,
       editing_category: nil,
       new_tag_name: "",
       new_category_name: "",
       new_category: ""
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_metadata(socket)}
  end

  @impl true
  def handle_event("edit-tag", %{"tag" => tag}, socket) do
    {:noreply, assign(socket, editing_tag: tag, new_tag_name: tag)}
  end

  def handle_event("cancel-edit-tag", _params, socket) do
    {:noreply, assign(socket, editing_tag: nil, new_tag_name: "")}
  end

  def handle_event("rename-tag", %{"new_name" => new_name}, socket) do
    old_tag = socket.assigns.editing_tag
    new_name = String.trim(new_name)

    if new_name != "" and new_name != old_tag do
      Skills.rename_tag(old_tag, new_name)
      Backplane.Admin.Audit.record("skill_tag.rename_requested", "skill_tag")
      Skills.Registry.refresh()

      {:noreply,
       socket
       |> put_flash(:info, dgettext("admin", "Renamed tag '%{old}' → '%{new}'", old: old_tag, new: new_name))
       |> assign(editing_tag: nil, new_tag_name: "")
       |> load_metadata()}
    else
      {:noreply, assign(socket, editing_tag: nil, new_tag_name: "")}
    end
  end

  def handle_event("delete-tag", %{"tag" => tag}, socket) do
    Skills.delete_tag(tag)
    Backplane.Admin.Audit.record("skill_tag.delete_requested", "skill_tag")
    Skills.Registry.refresh()

    {:noreply,
     socket
     |> put_flash(:info, dgettext("admin", "Removed tag '%{tag}' from all skills", tag: tag))
     |> load_metadata()}
  end

  def handle_event("edit-category", %{"category" => category}, socket) do
    {:noreply, assign(socket, editing_category: category, new_category_name: category)}
  end

  def handle_event("cancel-edit-category", _params, socket) do
    {:noreply, assign(socket, editing_category: nil, new_category_name: "")}
  end

  def handle_event("rename-category", %{"new_name" => new_name}, socket) do
    old_cat = socket.assigns.editing_category
    new_name = String.trim(new_name)

    if new_name != "" and new_name != old_cat do
      {count, _} = Skills.rename_category(old_cat, new_name)
      if count > 0, do: Backplane.Admin.Audit.record("skill_category.rename", "skill_category")

      {:noreply,
       socket
       |> put_flash(:info, dgettext("admin", "Renamed category '%{old}' → '%{new}'", old: old_cat, new: new_name))
       |> assign(editing_category: nil, new_category_name: "")
       |> load_metadata()}
    else
      {:noreply, assign(socket, editing_category: nil, new_category_name: "")}
    end
  end

  def handle_event("delete-category", %{"category" => category}, socket) do
    {count, _} = Skills.delete_category(category)
    if count > 0, do: Backplane.Admin.Audit.record("skill_category.delete", "skill_category")

    {:noreply,
     socket
     |> put_flash(:info, dgettext("admin", "Removed category '%{category}' from all skills", category: category))
     |> load_metadata()}
  end

  def handle_event("create-category", %{"category" => category}, socket) do
    # Categories are created implicitly by assigning them to skills.
    # This is a no-op placeholder if the user enters a category name here.
    category = String.trim(category)

    if category != "" do
      {:noreply,
       socket
       |> put_flash(:info, dgettext("admin", "Category '%{category}' will appear when assigned to skills", category: category))
       |> assign(new_category: "")}
    else
      {:noreply, socket}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp load_metadata(socket) do
    tags = safe_call(fn -> Skills.list_tags() end, [])
    categories = safe_call(fn -> Skills.list_categories() end, [])

    assign(socket,
      loading: false,
      tags: tags,
      categories: categories
    )
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  # ── Template ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">{dgettext("navigation", "Metadata")}</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          {dgettext("admin", "Manage tags and categories used across all skills.")}
        </p>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <%!-- Tags section --%>
        <.dm_card variant="bordered">
          <:title>
            <div class="flex items-center gap-2">
              <span>{dgettext("admin", "Tags")}</span>
              <.dm_badge variant="neutral" size="sm">{length(@tags)}</.dm_badge>
            </div>
          </:title>

          <div :if={@tags == []} class="text-on-surface-variant text-sm py-4">
            {dgettext("admin", "No tags defined yet.")}
          </div>

          <div :if={@tags != []} class="divide-y divide-outline-variant/40">
            <div :for={tag_info <- @tags} class="flex items-center justify-between py-2">
              <div :if={@editing_tag != tag_info.tag} class="flex items-center gap-2">
                <.dm_badge variant="ghost" size="sm">{tag_info.tag}</.dm_badge>
                <span class="text-xs text-on-surface-variant">
                  {dngettext("admin", "used by %{count} skill", "used by %{count} skills", tag_info.count)}
                </span>
              </div>

              <div :if={@editing_tag == tag_info.tag} class="flex-1">
                <.form
                  for={%{}}
                  as={:rename}
                  phx-submit="rename-tag"
                  class="flex items-center gap-2"
                >
                  <input
                    type="text"
                    name="new_name"
                    value={@new_tag_name}
                    class="input input-bordered input-sm flex-1"
                    autofocus
                  />
                  <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Save")} position="bottom">
                    <.dm_btn {tooltip_attrs}
                      type="submit"
                      size="xs"
                      variant="primary"
                      shape="circle"
                      aria-label={dgettext("admin", "Save %{name} tag name", name: tag_info.tag)}
                    >
                      <.dm_mdi name="check" class="w-4 h-4" />
                    </.dm_btn>
                  </.dm_tooltip>
                  <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Cancel")} position="bottom">
                    <.dm_btn {tooltip_attrs}
                      type="button"
                      size="xs"
                      shape="circle"
                      aria-label={dgettext("admin", "Cancel renaming %{name} tag", name: tag_info.tag)}
                      phx-click="cancel-edit-tag"
                    >
                      <.dm_mdi name="close" class="w-4 h-4" />
                    </.dm_btn>
                  </.dm_tooltip>
                </.form>
              </div>

              <div :if={@editing_tag != tag_info.tag} class="flex gap-1">
                <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Rename")} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="outline"
                    aria-label={dgettext("admin", "Rename %{name} tag", name: tag_info.tag)}
                    phx-click="edit-tag"
                    phx-value-tag={tag_info.tag}
                  >
                    <.dm_mdi name="pencil" class="w-4 h-4" />
                  </.dm_btn>
                </.dm_tooltip>
                <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Delete")} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="error"
                    aria-label={dgettext("admin", "Delete %{name} tag", name: tag_info.tag)}
                    data-confirm={
                      dngettext(
                        "admin",
                        "Remove tag '%{tag}' from %{count} skill?",
                        "Remove tag '%{tag}' from all %{count} skills?",
                        tag_info.count,
                        tag: tag_info.tag
                      )
                    }
                    phx-click="delete-tag"
                    phx-value-tag={tag_info.tag}
                  >
                    <.dm_mdi name="delete" class="w-4 h-4" />
                  </.dm_btn>
                </.dm_tooltip>
              </div>
            </div>
          </div>
        </.dm_card>

        <%!-- Categories section --%>
        <.dm_card variant="bordered">
          <:title>
            <div class="flex items-center gap-2">
              <span>{dgettext("admin", "Categories")}</span>
              <.dm_badge variant="neutral" size="sm">{length(@categories)}</.dm_badge>
            </div>
          </:title>

          <div :if={@categories == []} class="text-on-surface-variant text-sm py-4">
            {dgettext("admin", "No categories defined yet. Assign a category to a skill to create one.")}
          </div>

          <div :if={@categories != []} class="divide-y divide-outline-variant/40">
            <div :for={cat_info <- @categories} class="flex items-center justify-between py-2">
              <div :if={@editing_category != cat_info.category} class="flex items-center gap-2">
                <span class="text-sm font-medium">{cat_info.category}</span>
                <span class="text-xs text-on-surface-variant">
                  {dngettext("admin", "%{count} skill", "%{count} skills", cat_info.count)}
                </span>
              </div>

              <div :if={@editing_category == cat_info.category} class="flex-1">
                <.form
                  for={%{}}
                  as={:rename}
                  phx-submit="rename-category"
                  class="flex items-center gap-2"
                >
                  <input
                    type="text"
                    name="new_name"
                    value={@new_category_name}
                    class="input input-bordered input-sm flex-1"
                    autofocus
                  />
                  <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Save")} position="bottom">
                    <.dm_btn {tooltip_attrs}
                      type="submit"
                      size="xs"
                      variant="primary"
                      shape="circle"
                      aria-label={dgettext("admin", "Save %{name} category name", name: cat_info.category)}
                    >
                      <.dm_mdi name="check" class="w-4 h-4" />
                    </.dm_btn>
                  </.dm_tooltip>
                  <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Cancel")} position="bottom">
                    <.dm_btn {tooltip_attrs}
                      type="button"
                      size="xs"
                      shape="circle"
                      aria-label={
                        dgettext("admin", "Cancel renaming %{name} category", name: cat_info.category)
                      }
                      phx-click="cancel-edit-category"
                    >
                      <.dm_mdi name="close" class="w-4 h-4" />
                    </.dm_btn>
                  </.dm_tooltip>
                </.form>
              </div>

              <div :if={@editing_category != cat_info.category} class="flex gap-1">
                <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Rename")} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="outline"
                    aria-label={dgettext("admin", "Rename %{name} category", name: cat_info.category)}
                    phx-click="edit-category"
                    phx-value-category={cat_info.category}
                  >
                    <.dm_mdi name="pencil" class="w-4 h-4" />
                  </.dm_btn>
                </.dm_tooltip>
                <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Delete")} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="error"
                    aria-label={dgettext("admin", "Delete %{name} category", name: cat_info.category)}
                    data-confirm={
                      dngettext(
                        "admin",
                        "Remove category '%{category}' from %{count} skill?",
                        "Remove category '%{category}' from all %{count} skills?",
                        cat_info.count,
                        category: cat_info.category
                      )
                    }
                    phx-click="delete-category"
                    phx-value-category={cat_info.category}
                  >
                    <.dm_mdi name="delete" class="w-4 h-4" />
                  </.dm_btn>
                </.dm_tooltip>
              </div>
            </div>
          </div>

          <div class="mt-4 border-t border-outline-variant pt-3">
            <.form
              for={%{}}
              as={:new_cat}
              phx-submit="create-category"
              class="flex items-end gap-2"
            >
              <div class="flex-1">
                <label class="block text-xs font-medium mb-1">{dgettext("admin", "New Category")}</label>
                <input
                  type="text"
                  name="category"
                  value={@new_category}
                  placeholder={dgettext("admin", "Enter category name")}
                  class="input input-bordered input-sm w-full"
                />
              </div>
              <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Add")} position="bottom">
                <.dm_btn {tooltip_attrs}
                  type="submit"
                  size="sm"
                  variant="primary"
                  shape="circle"
                  aria-label={dgettext("admin", "Add category")}
                >
                  <.dm_mdi name="plus" class="w-4 h-4" />
                </.dm_btn>
              </.dm_tooltip>
            </.form>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end
end
