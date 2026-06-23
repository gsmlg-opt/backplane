defmodule Backplane.Admin.HostAgentsLive do
  use Backplane.Admin, :live_view

  alias Backplane.Skills.{AgentManage, DesiredState, Host, Hosts}

  @tabs [
    {"overview", "Overview"},
    {"setup", "Setup"},
    {"auth", "Auth"},
    {"config", "Config"},
    {"desired", "Desired State"},
    {"sync", "Sync/MCP"},
    {"danger", "Danger"}
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
       revealed_token: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :show -> {:noreply, load_show(socket, params["id"])}
      _ -> {:noreply, load_index(socket)}
    end
  end

  @impl true
  def handle_info(:agents_changed, %{assigns: %{live_action: :show, entry: entry}} = socket) do
    {:noreply, load_show(socket, entry && entry.host.id)}
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

  def handle_event("select_tab", %{"tab" => tab}, socket)
      when tab in [
             "overview",
             "setup",
             "auth",
             "config",
             "desired",
             "sync",
             "danger"
           ] do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("select_tab", _params, socket), do: {:noreply, socket}

  def handle_event("rename_agent", %{"agent" => params}, %{assigns: %{entry: entry}} = socket) do
    case Hosts.update_agent(entry.host, normalize_agent_params(params)) do
      {:ok, host} ->
        {:noreply,
         socket
         |> assign(rename_error: nil)
         |> load_show(host.id)}

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
         |> load_show(entry.host.id)}

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
         |> load_show(entry.host.id)}

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
        <button
          :for={{tab, label} <- @tabs}
          id={"agent-tab-#{tab}"}
          type="button"
          phx-click="select_tab"
          phx-value-tab={tab}
          class={[
            "rounded px-3 py-2 text-sm font-medium",
            tab == @active_tab && "bg-primary text-on-primary",
            tab != @active_tab && "text-on-surface-variant hover:bg-surface-container-high"
          ]}
        >
          {label}
        </button>
      </div>

      <.overview_tab :if={@active_tab == "overview"} entry={@entry} error={@rename_error} />
      <.setup_tab :if={@active_tab == "setup"} entry={@entry} />
      <.auth_tab
        :if={@active_tab == "auth"}
        entry={@entry}
        error={@token_error}
        revealed_token={@revealed_token}
      />
      <.config_tab :if={@active_tab == "config"} entry={@entry} />
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
                    navigate={~p"/system/host-agents/#{entry.host.id}"}
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
      revealed_token: nil
    )
  end

  defp load_show(socket, nil) do
    socket
    |> put_flash(:error, "Host agent not found")
    |> push_navigate(to: ~p"/system/host-agents")
  end

  defp load_show(socket, id) do
    with {:error, :not_found} <- AgentManage.get_agent(id),
         %Host{} = host <- Hosts.get_host(id),
         {:ok, _pid} <- AgentManage.ensure_agent(host) do
      AgentManage.get_agent(id)
    end
    |> case do
      {:ok, entry} ->
        assign(socket,
          current_path: "/system/host-agents/#{entry.host.id}",
          agents: [],
          entry: entry,
          active_tab: socket.assigns.active_tab || "overview",
          agent_modal_open: false,
          create_error: nil,
          delete_modal_open: socket.assigns.delete_modal_open
        )

      _ ->
        load_show(socket, nil)
    end
  end

  defp normalize_agent_params(params) do
    Map.update(params, "name", "", &String.trim/1)
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
          <p :if={@error} class="text-sm text-error">{@error}</p>
          <.dm_btn type="submit" variant="primary" size="sm">Save</.dm_btn>
        </form>
      </.dm_card>
    </div>
    """
  end

  defp setup_tab(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>Setup</:title>
      <div class="space-y-4 text-sm">
        <p class="text-on-surface-variant">
          Use this host ID with an assigned token on the host agent.
        </p>
        <pre class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-xs"><code>{agent_yaml(@entry)}</code></pre>
      </div>
    </.dm_card>
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
        <:title>Reported Config</:title>
        <div :if={is_nil(@entry.config)} class="text-sm text-on-surface-variant">
          Config not reported yet.
        </div>

        <div :if={@entry.config} class="space-y-4">
          <div :if={config_targets(@entry.config) == []} class="text-sm text-on-surface-variant">
            No targets reported.
          </div>
          <div :if={config_targets(@entry.config) != []} class="overflow-x-auto">
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
                <tr :for={target <- config_targets(@entry.config)}>
                  <td class="px-3 py-2 align-top font-medium">{target["name"] || "-"}</td>
                  <td class="px-3 py-2 align-top">{target["runtime"] || "-"}</td>
                  <td class="px-3 py-2 align-top">
                    <code class="text-xs break-all">{target["path"] || "-"}</code>
                  </td>
                  <td class="px-3 py-2 align-top">
                    <.dm_badge variant={if target["enabled"] == false, do: "error", else: "success"} size="sm">
                      {if target["enabled"] == false, do: "No", else: "Yes"}
                    </.dm_badge>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </.dm_card>

      <.dm_card :if={@entry.config} variant="bordered">
        <:title>Raw Config JSON</:title>
        <pre class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-xs"><code>{json(@entry.config)}</code></pre>
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
    agent:
      machine_name: #{entry.host.name}
      hub_url: #{hub_url_hint()}
      host_id: #{entry.host.id}
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

  defp config_targets(%{"targets" => targets}) when is_list(targets), do: targets
  defp config_targets(_config), do: []

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
