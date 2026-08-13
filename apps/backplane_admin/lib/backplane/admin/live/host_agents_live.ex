defmodule Backplane.Admin.HostAgentsLive do
  use Backplane.Admin, :live_view

  alias Backplane.Skills.{AgentManage, AgentPlugins, DesiredState, Host, Hosts}

  @tabs [
    {"overview", "Overview"},
    {"auth", "Auth"},
    {"config", "Config"},
    {"plugin", "Plugin"},
    {"desired", "Desired State"},
    {"sync", "Sync/MCP"},
    {"danger", "Danger"}
  ]
  @tab_ids Enum.map(@tabs, &elem(&1, 0))
  @default_tab "overview"
  @memory_plugin_rows [
    %{
      "plugin" => "memory",
      "name" => "Backplane Memory",
      "runtime" => "hermes",
      "target_path" => "~/.hermes/plugins/backplane-memory"
    },
    %{
      "plugin" => "memory",
      "name" => "Backplane Memory",
      "runtime" => "openclaw",
      "target_path" => "~/.openclaw/extensions/backplane-memory"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: AgentManage.subscribe()

    {:ok,
     assign(socket,
       current_path: "/system/host-agents",
       tabs: @tabs,
       agents: [],
       entry: nil,
       active_tab: "overview",
       agent_modal_open: false,
       create_error: nil,
       token_error: nil,
       rename_error: nil,
       delete_error: nil,
       delete_modal_open: false,
       generated_token: nil,
       revealed_token: nil,
       plugin_statuses: nil,
       plugin_result: nil,
       plugin_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :show -> {:noreply, load_show(socket, params["id"], params["tab"])}
      _ -> {:noreply, load_index(socket)}
    end
  end

  @impl true
  def handle_info(:agents_changed, %{assigns: %{live_action: :show, entry: entry}} = socket) do
    {:noreply, load_show(socket, entry && entry.host.id, socket.assigns.active_tab)}
  end

  def handle_info(:agents_changed, socket) do
    {:noreply, load_index(socket)}
  end

  @impl true
  def handle_event("open_agent_modal", _params, socket) do
    {:noreply, assign(socket, agent_modal_open: true, create_error: nil)}
  end

  def handle_event("close_agent_modal", _params, socket) do
    {:noreply, assign(socket, agent_modal_open: false, create_error: nil)}
  end

  def handle_event("create_agent", %{"agent" => params}, socket) do
    case Hosts.create_agent_with_token(normalize_agent_params(params)) do
      {:ok, host, auth_token, token} ->
        generated_token = %{agent_name: host.name, token_name: auth_token.name, value: token}

        {:noreply,
         socket
         |> assign(
           agent_modal_open: false,
           create_error: nil,
           generated_token: generated_token
         )
         |> load_index()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           create_error: changeset_summary(changeset),
           agent_modal_open: true
         )}
    end
  end

  def handle_event("refresh_plugins", _params, %{assigns: %{entry: entry}} = socket) do
    case AgentPlugins.list(entry) do
      {:ok, statuses} ->
        {:noreply,
         assign(socket,
           plugin_statuses: statuses,
           plugin_result: "Plugin status refreshed",
           plugin_error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, plugin_result: nil, plugin_error: plugin_error(reason))}
    end
  end

  def handle_event("install_plugin", %{"plugin" => params}, %{assigns: %{entry: entry}} = socket) do
    case AgentPlugins.install(entry, params) do
      {:ok, status} ->
        {:noreply,
         assign(socket,
           plugin_statuses: merge_plugin_status(socket.assigns.plugin_statuses, status),
           plugin_result: plugin_action_message(status, "installed"),
           plugin_error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, plugin_result: nil, plugin_error: plugin_error(reason))}
    end
  end

  def handle_event("remove_plugin", %{"plugin" => params}, %{assigns: %{entry: entry}} = socket) do
    case AgentPlugins.remove(entry, params) do
      {:ok, status} ->
        {:noreply,
         assign(socket,
           plugin_statuses: merge_plugin_status(socket.assigns.plugin_statuses, status),
           plugin_result: plugin_action_message(status, "removed"),
           plugin_error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, plugin_result: nil, plugin_error: plugin_error(reason))}
    end
  end

  def handle_event("rename_agent", %{"agent" => params}, %{assigns: %{entry: entry}} = socket) do
    case Hosts.update_agent(entry.host, normalize_agent_params(params)) do
      {:ok, host} ->
        {:noreply,
         socket
         |> assign(rename_error: nil)
         |> load_show(host.id, socket.assigns.active_tab)}

      {:error, changeset} ->
        {:noreply, assign(socket, rename_error: changeset_summary(changeset))}
    end
  end

  def handle_event("create_token", %{"token" => params}, %{assigns: %{entry: entry}} = socket) do
    params =
      params
      |> normalize_token_params()
      |> Map.update("name", "#{entry.host.name} token", fn
        "" -> "#{entry.host.name} token"
        name -> name
      end)

    case Hosts.create_auth_token_for_agent(entry.host, params) do
      {:ok, auth_token, token} ->
        {:noreply,
         socket
         |> assign(token_error: nil, revealed_token: %{token_id: auth_token.id, value: token})
         |> load_show(entry.host.id, socket.assigns.active_tab)}

      {:error, changeset} ->
        {:noreply, assign(socket, token_error: changeset_summary(changeset))}
    end
  end

  def handle_event("reveal_token", %{"id" => id}, socket) do
    case Hosts.reveal_auth_token(id) do
      {:ok, token} ->
        {:noreply,
         assign(socket, revealed_token: %{token_id: id, value: token}, token_error: nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, token_error: "Unable to reveal token")}
    end
  end

  def handle_event("revoke_token", %{"id" => id}, %{assigns: %{entry: entry}} = socket) do
    case Hosts.revoke_auth_token_for_agent(entry.host, id) do
      {:ok, _auth_token} ->
        {:noreply,
         socket
         |> assign(token_error: nil, revealed_token: nil)
         |> load_show(entry.host.id, socket.assigns.active_tab)}

      {:error, _reason} ->
        {:noreply, assign(socket, token_error: "Unable to revoke token")}
    end
  end

  def handle_event("open_delete_modal", _params, socket) do
    {:noreply, assign(socket, delete_modal_open: true, delete_error: nil)}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply, assign(socket, delete_modal_open: false, delete_error: nil)}
  end

  def handle_event("delete_agent", %{"delete" => %{"confirmation" => confirmation}}, socket) do
    entry = socket.assigns.entry

    if String.trim(confirmation || "") == entry.host.name do
      case Hosts.delete_agent(entry.host) do
        {:ok, _host} ->
          {:noreply, push_navigate(socket, to: ~p"/system/host-agents")}

        {:error, _changeset} ->
          {:noreply,
           assign(socket, delete_modal_open: true, delete_error: "Failed to delete agent")}
      end
    else
      {:noreply,
       assign(socket, delete_modal_open: true, delete_error: "Type the agent name to confirm")}
    end
  end

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <.link navigate={~p"/system/host-agents"} class="text-sm text-primary underline">
          Host Agents
        </.link>
        <div class="mt-2 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h1 class="text-2xl font-bold">{@entry.host.name}</h1>
            <p class="mt-1 font-mono text-xs text-on-surface-variant">{@entry.host.id}</p>
          </div>
          <.dm_badge variant={status_variant(@entry.status)} size="sm">
            {status_label(@entry.status)}
          </.dm_badge>
        </div>
      </div>

      <div class="mb-6 flex flex-wrap gap-2 border-b border-outline-variant pb-2">
        <.link
          :for={{tab, label} <- @tabs}
          id={"agent-tab-#{tab}"}
          patch={~p"/system/host-agents/#{@entry.host.id}/#{tab}"}
          class={[
            "rounded px-3 py-2 text-sm font-medium",
            tab == @active_tab && "bg-primary text-on-primary",
            tab != @active_tab && "text-on-surface-variant hover:bg-surface-container-high"
          ]}
        >
          {label}
        </.link>
      </div>

      <.overview_tab :if={@active_tab == "overview"} entry={@entry} error={@rename_error} />
      <.auth_tab
        :if={@active_tab == "auth"}
        entry={@entry}
        error={@token_error}
        revealed_token={@revealed_token}
      />
      <.config_tab :if={@active_tab == "config"} entry={@entry} />
      <.plugin_tab
        :if={@active_tab == "plugin"}
        entry={@entry}
        statuses={@plugin_statuses}
        result={@plugin_result}
        error={@plugin_error}
      />
      <.desired_tab :if={@active_tab == "desired"} entry={@entry} />
      <.sync_tab :if={@active_tab == "sync"} entry={@entry} />
      <.danger_tab :if={@active_tab == "danger"} entry={@entry} />
      <.delete_agent_modal
        :if={@delete_modal_open}
        entry={@entry}
        error={@delete_error}
      />
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 class="text-2xl font-bold">Host Agent Management</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            Durable host agents, their cached manager state, and the latest live connection metadata.
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

      <.token_notice :if={@generated_token} generated_token={@generated_token} />

      <div class="overflow-x-auto rounded-md border border-outline-variant bg-surface-container">
        <table id="host-agents-table" class="min-w-full text-sm">
          <thead class="bg-surface-container-high text-on-surface">
            <tr>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Name</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Status</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Connect IP</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Agent Version</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Targets</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Last Connected</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Last Sync</th>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Actions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-outline-variant">
            <tr :if={@agents == []}>
              <td colspan="8" class="px-3 py-6 text-center text-on-surface-variant">
                No host agents registered.
              </td>
            </tr>
            <tr :for={entry <- @agents} class="hover:bg-surface-container-high">
              <td class="px-3 py-2 align-top">
                <span class="font-medium">{entry.host.name}</span>
              </td>
              <td class="px-3 py-2 align-top">
                <.dm_badge variant={status_variant(entry.status)} size="sm">
                  {status_label(entry.status)}
                </.dm_badge>
              </td>
              <td class="px-3 py-2 align-top">{entry.connect_ip || "-"}</td>
              <td class="px-3 py-2 align-top">{agent_version(entry)}</td>
              <td class="px-3 py-2 align-top">{targets_summary(entry)}</td>
              <td class="px-3 py-2 align-top">{relative_time(entry.connected_at)}</td>
              <td class="px-3 py-2 align-top">{relative_time(entry.last_sync)}</td>
              <td class="px-3 py-2 align-top">
                <.dm_tooltip content="View" position="bottom">
                  <.link
                    navigate={~p"/system/host-agents/#{entry.host.id}/overview"}
                    aria-label="View"
                  >
                    <.dm_btn type="button" size="xs" shape="circle" variant="outline" aria-label="View">
                      <.dm_mdi name="eye" class="w-4 h-4" />
                    </.dm_btn>
                  </.link>
                </.dm_tooltip>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.agent_modal :if={@agent_modal_open} error={@create_error} />
    </div>
    """
  end

  defp load_index(socket) do
    assign(socket,
      current_path: "/system/host-agents",
      agents: AgentManage.list_agents(),
      entry: nil,
      active_tab: "overview",
      agent_modal_open: false,
      create_error: nil,
      token_error: nil,
      rename_error: nil,
      delete_error: nil,
      delete_modal_open: false,
      generated_token: socket.assigns.generated_token,
      revealed_token: nil,
      plugin_statuses: nil,
      plugin_result: nil,
      plugin_error: nil
    )
  end

  defp load_show(socket, nil, _tab) do
    socket
    |> put_flash(:error, "Host agent not found")
    |> push_navigate(to: ~p"/system/host-agents")
  end

  defp load_show(socket, id, tab) do
    {active_tab, redirect?} = normalize_tab(tab)

    with {:error, :not_found} <- AgentManage.get_agent(id),
         %Host{} = host <- Hosts.get_host(id),
         {:ok, _pid} <- AgentManage.ensure_agent(host) do
      AgentManage.get_agent(id)
    end
    |> case do
      {:ok, entry} ->
        socket =
          assign(socket,
            current_path: "/system/host-agents/#{entry.host.id}/#{active_tab}",
            agents: [],
            entry: entry,
            active_tab: active_tab,
            agent_modal_open: false,
            create_error: nil,
            delete_modal_open: socket.assigns.delete_modal_open
          )

        if redirect? do
          push_patch(socket, to: ~p"/system/host-agents/#{entry.host.id}/#{active_tab}")
        else
          socket
        end

      _ ->
        load_show(socket, nil, tab)
    end
  end

  defp normalize_tab(tab) when tab in @tab_ids, do: {tab, false}
  defp normalize_tab(_tab), do: {@default_tab, true}

  defp normalize_agent_params(params) do
    params
    |> Map.update("name", "", &String.trim/1)
    |> Map.update("memory_scope", "proj_local", &String.trim/1)
  end

  defp normalize_token_params(params) do
    Map.update(params, "name", "", &String.trim/1)
  end

  defp overview_tab(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1fr)_24rem]">
      <.dm_card variant="bordered">
        <:title>Overview</:title>
        <dl class="grid grid-cols-1 gap-4 text-sm sm:grid-cols-2">
          <div>
            <dt class="font-medium">Status</dt>
            <dd class="text-on-surface-variant">{status_label(@entry.status)}</dd>
          </div>
          <div>
            <dt class="font-medium">Connect IP</dt>
            <dd class="text-on-surface-variant">{connect_ip(@entry)}</dd>
          </div>
          <div>
            <dt class="font-medium">IP Source</dt>
            <dd class="text-on-surface-variant">{@entry.connect_ip_source || "-"}</dd>
          </div>
          <div>
            <dt class="font-medium">Agent Version</dt>
            <dd class="text-on-surface-variant">{agent_version(@entry)}</dd>
          </div>
          <div>
            <dt class="font-medium">Targets</dt>
            <dd class="text-on-surface-variant">{targets_summary(@entry)}</dd>
          </div>
          <div>
            <dt class="font-medium">Connected</dt>
            <dd class="text-on-surface-variant">{relative_time(@entry.connected_at)}</dd>
          </div>
        </dl>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Name</:title>
        <form id="agent-name-form" phx-submit="rename_agent" class="space-y-4">
          <.dm_input id="agent-name" name="agent[name]" label="Name" value={@entry.host.name} />
          <.dm_input id="agent-memory-scope" name="agent[memory_scope]" label="Memory scope" value={@entry.host.memory_scope} />
          <p :if={@error} class="text-sm text-error">{@error}</p>
          <.dm_btn type="submit" variant="primary" size="sm">Save</.dm_btn>
        </form>
      </.dm_card>
    </div>
    """
  end

  defp auth_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <.token_notice :if={@revealed_token} generated_token={%{value: @revealed_token.value}} />

      <.dm_card variant="bordered">
        <:title>Auth Tokens</:title>
        <p :if={@error} class="mb-3 text-sm text-error">{@error}</p>

        <div :if={@entry.tokens == []} class="text-sm text-on-surface-variant">
          No tokens assigned.
        </div>

        <div :if={@entry.tokens != []} class="overflow-x-auto">
          <table id="agent-auth-table" class="min-w-full text-sm">
            <thead class="bg-surface-container-high text-on-surface">
              <tr>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Name</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-outline-variant">
              <tr :for={token <- @entry.tokens}>
                <td class="px-3 py-2 align-top">{token.name}</td>
                <td class="px-3 py-2 align-top">
                  <div class="flex flex-wrap gap-1">
                    <.dm_tooltip content="Reveal" position="bottom">
                      <.dm_btn
                        id={"reveal-token-#{token.id}"}
                        type="button"
                        variant="outline"
                        size="xs"
                        shape="circle"
                        aria-label="Reveal"
                        phx-click="reveal_token"
                        phx-value-id={token.id}
                      >
                        <.dm_mdi name="eye" class="w-4 h-4" />
                      </.dm_btn>
                    </.dm_tooltip>
                    <.dm_tooltip content="Revoke" position="bottom">
                      <.dm_btn
                        id={"revoke-token-#{token.id}"}
                        type="button"
                        variant="error"
                        size="xs"
                        shape="circle"
                        aria-label="Revoke"
                        phx-click="revoke_token"
                        phx-value-id={token.id}
                      >
                        <.dm_mdi name="key-remove" class="w-4 h-4" />
                      </.dm_btn>
                    </.dm_tooltip>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Create Token</:title>
        <form id="create-agent-token-form" phx-submit="create_token" class="space-y-4">
          <.dm_input id="token-name" name="token[name]" label="Name" value={"#{@entry.host.name} token"} />
          <.dm_btn type="submit" variant="primary" size="sm">Create Token</.dm_btn>
        </form>
      </.dm_card>
    </div>
    """
  end

  defp config_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <.dm_card variant="bordered">
        <:title>Setup Example</:title>
        <div class="space-y-4 text-sm">
          <p class="text-on-surface-variant">
            Use this host ID with an assigned token on the host agent.
          </p>
          <pre
            id="setup-example-yaml"
            class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-xs"
          ><code class="language-yaml">{agent_yaml(@entry)}</code></pre>
        </div>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Reported Config</:title>
        <div :if={is_nil(@entry.config)} class="text-sm text-on-surface-variant">
          Config not reported yet.
        </div>

        <div :if={@entry.config} class="space-y-4">
          <pre
            id="reported-config-yaml"
            class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-xs"
          ><code class="language-yaml">{yaml(@entry.config)}</code></pre>
        </div>
      </.dm_card>
    </div>
    """
  end

  defp plugin_tab(assigns) do
    assigns =
      assigns
      |> assign(:plugin_rows, plugin_rows(assigns.statuses))
      |> assign(:plugin_endpoint, plugin_endpoint(assigns.entry))
      |> assign(:plugin_example, plugin_example(assigns.entry))

    ~H"""
    <div class="space-y-6">
      <.dm_card variant="bordered">
        <:title>Packaged Plugins</:title>
        <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div class="text-sm text-on-surface-variant">
            Memory is the only packaged plugin currently available.
          </div>
          <.dm_btn id="refresh-plugin-status" type="button" size="sm" variant="outline" phx-click="refresh_plugins">
            Refresh
          </.dm_btn>
        </div>

        <p :if={@result} class="mb-3 text-sm text-success">{@result}</p>
        <p :if={@error} class="mb-3 text-sm text-error">{@error}</p>

        <div class="overflow-x-auto">
          <table id="host-agent-plugins-table" class="min-w-full text-sm">
            <thead class="bg-surface-container-high text-on-surface">
              <tr>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Plugin</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Runtime</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Status</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Target</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-outline-variant">
              <tr :for={row <- @plugin_rows}>
                <td class="px-3 py-2 align-top font-medium">{row["name"]}</td>
                <td class="px-3 py-2 align-top">{runtime_label(row["runtime"])}</td>
                <td class="px-3 py-2 align-top">
                  <.dm_badge variant={plugin_status_variant(row)} size="sm">
                    {plugin_status_label(row)}
                  </.dm_badge>
                </td>
                <td class="px-3 py-2 align-top">
                  <code class="text-xs break-all">{row["target_path"]}</code>
                </td>
                <td class="px-3 py-2 align-top">
                  <div class="flex flex-wrap gap-2">
                    <form id={"install-plugin-#{row["runtime"]}"} phx-submit="install_plugin">
                      <input type="hidden" name="plugin[plugin]" value={row["plugin"]} />
                      <input type="hidden" name="plugin[runtime]" value={row["runtime"]} />
                      <input type="hidden" name="plugin[force]" value="true" />
                      <.dm_btn type="submit" size="xs" variant="primary">
                        Install
                      </.dm_btn>
                    </form>
                    <form id={"remove-plugin-#{row["runtime"]}"} phx-submit="remove_plugin">
                      <input type="hidden" name="plugin[plugin]" value={row["plugin"]} />
                      <input type="hidden" name="plugin[runtime]" value={row["runtime"]} />
                      <.dm_btn type="submit" size="xs" variant="outline">
                        Remove
                      </.dm_btn>
                    </form>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Plugin Config</:title>
        <dl class="mb-4 grid grid-cols-1 gap-4 text-sm sm:grid-cols-2">
          <div>
            <dt class="font-medium">Local MCP Endpoint</dt>
            <dd class="text-on-surface-variant break-all">{@plugin_endpoint}</dd>
          </div>
          <div>
            <dt class="font-medium">Tool Prefix</dt>
            <dd class="text-on-surface-variant">host_agent</dd>
          </div>
        </dl>
        <pre class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-xs"><code>{@plugin_example}</code></pre>
      </.dm_card>
    </div>
    """
  end

  defp desired_tab(assigns) do
    assigns = assign(assigns, desired: desired_state(assigns.entry))

    ~H"""
    <.dm_card variant="bordered">
      <:title>Desired State</:title>
      <pre class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-xs"><code>{json(@desired)}</code></pre>
    </.dm_card>
    """
  end

  defp sync_tab(assigns) do
    assigns = assign(assigns, desired: desired_state(assigns.entry))

    ~H"""
    <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
      <.dm_card variant="bordered">
        <:title>Sync</:title>
        <dl class="space-y-3 text-sm">
          <div>
            <dt class="font-medium">Last Sync</dt>
            <dd class="text-on-surface-variant">{relative_time(@entry.last_sync)}</dd>
          </div>
          <div>
            <dt class="font-medium">Last Error</dt>
            <dd class="text-on-surface-variant">{@entry.last_error || "-"}</dd>
          </div>
        </dl>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>MCP</:title>
        <dl class="space-y-3 text-sm">
          <div>
            <dt class="font-medium">Desired Servers</dt>
            <dd class="text-on-surface-variant">{length(@desired["mcp_servers"] || [])}</dd>
          </div>
          <div>
            <dt class="font-medium">Desired Skills</dt>
            <dd class="text-on-surface-variant">{length(@desired["skills"] || [])}</dd>
          </div>
        </dl>
      </.dm_card>
    </div>
    """
  end

  defp danger_tab(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>Delete Agent</:title>
      <div class="space-y-4">
        <p class="text-sm text-on-surface-variant">
          Delete this agent and revoke its assigned tokens.
        </p>
        <.dm_btn
          id="open-delete-agent-modal"
          type="button"
          variant="error"
          size="sm"
          phx-click="open_delete_modal"
        >
          Delete Agent
        </.dm_btn>
      </div>
    </.dm_card>
    """
  end

  defp delete_agent_modal(assigns) do
    ~H"""
    <div
      id="delete-agent-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4 py-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="delete-agent-modal-title"
    >
      <div class="w-full max-w-lg rounded-lg border border-outline-variant bg-surface shadow-xl">
        <div class="flex items-center justify-between border-b border-outline-variant px-5 py-4">
          <h2 id="delete-agent-modal-title" class="text-lg font-semibold text-on-surface">
            Delete Agent
          </h2>
          <button
            type="button"
            class="rounded px-2 py-1 text-sm text-on-surface-variant hover:bg-surface-container-high hover:text-on-surface"
            phx-click="close_delete_modal"
            aria-label="Close"
          >
            x
          </button>
        </div>
        <div class="px-5 py-5">
          <form id="delete-agent-form" phx-submit="delete_agent" class="space-y-4">
            <p class="text-sm text-on-surface-variant">
              Type <strong>{@entry.host.name}</strong> to delete this agent and revoke its assigned tokens.
            </p>
            <.dm_input
              id="delete-confirmation"
              name="delete[confirmation]"
              label="Agent name"
              value=""
            />
            <p :if={@error} class="text-sm text-error">{@error}</p>
            <div class="flex flex-wrap justify-end gap-2">
              <.dm_btn type="button" variant="outline" size="sm" phx-click="close_delete_modal">
                Cancel
              </.dm_btn>
              <.dm_btn type="submit" variant="error" size="sm">Delete Agent</.dm_btn>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp agent_modal(assigns) do
    ~H"""
    <div
      id="host-agent-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4 py-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="host-agent-modal-title"
    >
      <div class="w-full max-w-lg rounded-lg border border-outline-variant bg-surface shadow-xl">
        <div class="flex items-center justify-between border-b border-outline-variant px-5 py-4">
          <h2 id="host-agent-modal-title" class="text-lg font-semibold text-on-surface">
            Add Agent
          </h2>
          <button
            type="button"
            class="rounded px-2 py-1 text-sm text-on-surface-variant hover:bg-surface-container-high hover:text-on-surface"
            phx-click="close_agent_modal"
            aria-label="Close"
          >
            x
          </button>
        </div>
        <div class="px-5 py-5">
          <form id="host-agent-form" phx-submit="create_agent" class="space-y-4">
            <.dm_input id="agent-name" name="agent[name]" label="Name" value="" placeholder="workstation" />
            <.dm_input id="agent-memory-scope" name="agent[memory_scope]" label="Memory scope" value="proj_local" />
            <p :if={@error} class="text-sm text-error">{@error}</p>
            <div class="flex flex-wrap justify-end gap-2">
              <.dm_btn type="button" variant="outline" size="sm" phx-click="close_agent_modal">
                Cancel
              </.dm_btn>
              <.dm_btn type="submit" variant="primary" size="sm">Add Agent</.dm_btn>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp token_notice(assigns) do
    ~H"""
    <div class="mb-6 rounded-md border border-warning bg-surface-container px-4 py-3">
      <div class="text-sm font-medium text-warning">Host agent token</div>
      <p class="mt-1 text-xs text-on-surface-variant">Copy this value for the host agent config.</p>
      <code class="mt-3 block rounded bg-surface-container-high px-3 py-2 font-mono text-xs break-all text-warning">
        {@generated_token.value}
      </code>
    </div>
    """
  end

  defp agent_yaml(entry) do
    """
    # Backplane host agent configuration
    agent:
      host_id: #{entry.host.id}
      machine_name: #{entry.host.name}
      hub_url: #{hub_url_hint()}
      token: REPLACE_WITH_AUTH_TOKEN
      interval_ms: 60000
      manifest_path: ~/.local/share/backplane/host_agent/manifest.json
      work_dir: ~/.local/share/backplane/host_agent

      # Local Memory HTTP API. Bind 127.0.0.1 and set http_port to expose
      # /memory/:agent_id/mcp and /memory/:agent_id/call/:method to processes
      # on this host. Set http_port to 0 to disable.
      http_bind: 127.0.0.1
      http_port: 4222

    memory:
      enabled: true
      db_path: ~/.local/share/backplane/host_agent/memory/host_agent_memory.db
      bound_scope: proj_local
      local_ttl_days: 90
      sync_interval_ms: 5000
      sync_batch_size: 50
      max_attempts: 5
      tombstone_relearn: block

    telemetry:
      enabled: true
      dir: ~/.local/share/backplane/host_agent/telemetry
      sync_interval_ms: 10000
      sync_batch_size: 100
      retention_days: 14

    targets:
      - name: agents
        runtime: agent-skills
        path: ~/.local/share/backplane/host_agent/skills
        enabled: true
    """
  end

  defp connect_ip(%{connect_ip: nil}), do: "-"
  defp connect_ip(%{connect_ip: ip, connect_ip_source: nil}), do: ip
  defp connect_ip(%{connect_ip: ip, connect_ip_source: source}), do: "#{ip} (#{source})"

  defp agent_version(%{runtime: %{agent_version: version}}) when is_binary(version), do: version
  defp agent_version(_entry), do: "-"

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

  defp targets_summary(_entry), do: "0"

  defp plugin_rows(statuses) when is_list(statuses) do
    status_by_key =
      Map.new(statuses, fn status ->
        {{status["plugin"], status["runtime"]}, status}
      end)

    Enum.map(@memory_plugin_rows, fn row ->
      Map.merge(row, Map.get(status_by_key, {row["plugin"], row["runtime"]}, %{}))
    end)
  end

  defp plugin_rows(_statuses), do: @memory_plugin_rows

  defp merge_plugin_status(statuses, status) when is_map(status) do
    statuses
    |> List.wrap()
    |> Enum.reject(&(&1["plugin"] == status["plugin"] and &1["runtime"] == status["runtime"]))
    |> Kernel.++([status])
  end

  defp plugin_status_label(%{"valid" => true}), do: "Installed"
  defp plugin_status_label(%{"installed" => true}), do: "Invalid"
  defp plugin_status_label(%{"installed" => false}), do: "Not installed"
  defp plugin_status_label(_row), do: "Unknown"

  defp plugin_status_variant(%{"valid" => true}), do: "success"
  defp plugin_status_variant(%{"installed" => true}), do: "warning"
  defp plugin_status_variant(%{"installed" => false}), do: "neutral"
  defp plugin_status_variant(_row), do: "info"

  defp plugin_endpoint(entry) do
    case AgentPlugins.endpoint(entry) do
      {:ok, url} -> url
      {:error, reason} -> "Unavailable: #{plugin_error(reason)}"
    end
  end

  defp plugin_example(entry) do
    url =
      case AgentPlugins.endpoint(entry) do
        {:ok, endpoint} -> endpoint
        {:error, _reason} -> "http://127.0.0.1:4222/memory/backplane-admin/mcp"
      end

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "host_agent::install_plugin",
        "arguments" => %{"plugin" => "memory", "runtime" => "hermes"}
      }
    }

    """
    curl -s -X POST #{url} \\
      -H 'content-type: application/json' \\
      -d '#{Jason.encode!(body)}'
    """
  end

  defp plugin_action_message(status, action) do
    "#{status["name"] || status["plugin"]} #{runtime_label(status["runtime"])} #{action}"
  end

  defp plugin_error(:http_disabled), do: "host-agent HTTP endpoint is disabled"
  defp plugin_error(:http_unavailable), do: "host-agent HTTP endpoint is unavailable"
  defp plugin_error(:connect_ip_unavailable), do: "host-agent connect IP is unavailable"

  defp plugin_error(%{__struct__: struct, reason: reason}) when is_atom(struct),
    do: "#{inspect(struct)}: #{inspect(reason)}"

  defp plugin_error({:http_error, status, _body}), do: "HTTP #{status}"
  defp plugin_error({:unexpected_result, result}), do: "unexpected result: #{inspect(result)}"

  defp plugin_error({:unexpected_response, response}),
    do: "unexpected response: #{inspect(response)}"

  defp plugin_error(reason) when is_binary(reason), do: reason
  defp plugin_error(reason), do: inspect(reason)

  defp runtime_label("hermes"), do: "Hermes"
  defp runtime_label("openclaw"), do: "OpenClaw"
  defp runtime_label(runtime) when is_binary(runtime), do: String.capitalize(runtime)
  defp runtime_label(_runtime), do: "Unknown"

  defp status_label(status) when is_atom(status),
    do: status |> Atom.to_string() |> String.capitalize()

  defp status_label(status) when is_binary(status), do: String.capitalize(status)
  defp status_label(_status), do: "Unknown"

  defp status_variant(:online), do: "success"
  defp status_variant(:offline), do: "neutral"
  defp status_variant("online"), do: "success"
  defp status_variant("connected"), do: "success"
  defp status_variant("installed"), do: "success"
  defp status_variant("failed"), do: "error"
  defp status_variant("error"), do: "error"
  defp status_variant(_status), do: "info"

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

  defp json(value), do: Jason.encode!(value, pretty: true)

  defp yaml(value) do
    value
    |> yaml_lines(0)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp yaml_lines(map, indent) when is_map(map) do
    map
    |> ordered_yaml_entries()
    |> Enum.flat_map(fn {key, value} ->
      yaml_entry_lines(to_string(key), value, indent)
    end)
  end

  defp yaml_lines(list, indent) when is_list(list) do
    Enum.flat_map(list, fn
      value when is_map(value) or is_list(value) ->
        [yaml_indent(indent) <> "-"] ++ yaml_lines(value, indent + 2)

      value ->
        [yaml_indent(indent) <> "- " <> yaml_scalar(value)]
    end)
  end

  defp yaml_lines(value, indent), do: [yaml_indent(indent) <> yaml_scalar(value)]

  defp yaml_entry_lines(key, value, indent) when is_map(value) or is_list(value) do
    [yaml_indent(indent) <> key <> ":"] ++ yaml_lines(value, indent + 2)
  end

  defp yaml_entry_lines(key, value, indent) do
    [yaml_indent(indent) <> key <> ": " <> yaml_scalar(value)]
  end

  defp ordered_yaml_entries(map) do
    Enum.sort_by(map, fn {key, _value} ->
      key = to_string(key)
      {yaml_key_rank(key), key}
    end)
  end

  defp yaml_key_rank(key) do
    [
      "agent",
      "host_id",
      "machine_name",
      "hub_url",
      "token",
      "interval_ms",
      "manifest_path",
      "work_dir",
      "http_bind",
      "http_port",
      "memory",
      "enabled",
      "db_path",
      "bound_scope",
      "local_ttl_days",
      "sync_interval_ms",
      "sync_batch_size",
      "max_attempts",
      "tombstone_relearn",
      "telemetry",
      "dir",
      "retention_days",
      "targets",
      "name",
      "runtime",
      "path"
    ]
    |> Enum.find_index(&(&1 == key))
    |> case do
      nil -> 10_000
      rank -> rank
    end
  end

  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(value) when is_binary(value), do: value
  defp yaml_scalar(value) when is_boolean(value), do: to_string(value)
  defp yaml_scalar(value) when is_number(value), do: to_string(value)
  defp yaml_scalar(value), do: inspect(value)

  defp yaml_indent(indent), do: String.duplicate(" ", indent)

  defp desired_state(%{host: %Host{} = host}) do
    {:ok, desired} = DesiredState.for_host(host)
    desired
  end

  defp hub_url_hint do
    Backplane.WebOrigins.api_base_url()
  end

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
end
