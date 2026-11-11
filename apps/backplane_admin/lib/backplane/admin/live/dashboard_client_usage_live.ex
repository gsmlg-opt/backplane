defmodule Backplane.Admin.DashboardClientUsageLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.Components.UsageTimeRange, only: [usage_time_range: 1]

  alias Backplane.Admin.Components.UsageTimeRange
  alias Backplane.Clients
  alias Backplane.LLM.LogQuery, as: LlmLogQuery
  alias Backplane.MCP.LogQuery, as: McpLogQuery

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/dashboard/usage/clients",
       loading: true,
       clients: [],
       llm_rows: [],
       rpc_rows: [],
       tool_rows: [],
       idle_clients: [],
       range: "today"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, load_usage(socket, params)}

  defp load_usage(socket, params) do
    {range, time_range} = UsageTimeRange.parse(params["range"])
    clients = safe_call(&Clients.list_clients/0, []) |> Enum.sort_by(&String.downcase(&1.name))

    socket
    |> assign(loading: false, range: range, clients: clients)
    |> assign_tab_rows(socket.assigns.live_action, clients, time_range)
  end

  defp assign_tab_rows(socket, :mcp, clients, time_range) do
    usage = safe_call(fn -> McpLogQuery.aggregate_by_client(time_range) end, %{})

    assign(socket,
      rpc_rows: client_rows(clients, usage, :rpc_methods),
      tool_rows: client_rows(clients, usage, :tools),
      idle_clients:
        clients_without_usage(clients, usage, &(&1.rpc_methods == [] and &1.tools == []))
    )
  end

  defp assign_tab_rows(socket, _llm, clients, time_range) do
    usage = safe_call(fn -> LlmLogQuery.aggregate_by_client(time_range) end, %{})

    assign(socket,
      llm_rows: client_rows(clients, usage, :models),
      idle_clients: clients_without_usage(clients, usage, &(&1.models == []))
    )
  end

  defp client_rows(clients, usage, key) do
    for client <- clients,
        entry <- usage |> Map.get(client.id, %{}) |> Map.get(key, []) do
      Map.put(entry, :client, client)
    end
  end

  defp clients_without_usage(clients, usage, empty?) do
    Enum.filter(clients, fn client ->
      case Map.fetch(usage, client.id) do
        {:ok, client_usage} -> empty?.(client_usage)
        :error -> true
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold">{dgettext("admin", "Client Usage")}</h1>
        <p class="mt-1 text-sm text-on-surface-variant">{dgettext("admin", "LLM models and MCP operations used by each registered client.")}</p>
      </div>

      <div id="client-usage-tabs" class="tabs tabs-lifted" role="tablist">
        <.link
          :for={{action, label, path} <- [{:llm, "LLM", ~p"/dashboard/usage/clients"}, {:mcp, "MCP", ~p"/dashboard/usage/clients/mcp"}]}
          id={"client-usage-tab-#{action}"}
          patch={path <> "?" <> URI.encode_query(%{"range" => @range})}
          class={["tab", tab_action(@live_action) == action && "tab-active"]}
          role="tab"
          aria-selected={to_string(tab_action(@live_action) == action)}
        >
          {label}
        </.link>
      </div>

      <.usage_time_range id="client-usage-range" action={tab_path(@live_action)} selected={@range} />

      <div :if={@loading} class="text-sm text-on-surface-variant">{dgettext("admin", "Loading client usage...")}</div>
      <div :if={!@loading and @clients == []} class="text-sm text-on-surface-variant">
        {dgettext("admin", "No clients configured.")}
        <.link navigate={~p"/system/clients"} class="text-primary underline">{dgettext("user", "Manage clients")}</.link>
      </div>

      <section :if={!@loading and @clients != [] and tab_action(@live_action) == :llm} id="client-llm-usage" class="space-y-3">
        <div :if={@llm_rows == []} class="text-sm text-on-surface-variant">{dgettext("admin", "No LLM usage recorded in this range.")}</div>
        <div :if={@llm_rows != []} class="overflow-x-auto">
          <.dm_table id="client-llm-usage-table" data={@llm_rows} hover zebra>
            <:col :let={row} label={dgettext("admin", "Client")}><.client_name client={row.client} /></:col>
            <:col :let={row} label={dgettext("admin", "Model")}><code>{row.model}</code></:col>
            <:col :let={row} label={dgettext("admin", "Requests")} class="tabular-nums">{format_number(row.requests)}</:col>
            <:col :let={row} label={dgettext("admin", "Input Tokens")} class="tabular-nums">{format_input_tokens(row)}</:col>
            <:col :let={row} label={dgettext("admin", "Output Tokens")} class="tabular-nums">{format_number(row.output_tokens)}</:col>
          </.dm_table>
        </div>
        <.idle_clients clients={@idle_clients} kind="LLM" />
      </section>

      <section :if={!@loading and @clients != [] and tab_action(@live_action) == :mcp} id="client-mcp-usage" class="space-y-6">
        <div :if={@tool_rows == [] and @rpc_rows == []} class="text-sm text-on-surface-variant">{dgettext("admin", "No MCP usage recorded in this range.")}</div>
        <div :if={@tool_rows != []} class="space-y-2">
          <h2 class="font-semibold">{dgettext("admin", "Tool Calls")}</h2>
          <div class="overflow-x-auto">
            <.dm_table id="client-mcp-tools-table" data={@tool_rows} hover zebra>
              <:col :let={row} label={dgettext("admin", "Client")}><.client_name client={row.client} /></:col>
              <:col :let={row} label={dgettext("admin", "Tool")}><code>{row.tool}</code></:col>
              <:col :let={row} label={dgettext("admin", "Calls")} class="tabular-nums">{format_number(row.requests)}</:col>
            </.dm_table>
          </div>
        </div>
        <div :if={@rpc_rows != []} class="space-y-2">
          <h2 class="font-semibold">{dgettext("admin", "RPC Methods")}</h2>
          <div class="overflow-x-auto">
            <.dm_table id="client-mcp-rpc-table" data={@rpc_rows} hover zebra>
              <:col :let={row} label={dgettext("admin", "Client")}><.client_name client={row.client} /></:col>
              <:col :let={row} label={dgettext("admin", "Method")}><code>{row.method}</code></:col>
              <:col :let={row} label={dgettext("admin", "Requests")} class="tabular-nums">{format_number(row.requests)}</:col>
              <:col :let={row} label={dgettext("admin", "Avg Duration")} class="tabular-nums">{dgettext("admin", "%{value} ms", value: format_number(row.avg_duration_ms))}</:col>
            </.dm_table>
          </div>
        </div>
        <.idle_clients clients={@idle_clients} kind="MCP" />
      </section>
    </div>
    """
  end

  attr(:client, :map, required: true)

  defp client_name(assigns) do
    ~H"""
    <span class="font-medium">{@client.name}</span>
    <.dm_badge :if={!@client.active} variant="neutral" size="sm">{dgettext("common", "Inactive")}</.dm_badge>
    """
  end

  attr(:clients, :list, required: true)
  attr(:kind, :string, required: true)

  defp idle_clients(assigns) do
    ~H"""
    <p :if={@clients != []} id="client-usage-idle" class="text-sm text-on-surface-variant">
      {dgettext("admin", "No %{kind} usage: %{clients}", kind: @kind, clients: Enum.map_join(@clients, ", ", & &1.name))}
    </p>
    """
  end

  defp tab_action(:mcp), do: :mcp
  defp tab_action(_action), do: :llm

  defp tab_path(:mcp), do: ~p"/dashboard/usage/clients/mcp"
  defp tab_path(_action), do: ~p"/dashboard/usage/clients"

  defp format_number(value) when is_integer(value) do
    value |> Integer.to_string() |> then(&Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, &1, ","))
  end

  defp format_number(value), do: to_string(value || 0)

  defp format_input_tokens(%{input_tokens: input_tokens, cached_tokens: cached_tokens}) do
    percentage =
      if input_tokens > 0 do
        cached_tokens * 100 / input_tokens
      else
        0.0
      end

    "#{format_number(input_tokens)} / #{format_number(cached_tokens)} (#{:erlang.float_to_binary(percentage, decimals: 1)}%)"
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
