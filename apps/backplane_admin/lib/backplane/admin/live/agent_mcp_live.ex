defmodule Backplane.Admin.AgentMcpLive do
  @moduledoc """
  Manages MCP server configurations that run on host agents.
  Supports adding/editing/deleting MCP server configs (HTTP + stdio)
  and viewing connected agents. These servers are agent-only — they
  are not registered on Backplane's ToolRegistry.
  """
  use Backplane.Admin, :live_view

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.{AgentManage, AgentMcpServer, AgentMcpServers, Hosts}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      AgentManage.subscribe()
      AgentMcpServers.subscribe()
    end

    {:ok,
     assign(socket,
       current_path: "/admin/mcp/agent",
       mcp_servers: [],
       connections: [],
       hosts: [],
       available_mcps: [],
       editing: nil,
       form: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(editing: nil, form: nil)
    |> load_all()
  end

  defp apply_action(socket, :new, _params) do
    changeset = AgentMcpServers.change(%AgentMcpServer{}, %{transport: "http"})

    socket
    |> assign(editing: :new, form: server_form(changeset))
    |> load_all()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case safe_call(fn -> AgentMcpServers.get!(id) end, nil) do
      nil ->
        socket
        |> put_flash(:error, "MCP server not found")
        |> push_patch(to: ~p"/admin/mcp/agent")

      server ->
        changeset = AgentMcpServers.change(server, %{})

        socket
        |> assign(editing: server, form: server_form(changeset))
        |> load_all()
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:agents_changed, socket) do
    {:noreply, assign(socket, connections: load_connections())}
  end

  def handle_info(:agent_mcp_servers_changed, socket) do
    {:noreply, assign(socket, mcp_servers: load_mcp_servers())}
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"agent_mcp_server" => params}, socket) do
    params = prepare_params(params)

    changeset =
      case socket.assigns.editing do
        :new -> AgentMcpServers.change(%AgentMcpServer{}, params)
        %AgentMcpServer{} = s -> AgentMcpServers.change(s, params)
      end

    {:noreply, assign(socket, form: server_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("save", %{"agent_mcp_server" => params}, socket) do
    params = prepare_params(params)

    case socket.assigns.editing do
      :new ->
        case AgentMcpServers.create(params) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "MCP server created")
             |> push_patch(to: ~p"/admin/mcp/agent")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: server_form(changeset))}
        end

      %AgentMcpServer{} = server ->
        case AgentMcpServers.update(server, params) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "MCP server updated")
             |> push_patch(to: ~p"/admin/mcp/agent")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: server_form(changeset))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    server = AgentMcpServers.get!(id)

    case AgentMcpServers.delete(server) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "MCP server deleted") |> load_all()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete MCP server")}
    end
  end

  def handle_event("toggle_server", %{"id" => id}, socket) do
    server = AgentMcpServers.get!(id)

    case AgentMcpServers.update(server, %{enabled: !server.enabled}) do
      {:ok, updated} ->
        msg = if updated.enabled, do: "MCP server enabled", else: "MCP server disabled"
        {:noreply, socket |> put_flash(:info, msg) |> load_all()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update MCP server")}
    end
  end

  # ── Data loading ────────────────────────────────────────────────────────────

  defp load_all(socket) do
    assign(socket,
      mcp_servers: load_mcp_servers(),
      connections: load_connections(),
      hosts: load_hosts(),
      available_mcps: load_available_mcps()
    )
  end

  defp load_mcp_servers do
    safe_call(fn -> AgentMcpServers.list() end, [])
  end

  defp load_connections do
    safe_call(fn -> AgentManage.list_connected() end, [])
  end

  defp load_hosts do
    safe_call(fn -> Hosts.list_hosts() end, [])
  end

  defp load_available_mcps do
    tools = safe_call(fn -> ToolRegistry.list_all() end, [])

    tools
    |> Enum.filter(fn tool ->
      match?({:managed, _}, tool.origin)
    end)
    |> Enum.group_by(fn tool ->
      {:managed, elem(tool.origin, 1)}
    end)
    |> Enum.map(fn {{kind, prefix}, tools} ->
      %{
        kind: kind,
        prefix: prefix,
        tool_count: length(tools),
        tools: Enum.map(tools, fn t -> %{name: t.name, description: t.description} end)
      }
    end)
    |> Enum.sort_by(fn m -> m.prefix end)
  end

  defp kind_label(:managed), do: "Managed"
  defp kind_label(_), do: "Other"

  defp kind_icon(:managed), do: "cog"
  defp kind_icon(_), do: "puzzle-outline"

  defp tool_short_name(name) do
    case String.split(name, "::", parts: 2) do
      [_prefix, short] -> short
      _ -> name
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp server_form(%Ecto.Changeset{} = changeset) do
    changeset
    |> changeset_params()
    |> to_form(
      as: :agent_mcp_server,
      errors: changeset_errors(changeset),
      action: changeset.action
    )
  end

  defp changeset_params(%Ecto.Changeset{data: data, changes: changes, params: params}) do
    data
    |> schema_fields()
    |> stringify_keys()
    |> Map.merge(stringify_keys(params || %{}))
    |> Map.merge(stringify_keys(changes))
  end

  defp schema_fields(%struct{} = data),
    do: Map.new(struct.__schema__(:fields), fn field -> {field, Map.get(data, field)} end)

  defp stringify_keys(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp changeset_errors(%Ecto.Changeset{action: nil}), do: []
  defp changeset_errors(%Ecto.Changeset{errors: errors}), do: errors

  defp prepare_params(params) do
    params
    |> Map.put("args", parse_args(params["args"]))
    |> Map.put("env", parse_env(params["env"]))
    |> then(fn p ->
      case p["host_id"] do
        "" -> Map.put(p, "host_id", nil)
        _ -> p
      end
    end)
  end

  defp parse_args(nil), do: []
  defp parse_args(""), do: []

  defp parse_args(val) when is_binary(val) do
    val |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_args(val) when is_list(val), do: val

  defp parse_env(nil), do: %{}
  defp parse_env(""), do: %{}

  defp parse_env(val) when is_binary(val) do
    case Jason.decode(val) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp parse_env(val) when is_map(val), do: val

  defp transport_value(form) do
    Phoenix.HTML.Form.input_value(form, :transport) || "http"
  end

  defp args_display(args) when is_list(args), do: Enum.join(args, ", ")
  defp args_display(_), do: ""

  defp env_display(env) when is_map(env) and map_size(env) > 0 do
    case Jason.encode(env, pretty: true) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp env_display(_), do: ""

  defp host_name_for(nil, _hosts), do: "All Agents"

  defp host_name_for(host_id, hosts) do
    case Enum.find(hosts, &(&1.id == host_id)) do
      %{name: name} -> name
      _ -> "Unknown"
    end
  end

  defp host_options(hosts) do
    [{"", "All Agents (global)"}] ++
      Enum.map(hosts, fn h -> {h.id, h.name} end)
  end

  defp agent_version(%{runtime: %{agent_version: version}}) when is_binary(version), do: version
  defp agent_version(_), do: "—"

  defp agent_status(%{runtime: %{status: status}}) when is_binary(status), do: status
  defp agent_status(_), do: "connected"

  defp status_variant("online"), do: "success"
  defp status_variant("connected"), do: "success"
  defp status_variant("installed"), do: "success"
  defp status_variant("failed"), do: "error"
  defp status_variant("error"), do: "error"
  defp status_variant(_), do: "info"

  defp targets_list(%{runtime: %{targets: targets}}) when is_list(targets), do: targets
  defp targets_list(%{config: %{"targets" => targets}}) when is_list(targets), do: targets
  defp targets_list(_), do: []

  defp target_name(%{"name" => name}), do: name
  defp target_name(%{name: name}), do: name
  defp target_name(name) when is_binary(name), do: name
  defp target_name(_), do: "unnamed"

  defp target_runtime(%{"runtime" => runtime}), do: runtime
  defp target_runtime(%{runtime: runtime}) when is_binary(runtime), do: runtime
  defp target_runtime(_), do: nil

  defp target_enabled?(%{"enabled" => enabled}), do: enabled != false
  defp target_enabled?(%{enabled: enabled}), do: enabled != false
  defp target_enabled?(_), do: true

  defp relative_time(nil), do: "—"

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
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

  # ── Template ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= case @live_action do %>
        <% action when action in [:new, :edit] -> %>
          {form_view(assigns)}
        <% _ -> %>
          {index_view(assigns)}
      <% end %>
    </div>
    """
  end

  defp index_view(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-bold">Agent MCP</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            MCP server configs pushed to host agents. These servers run locally on the agent, not on Backplane.
          </p>
        </div>
        <.link patch={~p"/admin/mcp/agent/new"}>
          <.dm_btn variant="primary" size="sm">Add MCP Server</.dm_btn>
        </.link>
      </div>

      <%!-- Section 1: Agent MCP Servers --%>
      <section class="mb-8">
        <h2 class="text-lg font-semibold mb-3">Agent MCP Servers</h2>

        <div :if={@mcp_servers == []} class="text-sm text-on-surface-variant mb-4">
          No MCP servers configured for host agents. Click "Add MCP Server" to create one.
        </div>

        <div :if={@mcp_servers != []} class="overflow-x-auto">
          <table class="min-w-full text-sm">
            <thead class="bg-surface-container-high text-on-surface">
              <tr>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Name</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Prefix</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Transport</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Target</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Connection</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Status</th>
                <th scope="col" class="px-3 py-2 text-right font-semibold">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-outline-variant">
              <tr :for={server <- @mcp_servers} class="hover:bg-surface-container-high">
                <td class="px-3 py-1.5 align-middle">
                  <span class="font-medium">{server.name}</span>
                </td>
                <td class="px-3 py-1.5 align-middle">
                  <span class="text-xs text-on-surface-variant font-mono">{server.prefix}::</span>
                </td>
                <td class="px-3 py-1.5 align-middle">
                  <.dm_badge variant="info">{server.transport}</.dm_badge>
                </td>
                <td class="px-3 py-1.5 align-middle">
                  <.dm_badge variant="neutral" size="sm">
                    {host_name_for(server.host_id, @hosts)}
                  </.dm_badge>
                </td>
                <td class="px-3 py-1.5 align-middle text-on-surface-variant">
                  <span :if={server.url}>
                    <span class="text-on-surface">{server.url}</span>
                  </span>
                  <span :if={server.command}>
                    <span class="text-on-surface">{server.command}</span>
                    <span :if={server.args != []} class="ml-1 text-xs">
                      [{Enum.join(server.args, ", ")}]
                    </span>
                  </span>
                </td>
                <td class="px-3 py-1.5 align-middle">
                  <.dm_badge
                    variant={if server.enabled, do: "success", else: "ghost"}
                    size="sm"
                  >
                    {if server.enabled, do: "Enabled", else: "Disabled"}
                  </.dm_badge>
                </td>
                <td class="px-3 py-1.5 align-middle text-right">
                  <div class="flex items-center justify-end gap-1">
                    <.dm_tooltip content={if server.enabled, do: "Disable", else: "Enable"}>
                      <.dm_btn
                        size="xs"
                        shape="circle"
                        variant={if server.enabled, do: "warning", else: "primary"}
                        phx-click="toggle_server"
                        phx-value-id={server.id}
                      >
                        <.dm_mdi
                          name={if server.enabled, do: "pause", else: "play"}
                          class="w-4 h-4"
                        />
                      </.dm_btn>
                    </.dm_tooltip>
                    <.dm_tooltip content="Edit">
                      <.link patch={~p"/admin/mcp/agent/#{server.id}/edit"}>
                        <.dm_btn size="xs" shape="circle" variant="outline">
                          <.dm_mdi name="pencil" class="w-4 h-4" />
                        </.dm_btn>
                      </.link>
                    </.dm_tooltip>
                    <.dm_tooltip content="Delete">
                      <.dm_btn
                        size="xs"
                        shape="circle"
                        variant="error"
                        phx-click="delete"
                        phx-value-id={server.id}
                        data-confirm={"Delete MCP server #{server.name}?"}
                      >
                        <.dm_mdi name="delete" class="w-4 h-4" />
                      </.dm_btn>
                    </.dm_tooltip>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <%!-- Section 2: Connected Agents --%>
      <section class="mb-8">
        <h2 class="text-lg font-semibold mb-3">Connected Agents</h2>

        <div :if={@connections == []} class="text-sm text-on-surface-variant">
          No host agents currently connected.
          <.link navigate={~p"/admin/system/host-agents"} class="text-primary underline">
            Manage host agents →
          </.link>
        </div>

        <div :if={@connections != []} class="overflow-x-auto">
          <table class="min-w-full text-sm">
            <thead class="bg-surface-container-high text-on-surface">
              <tr>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Name</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Status</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Version</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Connected</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Targets</th>
                <th scope="col" class="px-3 py-2 text-right font-semibold">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-outline-variant">
              <%= for conn <- @connections do %>
                <tr class="hover:bg-surface-container-high">
                  <td class="px-3 py-1.5 align-middle">
                    <div class="flex items-center gap-2">
                      <.dm_mdi name="robot" class="admin-sidebar-icon" />
                      <span class="font-medium">{conn.host.name}</span>
                    </div>
                  </td>
                  <td class="px-3 py-1.5 align-middle">
                    <.dm_badge variant={status_variant(agent_status(conn))} size="sm">
                      {agent_status(conn)}
                    </.dm_badge>
                  </td>
                  <td class="px-3 py-1.5 align-middle">
                    <span class="text-xs text-on-surface-variant">v{agent_version(conn)}</span>
                  </td>
                  <td class="px-3 py-1.5 align-middle">
                    <span class="text-xs text-on-surface-variant">
                      {relative_time(conn.connected_at)}
                    </span>
                  </td>
                  <td class="px-3 py-1.5 align-middle">
                    <span class="text-xs text-on-surface-variant">
                      {length(targets_list(conn))} targets
                    </span>
                  </td>
                  <td class="px-3 py-1.5 align-middle text-right">
                    <.link navigate={~p"/admin/system/host-agents/#{conn.host.id}"}>
                      <.dm_btn size="xs" variant="outline">Config</.dm_btn>
                    </.link>
                  </td>
                </tr>
                <tr :if={targets_list(conn) != []} class="bg-surface-container">
                  <td colspan="6" class="px-3 py-2">
                    <h4 class="text-xs font-medium text-on-surface-variant mb-2">MCP Targets</h4>
                    <div class="overflow-x-auto">
                      <table class="min-w-full text-sm">
                        <thead class="bg-surface-container-high text-on-surface">
                          <tr>
                            <th scope="col" class="px-3 py-2 text-left font-semibold">Name</th>
                            <th scope="col" class="px-3 py-2 text-left font-semibold">Runtime</th>
                            <th scope="col" class="px-3 py-2 text-left font-semibold">Status</th>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-outline-variant">
                          <tr :for={target <- targets_list(conn)} class="hover:bg-surface-container-high">
                            <td class="px-3 py-1.5 align-middle">
                              <span class="font-medium">{target_name(target)}</span>
                            </td>
                            <td class="px-3 py-1.5 align-middle text-on-surface-variant">
                              {target_runtime(target) || "—"}
                            </td>
                            <td class="px-3 py-1.5 align-middle">
                              <.dm_badge
                                variant={if target_enabled?(target), do: "success", else: "error"}
                                size="sm"
                              >
                                {if target_enabled?(target), do: "Enabled", else: "Disabled"}
                              </.dm_badge>
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </section>

      <%!-- Section 3: Managed Services on Backplane MCP --%>
      <section>
        <h2 class="text-lg font-semibold mb-3">Backplane MCP Services</h2>
        <p class="text-sm text-on-surface-variant mb-4">
          Managed services running on the Backplane MCP server. Host agents access these via the MCP endpoint.
        </p>

        <div :if={@available_mcps == []} class="text-sm text-on-surface-variant">
          No managed services registered.
        </div>

        <div :if={@available_mcps != []} class="overflow-x-auto">
          <table class="min-w-full text-sm">
            <thead class="bg-surface-container-high text-on-surface">
              <tr>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Prefix</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Namespace</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Type</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Status</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Tools</th>
                <th scope="col" class="px-3 py-2 text-left font-semibold">Tool List</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-outline-variant">
              <tr :for={mcp <- @available_mcps} class="hover:bg-surface-container-high">
                <td class="px-3 py-1.5 align-middle">
                  <div class="flex items-center gap-2">
                    <.dm_mdi name={kind_icon(mcp.kind)} class="w-5 h-5 text-on-surface-variant" />
                    <span class="font-medium">{mcp.prefix}</span>
                  </div>
                </td>
                <td class="px-3 py-1.5 align-middle">
                  <span class="text-xs text-on-surface-variant font-mono">{mcp.prefix}::</span>
                </td>
                <td class="px-3 py-1.5 align-middle">
                  <.dm_badge variant="info" size="sm">{kind_label(mcp.kind)}</.dm_badge>
                </td>
                <td class="px-3 py-1.5 align-middle">
                  <.dm_badge variant="success" size="sm">Enabled</.dm_badge>
                </td>
                <td class="px-3 py-1.5 align-middle">
                  <span class="text-on-surface-variant">{mcp.tool_count}</span>
                </td>
                <td class="px-3 py-1.5 align-middle">
                  <div class="flex flex-wrap gap-1">
                    <.link
                      :for={tool <- mcp.tools}
                      navigate={
                        case mcp.kind do
                          :managed -> "/admin/mcp/managed/#{mcp.prefix}/tool/#{tool_short_name(tool.name)}"
                          _ -> "/admin/mcp/tools"
                        end
                      }
                    >
                      <.dm_badge variant="ghost" class="cursor-pointer hover:bg-surface-container-high transition-colors">
                        {tool_short_name(tool.name)}
                      </.dm_badge>
                    </.link>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  defp form_view(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-3 mb-6">
        <.link patch={~p"/admin/mcp/agent"} class="text-sm text-primary hover:underline">
          &larr; Agent MCP
        </.link>
        <h1 class="text-2xl font-bold">
          {if @editing == :new, do: "New Agent MCP Server", else: "Edit #{@editing.name}"}
        </h1>
      </div>

      <.dm_card variant="bordered">
        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <.dm_input
                id="server-name"
                name="agent_mcp_server[name]"
                label="Name"
                value={@form[:name].value}
                placeholder="File System"
              />
              <.form_error field={@form[:name]} />
            </div>
            <div>
              <.dm_input
                id="server-prefix"
                name="agent_mcp_server[prefix]"
                label="Prefix"
                value={@form[:prefix].value}
                placeholder="fs"
              />
              <.form_error field={@form[:prefix]} />
            </div>
          </div>

          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <.dm_select
                id="server-transport"
                name="agent_mcp_server[transport]"
                label="Transport"
                options={[{"http", "HTTP"}, {"stdio", "Stdio"}]}
                value={transport_value(@form)}
              />
              <.form_error field={@form[:transport]} />
            </div>
            <div>
              <.dm_select
                id="server-host"
                name="agent_mcp_server[host_id]"
                label="Target Agent"
                options={host_options(@hosts)}
                value={@form[:host_id].value || ""}
              />
            </div>
          </div>

          <div :if={transport_value(@form) == "http"}>
            <.dm_input
              id="server-url"
              name="agent_mcp_server[url]"
              label="URL"
              value={@form[:url].value || ""}
              placeholder="https://example.com/mcp"
            />
            <.form_error field={@form[:url]} />
          </div>

          <div :if={transport_value(@form) == "stdio"} class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <.dm_input
                id="server-command"
                name="agent_mcp_server[command]"
                label="Command"
                value={@form[:command].value || ""}
                placeholder="/usr/bin/node"
              />
              <.form_error field={@form[:command]} />
            </div>
            <div>
              <.dm_input
                id="server-args"
                name="agent_mcp_server[args]"
                label="Args (comma-separated)"
                value={args_display(@form[:args].value)}
                placeholder="server.js,--port,3000"
              />
              <.form_error field={@form[:args]} />
            </div>
          </div>

          <div :if={transport_value(@form) == "stdio"}>
            <.dm_textarea
              id="server-env"
              name="agent_mcp_server[env]"
              label="Environment Variables (JSON object, optional)"
              rows={3}
              value={env_display(@form[:env].value)}
              placeholder={~s({"NODE_ENV": "production"})}
              class="font-mono"
            />
          </div>

          <div class="flex gap-2 pt-2">
            <.dm_btn type="submit" variant="primary">Save</.dm_btn>
            <.link patch={~p"/admin/mcp/agent"}>
              <.dm_btn type="button">Cancel</.dm_btn>
            </.link>
          </div>
        </.form>
      </.dm_card>
    </div>
    """
  end
end
