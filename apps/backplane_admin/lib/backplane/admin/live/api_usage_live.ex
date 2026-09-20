defmodule Backplane.Admin.ApiUsageLive do
  use Backplane.Admin, :live_view

  alias Backplane.Admin.Audit
  alias Backplane.Monitor.{ApiAccount, ApiAccounts}

  @fields ~w(name provider credential_name management_credential_name active)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/system/monitor/api-usage",
       accounts: [],
       editing: nil,
       form: nil,
       credentials: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = load_accounts(socket)

    case socket.assigns.live_action do
      :index ->
        {:noreply, assign(socket, editing: nil, form: nil)}

      :new ->
        {:noreply, edit_account(socket, %ApiAccount{}, :new)}

      :edit ->
        case ApiAccounts.get_account(params["id"]) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "API account not found")
             |> push_patch(to: ~p"/system/monitor/api-usage")}

          account ->
            {:noreply, edit_account(socket, account, account)}
        end
    end
  end

  @impl true
  def handle_event("validate", %{"account" => params}, socket) do
    changeset = ApiAccounts.change_account(form_account(socket), account_params(params))
    {:noreply, assign(socket, form: account_form(%{changeset | action: :validate}))}
  end

  def handle_event("save", %{"account" => params}, socket) do
    params = account_params(params)

    {action, result} =
      case socket.assigns.editing do
        :new -> {"create", ApiAccounts.create_account(params)}
        %ApiAccount{} = account -> {"update", ApiAccounts.update_account(account, params)}
      end

    case result do
      {:ok, account} ->
        Audit.record("monitor_api_account.#{action}", "monitor_api_account", account.id)

        {:noreply,
         socket
         |> put_flash(:info, "API account saved")
         |> push_patch(to: ~p"/system/monitor/api-usage")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: account_form(changeset))}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    mutate_account(socket, id, "toggle", fn account ->
      ApiAccounts.update_account(account, %{active: !account.active})
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    mutate_account(socket, id, "delete", &ApiAccounts.delete_account/1)
  end

  defp mutate_account(socket, id, action, mutation) do
    case ApiAccounts.get_account(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "API account not found")}

      account ->
        case mutation.(account) do
          {:ok, _account} ->
            Audit.record("monitor_api_account.#{action}", "monitor_api_account", account.id)
            {:noreply, load_accounts(socket)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not change API account")}
        end
    end
  end

  defp edit_account(socket, account, editing) do
    credentials =
      ApiAccounts.credential_options()
      |> Enum.map(fn entry ->
        name = Map.get(entry, :name) || Map.fetch!(entry, "name")
        {name, name}
      end)
      |> Enum.sort()

    assign(socket,
      editing: editing,
      credentials: credentials,
      form: account_form(ApiAccounts.change_account(account, %{}))
    )
  end

  defp form_account(%{assigns: %{editing: :new}}), do: %ApiAccount{}
  defp form_account(%{assigns: %{editing: account}}), do: account

  defp account_params(params) do
    params = Map.take(params, @fields)

    if params["provider"] not in ["openrouter", "exa"],
      do: Map.put(params, "management_credential_name", nil),
      else: params
  end

  defp account_form(changeset) do
    values =
      Map.new(@fields, fn field ->
        {field, Ecto.Changeset.get_field(changeset, String.to_existing_atom(field))}
      end)

    values = Map.merge(values, Map.take(changeset.params || %{}, @fields))
    errors = if changeset.action, do: changeset.errors, else: []
    to_form(values, as: :account, errors: errors, action: changeset.action)
  end

  defp load_accounts(socket), do: assign(socket, accounts: ApiAccounts.list_accounts())

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">API Usage</h1>
          <p class="text-sm text-on-surface-variant">
            Configure API accounts and their vault credential references.
            Balances and spending are available on the API Usage dashboard.
          </p>
        </div>
        <div class="flex items-center gap-3">
          <.link patch={~p"/system/monitor/api-usage/new"}>
            <.dm_btn variant="primary" size="sm">New API Account</.dm_btn>
          </.link>
        </div>
      </div>

      <.dm_card :if={@editing} variant="bordered">
        <:title>{if @editing == :new, do: "New API Account", else: "Edit API Account"}</:title>
        <.form for={@form} id="api-account-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <.dm_input id="api-account-name" name="account[name]" label="Name" value={@form[:name].value} />
          <.form_error field={@form[:name]} />
          <.dm_select id="api-account-provider" name="account[provider]" label="Provider"
            value={@form[:provider].value} prompt="Select a provider..."
            options={Enum.map(ApiAccount.providers(), &{&1, provider_label(&1)})} />
          <.form_error field={@form[:provider]} />
          <.dm_select id="api-account-credential" name="account[credential_name]" label="API-key credential"
            value={@form[:credential_name].value} prompt="Select a credential..." options={@credentials}
            helper="Only LLM/service API-key vault entries are eligible. Secret values are never displayed." />
          <.form_error field={@form[:credential_name]} />
          <div :if={@form[:provider].value == "openrouter"}>
            <.dm_select id="api-account-management-credential" name="account[management_credential_name]"
              label="Management credential (optional)" value={@form[:management_credential_name].value}
              prompt="No management credential" options={@credentials}
              helper="OpenRouter account credits require a management key. Missing or failed credits do not hide key usage." />
            <.form_error field={@form[:management_credential_name]} />
          </div>
          <p :if={@form[:provider].value == "exa"} class="text-sm text-on-surface-variant">
            Exa search works with a regular API key. Exa usage analytics require Team Management API access,
            which is not enabled for ordinary accounts. Contact Exa support to request access.
          </p>
          <.dm_checkbox id="api-account-active" name="account[active]" label="Active"
            checked={@form[:active].value in [true, "true"]} />
          <.form_error field={@form[:active]} />
          <div class="flex gap-3">
            <.dm_btn type="submit" variant="primary">Save</.dm_btn>
            <.link patch={~p"/system/monitor/api-usage"}>
              <.dm_btn type="button">Cancel</.dm_btn>
            </.link>
          </div>
        </.form>
      </.dm_card>

      <p :if={!@editing && @accounts == []} class="text-on-surface-variant">
        No API accounts configured. Add an account using an API-key credential from the vault.
      </p>

      <.dm_table :if={!@editing && @accounts != []} id="monitor-api-accounts-table" data={@accounts} hover zebra>
        <:col :let={account} label="Name">
          <div id={"api-account-#{account.id}"} class="font-medium text-on-surface">{account.name}</div>
        </:col>
        <:col :let={account} label="Provider">
          <.dm_badge variant="info" size="sm">{provider_label(account.provider)}</.dm_badge>
        </:col>
        <:col :let={account} label="API-key credential">
          <code class="text-xs font-mono">{account.credential_name}</code>
        </:col>
        <:col :let={account} label="Management credential">
          <code class="text-xs font-mono">{account.management_credential_name || "Not configured"}</code>
        </:col>
        <:col :let={account} label="Status">
          <.dm_badge variant={if account.active, do: "success", else: "warning"} size="sm">
            {if account.active, do: "Active", else: "Paused"}
          </.dm_badge>
        </:col>
        <:col :let={account} label="Last Updated">
          <span class="text-xs text-on-surface-variant"><.local_time datetime={account.updated_at} /></span>
        </:col>
        <:col :let={account} label="Actions">
          <div class="flex items-center gap-1">
            <.dm_tooltip content={if account.active, do: "Pause", else: "Resume"} position="bottom">
              <.dm_btn id={"toggle-api-account-#{account.id}"} type="button" size="xs" shape="circle"
                variant={if account.active, do: "warning", else: "success"}
                aria-label={"#{if account.active, do: "Pause", else: "Resume"} #{account.name}"}
                phx-click="toggle_active" phx-value-id={account.id}>
                <.dm_mdi name={if account.active, do: "pause", else: "play"} class="h-4 w-4" />
                <span class="sr-only">{if account.active, do: "Pause", else: "Resume"}</span>
              </.dm_btn>
            </.dm_tooltip>
            <.dm_tooltip content="Edit" position="bottom">
              <.link id={"edit-api-account-#{account.id}"} patch={~p"/system/monitor/api-usage/#{account.id}/edit"} class="no-underline">
                <.dm_btn type="button" size="xs" shape="circle" aria-label={"Edit #{account.name}"}>
                  <.dm_mdi name="pencil" class="h-4 w-4" /><span class="sr-only">Edit</span>
                </.dm_btn>
              </.link>
            </.dm_tooltip>
            <.dm_tooltip content="Delete" position="bottom">
              <.dm_btn id={"delete-api-account-#{account.id}"} type="button" size="xs" shape="circle" variant="error"
                aria-label={"Delete #{account.name}"} phx-click="delete" phx-value-id={account.id}
                confirm="Delete this API account?">
                <.dm_mdi name="trash-can" class="h-4 w-4" /><span class="sr-only">Delete</span>
              </.dm_btn>
            </.dm_tooltip>
          </div>
        </:col>
      </.dm_table>
    </div>
    """
  end

  defp provider_label("openrouter"), do: "OpenRouter"
  defp provider_label("deepseek"), do: "DeepSeek"
  defp provider_label("exa"), do: "Exa"
  defp provider_label("tavily"), do: "Tavily"
  defp provider_label("firecrawl"), do: "Firecrawl"

  defp form_error(assigns) do
    ~H"""
    <.dm_error :for={error <- @field.errors}>{translate_error(error)}</.dm_error>
    """
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, translated ->
      String.replace(translated, "%{#{key}}", fn _match -> to_string(value) end)
    end)
  end
end
