defmodule Backplane.Admin.ClientsLive do
  use Backplane.Admin, :live_view

  alias Backplane.Clients
  alias Backplane.Clients.Client

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/system/clients",
       loading: true,
       editing: nil,
       form: nil,
       generated_token: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(generated_token: nil) |> load_clients()}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new", _, socket) do
    changeset = Client.changeset(%Client{}, %{scopes: ["*"]})

    {:noreply,
     assign(socket,
       editing: :new,
       form: to_form(changeset),
       generated_token: nil
     )}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Clients.get_client(id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Client not found"))}

      client ->
        changeset = Client.changeset(client, %{})

        {:noreply,
         assign(socket,
           editing: client,
           form: to_form(changeset),
           generated_token: nil
         )}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

  def handle_event("toggle_active", %{"id" => id, "active" => value}, socket)
      when value in ["true", "false"] do
    active = value == "true"

    case Clients.get_client(id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Client not found"))}

      %Client{active: ^active} ->
        {:noreply, load_clients(socket)}

      client ->
        case Clients.update_client(client, %{active: active}) do
          {:ok, _} ->
            Backplane.Admin.Audit.record("client.toggle", "client", client.id)
            {:noreply, load_clients(socket)}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, dgettext("errors", "Failed to toggle client status"))}
        end
    end
  end

  def handle_event("toggle_active", _, socket), do: {:noreply, socket}

  def handle_event("save", %{"client" => params}, socket) do
    case socket.assigns.editing do
      :new -> create_client(socket, params)
      %Client{} = client -> update_client(socket, client, params)
      nil -> {:noreply, socket}
    end
  end

  def handle_event("validate", %{"client" => params}, %{assigns: %{editing: editing}} = socket)
      when not is_nil(editing) do
    client = if editing == :new, do: %Client{}, else: editing
    changeset = Client.changeset(client, prepare_params(params, editing))
    {:noreply, assign(socket, form: to_form(%{changeset | action: :validate}))}
  end

  def handle_event("validate", _, socket), do: {:noreply, socket}

  def handle_event("delete", %{"id" => id}, socket) do
    case Clients.get_client(id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Client not found"))}

      client ->
        case Clients.delete_client(client) do
          {:ok, _} ->
            Backplane.Admin.Audit.record("client.delete", "client", client.id)

            {:noreply,
             socket
             |> put_flash(:info, dgettext("user", "Client %{name} deleted", name: client.name))
             |> assign(editing: nil, form: nil, generated_token: nil)
             |> load_clients()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, dgettext("errors", "Failed to delete client"))}
        end
    end
  end

  def handle_event("dismiss_token", _, socket) do
    {:noreply, assign(socket, generated_token: nil)}
  end

  def handle_event("rotate_token", %{"id" => id}, socket) do
    case Clients.get_client(id) do
      nil -> {:noreply, put_flash(socket, :error, dgettext("errors", "Client not found"))}
      client -> rotate_client_token(socket, client)
    end
  end

  def handle_event("rotate_token", _, socket) do
    {:noreply,
     put_flash(socket, :error, dgettext("errors", "Select a client before rotating its token"))}
  end

  defp rotate_client_token(socket, client) do
    case Clients.rotate_client_token(client) do
      {:ok, updated, token} ->
        Backplane.Admin.Audit.record("client.token_rotated", "client", updated.id)

        {:noreply,
         socket
         |> assign(editing: nil, form: nil, generated_token: token)
         |> put_flash(:info, dgettext("user", "Token replaced for %{name}", name: updated.name))
         |> load_clients()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Failed to rotate client token"))}
    end
  end

  defp create_client(socket, params) do
    case Clients.issue_client(prepare_params(params, :new)) do
      {:ok, client, token} ->
        Backplane.Admin.Audit.record("client.create", "client", client.id)

        {:noreply,
         socket
         |> put_flash(:info, dgettext("user", "Client %{name} created", name: client.name))
         |> assign(editing: nil, form: nil, generated_token: token)
         |> load_clients()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_client(socket, client, params) do
    attrs = prepare_params(params, client)

    case Clients.update_client(client, attrs) do
      {:ok, client} ->
        Backplane.Admin.Audit.record("client.update", "client", client.id)

        {:noreply,
         socket
         |> put_flash(:info, dgettext("user", "Client %{name} updated", name: client.name))
         |> assign(editing: nil, form: nil, generated_token: nil)
         |> load_clients()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp prepare_params(params, editing) do
    scopes =
      (params["scopes"] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    scopes = if scopes == [], do: ["*"], else: scopes

    attrs = if editing == :new, do: Map.take(params, ["name"]), else: %{}
    Map.put(attrs, "scopes", scopes)
  end

  defp load_clients(socket) do
    clients =
      try do
        Clients.list_clients()
      rescue
        _ -> []
      end

    assign(socket, loading: false, clients: clients)
  end

  defp relative_time(nil), do: dgettext("common", "Never")

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> dgettext("common", "%{count}s ago", count: diff)
      diff < 3600 -> dgettext("common", "%{count}m ago", count: div(diff, 60))
      diff < 86400 -> dgettext("common", "%{count}h ago", count: div(diff, 3600))
      true -> dgettext("common", "%{count}d ago", count: div(diff, 86400))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-w-0">
      <div class="mb-6 flex flex-wrap items-center justify-between gap-2">
        <h1 class="text-2xl font-bold">{dgettext("navigation", "Clients")}</h1>
        <.dm_btn id="new-client" variant="primary" size="sm" phx-click={JS.push("new") |> JS.push_focus()}>
          {dgettext("user", "New Client")}
        </.dm_btn>
      </div>

      <.dm_modal
        :if={@editing}
        id="client-form-modal"
        phx-hook="OpenAIServiceModal"
        phx-remove={JS.dispatch("click", to: "#client-form-modal .dialog-close") |> JS.pop_focus()}
      >
        <:title>
          {if @editing == :new,
            do: dgettext("user", "New Client"),
            else: dgettext("admin", "Edit %{name}", name: @editing.name)}
        </:title>
        <:body>
        <.form id="client-form" for={@form} phx-submit="save" phx-change="validate" class="space-y-4">
          <.dm_input
            id="client-name"
            name="client[name]"
            label={dgettext("common", "Name")}
            value={@form[:name].value}
            disabled={@editing != :new}
            autofocus={@editing == :new}
            placeholder="synapsis-prod"
          />
          <.form_error field={@form[:name]} />

          <.dm_input
            id="client-scopes"
            name="client[scopes]"
            label={dgettext("user", "Scopes (comma-separated)")}
            value={
              case @form[:scopes].value do
                list when is_list(list) -> Enum.join(list, ", ")
                other -> other || "*"
              end
            }
            placeholder="*, skill::*, math::evaluate"
            autofocus={@editing != :new}
          />
          <p class="text-xs text-on-surface-variant -mt-2">
            {dgettext("user", "Examples: * (all), skill::* (all skill tools), math::evaluate (single tool)")}
          </p>
          <.form_error field={@form[:scopes]} />

        </.form>
        </:body>
        <:footer>
          <.dm_btn id="cancel-client-form" type="button" variant="ghost" phx-click="cancel">
            {dgettext("common", "Cancel")}
          </.dm_btn>
          <.dm_btn
            type="submit"
            form="client-form"
            native_submit
            variant="primary"
            phx-disable-with={dgettext("common", "Saving...")}
          >
            {dgettext("common", "Save")}
          </.dm_btn>
        </:footer>
      </.dm_modal>

      <.dm_card :if={@generated_token} variant="bordered" class="mb-6 border-warning">
        <:title>{dgettext("user", "Bearer Token — copy now, shown only once")}</:title>
        <code id="issued-token" class="block text-sm text-warning font-mono break-all">
          {@generated_token}
        </code>
        <.dm_btn type="button" size="xs" phx-click="dismiss_token">{dgettext("common", "Dismiss")}</.dm_btn>
      </.dm_card>

      <p :if={@clients == []} id="clients-empty" class="text-on-surface-variant">
        {dgettext("user", "No clients configured. Create a client to issue a scoped access token.")}
      </p>

      <div :if={@clients != []} class="min-w-0 w-full overflow-x-auto">
        <.dm_table id="clients-table" data={@clients} style="min-width: 44rem" hover zebra>
          <:col :let={client} label={dgettext("common", "Name")}>
            <span class="break-all font-medium">{client.name}</span>
          </:col>
          <:col :let={client} label={dgettext("common", "Status")}>
            <div class="flex flex-wrap gap-1">
              <.dm_badge variant={if client.active, do: "success", else: "error"} size="sm">
                {if client.active,
                  do: dgettext("common", "Active"),
                  else: dgettext("common", "Inactive")}
              </.dm_badge>
              <.dm_badge :if={is_nil(client.token_digest)} variant="warning" size="sm">
                {dgettext("user", "Not issued")}
              </.dm_badge>
            </div>
          </:col>
          <:col :let={client} label={dgettext("user", "Scopes")}>
            <div class="flex flex-wrap gap-1">
              <.dm_badge :for={scope <- client.scopes} variant="info" size="sm" class="max-w-full">
                <span class="break-all">{scope}</span>
              </.dm_badge>
            </div>
          </:col>
          <:col :let={client} label={dgettext("user", "Token issued at")} class="whitespace-nowrap">
            <time :if={client.token_issued_at} datetime={DateTime.to_iso8601(client.token_issued_at)}>
              {Calendar.strftime(client.token_issued_at, "%Y-%m-%d %H:%M:%S UTC")}
            </time>
            <span :if={is_nil(client.token_issued_at)} class="text-on-surface-variant">
              {if client.token_digest, do: dgettext("common", "Unknown"), else: "—"}
            </span>
          </:col>
          <:col :let={client} label={dgettext("user", "Last seen")} class="whitespace-nowrap">
            {relative_time(client.last_seen_at)}
          </:col>
          <:col :let={client} label={dgettext("common", "Actions")}>
            <% status_action = if client.active, do: dgettext("common", "Deactivate"), else: dgettext("common", "Activate") %>
            <% token_action = if client.token_digest, do: dgettext("user", "Rotate Token"), else: dgettext("user", "Issue Token") %>
            <div class="flex items-center gap-1">
              <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Edit")} position="bottom">
                <.dm_btn
                  {tooltip_attrs}
                  id={"edit-client-#{client.id}"}
                  type="button"
                  variant="outline"
                  size="xs"
                  shape="circle"
                  aria-label={dgettext("admin", "Edit %{name}", name: client.name)}
                  phx-click={JS.push("edit", value: %{id: client.id}) |> JS.push_focus()}
                >
                  <.dm_mdi name="pencil" class="h-4 w-4" />
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip :let={tooltip_attrs} content={status_action} position="bottom">
                <.dm_btn
                  {tooltip_attrs}
                  id={"toggle-client-#{client.id}"}
                  type="button"
                  variant="ghost"
                  size="xs"
                  shape="circle"
                  aria-label={
                    if client.active,
                      do: dgettext("admin", "Deactivate %{name}", name: client.name),
                      else: dgettext("admin", "Activate %{name}", name: client.name)
                  }
                  confirm={
                    if client.active,
                      do: dgettext("user", "Deactivate %{name}? Its token will stop authenticating until the client is activated again.", name: client.name),
                      else: dgettext("user", "Activate %{name}? Its issued token can authenticate again.", name: client.name)
                  }
                  confirm_text={status_action}
                  cancel_text={dgettext("common", "Cancel")}
                  phx-click="toggle_active"
                  phx-value-id={client.id}
                  phx-value-active={to_string(!client.active)}
                >
                  <.dm_mdi name={if client.active, do: "pause", else: "play"} class="h-4 w-4" />
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip :let={tooltip_attrs} content={token_action} position="bottom">
                <.dm_btn
                  {tooltip_attrs}
                  id={"rotate-client-token-#{client.id}"}
                  type="button"
                  variant="outline"
                  size="xs"
                  shape="circle"
                  aria-label={
                    if client.token_digest,
                      do: dgettext("user", "Rotate token for %{name}", name: client.name),
                      else: dgettext("user", "Issue token for %{name}", name: client.name)
                  }
                  confirm={
                    if client.token_digest,
                      do: dgettext("user", "Rotate the token for %{name}? Its current token will stop authenticating this client.", name: client.name),
                      else: dgettext("user", "Issue a token for %{name}? It will be shown only once.", name: client.name)
                  }
                  confirm_text={token_action}
                  cancel_text={dgettext("common", "Cancel")}
                  phx-click="rotate_token"
                  phx-value-id={client.id}
                  phx-disable-with={dgettext("common", "Saving...")}
                >
                  <.dm_mdi name={if client.token_digest, do: "key-change", else: "key-plus"} class="h-4 w-4" />
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Delete")} position="bottom">
                <.dm_btn
                  {tooltip_attrs}
                  id={"delete-client-#{client.id}"}
                  type="button"
                  variant="error"
                  size="xs"
                  shape="circle"
                  aria-label={dgettext("admin", "Delete %{name}", name: client.name)}
                  confirm={
                    dgettext("user", "Delete client %{name}? This cannot be undone.", name: client.name)
                  }
                  phx-click="delete"
                  phx-value-id={client.id}
                >
                  <.dm_mdi name="delete" class="h-4 w-4" />
                </.dm_btn>
              </.dm_tooltip>
            </div>
          </:col>
        </.dm_table>
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
