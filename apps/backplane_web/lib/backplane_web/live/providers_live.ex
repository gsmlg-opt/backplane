defmodule BackplaneWeb.ProvidersLive do
  use BackplaneWeb, :live_view

  alias Backplane.LLM.HealthChecker
  alias Backplane.LLM.ModelAlias
  alias Backplane.LLM.Provider
  alias Backplane.LLM.UsageQuery
  alias Backplane.PubSubBroadcaster
  alias Backplane.Settings.Credentials

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.llm_providers_topic())
    end

    {:ok,
     assign(socket,
       current_path: "/admin/providers",
       loading: true,
       providers: [],
       editing: nil,
       form: nil,
       alias_form: nil,
       alias_provider_id: nil,
       editing_alias: nil,
       selected_provider: nil,
       usage: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_providers(socket)}
  end

  @impl true
  def handle_info({:llm_providers_changed, _}, socket) do
    {:noreply, load_providers(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ── Events ────────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("new", _, socket) do
    changeset = Provider.changeset(%Provider{}, %{})

    {:noreply,
     assign(socket,
       editing: :new,
       form: provider_form(changeset),
       alias_form: nil,
       alias_provider_id: nil
     )}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Provider.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Provider not found")}

      provider ->
        changeset = Provider.update_changeset(provider, %{})

        {:noreply,
         assign(socket,
           editing: provider,
           form: provider_form(changeset),
           alias_form: nil,
           alias_provider_id: nil
         )}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply,
     assign(socket,
       editing: nil,
       form: nil,
       alias_form: nil,
       alias_provider_id: nil,
       editing_alias: nil
     )}
  end

  def handle_event("validate", %{"provider" => params}, socket) do
    changeset =
      case socket.assigns.editing do
        :new ->
          Provider.changeset(%Provider{}, prepare_provider_params(params))

        %Provider{} = provider ->
          Provider.update_changeset(provider, prepare_provider_params(params))
      end

    {:noreply, assign(socket, form: provider_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("save", %{"provider" => params}, socket) do
    attrs = prepare_provider_params(params)

    case socket.assigns.editing do
      :new -> create_provider(socket, attrs)
      %Provider{} = provider -> update_provider(socket, provider, attrs)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Provider.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Provider not found")}

      provider ->
        case Provider.soft_delete(provider) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Provider #{provider.name} deleted")
             |> assign(editing: nil, form: nil, selected_provider: nil, usage: nil)
             |> load_providers()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete provider")}
        end
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    case Provider.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Provider not found")}

      provider ->
        case Provider.update(provider, %{enabled: !provider.enabled}) do
          {:ok, _} ->
            {:noreply, load_providers(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle provider")}
        end
    end
  end

  def handle_event("new_alias", %{"provider-id" => id}, socket) do
    case Provider.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Provider not found")}

      provider ->
        alias_changeset = ModelAlias.changeset(%ModelAlias{}, %{})

        {:noreply,
         assign(socket,
           alias_form: model_alias_form(alias_changeset),
           alias_provider_id: provider.id,
           editing: nil,
           form: nil
         )}
    end
  end

  def handle_event("edit_alias", %{"id" => id}, socket) do
    case ModelAlias.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Alias not found")}

      model_alias ->
        changeset = ModelAlias.changeset(model_alias, %{})

        {:noreply,
         assign(socket,
           alias_form: model_alias_form(changeset),
           alias_provider_id: model_alias.provider_id,
           editing_alias: model_alias,
           editing: nil,
           form: nil
         )}
    end
  end

  def handle_event("save_alias", %{"model_alias" => params}, socket) do
    provider_id = socket.assigns.alias_provider_id

    case socket.assigns.editing_alias do
      nil ->
        # Creating new alias
        attrs = %{
          "alias" => params["alias"],
          "model" => params["model"],
          "provider_id" => provider_id
        }

        case ModelAlias.create(attrs) do
          {:ok, _alias} ->
            {:noreply,
             socket
             |> put_flash(:info, "Alias created")
             |> assign(alias_form: nil, alias_provider_id: nil, editing_alias: nil)
             |> load_providers()}

          {:error, changeset} ->
            {:noreply, assign(socket, alias_form: model_alias_form(changeset))}
        end

      %ModelAlias{} = existing ->
        # Updating existing alias
        attrs = %{
          "alias" => params["alias"],
          "model" => params["model"],
          "provider_id" => provider_id
        }

        case ModelAlias.update(existing, attrs) do
          {:ok, _alias} ->
            {:noreply,
             socket
             |> put_flash(:info, "Alias updated")
             |> assign(alias_form: nil, alias_provider_id: nil, editing_alias: nil)
             |> load_providers()}

          {:error, changeset} ->
            {:noreply, assign(socket, alias_form: model_alias_form(changeset))}
        end
    end
  end

  def handle_event("delete_alias", %{"id" => id}, socket) do
    case ModelAlias.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Alias not found")}

      model_alias ->
        case ModelAlias.delete(model_alias) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Alias deleted")
             |> load_providers()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete alias")}
        end
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    case Provider.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Provider not found")}

      provider ->
        usage =
          try do
            UsageQuery.aggregate(%{provider_id: provider.id})
          rescue
            _ -> nil
          end

        {:noreply, assign(socket, selected_provider: provider, usage: usage)}
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp create_provider(socket, attrs) do
    case Provider.create(attrs) do
      {:ok, provider} ->
        {:noreply,
         socket
         |> put_flash(:info, "Provider #{provider.name} created")
         |> assign(editing: nil, form: nil)
         |> load_providers()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: provider_form(changeset))}
    end
  end

  defp update_provider(socket, provider, attrs) do
    case Provider.update(provider, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Provider #{updated.name} updated")
         |> assign(editing: nil, form: nil)
         |> load_providers()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: provider_form(changeset))}
    end
  end

  defp prepare_provider_params(params) do
    params
    |> Map.put("models", parse_models(params["models"]))
    |> Map.put("rpm_limit", parse_rpm_limit(params["rpm_limit"]))
    |> Map.put("default_headers", parse_default_headers(params["default_headers"]))
    |> Map.put("api_type", parse_api_type(params["api_type"]))
    |> then(fn result ->
      case result["credential"] do
        "" -> Map.put(result, "credential", nil)
        _ -> result
      end
    end)
  end

  defp parse_models(nil), do: []

  defp parse_models(val) do
    val
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_rpm_limit(nil), do: nil
  defp parse_rpm_limit(""), do: nil

  defp parse_rpm_limit(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_default_headers(nil), do: %{}
  defp parse_default_headers(""), do: %{}

  defp parse_default_headers(val) do
    case Jason.decode(val) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp parse_api_type("anthropic"), do: :anthropic
  defp parse_api_type("openai"), do: :openai
  defp parse_api_type(other), do: other

  defp provider_form(changeset) do
    changeset
    |> changeset_params([
      :name,
      :api_type,
      :api_url,
      :credential,
      :models,
      :rpm_limit,
      :default_headers
    ])
    |> to_form(as: :provider, errors: visible_errors(changeset))
  end

  defp model_alias_form(changeset) do
    changeset
    |> changeset_params([:alias, :model, :provider_id])
    |> to_form(as: :model_alias, errors: visible_errors(changeset))
  end

  defp changeset_params(changeset, fields) do
    Map.new(fields, fn field ->
      {Atom.to_string(field), Ecto.Changeset.get_field(changeset, field)}
    end)
  end

  defp visible_errors(%Ecto.Changeset{action: nil}), do: []
  defp visible_errors(%Ecto.Changeset{errors: errors}), do: errors

  defp load_providers(socket) do
    providers =
      try do
        Provider.list()
      rescue
        _ -> []
      end

    credential_options =
      try do
        creds = Credentials.list()
        [{"", "Select a credential..."} | Enum.map(creds, fn c -> {c.name, c.name} end)]
      rescue
        _ -> [{"", "Select a credential..."}]
      end

    assign(socket, loading: false, providers: providers, credential_options: credential_options)
  end

  defp api_type_badge_variant(:anthropic), do: "tertiary"
  defp api_type_badge_variant(:openai), do: "info"
  defp api_type_badge_variant(_), do: "neutral"

  defp api_type_label(:anthropic), do: "Anthropic"
  defp api_type_label(:openai), do: "OpenAI"
  defp api_type_label(_), do: "Unknown"

  defp health_dot(provider_id) do
    if HealthChecker.healthy?(provider_id), do: "bg-success", else: "bg-error"
  end

  defp models_display(models) when is_list(models), do: Enum.join(models, ", ")
  defp models_display(_), do: ""

  defp headers_display(headers) when is_map(headers) and map_size(headers) > 0 do
    case Jason.encode(headers, pretty: true) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp headers_display(_), do: ""

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

  # ── Template ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">LLM Providers</h1>
        <.dm_btn variant="primary" size="sm" phx-click="new">Add Provider</.dm_btn>
      </div>

      <%!-- Provider Form (create/edit) --%>
      <.dm_card :if={@editing} variant="bordered" class="mb-6">
        <:title>
          {if @editing == :new, do: "New Provider", else: "Edit Provider"}
        </:title>
        <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-4">
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <.dm_input
                id="provider-name"
                name="provider[name]"
                label="Name"
                value={@form[:name].value}
                placeholder="anthropic-prod"
              />
              <.form_error field={@form[:name]} />
            </div>

            <div>
              <.dm_select
                id="provider-api-type"
                name="provider[api_type]"
                label="API Type"
                options={[{"anthropic", "Anthropic"}, {"openai", "OpenAI"}]}
                value={to_string(@form[:api_type].value)}
              />
              <.form_error field={@form[:api_type]} />
            </div>

            <div>
              <.dm_input
                id="provider-api-url"
                name="provider[api_url]"
                label="API URL"
                value={@form[:api_url].value}
                placeholder="https://api.anthropic.com"
              />
              <.form_error field={@form[:api_url]} />
            </div>

            <div>
              <.dm_select
                id="provider-credential"
                name="provider[credential]"
                label="Credential"
                options={@credential_options}
                value={@form[:credential].value || ""}
              />
              <p class="text-xs text-on-surface-variant mt-1">
                Select a credential from the <.link navigate={~p"/admin/settings?tab=credentials"} class="text-primary underline">credential store</.link>.
              </p>
              <.form_error field={@form[:credential]} />
            </div>

            <div class="sm:col-span-2">
              <.dm_input
                id="provider-models"
                name="provider[models]"
                label="Models (comma-separated)"
                value={models_display(@form[:models].value)}
                placeholder="claude-sonnet-4-20250514, claude-haiku-3-20240307"
              />
              <.form_error field={@form[:models]} />
            </div>

            <div>
              <.dm_input
                id="provider-rpm-limit"
                name="provider[rpm_limit]"
                label="RPM Limit (optional)"
                value={@form[:rpm_limit].value}
                placeholder="60"
              />
              <.form_error field={@form[:rpm_limit]} />
            </div>

            <div class="sm:col-span-2">
              <.dm_textarea
                id="provider-default-headers"
                name="provider[default_headers]"
                label="Default Headers (JSON object, optional)"
                rows={3}
                value={headers_display(@form[:default_headers].value)}
                placeholder={~s({"anthropic-version": "2023-06-01"})}
                class="font-mono"
              />
              <.form_error field={@form[:default_headers]} />
            </div>
          </div>

          <div class="flex gap-2">
            <.dm_btn type="submit" variant="primary">Save</.dm_btn>
            <.dm_btn type="button" phx-click="cancel">Cancel</.dm_btn>
          </div>
        </.form>
      </.dm_card>

      <%!-- Alias Form --%>
      <.dm_card :if={@alias_form} variant="bordered" class="mb-6">
        <:title>{if @editing_alias, do: "Edit Model Alias", else: "Add Model Alias"}</:title>
        <.form for={@alias_form} phx-submit="save_alias" class="flex items-end gap-4">
          <div>
            <.dm_input
              id="alias-name"
              name="model_alias[alias]"
              label="Alias Name"
              value={@alias_form[:alias].value}
              placeholder="fast"
            />
            <.form_error field={@alias_form[:alias]} />
          </div>
          <div>
            <.dm_select
              id="alias-model"
              name="model_alias[model]"
              label="Model"
              options={Enum.map(alias_provider_models(@providers, @alias_provider_id), &{&1, &1})}
              value={to_string(@alias_form[:model].value)}
            />
            <.form_error field={@alias_form[:model]} />
          </div>
          <div class="flex gap-2">
            <.dm_btn type="submit" variant="primary" size="sm">Save</.dm_btn>
            <.dm_btn type="button" size="sm" phx-click="cancel">Cancel</.dm_btn>
          </div>
        </.form>
      </.dm_card>

      <%!-- Usage Panel --%>
      <.dm_card :if={@selected_provider && @usage} variant="bordered" class="mb-6">
        <:title>
          <div class="flex items-center justify-between">
            <span>Usage: {@selected_provider.name}</span>
            <.dm_btn
              variant="ghost"
              size="xs"
              phx-click="select"
              phx-value-id={@selected_provider.id}
            >
              Refresh
            </.dm_btn>
          </div>
        </:title>
        <div class="grid grid-cols-2 gap-4 sm:grid-cols-4 mb-4">
          <.dm_stat title="Total Requests" value={to_string(@usage.total_requests)} />
          <.dm_stat title="Input Tokens" value={to_string(@usage.total_input_tokens)} />
          <.dm_stat title="Output Tokens" value={to_string(@usage.total_output_tokens)} />
          <.dm_stat title="Avg Latency" value={"#{@usage.avg_latency_ms}ms"} />
        </div>

        <div :if={@usage.by_model != []} class="mb-4">
          <h3 class="text-sm font-medium text-on-surface mb-2">By Model</h3>
          <div class="space-y-1">
            <div
              :for={row <- @usage.by_model}
              class="flex items-center justify-between text-sm px-3 py-1.5 bg-surface-container-high rounded"
            >
              <span class="text-on-surface font-mono">{row.model}</span>
              <span class="text-on-surface-variant">{row.requests} reqs</span>
            </div>
          </div>
        </div>

        <div :if={map_size(@usage.by_status) > 0}>
          <h3 class="text-sm font-medium text-on-surface mb-2">By Status</h3>
          <div class="flex flex-wrap gap-2">
            <.dm_badge
              :for={{status, count} <- @usage.by_status}
              variant="neutral"
              size="sm"
            >
              {status}: {count}
            </.dm_badge>
          </div>
        </div>
      </.dm_card>

      <%!-- Provider List --%>
      <div :if={@providers == []} class="text-on-surface-variant">
        No LLM providers configured.
      </div>

      <div class="space-y-4">
        <.dm_card :for={provider <- @providers} variant="bordered">
          <div class="flex items-start justify-between">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <.dm_btn
                  variant="link"
                  size="sm"
                  phx-click="select"
                  phx-value-id={provider.id}
                >
                  {provider.name}
                </.dm_btn>
                <.dm_badge variant={api_type_badge_variant(provider.api_type)} size="sm">
                  {api_type_label(provider.api_type)}
                </.dm_badge>
                <span
                  class={["inline-block w-2 h-2 rounded-full", health_dot(provider.id)]}
                  title={if HealthChecker.healthy?(provider.id), do: "Healthy", else: "Unhealthy"}
                >
                </span>
              </div>
              <p class="text-xs text-on-surface-variant mt-1 truncate">{provider.api_url}</p>
              <p class="text-xs text-on-surface-variant mt-0.5">
                {length(provider.models || [])} model(s)
                <%= if provider.credential do %>
                  · credential: <code>{provider.credential}</code>
                <% end %>
              </p>

              <%!-- Aliases --%>
              <div :if={provider.aliases != []} class="flex flex-wrap gap-1 mt-2">
                <span :for={a <- provider.aliases} class="inline-flex items-center gap-1">
                  <.dm_badge variant="neutral" size="sm">
                    {a.alias} → {a.model}
                  </.dm_badge>
                  <.dm_btn
                    variant="ghost"
                    size="xs"
                    phx-click="edit_alias"
                    phx-value-id={a.id}
                    title="Edit alias"
                  >
                    ✎
                  </.dm_btn>
                  <.dm_btn
                    variant="error"
                    size="xs"
                    data-confirm={"Delete alias #{a.alias}?"}
                    phx-click="delete_alias"
                    phx-value-id={a.id}
                    title="Delete alias"
                  >
                    ×
                  </.dm_btn>
                </span>
              </div>
            </div>

            <div class="flex items-center gap-2 ml-4 flex-shrink-0">
              <.dm_btn
                variant={if provider.enabled, do: "warning", else: "success"}
                size="xs"
                phx-click="toggle_enabled"
                phx-value-id={provider.id}
              >
                {if provider.enabled, do: "Disable", else: "Enable"}
              </.dm_btn>
              <.dm_btn size="xs" phx-click="new_alias" phx-value-provider-id={provider.id}>
                + Alias
              </.dm_btn>
              <.dm_btn size="xs" phx-click="edit" phx-value-id={provider.id}>Edit</.dm_btn>
              <.dm_btn
                variant="error"
                size="xs"
                data-confirm={"Delete provider #{provider.name}? This cannot be undone."}
                phx-click="delete"
                phx-value-id={provider.id}
              >
                Delete
              </.dm_btn>
            </div>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end

  defp alias_provider_models(providers, provider_id) do
    provider = Enum.find(providers, &(&1.id == provider_id))
    if provider, do: provider.models || [], else: []
  end
end
