defmodule BackplaneWeb.SkillMetadataLive do
  @moduledoc """
  Manage skill metadata: tags and categories as first-class entities.
  Supports rename and delete operations across all skills.
  """

  use BackplaneWeb, :live_view

  alias Backplane.Skills

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/skills/metadata",
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
      Skills.Registry.refresh()

      {:noreply,
       socket
       |> put_flash(:info, "Renamed tag '#{old_tag}' → '#{new_name}'")
       |> assign(editing_tag: nil, new_tag_name: "")
       |> load_metadata()}
    else
      {:noreply, assign(socket, editing_tag: nil, new_tag_name: "")}
    end
  end

  def handle_event("delete-tag", %{"tag" => tag}, socket) do
    Skills.delete_tag(tag)
    Skills.Registry.refresh()

    {:noreply,
     socket
     |> put_flash(:info, "Removed tag '#{tag}' from all skills")
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
      Skills.rename_category(old_cat, new_name)

      {:noreply,
       socket
       |> put_flash(:info, "Renamed category '#{old_cat}' → '#{new_name}'")
       |> assign(editing_category: nil, new_category_name: "")
       |> load_metadata()}
    else
      {:noreply, assign(socket, editing_category: nil, new_category_name: "")}
    end
  end

  def handle_event("delete-category", %{"category" => category}, socket) do
    Skills.delete_category(category)

    {:noreply,
     socket
     |> put_flash(:info, "Removed category '#{category}' from all skills")
     |> load_metadata()}
  end

  def handle_event("create-category", %{"category" => category}, socket) do
    # Categories are created implicitly by assigning them to skills.
    # This is a no-op placeholder if the user enters a category name here.
    category = String.trim(category)

    if category != "" do
      {:noreply,
       socket
       |> put_flash(:info, "Category '#{category}' will appear when assigned to skills")
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
        <h1 class="text-2xl font-bold">Metadata</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Manage tags and categories used across all skills.
        </p>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <%!-- Tags section --%>
        <.dm_card variant="bordered">
          <:title>
            <div class="flex items-center gap-2">
              <span>Tags</span>
              <.dm_badge variant="neutral" size="sm">{length(@tags)}</.dm_badge>
            </div>
          </:title>

          <div :if={@tags == []} class="text-on-surface-variant text-sm py-4">
            No tags defined yet.
          </div>

          <div :if={@tags != []} class="divide-y divide-outline-variant/40">
            <div :for={tag_info <- @tags} class="flex items-center justify-between py-2">
              <div :if={@editing_tag != tag_info.tag} class="flex items-center gap-2">
                <.dm_badge variant="ghost" size="sm">{tag_info.tag}</.dm_badge>
                <span class="text-xs text-on-surface-variant">
                  used by {tag_info.count} skill(s)
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
                  <.dm_btn type="submit" size="xs" variant="primary">Save</.dm_btn>
                  <.dm_btn type="button" size="xs" phx-click="cancel-edit-tag">Cancel</.dm_btn>
                </.form>
              </div>

              <div :if={@editing_tag != tag_info.tag} class="flex gap-1">
                <.dm_btn
                  type="button"
                  size="xs"
                  phx-click="edit-tag"
                  phx-value-tag={tag_info.tag}
                >
                  Rename
                </.dm_btn>
                <.dm_btn
                  type="button"
                  size="xs"
                  variant="error"
                  data-confirm={"Remove tag '#{tag_info.tag}' from all #{tag_info.count} skill(s)?"}
                  phx-click="delete-tag"
                  phx-value-tag={tag_info.tag}
                >
                  Delete
                </.dm_btn>
              </div>
            </div>
          </div>
        </.dm_card>

        <%!-- Categories section --%>
        <.dm_card variant="bordered">
          <:title>
            <div class="flex items-center gap-2">
              <span>Categories</span>
              <.dm_badge variant="neutral" size="sm">{length(@categories)}</.dm_badge>
            </div>
          </:title>

          <div :if={@categories == []} class="text-on-surface-variant text-sm py-4">
            No categories defined yet. Assign a category to a skill to create one.
          </div>

          <div :if={@categories != []} class="divide-y divide-outline-variant/40">
            <div :for={cat_info <- @categories} class="flex items-center justify-between py-2">
              <div :if={@editing_category != cat_info.category} class="flex items-center gap-2">
                <span class="text-sm font-medium">{cat_info.category}</span>
                <span class="text-xs text-on-surface-variant">
                  {cat_info.count} skill(s)
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
                  <.dm_btn type="submit" size="xs" variant="primary">Save</.dm_btn>
                  <.dm_btn type="button" size="xs" phx-click="cancel-edit-category">
                    Cancel
                  </.dm_btn>
                </.form>
              </div>

              <div :if={@editing_category != cat_info.category} class="flex gap-1">
                <.dm_btn
                  type="button"
                  size="xs"
                  phx-click="edit-category"
                  phx-value-category={cat_info.category}
                >
                  Rename
                </.dm_btn>
                <.dm_btn
                  type="button"
                  size="xs"
                  variant="error"
                  data-confirm={"Remove category '#{cat_info.category}' from all #{cat_info.count} skill(s)?"}
                  phx-click="delete-category"
                  phx-value-category={cat_info.category}
                >
                  Delete
                </.dm_btn>
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
                <label class="block text-xs font-medium mb-1">New Category</label>
                <input
                  type="text"
                  name="category"
                  value={@new_category}
                  placeholder="Enter category name"
                  class="input input-bordered input-sm w-full"
                />
              </div>
              <.dm_btn type="submit" size="sm" variant="primary">Add</.dm_btn>
            </.form>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end
end
