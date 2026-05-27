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
  def handle_params(_params, _uri, socket) do
    {:noreply, load_plans(socket)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new", _, socket) do
    changeset = Plan.changeset(%Plan{}, %{})

    {:noreply,
     assign(socket,
       editing: :new,
       form: to_form(changeset),
       credentials: load_credentials()
     )}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Monitor.get_plan(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Plan not found")}

      plan ->
        changeset = Plan.changeset(plan, %{})

        {:noreply,
         assign(socket,
           editing: plan,
           form: to_form(changeset),
           credentials: load_credentials()
         )}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

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
             |> assign(editing: nil, form: nil)
             |> load_plans()}

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
         |> assign(editing: nil, form: nil)
         |> load_plans()}

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
         |> assign(editing: nil, form: nil)
         |> load_plans()}

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
        <.dm_btn variant="primary" size="sm" phx-click="new">New Plan</.dm_btn>
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
            <.dm_btn type="button" phx-click="cancel">Cancel</.dm_btn>
          </div>
        </.form>
      </.dm_card>

      <div :if={@plans == []} class="text-on-surface-variant">
        No plans configured. Add a subscription plan to monitor its usage.
      </div>

      <div class="space-y-4">
        <.dm_card :for={plan <- @plans} variant="bordered">
          <div class="flex items-center justify-between">
            <div>
              <div class="flex items-center gap-2">
                <h3 class="text-sm font-medium">{plan.name}</h3>
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
                <.dm_badge
                  variant={if plan.active, do: "success", else: "error"}
                  size="sm"
                >
                  {if plan.active, do: "Active", else: "Inactive"}
                </.dm_badge>
              </div>
              <p class="text-xs text-on-surface-variant mt-1">
                Credential: <span class="text-on-surface font-mono">{plan.credential_name}</span>
              </p>
              <p class="text-xs text-on-surface-variant mt-1">
                Updated {Calendar.strftime(plan.updated_at, "%Y-%m-%d %H:%M")}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <.dm_btn
                variant={if plan.active, do: "warning", else: "success"}
                size="xs"
                phx-click="toggle_active"
                phx-value-id={plan.id}
              >
                {if plan.active, do: "Deactivate", else: "Activate"}
              </.dm_btn>
              <.dm_btn size="xs" phx-click="edit" phx-value-id={plan.id}>Edit</.dm_btn>
              <.dm_btn
                variant="error"
                size="xs"
                confirm={"Delete plan #{plan.name}? This cannot be undone."}
                phx-click="delete"
                phx-value-id={plan.id}
              >
                Delete
              </.dm_btn>
            </div>
          </div>
        </.dm_card>
      </div>
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
