defmodule BackplaneWeb.SkillDraftLive do
  @moduledoc """
  Create and edit self-managed skills (source_kind == "database").
  Upstream skills are excluded from this view.
  """

  use BackplaneWeb, :live_view

  alias Backplane.Skills
  alias Backplane.Skills.Skill
  alias Backplane.Skills.Sources.Database, as: DbSource
  alias Backplane.Skills.Registry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/skills/draft",
       loading: true,
       skills: [],
       form: nil,
       editing_skill: nil,
       show_form: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :index ->
        {:noreply,
         socket
         |> assign(form: nil, editing_skill: nil, show_form: false)
         |> load_skills()}

      :new ->
        form = build_new_form()

        {:noreply,
         assign(socket,
           form: form,
           editing_skill: nil,
           show_form: true,
           loading: false
         )}

      :edit ->
        skill_id = params["id"]

        case Skills.get(skill_id) do
          {:ok, skill} ->
            form = build_edit_form(skill)

            {:noreply,
             socket
             |> assign(form: form, editing_skill: skill, show_form: true, loading: false)
             |> load_skills()}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, "Skill not found")
             |> push_patch(to: ~p"/admin/skills/draft")}
        end
    end
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/skills/draft/new")}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Skills.get(id) do
      {:ok, skill} ->
        form = build_edit_form(skill)
        {:noreply, assign(socket, form: form, editing_skill: skill, show_form: true)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/skills/draft")}
  end

  def handle_event("validate", %{"skill" => params}, socket) do
    params = Map.update(params, "tags", [], &parse_tags/1)

    changeset =
      (socket.assigns.editing_skill || %Skill{})
      |> Skill.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :skill))}
  end

  def handle_event("save", %{"skill" => params}, socket) do
    if socket.assigns.editing_skill do
      update_skill(socket, params)
    else
      create_skill(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Skills.delete(id) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{deleted.name}")
         |> load_skills()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete skill")}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp create_skill(socket, params) do
    tags = parse_tags(params["tags"])

    attrs =
      Map.merge(params, %{
        "tags" => tags,
        "source_kind" => "database"
      })

    case DbSource.create(attrs) do
      {:ok, skill} ->
        Registry.refresh()

        {:noreply,
         socket
         |> put_flash(:info, "Created skill '#{skill.name}'")
         |> push_patch(to: ~p"/admin/skills/draft")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :skill))}
    end
  end

  defp update_skill(socket, params) do
    skill = socket.assigns.editing_skill
    tags = parse_tags(params["tags"])
    attrs = Map.put(params, "tags", tags)

    case DbSource.update(skill.id, attrs) do
      {:ok, updated} ->
        Registry.refresh()

        {:noreply,
         socket
         |> put_flash(:info, "Updated skill '#{updated.name}'")
         |> push_patch(to: ~p"/admin/skills/draft")}

      {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
        {:noreply, assign(socket, form: to_form(changeset, as: :skill))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  defp load_skills(socket) do
    skills =
      Skills.list_all(source_kind: "database")
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    assign(socket, skills: skills, loading: false)
  end

  defp build_new_form do
    changeset = Skill.changeset(%Skill{}, %{})
    to_form(changeset, as: :skill)
  end

  defp build_edit_form(skill) do
    changeset = Skill.changeset(skill, %{})
    to_form(changeset, as: :skill)
  end

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(tags) when is_list(tags), do: tags
  defp parse_tags(_), do: []

  defp tags_to_string(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp tags_to_string(_), do: ""

  defp format_dt(nil), do: ""
  defp format_dt(dt) do
    assigns = %{dt: dt}
    ~H"""
    <.local_time datetime={@dt} />
    """
  end

  # ── Template ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Draft Skills</h1>
          <p class="text-sm text-on-surface-variant mt-1">
            Create and edit self-managed skills. Upstream and archive skills are managed elsewhere.
          </p>
        </div>
        <.link :if={!@show_form} patch={~p"/admin/skills/draft/new"} class="no-underline">
          <.dm_btn variant="primary" size="sm" shape="circle" class="group relative">
            <.dm_mdi name="plus" class="w-5 h-5" />
            <span class="pointer-events-none invisible group-hover:visible absolute -bottom-8 left-1/2 -translate-x-1/2 whitespace-nowrap rounded bg-inverse-surface px-2 py-1 text-xs text-inverse-on-surface shadow-md z-50">
              New Skill
            </span>
          </.dm_btn>
        </.link>
      </div>

      <%!-- Skill form --%>
      <.dm_card :if={@show_form} variant="bordered" class="mb-6">
        <:title>{if @editing_skill, do: "Edit Skill", else: "New Skill"}</:title>
        <.form
          for={@form}
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <.dm_input field={@form[:name]} label="Name" required placeholder="Skill name" />
            </div>
            <div>
              <.dm_input
                field={@form[:category]}
                label="Category"
                placeholder="e.g. coding, agent"
              />
            </div>
            <div class="sm:col-span-2">
              <.dm_input
                field={@form[:description]}
                label="Description"
                placeholder="Brief description of what this skill does"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-1">Tags</label>
              <input
                type="text"
                name="skill[tags]"
                value={tags_to_string(Phoenix.HTML.Form.input_value(@form, :tags) || [])}
                placeholder="tag1, tag2, tag3"
                class="input input-bordered w-full"
              />
              <p class="mt-1 text-xs text-on-surface-variant">Comma-separated list</p>
            </div>
            <div>
              <.dm_input field={@form[:version]} label="Version" placeholder="1.0.0" />
            </div>
          </div>

          <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <.dm_input field={@form[:author]} label="Author" placeholder="Author name" />
            <.dm_input field={@form[:license]} label="License" placeholder="MIT" />
            <.dm_input field={@form[:homepage]} label="Homepage" placeholder="https://..." />
          </div>

          <div>
            <label class="block text-sm font-medium mb-1">Content</label>
            <textarea
              name="skill[content]"
              rows="16"
              placeholder="# Skill content&#10;&#10;Write your skill instructions here..."
              class="w-full rounded-md border border-outline-variant bg-surface-container p-3 font-mono text-sm focus:outline-none focus:ring-2 focus:ring-primary"
            >{Phoenix.HTML.Form.input_value(@form, :content) || ""}</textarea>
            <p class="mt-1 text-xs text-on-surface-variant">
              Markdown format. This is the skill content that agents will read.
            </p>
          </div>

          <div class="flex gap-2 pt-2">
            <.dm_btn type="submit" variant="primary" size="sm">
              {if @editing_skill, do: "Update", else: "Create"}
            </.dm_btn>
            <.link patch={~p"/admin/skills/draft"} class="no-underline">
              <.dm_btn type="button" size="sm">Cancel</.dm_btn>
            </.link>
          </div>
        </.form>
      </.dm_card>

      <%!-- Skills list --%>
      <div :if={@skills == [] and not @show_form and not @loading} class="text-on-surface-variant py-12 text-center">
        No draft skills yet. Create one to get started.
      </div>

      <.dm_table :if={@skills != [] and not @show_form} id="draft-skills-table" data={@skills} hover zebra>
        <:col :let={skill} label="Name">
          <div class="font-medium text-on-surface">{skill.name}</div>
        </:col>
        <:col :let={skill} label="Description">
          <div :if={skill.description && skill.description != ""} class="group relative max-w-[240px]">
            <span class="block truncate text-sm text-on-surface-variant cursor-default">
              {skill.description}
            </span>
            <div class="invisible group-hover:visible absolute left-0 top-full z-50 mt-1 max-w-sm rounded-lg border border-outline-variant bg-surface-container-high p-3 text-sm text-on-surface shadow-lg">
              {skill.description}
            </div>
          </div>
          <span :if={!skill.description || skill.description == ""} class="text-xs text-on-surface-variant">-</span>
        </:col>
        <:col :let={skill} label="Slug">
          <code class="text-xs">{skill.slug}</code>
        </:col>
        <:col :let={skill} label="Category">
          <span :if={skill.category} class="text-sm">{skill.category}</span>
          <span :if={!skill.category} class="text-xs text-on-surface-variant">-</span>
        </:col>
        <:col :let={skill} label="Tags">
          <div class="flex flex-wrap gap-1">
            <.dm_badge :for={tag <- skill.tags} variant="ghost" size="sm">{tag}</.dm_badge>
            <span :if={skill.tags == []} class="text-xs text-on-surface-variant">-</span>
          </div>
        </:col>

        <:col :let={skill} label="Updated">
          <span class="text-xs text-on-surface-variant">{format_dt(skill.updated_at)}</span>
        </:col>
        <:col :let={skill} label="Actions">
          <div class="flex gap-1">
            <.dm_btn type="button" size="xs" shape="circle" class="group relative" phx-click="edit" phx-value-id={skill.id}>
              <.dm_mdi name="pencil" class="w-4 h-4" />
              <span class="pointer-events-none invisible group-hover:visible absolute -bottom-8 left-1/2 -translate-x-1/2 whitespace-nowrap rounded bg-inverse-surface px-2 py-1 text-xs text-inverse-on-surface shadow-md z-50">
                Edit
              </span>
            </.dm_btn>
            <.dm_btn
              type="button"
              size="xs"
              shape="circle"
              variant="error"
              class="group relative"
              confirm={"Delete skill '#{skill.name}'?"}
              confirm_title="Confirm Delete"
              phx-click="delete"
              phx-value-id={skill.id}
            >
              <.dm_mdi name="delete" class="w-4 h-4" />
              <span class="pointer-events-none invisible group-hover:visible absolute -bottom-8 left-1/2 -translate-x-1/2 whitespace-nowrap rounded bg-inverse-surface px-2 py-1 text-xs text-inverse-on-surface shadow-md z-50">
                Delete
              </span>
            </.dm_btn>
          </div>
        </:col>
      </.dm_table>
    </div>
    """
  end
end
