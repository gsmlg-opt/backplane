defmodule Backplane.Admin.EndpointsLive do
  use Backplane.Admin, :live_view

  alias Backplane.Admin.Audit
  alias Backplane.Auth.{EndpointAccess, OAuth, Resources}
  alias Backplane.Clients
  alias Backplane.Endpoints
  alias Backplane.Endpoints.Endpoint
  alias Backplane.LLM.ModelCatalog
  alias Backplane.Registry.ToolRegistry

  @list_fields ~w(mcp_prefixes models oauth_client_ids client_ids)
  @flag_fields ~w(mcp_enabled llm_enabled restrict_clients)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/system/endpoints")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket |> assign(editing: nil, errors: [], form: to_endpoint_form(defaults())) |> load()

    case socket.assigns.live_action do
      :index ->
        {:noreply, assign(socket, modal_open: false)}

      :new ->
        {:noreply, assign(socket, modal_open: true)}

      :edit ->
        case Enum.find(socket.assigns.endpoints, &(&1.id == params["id"])) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, dgettext("admin", "Endpoint not found"))
             |> push_patch(to: ~p"/system/endpoints")}

          endpoint ->
            {:noreply,
             assign(socket,
               modal_open: true,
               editing: endpoint,
               form: to_endpoint_form(values(endpoint))
             )}
        end
    end
  end

  @impl true
  def handle_event("add", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/system/endpoints/new")}

  def handle_event("edit", %{"id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/system/endpoints/#{id}/edit")}

  def handle_event("cancel", _params, socket) do
    if socket.assigns.modal_open,
      do: {:noreply, push_patch(socket, to: ~p"/system/endpoints")},
      else: {:noreply, socket}
  end

  def handle_event("save", %{"endpoint" => params}, socket) do
    attrs = normalize(params)

    {result, action} =
      case socket.assigns.editing do
        nil -> {Endpoints.create(attrs), "create"}
        endpoint -> {Endpoints.update(endpoint, attrs), "update"}
      end

    case result do
      {:ok, endpoint} ->
        Audit.record("endpoint.#{action}", "endpoint", endpoint.id)

        {:noreply,
         socket
         |> put_flash(:info, dgettext("admin", "Endpoint saved"))
         |> push_patch(to: ~p"/system/endpoints")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           form: to_endpoint_form(Map.merge(defaults(), params)),
           errors: errors(changeset)
         )}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with %Endpoint{} = endpoint <- find(socket, id),
         {:ok, updated} <- Endpoints.set_enabled(endpoint, not endpoint.enabled) do
      Audit.record(
        if(updated.enabled, do: "endpoint.enable", else: "endpoint.disable"),
        "endpoint",
        id
      )

      {:noreply, load(socket)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, dgettext("admin", "Endpoint could not be changed"))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Endpoint{} = endpoint <- find(socket, id),
         {:ok, _} <- EndpointAccess.delete_endpoint(endpoint) do
      Audit.record("endpoint.delete", "endpoint", id)

      {:noreply, socket |> load() |> put_flash(:info, dgettext("admin", "Endpoint deleted"))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, dgettext("admin", "Endpoint could not be deleted"))}
    end
  end

  defp find(socket, id), do: Enum.find(socket.assigns.endpoints, &(&1.id == id))

  defp load(socket) do
    tools = ToolRegistry.list_all()

    prefixes =
      for %{origin: {kind, prefix}} <- tools,
          kind in [:upstream, :managed],
          prefix not in Endpoints.forbidden_prefixes(),
          uniq: true,
          do: prefix

    assign(socket,
      endpoints: Endpoints.list(),
      prefix_options: Enum.sort(prefixes),
      model_options: ModelCatalog.entries() |> Enum.map(& &1["id"]) |> Enum.sort(),
      oauth_options:
        Enum.map(OAuth.list_clients(), &{to_string(&1.id), &1.name || to_string(&1.id)}),
      client_options: Enum.map(Clients.list_clients(), &{to_string(&1.id), &1.name})
    )
  end

  defp defaults do
    %{
      "name" => "",
      "description" => "",
      "mcp_enabled" => "false",
      "llm_enabled" => "false",
      "restrict_clients" => "false",
      "mcp_prefixes" => [],
      "models" => [],
      "oauth_client_ids" => [],
      "client_ids" => []
    }
  end

  defp values(endpoint) do
    Map.merge(defaults(), %{
      "name" => endpoint.name,
      "description" => endpoint.description || "",
      "mcp_enabled" => to_string(endpoint.mcp_enabled),
      "llm_enabled" => to_string(endpoint.llm_enabled),
      "restrict_clients" => to_string(endpoint.restrict_clients),
      "mcp_prefixes" => endpoint.mcp_prefixes,
      "models" => endpoint.models,
      "oauth_client_ids" => endpoint.oauth_client_ids,
      "client_ids" => endpoint.client_ids
    })
  end

  defp to_endpoint_form(values), do: to_form(values, as: :endpoint)

  # Only the permitted fields; `enabled` can never be submitted from the form.
  defp normalize(params) do
    params
    |> Map.take(["name", "description" | @flag_fields ++ @list_fields])
    |> Map.new(fn
      {key, value} when key in @list_fields ->
        {key, value |> List.wrap() |> Enum.reject(&(&1 == ""))}

      {key, value} when key in @flag_fields ->
        {key, value == "true"}

      pair ->
        pair
    end)
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, text ->
        if is_binary(value) or is_number(value),
          do: String.replace(text, "%{#{key}}", to_string(value)),
          else: text
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
  end

  defp selected(form, field), do: form.params |> Map.get(field, []) |> List.wrap()

  # Allowlisted entries that are no longer offered stay visible and selected.
  defp choices(options, selected) do
    known = Enum.map(options, fn {value, label} -> {value, label, true} end)
    known_values = Enum.map(options, &elem(&1, 0))
    missing = for value <- selected, value not in known_values, do: {value, value, false}
    known ++ missing
  end

  defp plain(options), do: Enum.map(options, &{&1, &1})

  defp client_count(%{restrict_clients: false}), do: dgettext("admin", "All clients")

  defp client_count(endpoint),
    do: to_string(length(endpoint.oauth_client_ids) + length(endpoint.client_ids))

  defp urls(endpoint) do
    for {feature, base, enabled} <- [
          {"MCP", :mcp, endpoint.mcp_enabled},
          {"LLM", :v1, endpoint.llm_enabled}
        ],
        enabled do
      key = Resources.endpoint_key(endpoint.name, base)
      %{feature: feature, url: Resources.uri(key), metadata: Resources.metadata_uri(key)}
    end
  end

  attr(:legend, :string, required: true)
  attr(:field, :string, required: true)
  attr(:form, :map, required: true)
  attr(:options, :list, required: true)
  attr(:empty, :string, required: true)

  defp checkbox_group(assigns) do
    assigns =
      assign(assigns, choices: choices(assigns.options, selected(assigns.form, assigns.field)))

    ~H"""
    <fieldset id={"endpoint-#{@field}"} class="min-w-0">
      <legend class="mb-1 text-sm font-medium">{@legend}</legend>
      <input type="hidden" name={"endpoint[#{@field}][]"} value="" />
      <p :if={@choices == []} class="text-xs text-on-surface-variant">{@empty}</p>
      <div class="flex max-h-40 flex-col gap-1 overflow-y-auto">
        <div :for={{value, label, available} <- @choices} class="flex min-w-0 flex-wrap items-center gap-2">
          <.dm_checkbox
            id={"endpoint-#{@field}-#{value}"}
            name={"endpoint[#{@field}][]"}
            value={value}
            label={label}
            hidden_input={false}
            checked={value in selected(@form, @field)}
          />
          <.dm_badge :if={not available} variant="warning">{dgettext("admin", "Unavailable")}</.dm_badge>
        </div>
      </div>
    </fieldset>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full min-w-0 max-w-7xl space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold">{dgettext("admin", "Endpoints")}</h1>
          <p class="mt-2 text-sm text-on-surface-variant">
            {dgettext(
              "admin",
              "Named MCP and LLM surfaces restricted to selected MCP services, models and clients."
            )}
          </p>
        </div>
        <.dm_btn id="add-endpoint" type="button" variant="primary" phx-click={JS.push("add") |> JS.push_focus()}>
          {dgettext("common", "Add")}
        </.dm_btn>
      </div>

      <.dm_card variant="bordered">
        <:title>{dgettext("admin", "Configured endpoints")}</:title>
        <p :if={@endpoints == []} id="endpoints-empty" class="text-sm text-on-surface-variant">
          {dgettext("admin", "No endpoints configured yet. Click Add to create one.")}
        </p>
        <div :if={@endpoints != []} class="overflow-x-auto">
          <.dm_table style="min-width: 56rem" id="endpoints-table" data={@endpoints} hover zebra>
            <:col :let={endpoint} label={dgettext("common", "Name")}>
              <div class="whitespace-nowrap font-medium">{endpoint.name}</div>
              <p :if={endpoint.description} class="text-xs text-on-surface-variant">{endpoint.description}</p>
            </:col>
            <:col :let={endpoint} label={dgettext("admin", "Features")}>
              <div class="flex flex-wrap gap-1">
                <.dm_badge :if={endpoint.mcp_enabled} variant="info">MCP</.dm_badge>
                <.dm_badge :if={endpoint.llm_enabled} variant="info">LLM</.dm_badge>
                <span :if={not endpoint.mcp_enabled and not endpoint.llm_enabled} class="text-xs text-on-surface-variant">
                  {dgettext("admin", "None")}
                </span>
              </div>
              <div :for={url <- urls(endpoint)} id={"endpoint-urls-#{endpoint.name}-#{String.downcase(url.feature)}"} class="mt-2 min-w-0">
                <code class="block break-all text-xs">{url.url}</code>
                <code class="block break-all text-xs text-on-surface-variant">{url.metadata}</code>
              </div>
            </:col>
            <:col :let={endpoint} label={dgettext("admin", "MCP services")}>
              <code :for={prefix <- endpoint.mcp_prefixes} class="block text-xs">{prefix}</code>
            </:col>
            <:col :let={endpoint} label={dgettext("admin", "Models")}>
              <code :for={model <- endpoint.models} class="block break-all text-xs">{model}</code>
            </:col>
            <:col :let={endpoint} label={dgettext("admin", "Clients")}>
              {client_count(endpoint)}
            </:col>
            <:col :let={endpoint} label={dgettext("common", "Status")}>
              <.dm_badge variant={if endpoint.enabled, do: "success", else: "neutral"}>
                {if endpoint.enabled,
                  do: dgettext("common", "Enabled"),
                  else: dgettext("common", "Disabled")}
              </.dm_badge>
            </:col>
            <:col :let={endpoint} label={dgettext("common", "Actions")}>
              <div class="flex items-center gap-1">
                <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Edit")} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    id={"edit-endpoint-#{endpoint.name}"}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="outline"
                    aria-label={dgettext("admin", "Edit %{name} endpoint", name: endpoint.name)}
                    phx-click={JS.push("edit", value: %{id: endpoint.id}) |> JS.push_focus()}
                  >
                    <.dm_mdi name="pencil" class="h-4 w-4" />
                    <span class="sr-only">{dgettext("common", "Edit")}</span>
                  </.dm_btn>
                </.dm_tooltip>
                <.dm_tooltip :let={tooltip_attrs} content={
                    if endpoint.enabled,
                      do: dgettext("common", "Disable"),
                      else: dgettext("common", "Enable")
                  } position="bottom">
                  <.dm_btn {tooltip_attrs}
                    id={"toggle-endpoint-#{endpoint.name}"}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="ghost"
                    aria-label={
                      if endpoint.enabled,
                        do: dgettext("admin", "Disable %{name} endpoint", name: endpoint.name),
                        else: dgettext("admin", "Enable %{name} endpoint", name: endpoint.name)
                    }
                    phx-click="toggle"
                    phx-value-id={endpoint.id}
                  >
                    <.dm_mdi name={if endpoint.enabled, do: "pause", else: "play"} class="h-4 w-4" />
                    <span class="sr-only">
                      {if endpoint.enabled,
                        do: dgettext("common", "Disable"),
                        else: dgettext("common", "Enable")}
                    </span>
                  </.dm_btn>
                </.dm_tooltip>
                <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Delete")} position="bottom">
                  <.dm_btn {tooltip_attrs}
                    id={"delete-endpoint-#{endpoint.name}"}
                    type="button"
                    size="xs"
                    shape="circle"
                    variant="error"
                    aria-label={dgettext("admin", "Delete %{name} endpoint", name: endpoint.name)}
                    phx-click="delete"
                    phx-value-id={endpoint.id}
                    data-confirm={
                      dgettext(
                        "admin",
                        "Delete the %{name} endpoint? Every access token issued for it is revoked.",
                        name: endpoint.name
                      )
                    }
                  >
                    <.dm_mdi name="delete" class="h-4 w-4" />
                    <span class="sr-only">{dgettext("common", "Delete")}</span>
                  </.dm_btn>
                </.dm_tooltip>
              </div>
            </:col>
          </.dm_table>
        </div>
      </.dm_card>

      <.dm_modal
        :if={@modal_open}
        id="endpoint-modal"
        size="xl"
        phx-hook="OpenAIServiceModal"
        phx-remove={JS.pop_focus()}
      >
        <:title>
          {if @editing,
            do: dgettext("admin", "Edit %{name} endpoint", name: @editing.name),
            else: dgettext("admin", "Add endpoint")}
        </:title>
        <:body>
          <p class="mb-4 text-sm text-on-surface-variant">
            {dgettext(
              "admin",
              "The endpoint serves /endpoints/{name}/mcp and /endpoints/{name}/v1 with only the selections below."
            )}
          </p>
          <div :if={@errors != []} id="endpoint-errors" role="alert" class="mb-4 text-sm text-error">
            <p :for={error <- @errors}>{error}</p>
          </div>
          <.form for={@form} id="endpoint-form" phx-submit="save" class="space-y-4">
            <.dm_input
              field={@form[:name]}
              label={dgettext("common", "Name")}
              placeholder="chatgpt"
              readonly={@editing != nil}
              autofocus={@editing == nil}
            />
            <p class="text-xs text-on-surface-variant">
              {dgettext("admin", "Lowercase letters, digits and hyphens. The name cannot be changed later.")}
            </p>
            <.dm_input field={@form[:description]} label={dgettext("admin", "Description (optional)")} />

            <div class="space-y-2">
              <input type="hidden" name="endpoint[mcp_enabled]" value="false" />
              <.dm_checkbox
                id="endpoint-mcp-enabled"
                name="endpoint[mcp_enabled]"
                value="true"
                hidden_input={false}
                label={dgettext("admin", "MCP enabled")}
                checked={@form.params["mcp_enabled"] == "true"}
              />
              <.checkbox_group
                legend={dgettext("admin", "MCP services")}
                field="mcp_prefixes"
                form={@form}
                options={plain(@prefix_options)}
                empty={dgettext("admin", "No MCP services are registered.")}
              />
            </div>

            <div class="space-y-2">
              <input type="hidden" name="endpoint[llm_enabled]" value="false" />
              <.dm_checkbox
                id="endpoint-llm-enabled"
                name="endpoint[llm_enabled]"
                value="true"
                hidden_input={false}
                label={dgettext("admin", "LLM enabled")}
                checked={@form.params["llm_enabled"] == "true"}
              />
              <.checkbox_group
                legend={dgettext("admin", "Models")}
                field="models"
                form={@form}
                options={plain(@model_options)}
                empty={dgettext("admin", "No models are available.")}
              />
            </div>

            <div class="space-y-2">
              <input type="hidden" name="endpoint[restrict_clients]" value="false" />
              <.dm_checkbox
                id="endpoint-restrict-clients"
                name="endpoint[restrict_clients]"
                value="true"
                hidden_input={false}
                label={dgettext("admin", "Restrict clients")}
                checked={@form.params["restrict_clients"] == "true"}
              />
              <p class="text-xs text-on-surface-variant">
                {dgettext("admin", "When off, every client with access to the resource may use this endpoint.")}
              </p>
              <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                <.checkbox_group
                  legend={dgettext("admin", "OAuth clients")}
                  field="oauth_client_ids"
                  form={@form}
                  options={@oauth_options}
                  empty={dgettext("admin", "No OAuth clients.")}
                />
                <.checkbox_group
                  legend={dgettext("admin", "Client tokens")}
                  field="client_ids"
                  form={@form}
                  options={@client_options}
                  empty={dgettext("admin", "No client tokens.")}
                />
              </div>
            </div>

            <div class="flex gap-2">
              <.dm_btn type="submit" variant="primary" phx-disable-with={dgettext("common", "Saving...")}>
                {dgettext("admin", "Save endpoint")}
              </.dm_btn>
              <.dm_btn id="cancel-endpoint" type="button" variant="ghost" command="close" commandfor="endpoint-modal">
                {dgettext("common", "Cancel")}
              </.dm_btn>
            </div>
          </.form>
        </:body>
      </.dm_modal>
    </div>
    """
  end
end
