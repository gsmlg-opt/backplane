defmodule BackplaneWeb.ClientsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Clients
  alias Backplane.Clients.Client

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/clients",
       loading: true,
       editing: nil,
       form: nil,
       generated_token: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_clients(socket)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new", _, socket) do
    token = generate_token()
    changeset = Client.changeset(%Client{}, %{scopes: ["*"]})

    {:noreply,
     assign(socket,
       editing: :new,
       form: to_form(changeset),
       generated_token: token,
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
          Client.changeset(%Client{}, prepare_params(params, socket.assigns.generated_token))

        %Client{} = client ->
          Client.changeset(client, prepare_params(params, nil))
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
            {:noreply,
             socket
             |> put_flash(:info, "Client #{client.name} deleted")
             |> assign(editing: nil, form: nil)
             |> load_clients()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete client")}
        end
    end
  end

  def handle_event("regenerate_token", _, socket) do
    {:noreply, assign(socket, generated_token: generate_token())}
  end

  defp create_client(socket, params) do
    token = socket.assigns.generated_token
    attrs = prepare_params(params, token)

    case Clients.create_client(Map.put(attrs, "token", token)) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(:info, "Client #{client.name} created")
         |> assign(editing: nil, form: nil, generated_token: nil)
         |> load_clients()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_client(socket, client, params) do
    attrs = prepare_params(params, nil)
    # If a new token was generated during edit, include it
    attrs =
      if socket.assigns.generated_token do
        Map.put(attrs, "token", socket.assigns.generated_token)
      else
        attrs
      end

    case Clients.update_client(client, attrs) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(:info, "Client #{client.name} updated")
         |> assign(editing: nil, form: nil, generated_token: nil)
         |> load_clients()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp prepare_params(params, _token) do
    scopes =
      (params["scopes"] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    scopes = if scopes == [], do: ["*"], else: scopes

    # Build a token_hash placeholder for changeset validation (actual hashing happens in context)
    Map.put(params, "scopes", scopes)
    |> Map.put("token_hash", "placeholder")
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

  defp generate_token do
    "bp_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
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
        <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-4">
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

          <div :if={@generated_token} class="bg-surface-container border border-warning rounded-lg p-4">
            <label class="block text-sm font-medium text-warning mb-2">
              Bearer Token
              <span class="text-on-surface-variant">(copy now — shown only once)</span>
            </label>
            <div class="flex items-center gap-2">
              <code class="flex-1 text-sm text-warning bg-surface-container-high px-3 py-2 rounded font-mono break-all">
                {@generated_token}
              </code>
              <.dm_btn variant="ghost" size="xs" phx-click="regenerate_token">Regenerate</.dm_btn>
            </div>
          </div>

          <div :if={@editing != :new && !@generated_token}>
            <.dm_btn variant="warning" size="xs" phx-click="regenerate_token">Rotate Token</.dm_btn>
          </div>

          <div class="flex gap-2">
            <.dm_btn type="submit" variant="primary">Save</.dm_btn>
            <.dm_btn type="button" phx-click="cancel">Cancel</.dm_btn>
          </div>
        </.form>
      </.dm_card>

      <div :if={@clients == []} class="text-on-surface-variant">
        No clients configured. All MCP requests use legacy token authentication.
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
