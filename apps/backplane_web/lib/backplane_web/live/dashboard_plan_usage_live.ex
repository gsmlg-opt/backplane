defmodule BackplaneWeb.DashboardPlanUsageLive do
  use BackplaneWeb, :live_view

  alias Backplane.Monitor
  alias Backplane.Monitor.Plan

  @state_refresh_interval 60_000
  @claude_code_windows [
    {"five_hour", "5-hour"},
    {"seven_day", "7-day"},
    {"seven_day_opus", "7-day Opus"},
    {"seven_day_sonnet", "7-day Sonnet"},
    {"seven_day_omelette", "7-day Omelette"},
    {"seven_day_cowork", "7-day Cowork"},
    {"seven_day_oauth_apps", "7-day OAuth Apps"},
    {"cinder_cove", "Cinder Cove"},
    {"iguana_necktie", "Iguana Necktie"},
    {"omelette_promotional", "Omelette Promotional"},
    {"tangelo", "Tangelo"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @state_refresh_interval)
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
    Process.send_after(self(), :refresh, @state_refresh_interval)
    {:noreply, load_usage_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, load_usage_data(socket, refresh?: true)}
  end

  defp load_usage_data(socket, opts \\ []) do
    plan_data =
      try do
        if Keyword.get(opts, :refresh?, false) do
          Monitor.refresh_plan_usages()
        else
          Monitor.list_plan_usage_states()
        end
      rescue
        _ -> []
      end

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
            <% {:ok, %{provider: "openai_codex"} = data} -> %>
              <.openai_codex_card plan={item.plan} data={data} fetched_at={item.fetched_at} />
            <% {:ok, %{provider: "claude_code"} = data} -> %>
              <.claude_code_card plan={item.plan} data={data} fetched_at={item.fetched_at} />
            <% {:unsupported, _provider} -> %>
              <.unsupported_card plan={item.plan} />
            <% {:error, reason} -> %>
              <.error_card plan={item.plan} reason={reason} />
            <% nil -> %>
              <.loading_card plan={item.plan} />
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

  # --- OpenAI Codex Card ---

  defp openai_codex_card(assigns) do
    assigns =
      assigns
      |> assign(:limits, openai_codex_limits(assigns.data.limits))
      |> assign(:plan_type, format_plan_type(assigns.data.plan_type))

    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <span class="font-semibold">{@plan.name}</span>
            <.dm_badge variant="info" size="sm">OpenAI Codex</.dm_badge>
          </div>
          <span class="text-xs text-on-surface-variant">
            Updated {Calendar.strftime(@fetched_at, "%H:%M:%S")}
          </span>
        </div>
      </:title>
      <div class="space-y-4">
        <dl class="grid grid-cols-1 gap-3 text-sm sm:grid-cols-3">
          <div>
            <dt class="text-xs text-on-surface-variant">Plan</dt>
            <dd class="font-medium">{@plan_type}</dd>
          </div>
          <div>
            <dt class="text-xs text-on-surface-variant">Status</dt>
            <dd class="font-medium">{@data.status || "ok"}</dd>
          </div>
          <div>
            <dt class="text-xs text-on-surface-variant">Buckets</dt>
            <dd class="font-medium">{length(@limits)}</dd>
          </div>
        </dl>

        <div :if={@limits != []} class="grid grid-cols-1 gap-4 xl:grid-cols-2">
          <div
            :for={limit <- @limits}
            class="rounded border border-outline-variant bg-surface-container-low p-4"
          >
            <div class="mb-3 flex items-start justify-between gap-3">
              <div>
                <div class="text-sm font-semibold">{openai_codex_limit_title(limit)}</div>
                <div class="text-xs text-on-surface-variant">{limit.limit_id}</div>
              </div>
              <.dm_badge
                :if={limit.rate_limit_reached_type}
                variant="error"
                size="sm"
              >
                Limited
              </.dm_badge>
            </div>

            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <.openai_codex_window title="Primary" window={limit.primary} />
              <.openai_codex_window title="Secondary" window={limit.secondary} />
            </div>

            <dl
              :if={limit.credits || limit.rate_limit_reached_type}
              class="mt-3 grid grid-cols-1 gap-3 text-xs sm:grid-cols-2"
            >
              <div :if={limit.credits}>
                <dt class="text-on-surface-variant">Credits</dt>
                <dd class="font-medium">{format_openai_codex_credits(limit.credits)}</dd>
              </div>
              <div :if={limit.rate_limit_reached_type}>
                <dt class="text-on-surface-variant">Limit reached</dt>
                <dd class="font-medium">{limit.rate_limit_reached_type}</dd>
              </div>
            </dl>
          </div>
        </div>

        <div :if={@limits == []} class="text-sm text-on-surface-variant">
          No OpenAI Codex usage buckets reported.
        </div>
      </div>
    </.dm_card>
    """
  end

  defp openai_codex_window(assigns) do
    assigns =
      assigns
      |> assign(:used_percent, openai_codex_used_percent(assigns.window))
      |> assign(:percentage, normalize_percentage(openai_codex_used_percent(assigns.window)) || 0)

    ~H"""
    <div class="rounded border border-outline-variant bg-surface p-3">
      <div class="mb-2 flex items-center justify-between gap-3">
        <span class="text-xs font-medium">{@title}</span>
        <.dm_badge :if={@window} variant={percentage_variant(@percentage)} size="sm">
          {format_used_percent(@used_percent)} used
        </.dm_badge>
      </div>

      <div :if={@window} class="space-y-2">
        <.usage_bar percentage={@percentage} />
        <div class="flex items-center justify-between gap-3 text-xs text-on-surface-variant">
          <span>{format_window_minutes(@window.window_duration_mins)}</span>
          <span>{format_unix_reset_at(@window.resets_at)}</span>
        </div>
      </div>

      <div :if={!@window} class="text-xs text-on-surface-variant">
        Not reported
      </div>
    </div>
    """
  end

  # --- Claude Code Card ---

  defp claude_code_card(assigns) do
    assigns =
      assigns
      |> assign(:usage_windows, claude_code_usage_windows(assigns.data.usage))
      |> assign(:extra_usage, claude_code_extra_usage(assigns.data.usage))

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
      <div class="space-y-4">
        <div
          :if={@usage_windows != []}
          class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3"
        >
          <div
            :for={window <- @usage_windows}
            class="rounded border border-outline-variant bg-surface-container-low p-4"
          >
            <div class="mb-3 flex items-center justify-between gap-3">
              <span class="text-sm font-medium">{window.label}</span>
              <.dm_badge variant={percentage_variant(window.utilization)} size="sm">
                {window.utilization}% used
              </.dm_badge>
            </div>
            <.usage_bar percentage={window.utilization} />
            <div class="mt-2 text-xs text-on-surface-variant">
              <span :if={window.resets_at}>Resets {format_reset_at(window.resets_at)}</span>
              <span :if={!window.resets_at}>No reset reported</span>
            </div>
          </div>
        </div>

        <div
          :if={@extra_usage}
          class="rounded border border-outline-variant bg-surface-container-low p-4"
        >
          <div class="mb-3 flex items-center justify-between gap-3">
            <span class="text-sm font-medium">Extra Usage</span>
            <.dm_badge variant={if @extra_usage.enabled, do: "success", else: "warning"} size="sm">
              {if @extra_usage.enabled, do: "Enabled", else: "Disabled"}
            </.dm_badge>
          </div>

          <div
            :if={@extra_usage.utilization}
            class="mb-3 flex items-center justify-between gap-3"
          >
            <.usage_bar_inline used={@extra_usage.utilization} total={100} />
            <span class="text-xs font-medium">{@extra_usage.utilization}% used</span>
          </div>

          <dl class="grid grid-cols-1 gap-3 text-xs sm:grid-cols-3">
            <div>
              <dt class="text-on-surface-variant">Used Credits</dt>
              <dd class="font-medium">{format_credit(@extra_usage.used_credits, @extra_usage.currency)}</dd>
            </div>
            <div>
              <dt class="text-on-surface-variant">Monthly Limit</dt>
              <dd class="font-medium">{format_credit(@extra_usage.monthly_limit, @extra_usage.currency)}</dd>
            </div>
            <div>
              <dt class="text-on-surface-variant">Reason</dt>
              <dd class="font-medium">{@extra_usage.disabled_reason || "None"}</dd>
            </div>
          </dl>
        </div>

        <div :if={@usage_windows == [] && !@extra_usage} class="text-sm text-on-surface-variant">
          No Claude Code usage windows reported.
        </div>
      </div>
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

  defp loading_card(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>
        <div class="flex items-center gap-2">
          <span class="font-semibold">{@plan.name}</span>
          <.dm_badge variant="info" size="sm">
            {Plan.provider_label(@plan.provider)}
          </.dm_badge>
        </div>
      </:title>
      <p class="text-sm text-on-surface-variant">Usage is loading.</p>
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

  defp claude_code_usage_windows(payload) when is_map(payload) do
    @claude_code_windows
    |> Enum.flat_map(fn {key, label} ->
      case map_value(payload, key) do
        %{} = window ->
          utilization = normalize_percentage(map_value(window, "utilization"))

          if is_integer(utilization) do
            [%{label: label, utilization: utilization, resets_at: map_value(window, "resets_at")}]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp claude_code_usage_windows(_), do: []

  defp claude_code_extra_usage(payload) when is_map(payload) do
    case map_value(payload, "extra_usage") do
      %{} = extra_usage ->
        %{
          enabled: map_value(extra_usage, "is_enabled") == true,
          currency: map_value(extra_usage, "currency"),
          disabled_reason: map_value(extra_usage, "disabled_reason"),
          monthly_limit: map_value(extra_usage, "monthly_limit"),
          used_credits: map_value(extra_usage, "used_credits"),
          utilization: normalize_percentage(map_value(extra_usage, "utilization"))
        }

      _ ->
        nil
    end
  end

  defp claude_code_extra_usage(_), do: nil

  defp openai_codex_limits(limits) when is_map(limits) do
    limits
    |> Map.values()
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(fn limit ->
      case map_value(limit, "limit_id") do
        "codex" -> "0"
        id when is_binary(id) -> "1:#{id}"
        _ -> "2"
      end
    end)
  end

  defp openai_codex_limits(_), do: []

  defp openai_codex_limit_title(limit) do
    name = map_value(limit, "limit_name")
    id = map_value(limit, "limit_id")

    cond do
      is_binary(name) and name != "" -> name
      id == "codex" -> "Codex"
      is_binary(id) -> id
      true -> "Usage"
    end
  end

  defp openai_codex_used_percent(%{} = window), do: map_value(window, "used_percent")
  defp openai_codex_used_percent(_), do: nil

  defp format_plan_type(nil), do: "Unknown"

  defp format_plan_type(plan_type) when is_binary(plan_type) do
    plan_type
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_plan_type(plan_type), do: to_string(plan_type)

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      atom_key = String.to_existing_atom(key)
      if Map.has_key?(map, atom_key), do: Map.get(map, atom_key)
    end
  rescue
    ArgumentError -> nil
  end

  defp normalize_percentage(value) when is_integer(value), do: value |> max(0) |> min(100)

  defp normalize_percentage(value) when is_float(value),
    do: value |> round() |> max(0) |> min(100)

  defp normalize_percentage(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> normalize_percentage(parsed)
      _ -> nil
    end
  end

  defp normalize_percentage(_), do: nil

  defp format_reset_at(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%m/%d %H:%M UTC")
  end

  defp format_reset_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> format_reset_at(datetime)
      {:error, _reason} -> value
    end
  end

  defp format_used_percent(nil), do: "unknown"
  defp format_used_percent(value) when is_integer(value), do: "#{value}%"

  defp format_used_percent(value) when is_float(value) do
    rounded = Float.round(value, 1)

    if rounded == trunc(rounded) do
      "#{trunc(rounded)}%"
    else
      "#{rounded}%"
    end
  end

  defp format_used_percent(value), do: "#{value}%"

  defp format_window_minutes(nil), do: "Window not reported"

  defp format_window_minutes(minutes) when is_number(minutes) do
    minutes = round(minutes)

    cond do
      minutes < 60 ->
        "#{minutes}m"

      minutes < 1440 and rem(minutes, 60) == 0 ->
        "#{div(minutes, 60)}h"

      minutes < 1440 ->
        "#{div(minutes, 60)}h #{rem(minutes, 60)}m"

      rem(minutes, 1440) == 0 ->
        "#{div(minutes, 1440)}d"

      true ->
        days = div(minutes, 1440)
        hours = div(rem(minutes, 1440), 60)
        "#{days}d #{hours}h"
    end
  end

  defp format_unix_reset_at(nil), do: "No reset"

  defp format_unix_reset_at(value) when is_integer(value) do
    value
    |> DateTime.from_unix!()
    |> Calendar.strftime("%m/%d %H:%M UTC")
  end

  defp format_unix_reset_at(value) when is_float(value) do
    value
    |> trunc()
    |> format_unix_reset_at()
  end

  defp format_unix_reset_at(_), do: "No reset"

  defp format_openai_codex_credits(%{} = credits) do
    cond do
      map_value(credits, "unlimited") == true ->
        "Unlimited"

      balance = map_value(credits, "balance") ->
        to_string(balance)

      map_value(credits, "has_credits") == false ->
        "None"

      true ->
        "Not reported"
    end
  end

  defp format_openai_codex_credits(_), do: "Not reported"

  defp format_credit(nil, _currency), do: "Not set"
  defp format_credit(value, nil), do: to_string(value)
  defp format_credit(value, currency), do: "#{value} #{currency}"

  defp format_error(:not_found), do: "Credential not found"
  defp format_error(:decryption_failed), do: "Failed to decrypt credential"
  defp format_error(:provider_not_supported), do: "Provider not yet supported"
  defp format_error(:missing_access_token), do: "OpenAI Codex access token is missing"
  defp format_error(:missing_chatgpt_account_id), do: "OpenAI Codex account ID is missing"
  defp format_error(:invalid_usage_response), do: "Usage response was not recognized"
  defp format_error(:unauthorized), do: "OpenAI Codex token was rejected; reconnect is required"

  defp format_error({:invalid_credential_kind, kind, expected}),
    do: "Credential kind #{kind} is not #{expected}"

  defp format_error({:invalid_credential_auth_type, auth_type, expected}),
    do: "Credential auth type #{auth_type} is not #{expected}"

  defp format_error({:script_runtime_failed, reason}),
    do: "Script runtime failed: #{inspect(reason)}"

  defp format_error({:script_failed, reason}), do: "Script failed: #{inspect(reason)}"
  defp format_error({:api_error, status, _}), do: "API returned #{status}"
  defp format_error({:refresh_failed, status}), do: "OAuth refresh returned #{status}"

  defp format_error({:refresh_error, %Req.TransportError{reason: :nxdomain}}),
    do: "OAuth refresh host could not be resolved; check DNS or proxy settings"

  defp format_error({:refresh_error, %Req.TransportError{reason: reason}}),
    do: "OAuth refresh request failed: #{inspect(reason)}"

  defp format_error({:refresh_error, reason}),
    do: "OAuth refresh request failed: #{inspect(reason)}"

  defp format_error({:rate_limited, nil}), do: "Usage endpoint is rate limited"

  defp format_error({:rate_limited, seconds}),
    do: "Usage endpoint is rate limited for #{seconds}s"

  defp format_error({:request_failed, reason}), do: "Request failed: #{inspect(reason)}"
  defp format_error(other), do: inspect(other)

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
