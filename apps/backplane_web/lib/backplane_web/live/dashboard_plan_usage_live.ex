defmodule BackplaneWeb.DashboardPlanUsageLive do
  use BackplaneWeb, :live_view

  alias Backplane.Monitor
  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.UsageFetcher

  @refresh_interval 60_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok,
     assign(socket,
       current_path: "/admin/dashboard/usage/plans",
       loading: true,
       plan_data: []
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_usage_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, load_usage_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, load_usage_data(socket)}
  end

  defp load_usage_data(socket) do
    plans =
      try do
        Monitor.list_active_plans()
      rescue
        _ -> []
      end

    plan_data =
      Enum.map(plans, fn plan ->
        usage =
          if Plan.provider_supported?(plan.provider) do
            case UsageFetcher.fetch_usage(plan) do
              {:ok, data} -> {:ok, data}
              {:error, reason} -> {:error, reason}
            end
          else
            {:unsupported, plan.provider}
          end

        %{plan: plan, usage: usage, fetched_at: DateTime.utc_now()}
      end)

    assign(socket, loading: false, plan_data: plan_data)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between gap-4">
        <h1 class="text-2xl font-bold">Plan Usage</h1>
        <div class="flex items-center gap-3">
          <.link navigate={~p"/admin/system/monitor/plans"} class="text-sm text-primary underline">
            Manage Plans
          </.link>
          <.dm_btn variant="primary" size="sm" phx-click="refresh">Refresh</.dm_btn>
        </div>
      </div>

      <div :if={@plan_data == [] && !@loading} class="text-on-surface-variant">
        No active plans configured.
        <.link navigate={~p"/admin/system/monitor/plans"} class="text-primary underline">
          Add a plan
        </.link>
        to start monitoring usage.
      </div>

      <div class="grid grid-cols-1 gap-6">
        <div :for={item <- @plan_data}>
          <%= case item.usage do %>
            <% {:ok, %{provider: "zai"} = data} -> %>
              <.zai_card plan={item.plan} data={data} fetched_at={item.fetched_at} />
            <% {:ok, %{provider: "minimax"} = data} -> %>
              <.minimax_card plan={item.plan} data={data} fetched_at={item.fetched_at} />
            <% {:ok, %{provider: "claude_code"} = data} -> %>
              <.claude_code_card plan={item.plan} data={data} fetched_at={item.fetched_at} />
            <% {:unsupported, _provider} -> %>
              <.unsupported_card plan={item.plan} />
            <% {:error, reason} -> %>
              <.error_card plan={item.plan} reason={reason} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # --- z.ai Card ---

  defp zai_card(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <span class="font-semibold">{@plan.name}</span>
            <.dm_badge variant="info" size="sm">z.ai</.dm_badge>
          </div>
          <span class="text-xs text-on-surface-variant">
            Updated {Calendar.strftime(@fetched_at, "%H:%M:%S")}
          </span>
        </div>
      </:title>
      <div class="space-y-4">
        <div :for={limit <- @data.limits} class="space-y-2">
          <div class="flex items-center justify-between">
            <span class="text-sm font-medium">{limit_label(limit.type)}</span>
            <div class="flex items-center gap-2">
              <span :if={limit.remaining} class="text-xs text-on-surface-variant">
                {limit.remaining} remaining
              </span>
              <.dm_badge variant={percentage_variant(limit.percentage)} size="sm">
                {limit.percentage}% used
              </.dm_badge>
            </div>
          </div>
          <.usage_bar percentage={limit.percentage} />
          <div class="flex items-center justify-between text-xs text-on-surface-variant">
            <span>Window: {limit.number} {unit_label(limit.unit)}</span>
            <span :if={limit.next_reset}>
              Resets: {Calendar.strftime(limit.next_reset, "%m/%d %H:%M")} UTC
            </span>
          </div>
          <div :if={limit.details != []} class="mt-2">
            <.dm_table id={"zai-details-#{limit.type}"} data={limit.details} hover zebra>
              <:col :let={d} label="Tool">{d.tool_name}</:col>
              <:col :let={d} label="Used">{d.used}</:col>
            </.dm_table>
          </div>
        </div>
      </div>
    </.dm_card>
    """
  end

  # --- MiniMax Card ---

  defp minimax_card(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <span class="font-semibold">{@plan.name}</span>
            <.dm_badge variant="info" size="sm">MiniMax</.dm_badge>
          </div>
          <span class="text-xs text-on-surface-variant">
            Updated {Calendar.strftime(@fetched_at, "%H:%M:%S")}
          </span>
        </div>
      </:title>
      <div class="space-y-3">
        <.dm_table id={"minimax-models-#{@plan.id}"} data={@data.models} hover zebra>
          <:col :let={m} label="Category">{m.name}</:col>
          <:col :let={m} label="Current (5h)">
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <.usage_bar_inline used={100 - (m.current_interval_remaining_percent || 0)} total={100} />
                <span class="text-xs font-medium">{m.current_interval_remaining_percent}% remaining</span>
              </div>
              <div class="text-[10px] text-on-surface-variant flex flex-col gap-0.5">
                <span :if={m.start_time && m.end_time}>{format_time_range(m.start_time, m.end_time)}</span>
                <span :if={m.remains_time} class="text-info font-medium">{format_duration(m.remains_time)} left</span>
              </div>
            </div>
          </:col>
          <:col :let={m} label="Weekly">
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <.usage_bar_inline used={100 - (m.current_weekly_remaining_percent || 0)} total={100} />
                <span class="text-xs font-medium">{m.current_weekly_remaining_percent}% remaining</span>
              </div>
              <div class="text-[10px] text-on-surface-variant flex flex-col gap-0.5">
                <span :if={m.weekly_start_time && m.weekly_end_time}>{format_time_range(m.weekly_start_time, m.weekly_end_time)}</span>
                <span :if={m.weekly_remains_time} class="text-info font-medium">{format_duration(m.weekly_remains_time)} left</span>
              </div>
            </div>
          </:col>
        </.dm_table>
      </div>
    </.dm_card>
    """
  end

  # --- Claude Code Card ---

  defp claude_code_card(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <span class="font-semibold">{@plan.name}</span>
            <.dm_badge variant="info" size="sm">Claude Code</.dm_badge>
          </div>
          <span class="text-xs text-on-surface-variant">
            Updated {Calendar.strftime(@fetched_at, "%H:%M:%S")}
          </span>
        </div>
      </:title>
      <pre class="max-h-96 overflow-auto rounded bg-surface-container p-3 text-xs text-on-surface">{format_usage_payload(@data.usage)}</pre>
    </.dm_card>
    """
  end

  # --- Unsupported Card ---

  defp unsupported_card(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center gap-2">
          <span class="font-semibold">{@plan.name}</span>
          <.dm_badge variant="info" size="sm">
            {Plan.provider_label(@plan.provider)}
          </.dm_badge>
          <.dm_badge variant="warning" size="sm">Coming Soon</.dm_badge>
        </div>
      </:title>
      <p class="text-sm text-on-surface-variant">
        Usage monitoring for {Plan.provider_label(@plan.provider)} is not yet implemented.
      </p>
    </.dm_card>
    """
  end

  # --- Error Card ---

  defp error_card(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center gap-2">
          <span class="font-semibold">{@plan.name}</span>
          <.dm_badge variant="info" size="sm">
            {Plan.provider_label(@plan.provider)}
          </.dm_badge>
          <.dm_badge variant="error" size="sm">Error</.dm_badge>
        </div>
      </:title>
      <p class="text-sm text-error">
        Failed to fetch usage: {format_error(@reason)}
      </p>
    </.dm_card>
    """
  end

  # --- Shared Components ---

  defp usage_bar(assigns) do
    percentage = min(assigns.percentage || 0, 100)
    assigns = assign(assigns, :clamped, percentage)

    ~H"""
    <div class="w-full bg-surface-container-high rounded-full h-2.5">
      <div
        class={[
          "h-2.5 rounded-full transition-all duration-500",
          bar_color(@clamped)
        ]}
        style={"width: #{@clamped}%"}
      >
      </div>
    </div>
    """
  end

  defp usage_bar_inline(assigns) do
    percentage = if assigns.total > 0, do: round(assigns.used / assigns.total * 100), else: 0
    assigns = assign(assigns, :percentage, min(percentage, 100))

    ~H"""
    <div class="w-20 bg-surface-container-high rounded-full h-1.5">
      <div
        class={["h-1.5 rounded-full", bar_color(@percentage)]}
        style={"width: #{@percentage}%"}
      >
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp limit_label("TOKENS_LIMIT"), do: "Token Quota"
  defp limit_label("TIME_LIMIT"), do: "MCP Tool Calls"
  defp limit_label(other), do: other

  defp unit_label(3), do: "hours"
  defp unit_label(5), do: "month"
  defp unit_label(_), do: ""

  defp percentage_variant(p) when p >= 90, do: "error"
  defp percentage_variant(p) when p >= 70, do: "warning"
  defp percentage_variant(_), do: "success"

  defp bar_color(p) when p >= 90, do: "bg-error"
  defp bar_color(p) when p >= 70, do: "bg-warning"
  defp bar_color(_), do: "bg-success"

  defp format_error(:not_found), do: "Credential not found"
  defp format_error(:decryption_failed), do: "Failed to decrypt credential"
  defp format_error(:provider_not_supported), do: "Provider not yet supported"

  defp format_error({:invalid_credential_kind, kind, expected}),
    do: "Credential kind #{kind} is not #{expected}"

  defp format_error({:script_runtime_failed, reason}),
    do: "Script runtime failed: #{inspect(reason)}"

  defp format_error({:script_failed, reason}), do: "Script failed: #{inspect(reason)}"
  defp format_error({:api_error, status, _}), do: "API returned #{status}"
  defp format_error({:request_failed, reason}), do: "Request failed: #{inspect(reason)}"
  defp format_error(other), do: inspect(other)

  defp format_usage_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(payload, pretty: true)
    end
  end

  defp format_time_range(nil, nil), do: ""

  defp format_time_range(start_time, end_time) do
    case {start_time, end_time} do
      {%DateTime{} = s, %DateTime{} = e} ->
        if s.day == e.day do
          "#{Calendar.strftime(s, "%m/%d %H:%M")} - #{Calendar.strftime(e, "%H:%M")}"
        else
          "#{Calendar.strftime(s, "%m/%d %H:%M")} - #{Calendar.strftime(e, "%m/%d %H:%M")}"
        end

      _ ->
        ""
    end
  end

  defp format_duration(nil), do: ""

  defp format_duration(ms) when is_integer(ms) do
    total_seconds = div(ms, 1000)

    cond do
      total_seconds <= 0 ->
        "0s"

      total_seconds < 60 ->
        "#{total_seconds}s"

      total_seconds < 3600 ->
        minutes = div(total_seconds, 60)
        seconds = rem(total_seconds, 60)
        "#{minutes}m #{seconds}s"

      total_seconds < 86400 ->
        hours = div(total_seconds, 3600)
        minutes = div(rem(total_seconds, 3600), 60)
        "#{hours}h #{minutes}m"

      true ->
        days = div(total_seconds, 86400)
        hours = div(rem(total_seconds, 86400), 3600)
        "#{days}d #{hours}h"
    end
  end
end
