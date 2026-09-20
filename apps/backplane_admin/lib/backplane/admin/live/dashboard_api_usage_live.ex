defmodule Backplane.Admin.DashboardApiUsageLive do
  use Backplane.Admin, :live_view

  alias Backplane.Monitor.ApiAccounts
  alias Backplane.Settings

  @pending_interval 5_000
  @stable_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Settings.subscribe()

    {:ok,
     assign(socket,
       current_path: "/dashboard/usage/api",
       states: [],
       fetching_enabled: ApiAccounts.fetching_enabled?(),
       reload_timer: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load_states(socket)}

  @impl true
  def handle_info(:reload_states, socket), do: {:noreply, load_states(socket)}

  def handle_info({:setting_changed, "monitor.api_usage.enabled", enabled}, socket) do
    {:noreply, assign(socket, fetching_enabled: enabled == true)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", %{"id" => id}, socket) do
    if socket.assigns.fetching_enabled && ApiAccounts.fetching_enabled?() do
      :ok = ApiAccounts.refresh_account(id)
    end

    {:noreply, load_states(socket)}
  end

  def handle_event("refresh_all", _params, socket) do
    if socket.assigns.fetching_enabled && ApiAccounts.fetching_enabled?() do
      :ok = ApiAccounts.refresh_all()
    end

    {:noreply, load_states(socket)}
  end

  defp load_states(socket) do
    states = ApiAccounts.list_states()
    socket = assign(socket, states: states, fetching_enabled: ApiAccounts.fetching_enabled?())

    if connected?(socket) do
      if socket.assigns.reload_timer, do: Process.cancel_timer(socket.assigns.reload_timer)

      interval =
        if Enum.any?(states, & &1.refreshing), do: @pending_interval, else: @stable_interval

      assign(socket, reload_timer: Process.send_after(self(), :reload_states, interval))
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">API Usage</h1>
          <p class="text-sm text-on-surface-variant">
            API account balances and key spending, independent of subscription plans and LLM routing.
            Active accounts refresh every five minutes when API information fetching is enabled.
          </p>
        </div>
        <div class="flex items-center gap-3">
          <.dm_btn id="refresh-all-api-accounts" size="sm" phx-click="refresh_all" disabled={!@fetching_enabled}>
            Refresh All
          </.dm_btn>
          <.link navigate={~p"/system/monitor/api-usage"} class="text-primary underline text-sm">
            Manage API Accounts
          </.link>
        </div>
      </div>
      <div id="api-fetching-status" role="status" class="text-sm">
        <.dm_badge variant={if @fetching_enabled, do: "success", else: "warning"} size="sm">
          API information fetching: {if @fetching_enabled, do: "Enabled", else: "Disabled"}
        </.dm_badge>
        <p :if={!@fetching_enabled} class="mt-2 text-on-surface-variant">
          API information fetching is disabled globally. Cached data from the last successful refresh remains visible.
          Enable fetching in <.link navigate={~p"/system/config"} class="text-primary underline">System Config</.link>.
        </p>
      </div>
      <p :if={@states == []} class="text-on-surface-variant">
        No API accounts configured. Manage API Accounts to add an API-key credential from the vault.
      </p>
      <div class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <.account_card :for={state <- @states} state={state} fetching_enabled={@fetching_enabled} />
      </div>
    </div>
    """
  end

  defp account_card(assigns) do
    ~H"""
    <.dm_card id={"api-account-#{@state.account.id}"} variant="bordered">
      <:title>
        <div class="flex flex-wrap items-center gap-3">
          <h2 class="text-lg font-semibold">{@state.account.name}</h2>
          <.dm_badge variant="info" size="sm">{provider_label(@state.account.provider)}</.dm_badge>
          <.dm_badge :if={!@state.account.active} variant="warning" size="sm">Paused</.dm_badge>
          <.dm_badge :if={@state.refreshing} variant="info" size="sm">Refreshing</.dm_badge>
        </div>
      </:title>
      <div class="space-y-4">
        <p :if={@state.usage != nil && (!@fetching_enabled || !@state.account.active)} role="status" class="text-sm text-on-surface-variant">
          Cached data from the last successful refresh; fetching is {if @fetching_enabled, do: "paused for this account", else: "disabled globally"}.
        </p>
        <div class="text-xs text-on-surface-variant space-y-1">
          <p>Last success: <.timestamp id={"api-account-#{@state.account.id}-success"} datetime={@state.last_success_at} /></p>
          <p>Last attempt: <.timestamp id={"api-account-#{@state.account.id}-attempt"} datetime={@state.fetched_at} /></p>
        </div>
        <div :if={@state.error != nil} role="alert" class="text-sm text-error">
          Refresh failed. {error_message(@state.error)}
          <p :if={@state.usage != nil}>Retained data from last successful refresh; values may be stale.</p>
        </div>
        <p :if={@state.usage == nil} class="text-sm text-on-surface-variant">
          Usage unavailable. No successful snapshot yet.
        </p>
        <.usage_details :if={@state.usage != nil} account={@state.account} data={@state.usage} />
        <div class="flex flex-wrap items-center gap-3">
          <.dm_btn id={"refresh-api-account-#{@state.account.id}"} size="sm" phx-click="refresh"
            phx-value-id={@state.account.id} disabled={!@fetching_enabled || !@state.account.active || @state.refreshing}>
            Refresh
          </.dm_btn>

        </div>
      </div>
    </.dm_card>
    """
  end

  defp usage_details(assigns) do
    ~H"""
    <div class="space-y-4">
      <section>
        <h3 class="font-semibold">Account balances</h3>
        <p :if={@data.balances == []} class="text-sm text-on-surface-variant">Unavailable</p>
        <dl :for={balance <- @data.balances} class="text-sm space-y-1 mt-2">
          <div class="flex justify-between gap-3"><dt>Total balance</dt><dd>{amount(balance.total_balance, balance.currency)}</dd></div>
          <div :if={@account.provider == "deepseek"} class="flex justify-between gap-3"><dt>Granted</dt><dd>{amount(balance.granted_balance, balance.currency)}</dd></div>
          <div class="flex justify-between gap-3"><dt>{if @account.provider == "deepseek", do: "Topped up", else: "Purchased credits"}</dt><dd>{amount(balance.topped_up_balance, balance.currency)}</dd></div>
        </dl>
        <p :if={@account.provider == "openrouter"} class="text-xs text-on-surface-variant mt-2">
          Management credential required for OpenRouter account credits. These balances are account-wide,
          not this API key's remaining limit. Credit failures do not hide key spending.
        </p>
      </section>
      <section>
        <h3 class="font-semibold">{if @account.provider == "openrouter", do: "API key spending / account spending", else: "Spending"}</h3>
        <p :if={@account.provider == "openrouter"} class="text-xs text-on-surface-variant">
          Key usage covers only the selected API key. Account usage covers the whole account,
          when a management credential is configured.
        </p>
        <p :if={@data.usage == []} class="text-sm text-on-surface-variant">
          {if @account.provider == "deepseek", do: "Unavailable — DeepSeek does not provide spending totals.", else: "Unavailable"}
        </p>
        <dl :if={@data.usage != []} class="text-sm space-y-1 mt-2">
          <div :for={usage <- @data.usage} class="flex justify-between gap-3">
            <dt>{usage.label}</dt><dd>{amount(usage.amount, usage.currency)}</dd>
          </div>
        </dl>
      </section>
      <section :if={@data.limit != nil || @account.provider == "openrouter"}>
        <h3 class="font-semibold">{if @account.provider == "firecrawl", do: "Credit limit", else: "API key limit"}</h3>
        <p :if={@data.limit == nil} class="text-sm text-on-surface-variant">Unavailable / no configured limit</p>
        <dl :if={@data.limit != nil} class="text-sm space-y-1 mt-2">
          <div class="flex justify-between gap-3"><dt>Limit</dt><dd>{amount(@data.limit.amount, @data.limit.currency)}</dd></div>
          <div class="flex justify-between gap-3"><dt>Remaining</dt><dd>{amount(@data.limit.remaining, @data.limit.currency)}</dd></div>
          <div class="flex justify-between gap-3"><dt>Reset</dt><dd>{@data.limit.reset || "Unavailable"}</dd></div>
        </dl>
      </section>
      <p :if={@data.is_available != nil} class="text-sm">
        {if @data.is_available, do: "Available for API requests", else: "Unavailable for API requests"}
      </p>
      <p :for={warning <- @data.warnings} role="status" class="text-sm text-warning">
        {warning_message(warning)}
      </p>
    </div>
    """
  end

  defp timestamp(assigns) do
    ~H"""
    <span :if={@datetime == nil}>Never</span>
    <.local_time :if={@datetime != nil} id={@id} datetime={@datetime} format="datetime" />
    """
  end

  defp amount(nil, _currency), do: "Unavailable"
  defp amount(value, currency), do: "#{value} #{currency}"
  defp provider_label("openrouter"), do: "OpenRouter"
  defp provider_label("deepseek"), do: "DeepSeek"
  defp provider_label("exa"), do: "Exa"
  defp provider_label("tavily"), do: "Tavily"
  defp provider_label("firecrawl"), do: "Firecrawl"

  defp warning_message({:account_credits, _reason}),
    do:
      "OpenRouter account credits unavailable. Successfully fetched key spending is still shown."

  defp warning_message({:usage_unavailable, :team_management_key_required}),
    do:
      "Exa usage analytics are unavailable for ordinary accounts. Exa requires Team Management API access; contact Exa support to enable it."

  defp warning_message(_warning),
    do:
      "Some provider data is unavailable. Displayed values represent only successfully fetched fields."

  defp error_message(:credential_not_found), do: "Check the referenced vault credential."
  defp error_message(:timeout), do: "The provider timed out."

  defp error_message({:http_error, status}) when status in [401, 403],
    do: "The provider rejected authorization."

  defp error_message(_reason), do: "Check provider availability and API-key credentials."
end
