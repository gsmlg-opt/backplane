defmodule Backplane.Admin.SkillConfigLive do
  use Backplane.Admin, :live_view
  alias Backplane.Skills

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket |> assign(current_path: "/skills/config", q: "", page: 1, changes: %{}) |> load()}
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, socket |> assign(q: q, page: 1) |> load()}
  end

  def handle_event("page", %{"step" => step}, socket) when step in ["1", "-1"] do
    page = (socket.assigns.page + String.to_integer(step)) |> max(1) |> min(socket.assigns.pages)
    {:noreply, socket |> assign(:page, page) |> load()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.skills, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      skill ->
        changes = socket.assigns.changes
        selected = not Map.get(changes, id, skill.always_return)

        changes = put_selection(changes, id, skill.always_return, selected)
        {:noreply, assign(socket, :changes, changes)}
    end
  end

  def handle_event("bulk_select", %{"scope" => scope, "selected" => value}, socket)
      when scope in ["page", "all"] and value in ["true", "false"] do
    selected = value == "true"

    selections =
      case scope do
        "page" -> Enum.map(socket.assigns.skills, &{&1.id, &1.always_return})
        "all" -> Skills.always_return_selections()
      end

    changes =
      Enum.reduce(selections, socket.assigns.changes, fn {id, saved}, changes ->
        put_selection(changes, id, saved, selected)
      end)

    {:noreply, socket |> assign(:changes, changes) |> load()}
  end

  def handle_event("save", _, socket) do
    {:ok, :saved} = Skills.set_always_return(socket.assigns.changes)
    Backplane.Admin.Audit.record("skill.always_return_updated", "skill")

    {:noreply,
     socket
     |> assign(:changes, %{})
     |> put_flash(:info, dgettext("admin", "Skill configuration saved."))
     |> load()}
  end

  defp put_selection(changes, id, saved, selected) when saved == selected,
    do: Map.delete(changes, id)

  defp put_selection(changes, id, _saved, selected), do: Map.put(changes, id, selected)

  defp load(socket) do
    %{skills: skills, total: total} =
      Skills.paginated_list(
        page: socket.assigns.page,
        per_page: @page_size,
        q: socket.assigns.q,
        include_disabled: true
      )

    library_total =
      if socket.assigns.q == "", do: total, else: Skills.count(include_disabled: true)

    assign(socket,
      skills: skills,
      library_total: library_total,
      pages: max(1, ceil(total / @page_size))
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <h1 class="text-2xl font-bold">{dgettext("admin", "Skill configuration")}</h1>
      <p>{dgettext("admin", "Choose the skills to return when a session starts. Other published skills remain searchable.")}</p>
      <.form for={%{}} phx-change="filter" id="skill-config-filter">
        <.dm_input name="q" type="search" label={dgettext("admin", "Search skills")} value={@q} phx-debounce="200" />
      </.form>
      <div class="flex flex-wrap items-center gap-3">
        <.dm_btn phx-click="bulk_select" phx-value-scope="page" phx-value-selected="true" disabled={@skills == []}>
          {dgettext("admin", "Select this page (%{count})", count: length(@skills))}
        </.dm_btn>
        <.dm_btn phx-click="bulk_select" phx-value-scope="page" phx-value-selected="false" disabled={@skills == []}>
          {dgettext("admin", "Deselect this page (%{count})", count: length(@skills))}
        </.dm_btn>
        <.dm_btn phx-click="bulk_select" phx-value-scope="all" phx-value-selected="true" disabled={@library_total == 0}>
          {dgettext("admin", "Select entire library (%{count})", count: @library_total)}
        </.dm_btn>
        <.dm_btn phx-click="bulk_select" phx-value-scope="all" phx-value-selected="false" disabled={@library_total == 0}>
          {dgettext("admin", "Deselect entire library (%{count})", count: @library_total)}
        </.dm_btn>
      </div>
      <div class="overflow-x-auto">
        <table class="table w-full">
          <thead><tr>
            <th>{dgettext("admin", "Skill")}</th><th>{dgettext("admin", "Status")}</th><th>{dgettext("admin", "Always return")}</th>
          </tr></thead>
          <tbody>
            <tr :for={skill <- @skills}>
              <td>{skill.name}</td>
              <td>{if skill.enabled, do: skill.publication_status, else: dgettext("admin", "Disabled")}</td>
              <td><input type="checkbox" class="checkbox" checked={Map.get(@changes, skill.id, skill.always_return)}
                aria-label={dgettext("admin", "Always return %{skill}", skill: skill.name)}
                phx-click="toggle" phx-value-id={skill.id} /></td>
            </tr>
          </tbody>
        </table>
        <p :if={@skills == []}>{dgettext("admin", "No skills found.")}</p>
      </div>
      <div class="flex flex-wrap items-center gap-3">
        <.dm_btn phx-click="page" phx-value-step="-1" disabled={@page == 1}>{dgettext("admin", "Previous")}</.dm_btn>
        <span>{@page} / {@pages}</span>
        <.dm_btn phx-click="page" phx-value-step="1" disabled={@page >= @pages}>{dgettext("admin", "Next")}</.dm_btn>
        <.dm_btn variant="primary" phx-click="save" disabled={map_size(@changes) == 0}>{dgettext("admin", "Save")}</.dm_btn>
      </div>
    </section>
    """
  end
end
