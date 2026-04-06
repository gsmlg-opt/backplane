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
        <h1 class="text-2xl font-bold text-white">Clients</h1>
        <button
          phx-click="new"
          class="rounded-md bg-emerald-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-600"
        >
          New Client
        </button>
      </div>

      <div :if={@editing} class="bg-gray-900 border border-gray-800 rounded-lg p-6 mb-6">
        <h2 class="text-lg font-semibold text-white mb-4">
          {if @editing == :new, do: "New Client", else: "Edit Client"}
        </h2>
        <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Name</label>
            <input
              type="text"
              name="client[name]"
              value={@form[:name].value}
              disabled={@editing != :new}
              placeholder="synapsis-prod"
              class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white disabled:opacity-50"
            />
            <.form_error field={@form[:name]} />
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">
              Scopes
              <span class="text-gray-500">(comma-separated)</span>
            </label>
            <input
              type="text"
              name="client[scopes]"
              value={
                case @form[:scopes].value do
                  list when is_list(list) -> Enum.join(list, ", ")
                  other -> other || "*"
                end
              }
              placeholder="*, docs::*, git::repo-tree"
              class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
            />
            <p class="text-xs text-gray-500 mt-1">
              Examples: * (all), docs::* (all docs tools), git::repo-tree (single tool)
            </p>
            <.form_error field={@form[:scopes]} />
          </div>

          <div :if={@generated_token} class="bg-gray-950 border border-amber-800 rounded-lg p-4">
            <label class="block text-sm font-medium text-amber-400 mb-2">
              Bearer Token
              <span class="text-amber-600">(copy now — shown only once)</span>
            </label>
            <div class="flex items-center gap-2">
              <code class="flex-1 text-sm text-amber-300 bg-gray-900 px-3 py-2 rounded font-mono break-all">
                {@generated_token}
              </code>
              <button
                type="button"
                phx-click="regenerate_token"
                class="rounded px-2 py-1 text-xs bg-gray-700 text-gray-200 hover:bg-gray-600"
              >
                Regenerate
              </button>
            </div>
          </div>

          <div :if={@editing != :new && !@generated_token}>
            <button
              type="button"
              phx-click="regenerate_token"
              class="rounded px-3 py-1.5 text-xs bg-amber-900 text-amber-200 hover:bg-amber-800"
            >
              Rotate Token
            </button>
          </div>

          <div class="flex gap-2">
            <button
              type="submit"
              class="rounded-md bg-emerald-700 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-600"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="cancel"
              class="rounded-md bg-gray-700 px-4 py-2 text-sm font-medium text-white hover:bg-gray-600"
            >
              Cancel
            </button>
          </div>
        </.form>
      </div>

      <div :if={@clients == []} class="text-gray-400">
        No clients configured. All MCP requests use legacy token authentication.
      </div>

      <div class="space-y-4">
        <div
          :for={client <- @clients}
          class="bg-gray-900 border border-gray-800 rounded-lg p-4"
        >
          <div class="flex items-center justify-between">
            <div>
              <div class="flex items-center gap-2">
                <h3 class="text-sm font-medium text-white">{client.name}</h3>
                <span class={[
                  "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
                  if(client.active,
                    do: "bg-emerald-900 text-emerald-300",
                    else: "bg-red-900 text-red-300"
                  )
                ]}>
                  {if client.active, do: "Active", else: "Inactive"}
                </span>
              </div>
              <div class="flex flex-wrap gap-1 mt-2">
                <span
                  :for={scope <- client.scopes}
                  class="inline-flex items-center rounded-md bg-blue-900 px-2 py-0.5 text-xs font-medium text-blue-300"
                >
                  {scope}
                </span>
              </div>
              <p class="text-xs text-gray-500 mt-1">
                Last seen: {relative_time(client.last_seen_at)}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <button
                phx-click="toggle_active"
                phx-value-id={client.id}
                class={[
                  "rounded px-2 py-1 text-xs",
                  if(client.active,
                    do: "bg-amber-900 text-amber-200 hover:bg-amber-800",
                    else: "bg-emerald-900 text-emerald-200 hover:bg-emerald-800"
                  )
                ]}
              >
                {if client.active, do: "Deactivate", else: "Activate"}
              </button>
              <button
                phx-click="edit"
                phx-value-id={client.id}
                class="rounded px-2 py-1 text-xs bg-gray-700 text-gray-200 hover:bg-gray-600"
              >
                Edit
              </button>
              <button
                phx-click="delete"
                phx-value-id={client.id}
                data-confirm={"Delete client #{client.name}? This cannot be undone."}
                class="rounded px-2 py-1 text-xs bg-red-900 text-red-200 hover:bg-red-800"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp form_error(assigns) do
    ~H"""
    <div
      :for={msg <- Enum.map(@field.errors, &translate_error/1)}
      class="text-xs text-red-400 mt-1"
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
