defmodule Backplane.Admin.HostServicesLive do
  use Backplane.Admin, :live_view

  alias Backplane.LLM.{HostService, HostServices}
  alias Backplane.Skills.{AgentManage, Hosts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/system/host-agents",
       host: nil,
       services: [],
       form: to_form(defaults(), as: :service),
       editing: nil,
       errors: %{},
       online: false,
       protocols: HostService.protocols()
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Hosts.get_host(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("errors", "Host agent not found"))
         |> push_navigate(to: ~p"/system/host-agents")}

      host ->
        {:noreply, socket |> assign(host: host) |> reload()}
    end
  end

  @impl true
  def handle_event("save_service", %{"service" => params}, socket) do
    attrs = %{
      "host_id" => socket.assigns.host.id,
      "name" => params["name"],
      "enabled" => params["enabled"] in [true, "true", "on"],
      "endpoints" =>
        Map.new(socket.assigns.protocols, &{&1, String.trim(params[&1] || "")})
        |> Map.reject(fn {_api, url} -> url == "" end)
    }

    result =
      case socket.assigns.editing do
        nil -> HostServices.create(attrs)
        service -> HostServices.update(service, attrs)
      end

    case result do
      {:ok, service} ->
        Backplane.Admin.Audit.record("host_api_service.save", "host_api_service", service.id)

        {:noreply,
         socket
         |> assign(editing: nil, form: to_form(defaults(), as: :service), errors: %{})
         |> put_flash(:info, dgettext("admin", "API service saved"))
         |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(params, as: :service), errors: errors(changeset))}
    end
  end

  def handle_event("edit_service", %{"id" => id}, socket) do
    case owned_service(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "API service not found"))}

      service ->
        params =
          Map.merge(service.endpoints, %{
            "name" => service.name,
            "enabled" => to_string(service.enabled)
          })

        {:noreply,
         assign(socket, editing: service, form: to_form(params, as: :service), errors: %{})}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: to_form(defaults(), as: :service), errors: %{})}
  end

  def handle_event("delete_service", %{"id" => id}, socket) do
    case owned_service(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "API service not found"))}

      service ->
        case HostServices.delete(service) do
          {:ok, deleted} ->
            Backplane.Admin.Audit.record(
              "host_api_service.delete",
              "host_api_service",
              deleted.id
            )

            {:noreply,
             socket |> put_flash(:info, dgettext("admin", "API service deleted")) |> reload()}

          {:error, _changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               dgettext("errors", "Detach providers before deleting this service")
             )}
        end
    end
  end

  defp owned_service(socket, id) do
    case HostServices.get(id) do
      %{host_id: host_id} = service when host_id == socket.assigns.host.id -> service
      _ -> nil
    end
  end

  defp reload(socket) do
    online =
      case AgentManage.get_agent(socket.assigns.host.id) do
        {:ok, %{status: :online}} -> true
        _ -> false
      end

    assign(socket, services: HostServices.list_for_host(socket.assigns.host.id), online: online)
  end

  defp defaults, do: %{"name" => "", "enabled" => "true"}

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp label("openai_embeddings"), do: dgettext("admin", "OpenAI Embeddings")
  defp label("openai_chat_completions"), do: dgettext("admin", "OpenAI Chat Completions")
  defp label("openai_responses"), do: dgettext("admin", "OpenAI Responses")
  defp label("anthropic_messages"), do: dgettext("admin", "Anthropic Messages")

  defp endpoint_label(api), do: dgettext("admin", "%{api} endpoint URL", api: label(api))

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@host} class="space-y-6">
      <.link navigate={~p"/system/host-agents/#{@host.id}"} class="text-sm text-primary">{dgettext("admin", "← Host agent")}</.link>
      <div>
        <h1 class="text-2xl font-bold">{dgettext("admin", "%{name}: API Services", name: @host.name)}</h1>
        <p class="mt-2 text-sm text-on-surface-variant">
          {dgettext("admin", "Configure exact endpoints reachable from this host. Select the service in an LLM or Embedding provider.")}
          {if @online, do: dgettext("admin", "Host connection: online."), else: dgettext("admin", "Host connection: offline.")}
        </p>
      </div>

      <.dm_card variant="bordered">
        <:title>{if @editing, do: dgettext("admin", "Edit API Service"), else: dgettext("admin", "Add API Service")}</:title>
        <.form for={@form} id="host-api-service-form" phx-submit="save_service" class="space-y-4">
          <.dm_input id="host-api-service-name" name="service[name]" label={dgettext("common", "Name")} value={@form[:name].value} />
          <p :if={@errors[:name]} class="text-sm text-error">{Enum.join(@errors[:name], ", ")}</p>
          <p :if={@errors[:host_id]} class="text-sm text-error">{Enum.join(@errors[:host_id], ", ")}</p>
          <p :if={@errors[:revision]} class="text-sm text-error">{Enum.join(@errors[:revision], ", ")}</p>
          <div :for={api <- @protocols}>
            <.dm_input id={"host-api-service-#{api}"} name={"service[#{api}]"} label={endpoint_label(api)}
              value={@form[api].value} placeholder="http://127.0.0.1:8000/v1/..." />
          </div>
          <p :if={@errors[:endpoints]} class="text-sm text-error">{Enum.join(@errors[:endpoints], ", ")}</p>
          <p class="text-sm text-on-surface-variant">{dgettext("admin", "Leave unsupported APIs empty. URLs are used exactly as configured.")}</p>
          <input type="hidden" name="service[enabled]" value="false" />
          <.dm_checkbox id="host-api-service-enabled" name="service[enabled]" label={dgettext("admin", "Enable service")} value="true"
            checked={@form[:enabled].value in [true, "true", "on"]} />
          <div class="flex gap-2">
            <.dm_btn id="save-host-api-service" type="submit" variant="primary">{dgettext("admin", "Save Service")}</.dm_btn>
            <.dm_btn :if={@editing} type="button" phx-click="cancel_edit">{dgettext("common", "Cancel")}</.dm_btn>
          </div>
        </.form>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>{dgettext("admin", "Registered API Services")}</:title>
        <p :if={@services == []} class="text-sm text-on-surface-variant">{dgettext("admin", "No API services configured.")}</p>
        <div :for={service <- @services} id={"host-api-service-#{service.id}"} class="border-b border-outline-variant py-4">
          <div class="flex items-center justify-between gap-4">
            <div><strong>{service.name}</strong> · {if service.enabled, do: dgettext("common", "Enabled"), else: dgettext("common", "Disabled")}</div>
            <div class="flex gap-2">
              <.dm_btn id={"edit-host-api-service-#{service.id}"} size="sm" phx-click="edit_service" phx-value-id={service.id}>{dgettext("common", "Edit")}</.dm_btn>
              <.dm_btn id={"delete-host-api-service-#{service.id}"} size="sm" phx-click="delete_service" phx-value-id={service.id}
                data-confirm={dgettext("admin", "Delete this API service?")}>{dgettext("common", "Delete")}</.dm_btn>
            </div>
          </div>
          <div :for={{api, url} <- Enum.sort(service.endpoints)} class="mt-2 text-sm">
            {label(api)}: <span class="break-all font-mono">{url}</span>
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end
end
