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
       generated_token: nil,
       scope_input: ""
     )}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Clients.get_client(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Client not found")}

      client ->
        changeset = Client.changeset(client, %{})

        {:noreply,
         assign(socket,
           editing: client,
           form: to_form(changeset),
           generated_token: nil,
           scope_input: ""
         )}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, form: nil, generated_token: nil)}
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    case Clients.get_client(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Client not found")}

      client ->
        case Clients.update_client(client, %{active: !client.active}) do
          {:ok, _} ->
            Backplane.Admin.Audit.record("client.toggle", "client", client.id)
            {:noreply, load_clients(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle client status")}
        end
    end
  end

  def handle_event("save", %{"client" => params}, socket) do
    case socket.assigns.editing do
      :new -> create_client(socket, params)
      %Client{} = client -> update_client(socket, client, params)
    end
  end

  def handle_event("validate", %{"client" => params}, socket) do
    changeset =
      case socket.assigns.editing do
        :new ->
          Client.changeset(%Client{}, prepare_params(params))

        %Client{} = client ->
          Client.changeset(client, prepare_params(params))
      end

    {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Clients.get_client(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Client not found")}

      client ->
        case Clients.delete_client(client) do
          {:ok, _} ->
            Backplane.Admin.Audit.record("client.delete", "client", client.id)

            {:noreply,
             socket
             |> put_flash(:info, "Client #{client.name} deleted")
             |> assign(editing: nil, form: nil, generated_token: nil)
             |> load_clients()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete client")}
        end
    end
  end

  def handle_event("dismiss_token", _, socket) do
    {:noreply, assign(socket, generated_token: nil)}
  end

  def handle_event("rotate_token", _, %{assigns: %{editing: %Client{} = client}} = socket) do
    case Clients.rotate_client_token(client) do
      {:ok, updated, token} ->
        Backplane.Admin.Audit.record("client.token_rotated", "client", updated.id)

        {:noreply,
         socket
         |> assign(editing: nil, form: nil, generated_token: token)
         |> put_flash(:info, "Token replaced for #{updated.name}")
         |> load_clients()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate client token")}
    end
  end

  def handle_event("rotate_token", _, socket) do
    {:noreply, put_flash(socket, :error, "Select a client before rotating its token")}
  end

  defp create_client(socket, params) do
    case Clients.issue_client(prepare_params(params)) do
      {:ok, client, token} ->
        Backplane.Admin.Audit.record("client.create", "client", client.id)

        {:noreply,
         socket
         |> put_flash(:info, "Client #{client.name} created")
         |> assign(editing: nil, form: nil, generated_token: token)
         |> load_clients()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_client(socket, client, params) do
    attrs = prepare_params(params)

    case Clients.update_client(client, attrs) do
      {:ok, client} ->
        Backplane.Admin.Audit.record("client.update", "client", client.id)

        {:noreply,
         socket
         |> put_flash(:info, "Client #{client.name} updated")
         |> assign(editing: nil, form: nil, generated_token: nil)
         |> load_clients()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp prepare_params(params) do
    scopes =
      (params["scopes"] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    scopes = if scopes == [], do: ["*"], else: scopes

    Map.put(params, "scopes", scopes)
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

  defp relative_time(nil), do: "Never"

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Clients</h1>
        <.dm_btn variant="primary" size="sm" phx-click="new">New Client</.dm_btn>
      </div>

      <.dm_card :if={@editing} variant="bordered" class="mb-6">
        <:title>
          {if @editing == :new, do: "New Client", else: "Edit Client"}
        </:title>
        <.form id="client-form" for={@form} phx-submit="save" phx-change="validate" class="space-y-4">
          <.dm_input
            id="client-name"
            name="client[name]"
            label="Name"
            value={@form[:name].value}
            disabled={@editing != :new}
            placeholder="synapsis-prod"
          />
          <.form_error field={@form[:name]} />

          <.dm_input
            id="client-scopes"
            name="client[scopes]"
            label="Scopes (comma-separated)"
            value={
              case @form[:scopes].value do
                list when is_list(list) -> Enum.join(list, ", ")
                other -> other || "*"
              end
            }
            placeholder="*, skill::*, math::evaluate"
          />
          <p class="text-xs text-on-surface-variant -mt-2">
            Examples: * (all), skill::* (all skill tools), math::evaluate (single tool)
          </p>
          <.form_error field={@form[:scopes]} />

          <div :if={@editing != :new}>
            <.dm_btn
              type="button"
              variant="warning"
              size="xs"
              phx-click="rotate_token"
              confirm="Replace this client's token now? Its current token will stop working."
            >
              {if is_nil(@editing.token_digest), do: "Issue Token", else: "Rotate Token"}
            </.dm_btn>
          </div>

          <div class="flex gap-2">
            <.dm_btn type="submit" variant="primary">Save</.dm_btn>
            <.dm_btn type="button" phx-click="cancel">Cancel</.dm_btn>
          </div>
        </.form>
      </.dm_card>

      <.dm_card :if={@generated_token} variant="bordered" class="mb-6 border-warning">
        <:title>Bearer Token — copy now, shown only once</:title>
        <code id="issued-token" class="block text-sm text-warning font-mono break-all">
          {@generated_token}
        </code>
        <.dm_btn type="button" size="xs" phx-click="dismiss_token">Dismiss</.dm_btn>
      </.dm_card>

      <div :if={@clients == []} class="text-on-surface-variant">
        No clients configured. Create a client to issue a scoped access token.
      </div>

      <div class="space-y-4">
        <.dm_card :for={client <- @clients} variant="bordered">
          <div class="flex items-center justify-between">
            <div>
              <div class="flex items-center gap-2">
                <h3 class="text-sm font-medium">{client.name}</h3>
                <.dm_badge
                  variant={if client.active, do: "success", else: "error"}
                  size="sm"
                >
                  {if client.active, do: "Active", else: "Inactive"}
                </.dm_badge>
              </div>
              <.dm_badge :if={is_nil(client.token_digest)} variant="warning" size="sm">
                Not issued
              </.dm_badge>
              <div class="flex flex-wrap gap-1 mt-2">
                <.dm_badge
                  :for={scope <- client.scopes}
                  variant="info"
                  size="sm"
                >
                  {scope}
                </.dm_badge>
              </div>
              <p class="text-xs text-on-surface-variant mt-1">
                Last seen: {relative_time(client.last_seen_at)}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <.dm_btn
                variant={if client.active, do: "warning", else: "success"}
                size="xs"
                phx-click="toggle_active"
                phx-value-id={client.id}
              >
                {if client.active, do: "Deactivate", else: "Activate"}
              </.dm_btn>
              <.dm_btn size="xs" phx-click="edit" phx-value-id={client.id}>Edit</.dm_btn>
              <.dm_btn
                variant="error"
                size="xs"
                confirm={"Delete client #{client.name}? This cannot be undone."}
                phx-click="delete"
                phx-value-id={client.id}
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
