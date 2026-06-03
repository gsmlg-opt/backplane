defmodule BackplaneWeb.MonitorPlansLive do
  use BackplaneWeb, :live_view

  alias Backplane.Monitor
  alias Backplane.Monitor.Plan
  alias Backplane.Settings.Credentials

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/system/monitor/plans",
       loading: true,
       editing: nil,
       form: nil,
       credentials: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(editing: nil, form: nil)
    |> load_plans()
  end

  defp apply_action(socket, :new, _params) do
    changeset = Plan.changeset(%Plan{}, %{})

    socket
    |> assign(
      editing: :new,
      form: to_form(changeset),
      credentials: load_credentials()
    )
    |> load_plans()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Monitor.get_plan(id) do
      nil ->
        socket
        |> put_flash(:error, "Plan not found")
        |> push_patch(to: ~p"/admin/system/monitor/plans")

      plan ->
        changeset = Plan.changeset(plan, %{})

        socket
        |> assign(
          editing: plan,
          form: to_form(changeset),
          credentials: load_credentials()
        )
        |> load_plans()
    end
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    case Monitor.get_plan(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Plan not found")}

      plan ->
        case Monitor.update_plan(plan, %{active: !plan.active}) do
          {:ok, _} ->
            {:noreply, load_plans(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle plan status")}
        end
    end
  end

  def handle_event("save", %{"plan" => params}, socket) do
    case socket.assigns.editing do
      :new -> create_plan(socket, params)
      %Plan{} = plan -> update_plan(socket, plan, params)
    end
  end

  def handle_event("validate", %{"plan" => params}, socket) do
    changeset =
      case socket.assigns.editing do
        :new -> Plan.changeset(%Plan{}, params)
        %Plan{} = plan -> Plan.changeset(plan, params)
      end

    {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Monitor.get_plan(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Plan not found")}

      plan ->
        case Monitor.delete_plan(plan) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Plan #{plan.name} deleted")
             |> push_patch(to: ~p"/admin/system/monitor/plans")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete plan")}
        end
    end
  end

  defp create_plan(socket, params) do
    case Monitor.create_plan(params) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan #{plan.name} created")
         |> push_patch(to: ~p"/admin/system/monitor/plans")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_plan(socket, plan, params) do
    case Monitor.update_plan(plan, params) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan #{plan.name} updated")
         |> push_patch(to: ~p"/admin/system/monitor/plans")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp load_plans(socket) do
    plans =
      try do
        Monitor.list_plans()
      rescue
        _ -> []
      end

    assign(socket, loading: false, plans: plans)
  end

  defp load_credentials do
    try do
      Credentials.list()
      |> Enum.map(& &1.name)
      |> Enum.sort()
    rescue
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Plan Usage</h1>
        <.link patch={~p"/admin/system/monitor/plans/new"}>
          <.dm_btn variant="primary" size="sm">New Plan</.dm_btn>
        </.link>
      </div>

      <.dm_card :if={@editing} variant="bordered" class="mb-6">
        <:title>
          {if @editing == :new, do: "New Plan", else: "Edit Plan"}
        </:title>
        <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-4">
          <.dm_input
            id="plan-name"
            name="plan[name]"
            label="Name"
            value={@form[:name].value}
            disabled={@editing != :new}
            placeholder="my-zai-plan"
          />
          <.form_error field={@form[:name]} />

          <div>
            <label class="block text-sm font-medium mb-1">Provider</label>
            <select
              id="plan-provider"
              name="plan[provider]"
              class="w-full rounded-lg border border-outline bg-surface-container px-3 py-2 text-sm text-on-surface"
            >
              <option value="">Select a provider...</option>
              <option
                :for={p <- Plan.providers()}
                value={p}
                selected={to_string(@form[:provider].value) == p}
              >
                {Plan.provider_label(p)}{unless Plan.provider_supported?(p), do: " (Coming Soon)", else: ""}
              </option>
            </select>
          </div>
          <.form_error field={@form[:provider]} />

          <div>
            <label class="block text-sm font-medium mb-1">Credential</label>
            <select
              id="plan-credential"
              name="plan[credential_name]"
              class="w-full rounded-lg border border-outline bg-surface-container px-3 py-2 text-sm text-on-surface"
            >
              <option value="">Select a credential...</option>
              <option
                :for={cred <- @credentials}
                value={cred}
                selected={to_string(@form[:credential_name].value) == cred}
              >
                {cred}
              </option>
            </select>
            <p class="text-xs text-on-surface-variant mt-1">
              The API key credential used to query usage. Must be created in System → Credentials first.
            </p>
          </div>
          <.form_error field={@form[:credential_name]} />

          <div class="flex gap-2">
            <.dm_btn type="submit" variant="primary">Save</.dm_btn>
            <.link patch={~p"/admin/system/monitor/plans"} class="no-underline">
              <.dm_btn type="button">Cancel</.dm_btn>
            </.link>
          </div>
        </.form>
      </.dm_card>

      <div :if={!@editing && @plans == []} class="text-on-surface-variant">
        No plans configured. Add a subscription plan to monitor its usage.
      </div>

      <.dm_table :if={!@editing && @plans != []} id="monitor-plans-table" data={@plans} hover zebra>
        <:col :let={plan} label="Name">
          <div class="font-medium text-on-surface">{plan.name}</div>
        </:col>
        <:col :let={plan} label="Provider">
          <div class="flex items-center gap-2">
            <.dm_badge variant="info" size="sm">
              {Plan.provider_label(plan.provider)}
            </.dm_badge>
            <.dm_badge
              :if={!Plan.provider_supported?(plan.provider)}
              variant="warning"
              size="sm"
            >
              Coming Soon
            </.dm_badge>
          </div>
        </:col>
        <:col :let={plan} label="Credential">
          <code class="text-xs font-mono">{plan.credential_name}</code>
        </:col>
        <:col :let={plan} label="Status">
          <.dm_badge
            variant={if plan.active, do: "success", else: "error"}
            size="sm"
          >
            {if plan.active, do: "Active", else: "Inactive"}
          </.dm_badge>
        </:col>
        <:col :let={plan} label="Last Updated">
          <span class="text-xs text-on-surface-variant">
            {Calendar.strftime(plan.updated_at, "%Y-%m-%d %H:%M")}
          </span>
        </:col>
        <:col :let={plan} label="Actions">
          <div class="flex items-center gap-1">
            <.dm_tooltip content={if plan.active, do: "Deactivate", else: "Activate"} position="bottom">
              <.dm_btn
                type="button"
                variant={if plan.active, do: "warning", else: "success"}
                size="xs"
                shape="circle"
                aria-label={if plan.active, do: "Deactivate #{plan.name}", else: "Activate #{plan.name}"}
                phx-click="toggle_active"
                phx-value-id={plan.id}
              >
                <.dm_mdi name={if plan.active, do: "pause", else: "play"} class="h-4 w-4" />
                <span class="sr-only">{if plan.active, do: "Deactivate", else: "Activate"}</span>
              </.dm_btn>
            </.dm_tooltip>

            <.dm_tooltip content="Edit" position="bottom">
              <.link patch={~p"/admin/system/monitor/plans/#{plan.id}/edit"} class="no-underline">
                <.dm_btn
                  type="button"
                  size="xs"
                  shape="circle"
                  aria-label={"Edit #{plan.name}"}
                >
                  <.dm_mdi name="pencil" class="h-4 w-4" />
                  <span class="sr-only">Edit</span>
                </.dm_btn>
              </.link>
            </.dm_tooltip>

            <.dm_tooltip content="Delete" position="bottom">
              <.dm_btn
                type="button"
                variant="error"
                size="xs"
                shape="circle"
                aria-label={"Delete #{plan.name}"}
                confirm={"Delete plan #{plan.name}? This cannot be undone."}
                phx-click="delete"
                phx-value-id={plan.id}
              >
                <.dm_mdi name="trash-can" class="h-4 w-4" />
                <span class="sr-only">Delete</span>
              </.dm_btn>
            </.dm_tooltip>
          </div>
        </:col>
      </.dm_table>
    </div>
    """
  end

  defp form_error(assigns) do
    ~H"""
    <div
      :for={msg <- Enum.map(@field.errors, &translate_error/1)}
      class="text-xs text-error mt-1"
    >
      {msg}
    </div>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
