defmodule BackplaneWeb.HostAgentsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Skills.{Host, HostConnectionRegistry, Hosts}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: HostConnectionRegistry.subscribe()

    {:ok,
     assign(socket,
       current_path: "/admin/system/host-agents",
       auth_tokens: [],
       connections: [],
       connection: nil,
       hosts: [],
       generated_token: nil,
       token_modal_open: false,
       agent_modal_open: false,
       editing_host: nil,
       agent_form: empty_agent_form(),
       agent_error: nil,
       token_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :config -> {:noreply, load_config(socket, params["id"])}
      :auth -> {:noreply, load_auth(socket)}
      :manage -> {:noreply, load_manage(socket)}
      _ -> {:noreply, load_index(socket)}
    end
  end

  @impl true
  def handle_info(:connections_changed, socket) do
    case socket.assigns.live_action do
      :config ->
        host_id = socket.assigns.connection && socket.assigns.connection.host.id
        {:noreply, load_config(socket, host_id)}

      _ ->
        {:noreply, load_index(socket)}
    end
  end

  @impl true
  def handle_event("open_auth_token_modal", _params, socket) do
    {:noreply, assign(socket, token_modal_open: true, token_error: nil, generated_token: nil)}
  end

  def handle_event("close_auth_token_modal", _params, socket) do
    {:noreply, assign(socket, token_modal_open: false, token_error: nil)}
  end

  def handle_event("create_auth_token", %{"token" => params}, socket) do
    case Hosts.create_auth_token(normalize_token_params(params)) do
      {:ok, auth_token, token} ->
        {:noreply,
         socket
         |> put_flash(:info, "Auth token #{auth_token.name} created")
         |> assign(generated_token: token, token_error: nil, token_modal_open: false)
         |> load_auth()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, token_error: changeset_summary(changeset), token_modal_open: true)}
    end
  end

  def handle_event("delete_auth_token", %{"id" => id}, socket) do
    case Hosts.get_auth_token(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Auth token not found")}

      auth_token ->
        case Hosts.delete_auth_token(auth_token) do
          {:ok, _auth_token} ->
            {:noreply, load_auth(socket)}

          {:error, :assigned} ->
            {:noreply, put_flash(socket, :error, "Unassign token from agent before deleting")}
        end
    end
  end

  def handle_event("open_agent_modal", _params, socket) do
    {:noreply,
     assign(socket,
       agent_modal_open: true,
       editing_host: nil,
       agent_form: empty_agent_form(),
       agent_error: nil
     )}
  end

  def handle_event("save_agent", %{"agent" => params}, %{assigns: %{editing_host: nil}} = socket) do
    normalized_params = normalize_agent_params(params)

    case Hosts.create_agent(normalized_params) do
      {:ok, host} ->
        {:noreply,
         socket
         |> put_flash(:info, "Host agent #{host.name} created")
         |> assign(agent_modal_open: false)
         |> load_manage()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           agent_error: changeset_summary(changeset),
           agent_form: normalized_params,
           agent_modal_open: true
         )}
    end
  end

  def handle_event("save_agent", %{"agent" => params}, socket) do
    normalized_params = normalize_agent_params(params)

    case Hosts.update_agent(socket.assigns.editing_host, normalized_params) do
      {:ok, host} ->
        {:noreply,
         socket
         |> put_flash(:info, "Host agent #{host.name} updated")
         |> assign(agent_modal_open: false)
         |> load_manage()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           agent_error: changeset_summary(changeset),
           agent_form: normalized_params,
           agent_modal_open: true
         )}
    end
  end

  def handle_event("edit_agent", %{"id" => id}, socket) do
    case Hosts.get_host(id) do
      %Host{} = host ->
        {:noreply,
         assign(socket,
           editing_host: host,
           agent_form: %{
             "name" => host.name,
             "auth_token_ids" => Hosts.auth_token_ids_for_host(host)
           },
           agent_modal_open: true,
           agent_error: nil
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Host agent not found")}
    end
  end

  def handle_event("cancel_agent_edit", _params, socket) do
    {:noreply,
     assign(socket,
       agent_modal_open: false,
       editing_host: nil,
       agent_form: empty_agent_form(),
       agent_error: nil
     )}
  end

  def handle_event("close_agent_modal", _params, socket) do
    {:noreply,
     assign(socket,
       agent_modal_open: false,
       editing_host: nil,
       agent_form: empty_agent_form(),
       agent_error: nil
     )}
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    case Hosts.get_host(id) do
      %Host{} = host ->
        case Hosts.delete_agent(host) do
          {:ok, _host} -> {:noreply, load_manage(socket)}
          {:error, _changeset} -> {:noreply, put_flash(socket, :error, "Failed to remove agent")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Host agent not found")}
    end
  end

  @impl true
  def render(%{live_action: :auth} = assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 class="text-2xl font-bold">Agent Auth</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            Create and manage auth tokens for host agents. Agents use these tokens to connect to Backplane.
          </p>
        </div>

        <.dm_btn
          id="open-auth-token-modal"
          type="button"
          variant="primary"
          size="sm"
          phx-click="open_auth_token_modal"
        >
          Create Token
        </.dm_btn>
      </div>

      <.token_notice :if={@generated_token} token={@generated_token} />

      <section class="space-y-6">
        <.dm_card variant="bordered">
          <:title>Agent Auth</:title>
          <div :if={@auth_tokens == []} class="text-sm text-on-surface-variant">
            No auth tokens created.
          </div>

          <div :if={@auth_tokens != []} class="overflow-x-auto">
            <table id="host-auth-table" class="min-w-full text-sm">
              <thead class="bg-surface-container-high text-on-surface">
                <tr>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">Name</th>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">In Use</th>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">Actions</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-outline-variant">
                <tr :for={entry <- @auth_tokens} class="hover:bg-surface-container-high">
                  <td class="px-3 py-2 align-top">
                    <span class="font-medium">{entry.token.name}</span>
                  </td>
                  <td class="px-3 py-2 align-top">
                    {assigned_host_name(entry)}
                  </td>
                  <td class="px-3 py-2 align-top">
                    <.dm_btn
                      id={"delete-auth-token-#{entry.token.id}"}
                      type="button"
                      variant="error"
                      size="xs"
                      phx-click="delete_auth_token"
                      phx-value-id={entry.token.id}
                    >
                      Delete
                    </.dm_btn>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.dm_card>
      </section>

      <.auth_token_modal :if={@token_modal_open} token_error={@token_error} />
    </div>
    """
  end

  def render(%{live_action: :manage} = assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 class="text-2xl font-bold">Agent Management</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            Add, edit, and remove host agents. Assign one or more Agent Auth tokens when the agent should be allowed to connect.
          </p>
        </div>

        <.dm_btn
          id="open-agent-modal"
          type="button"
          variant="primary"
          size="sm"
          phx-click="open_agent_modal"
        >
          Add Agent
        </.dm_btn>
      </div>

      <section class="space-y-6">
        <.dm_card variant="bordered">
          <:title>Managed Agents</:title>
          <div :if={@hosts == []} class="text-sm text-on-surface-variant">
            No host agents registered.
          </div>

          <div :if={@hosts != []} class="overflow-x-auto">
            <table id="agent-management-table" class="min-w-full text-sm">
              <thead class="bg-surface-container-high text-on-surface">
                <tr>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">Name</th>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">Auth Tokens</th>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">Actions</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-outline-variant">
                <tr :for={host <- @hosts} class="hover:bg-surface-container-high">
                  <td class="px-3 py-2 align-top">
                    <span class="font-medium">{host.name}</span>
                  </td>
                  <td class="px-3 py-2 align-top">
                    <span class="text-sm">{agent_token_names(host)}</span>
                  </td>
                  <td class="px-3 py-2 align-top">
                    <div class="flex flex-wrap gap-2">
                      <.dm_btn
                        id={"edit-agent-#{host.id}"}
                        type="button"
                        variant="primary"
                        size="xs"
                        phx-click="edit_agent"
                        phx-value-id={host.id}
                      >
                        Edit
                      </.dm_btn>
                      <.dm_btn
                        id={"delete-agent-#{host.id}"}
                        type="button"
                        variant="error"
                        size="xs"
                        phx-click="delete_agent"
                        phx-value-id={host.id}
                      >
                        Remove
                      </.dm_btn>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.dm_card>
      </section>

      <.agent_modal
        :if={@agent_modal_open}
        auth_tokens={@auth_tokens}
        editing_host={@editing_host}
        agent_form={@agent_form}
        agent_error={@agent_error}
      />
    </div>
    """
  end

  def render(%{live_action: :config} = assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <.link navigate={~p"/admin/system/host-agents"} class="text-sm text-primary underline">
          Host agents
        </.link>
        <div class="mt-2 flex flex-wrap items-center gap-3">
          <h1 class="text-2xl font-bold">Host Agent Config</h1>
          <.dm_badge variant="success" size="sm">Connected</.dm_badge>
        </div>
        <p class="mt-1 text-sm text-on-surface-variant">{@connection.host.name}</p>
      </div>

      <div class="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1fr)_24rem]">
        <div class="space-y-6">
          <.dm_card variant="bordered">
            <:title>Reported Config</:title>
            <div :if={is_nil(@connection.config)} class="text-sm text-on-surface-variant">
              Config not reported yet.
            </div>

            <div :if={@connection.config} class="space-y-4">
              <div :if={config_targets(@connection.config) == []} class="text-sm text-on-surface-variant">
                No targets reported.
              </div>
              <div :if={config_targets(@connection.config) != []} class="overflow-x-auto">
                <table id="host-config-targets-table" class="min-w-full text-sm">
                  <thead class="bg-surface-container-high text-on-surface">
                    <tr>
                      <th scope="col" class="px-3 py-2 text-left font-semibold">Name</th>
                      <th scope="col" class="px-3 py-2 text-left font-semibold">Runtime</th>
                      <th scope="col" class="px-3 py-2 text-left font-semibold">Path</th>
                      <th scope="col" class="px-3 py-2 text-left font-semibold">Enabled</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-outline-variant">
                    <tr :for={target <- config_targets(@connection.config)}>
                      <td class="px-3 py-2 align-top font-medium">{target["name"] || "-"}</td>
                      <td class="px-3 py-2 align-top">{target["runtime"] || "-"}</td>
                      <td class="px-3 py-2 align-top">
                        <code class="text-xs break-all">{target["path"] || "-"}</code>
                      </td>
                      <td class="px-3 py-2 align-top">
                        <.dm_badge
                          variant={if target["enabled"] == false, do: "error", else: "success"}
                          size="sm"
                        >
                          {if target["enabled"] == false, do: "No", else: "Yes"}
                        </.dm_badge>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </.dm_card>

          <.dm_card :if={@connection.config} variant="bordered">
            <:title>Raw Config JSON</:title>
            <pre class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-xs"><code>{raw_config_json(@connection.config)}</code></pre>
          </.dm_card>
        </div>

        <aside class="space-y-6">
          <.dm_card variant="bordered">
            <:title>Connection</:title>
            <dl class="space-y-3 text-sm">
              <div>
                <dt class="font-medium">Name</dt>
                <dd class="text-on-surface-variant">{@connection.host.name}</dd>
              </div>
              <div>
                <dt class="font-medium">Agent version</dt>
                <dd class="text-on-surface-variant">{agent_version(@connection)}</dd>
              </div>
              <div>
                <dt class="font-medium">Host ID</dt>
                <dd class="font-mono text-xs break-all text-on-surface-variant">
                  {@connection.host.id}
                </dd>
              </div>
              <div>
                <dt class="font-medium">Connected</dt>
                <dd class="text-on-surface-variant">{relative_time(@connection.connected_at)}</dd>
              </div>
            </dl>
          </.dm_card>
        </aside>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Host Agents</h1>
        <p class="mt-1 text-sm text-on-surface-variant">
          Host agents with active WebSocket connections.
        </p>
      </div>

      <.connect_guide />

      <div :if={@connections == []} class="text-sm text-on-surface-variant">
        No host agents connected.
      </div>

      <div
        :if={@connections != []}
        class="overflow-x-auto rounded-md border border-outline-variant bg-surface-container"
      >
        <table id="host-agents-table" class="min-w-full text-sm">
          <thead class="bg-surface-container-high text-on-surface">
            <tr>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Name</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Status</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Agent Version</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Targets</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Connected</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Config</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-outline-variant">
            <tr :for={connection <- @connections} class="hover:bg-surface-container-high">
              <td class="px-3 py-2 align-top">
                <span class="font-medium">{connection.host.name}</span>
              </td>
              <td class="px-3 py-2 align-top">
                <.dm_badge variant={status_variant(connection_status(connection))} size="sm">
                  {connection_status(connection)}
                </.dm_badge>
              </td>
              <td class="px-3 py-2 align-top">{agent_version(connection)}</td>
              <td class="px-3 py-2 align-top">{targets_summary(connection)}</td>
              <td class="px-3 py-2 align-top">{relative_time(connection.connected_at)}</td>
              <td class="px-3 py-2 align-top">
                <.link
                  navigate={~p"/admin/system/host-agents/#{connection.host.id}/config"}
                  class="text-primary underline"
                >
                  Config
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp load_index(socket) do
    assign(socket,
      current_path: "/admin/system/host-agents",
      auth_tokens: [],
      connections: HostConnectionRegistry.list_connected(),
      connection: nil,
      hosts: [],
      generated_token: nil,
      token_modal_open: false,
      agent_modal_open: false,
      editing_host: nil,
      agent_form: empty_agent_form(),
      agent_error: nil,
      token_error: nil
    )
  end

  defp load_auth(socket) do
    assign(socket,
      current_path: "/admin/system/host-agents/auth",
      auth_tokens: Hosts.list_auth_tokens_with_assignments(),
      connections: [],
      connection: nil,
      hosts: [],
      token_modal_open: false,
      agent_modal_open: false,
      editing_host: nil,
      agent_form: empty_agent_form(),
      agent_error: nil,
      token_error: nil
    )
  end

  defp load_manage(socket) do
    assign(socket,
      current_path: "/admin/system/host-agents/manage",
      auth_tokens: Hosts.list_auth_tokens_with_assignments(),
      connections: [],
      connection: nil,
      hosts: Hosts.list_hosts_with_auth_tokens(),
      generated_token: nil,
      token_modal_open: false,
      agent_modal_open: false,
      editing_host: nil,
      agent_form: empty_agent_form(),
      agent_error: nil,
      token_error: nil
    )
  end

  defp load_config(socket, nil) do
    socket
    |> put_flash(:error, "Agent is not connected.")
    |> push_navigate(to: ~p"/admin/system/host-agents")
  end

  defp load_config(socket, id) do
    case HostConnectionRegistry.get(id) do
      nil ->
        socket
        |> put_flash(:error, "Agent is not connected.")
        |> push_navigate(to: ~p"/admin/system/host-agents")

      connection ->
        assign(socket,
          current_path: "/admin/system/host-agents/#{connection.host.id}/config",
          auth_tokens: [],
          connections: [],
          connection: connection,
          hosts: [],
          generated_token: nil,
          token_modal_open: false,
          agent_modal_open: false,
          editing_host: nil,
          agent_form: empty_agent_form(),
          agent_error: nil,
          token_error: nil
        )
    end
  end

  defp normalize_token_params(params) do
    Map.update(params, "name", "", &String.trim/1)
  end

  defp normalize_agent_params(params) do
    params
    |> Map.update("name", "", &String.trim/1)
    |> Map.put_new("auth_token_ids", [])
  end

  defp empty_agent_form do
    %{"name" => "", "auth_token_ids" => []}
  end

  defp assigned_host_name(%{assigned_host: %Host{name: name}}), do: name
  defp assigned_host_name(_entry), do: "No"

  defp token_checked?(token_id, %{"auth_token_ids" => auth_token_ids}) do
    to_string(token_id) in Enum.map(auth_token_ids, &to_string/1)
  end

  defp token_disabled?(%{assigned_host: nil}, _editing_host), do: false
  defp token_disabled?(%{assigned_host: %Host{id: host_id}}, %Host{id: host_id}), do: false
  defp token_disabled?(%{assigned_host: %Host{}}, _editing_host), do: true

  defp token_assignment_label(%{assigned_host: nil}, _editing_host), do: "Unassigned"

  defp token_assignment_label(%{assigned_host: %Host{id: host_id}}, %Host{id: host_id}),
    do: "Assigned to this agent"

  defp token_assignment_label(%{assigned_host: %Host{name: name}}, _editing_host),
    do: "Assigned to #{name}"

  defp agent_token_names(%Host{auth_tokens: auth_tokens}) when is_list(auth_tokens) do
    case Enum.map(auth_tokens, & &1.name) do
      [] -> "No tokens"
      names -> Enum.join(names, ", ")
    end
  end

  defp connection_status(%{runtime: %{status: status}}) when is_binary(status), do: status
  defp connection_status(_connection), do: "connected"

  defp agent_version(%{runtime: %{agent_version: version}}) when is_binary(version), do: version
  defp agent_version(_connection), do: "-"

  defp targets_summary(%{runtime: %{targets: targets}}) when is_list(targets) do
    targets
    |> Enum.map(fn
      %{"name" => name} -> name
      %{name: name} -> name
      name when is_binary(name) -> name
      _target -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> to_string(length(targets))
      names -> Enum.join(names, ", ")
    end
  end

  defp targets_summary(_connection), do: "0"

  defp config_targets(%{"targets" => targets}) when is_list(targets), do: targets
  defp config_targets(_config), do: []

  defp raw_config_json(config) do
    Jason.encode!(config, pretty: true)
  end

  defp relative_time(nil), do: "Never"

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp status_variant("online"), do: "success"
  defp status_variant("connected"), do: "success"
  defp status_variant("installed"), do: "success"
  defp status_variant("failed"), do: "error"
  defp status_variant("error"), do: "error"
  defp status_variant("unknown"), do: "neutral"
  defp status_variant(_), do: "info"

  defp changeset_summary(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{field} #{&1}")
    end)
    |> Enum.join(", ")
  end

  defp auth_token_modal(assigns) do
    ~H"""
    <.modal id="host-auth-token-modal" title="Create Token" on_cancel="close_auth_token_modal">
      <form id="host-auth-token-form" phx-submit="create_auth_token" class="space-y-4">
        <.dm_input
          id="auth-token-name"
          name="token[name]"
          label="Name"
          value=""
          placeholder="workstations"
        />
        <p :if={@token_error} class="text-sm text-error">{@token_error}</p>
        <div class="flex flex-wrap justify-end gap-2">
          <.dm_btn type="button" variant="outline" size="sm" phx-click="close_auth_token_modal">
            Cancel
          </.dm_btn>
          <.dm_btn type="submit" variant="primary" size="sm">Create Token</.dm_btn>
        </div>
      </form>
    </.modal>
    """
  end

  defp agent_modal(assigns) do
    assigns =
      assign(assigns,
        visible_auth_tokens: visible_auth_tokens(assigns.auth_tokens, assigns.editing_host)
      )

    ~H"""
    <.modal
      id="host-agent-modal"
      title={if @editing_host, do: "Edit Agent", else: "Add Agent"}
      on_cancel="close_agent_modal"
    >
      <form id="host-agent-form" phx-submit="save_agent" class="space-y-4">
        <.dm_input
          id="agent-name"
          name="agent[name]"
          label="Name"
          value={@agent_form["name"]}
          placeholder="workstation"
        />

        <fieldset class="space-y-3">
          <legend class="text-sm font-medium text-on-surface">Auth Tokens</legend>
          <p :if={@visible_auth_tokens == []} class="text-sm text-on-surface-variant">
            No auth tokens available.
          </p>
          <label
            :for={entry <- @visible_auth_tokens}
            class={[
              "flex items-start gap-2 rounded border border-outline-variant px-3 py-2 text-sm",
              token_disabled?(entry, @editing_host) && "opacity-60"
            ]}
          >
            <input
              type="checkbox"
              name="agent[auth_token_ids][]"
              value={entry.token.id}
              checked={token_checked?(entry.token.id, @agent_form)}
              disabled={token_disabled?(entry, @editing_host)}
              class="mt-1"
            />
            <span>
              <span class="block font-medium">{entry.token.name}</span>
              <span class="block text-xs text-on-surface-variant">
                {token_assignment_label(entry, @editing_host)}
              </span>
            </span>
          </label>
        </fieldset>

        <p :if={@agent_error} class="text-sm text-error">{@agent_error}</p>
        <div class="flex flex-wrap justify-end gap-2">
          <.dm_btn type="button" variant="outline" size="sm" phx-click="cancel_agent_edit">
            Cancel
          </.dm_btn>
          <.dm_btn type="submit" variant="primary" size="sm">
            {if @editing_host, do: "Update Agent", else: "Add Agent"}
          </.dm_btn>
        </div>
      </form>
    </.modal>
    """
  end

  defp visible_auth_tokens(auth_tokens, nil) do
    Enum.filter(auth_tokens, &is_nil(&1.assigned_host))
  end

  defp visible_auth_tokens(auth_tokens, _editing_host), do: auth_tokens

  defp modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4 py-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
    >
      <div class="w-full max-w-lg rounded-lg border border-outline-variant bg-surface shadow-xl">
        <div class="flex items-center justify-between border-b border-outline-variant px-5 py-4">
          <h2 id={"#{@id}-title"} class="text-lg font-semibold text-on-surface">{@title}</h2>
          <button
            type="button"
            class="rounded px-2 py-1 text-sm text-on-surface-variant hover:bg-surface-container-high hover:text-on-surface"
            phx-click={@on_cancel}
            aria-label="Close"
          >
            x
          </button>
        </div>
        <div class="px-5 py-5">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  defp connect_guide(assigns) do
    ~H"""
    <.dm_card variant="bordered" class="mb-6">
      <:title>Connect a host agent</:title>
      <div class="space-y-3 text-sm">
        <ol class="list-decimal space-y-2 pl-5">
          <li>
            In <strong>Agent Auth</strong>, create a token and copy it (shown once).
          </li>
          <li>
            In <strong>Agent Management</strong>, add an agent and assign the token.
          </li>
          <li>
            On the host machine, install Backplane (or check out the repo) and run
            <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">mix agent.run</code>.
            The agent writes a sample config to
            <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">~/.config/backplane/host_agent.yaml</code>
            on first run. Edit it (see below) and re-run.
          </li>
        </ol>

        <details class="mt-2">
          <summary class="cursor-pointer text-sm font-medium text-primary">
            Sample <code>~/.config/backplane/host_agent.yaml</code>
          </summary>
          <pre class="mt-3 overflow-x-auto rounded-md bg-surface-container-high p-4 text-xs"><code>{sample_yaml()}</code></pre>
        </details>

        <p class="text-on-surface-variant">
          The agent reads YAML from
          <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">$BACKPLANE_HOST_AGENT_CONFIG</code>
          if set, otherwise from
          <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">$XDG_CONFIG_HOME/backplane/host_agent.yaml</code>
          (defaults to
          <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">~/.config/backplane/host_agent.yaml</code>).
        </p>

        <details class="mt-3">
          <summary class="cursor-pointer text-sm font-medium text-primary">
            Local Memory HTTP API
          </summary>
          <div class="mt-3 space-y-2">
            <p>
              Set <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">agent.http_port</code>
              in the config to expose a local memory API to other processes on the host.
              The agent proxies these calls to Backplane through the WebSocket channel.
            </p>
            <ul class="list-disc space-y-1 pl-5">
              <li>
                <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">POST /memory/:agent_id/call/:method</code>
                — direct call. JSON body becomes the method args.
                <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">:method</code>
                is one of: remember, recall, list, forget, stats.
              </li>
              <li>
                <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">POST /memory/:agent_id/mcp</code>
                — JSON-RPC MCP endpoint. Supports
                <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">initialize</code>,
                <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">tools/list</code>,
                <code class="rounded bg-surface-container-high px-1.5 py-0.5 text-xs">tools/call</code>.
              </li>
            </ul>
          </div>
        </details>
      </div>
    </.dm_card>
    """
  end

  defp sample_yaml do
    """
    agent:
      machine_name: my-host
      hub_url: #{hub_url_hint()}
      token: PASTE_TOKEN_HERE
      interval_ms: 60000
      manifest_path: ~/.local/share/backplane/host_agent/manifest.json
      work_dir: ~/.local/share/backplane/host_agent

    targets:
      - name: agents
        runtime: agent-skills
        path: ~/.local/share/backplane/host_agent/skills
        enabled: true
    """
  end

  defp hub_url_hint do
    case Application.get_env(:backplane_web, BackplaneWeb.Endpoint, []) |> Keyword.get(:url) do
      [host: host, port: port] -> "http://#{host}:#{port}"
      _ -> "http://localhost:4220"
    end
  end

  defp token_notice(assigns) do
    ~H"""
    <div class="mb-6 rounded-md border border-warning bg-surface-container px-4 py-3">
      <div class="text-sm font-medium text-warning">Host agent token</div>
      <p class="mt-1 text-xs text-on-surface-variant">Copy this value now. It is shown only once.</p>
      <code class="mt-3 block rounded bg-surface-container-high px-3 py-2 font-mono text-xs break-all text-warning">
        {@token}
      </code>
    </div>
    """
  end
end
