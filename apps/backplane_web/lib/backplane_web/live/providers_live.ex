defmodule BackplaneWeb.ProvidersLive do
  use BackplaneWeb, :live_view

  alias Backplane.LLM.HealthChecker
  alias Backplane.LLM.ModelAlias
  alias Backplane.LLM.Provider
  alias Backplane.LLM.UsageQuery
  alias Backplane.PubSubBroadcaster

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
       form: to_form(changeset),
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
           form: to_form(changeset),
           alias_form: nil,
           alias_provider_id: nil
         )}
    end
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, form: nil, alias_form: nil, alias_provider_id: nil)}
  end

  def handle_event("validate", %{"provider" => params}, socket) do
    changeset =
      case socket.assigns.editing do
        :new ->
          Provider.changeset(%Provider{}, prepare_provider_params(params))

        %Provider{} = provider ->
          Provider.update_changeset(provider, prepare_provider_params(params))
      end

    {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
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
           alias_form: to_form(alias_changeset, as: :model_alias),
           alias_provider_id: provider.id,
           editing: nil,
           form: nil
         )}
    end
  end

  def handle_event("save_alias", %{"model_alias" => params}, socket) do
    provider_id = socket.assigns.alias_provider_id

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
         |> assign(alias_form: nil, alias_provider_id: nil)
         |> load_providers()}

      {:error, changeset} ->
        {:noreply, assign(socket, alias_form: to_form(changeset, as: :model_alias))}
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
        {:noreply, assign(socket, form: to_form(changeset))}
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
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp prepare_provider_params(params) do
    result =
      params
      |> Map.put("models", parse_models(params["models"]))
      |> Map.put("rpm_limit", parse_rpm_limit(params["rpm_limit"]))
      |> Map.put("default_headers", parse_default_headers(params["default_headers"]))
      |> Map.put("api_type", parse_api_type(params["api_type"]))

    if params["api_key"] == "" do
      Map.delete(result, "api_key")
    else
      result
    end
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

  defp load_providers(socket) do
    providers =
      try do
        Provider.list()
      rescue
        _ -> []
      end

    assign(socket, loading: false, providers: providers)
  end

  defp api_type_badge(:anthropic), do: {"bg-purple-900 text-purple-300", "Anthropic"}
  defp api_type_badge(:openai), do: {"bg-blue-900 text-blue-300", "OpenAI"}
  defp api_type_badge(_), do: {"bg-gray-700 text-gray-300", "Unknown"}

  defp health_dot(provider_id) do
    if HealthChecker.healthy?(provider_id) do
      "bg-emerald-500"
    else
      "bg-red-500"
    end
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
      class="text-xs text-red-400 mt-1"
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
        <h1 class="text-2xl font-bold text-white">LLM Providers</h1>
        <button
          phx-click="new"
          class="rounded-md bg-emerald-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-600"
        >
          Add Provider
        </button>
      </div>

      <%!-- Provider Form (create/edit) --%>
      <div :if={@editing} class="bg-gray-900 border border-gray-800 rounded-lg p-6 mb-6">
        <h2 class="text-lg font-semibold text-white mb-4">
          {if @editing == :new, do: "New Provider", else: "Edit Provider"}
        </h2>
        <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-4">
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">Name</label>
              <input
                type="text"
                name="provider[name]"
                value={@form[:name].value}
                placeholder="anthropic-prod"
                class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
              />
              <.form_error field={@form[:name]} />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">API Type</label>
              <select
                name="provider[api_type]"
                class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
              >
                <option value="anthropic" selected={to_string(@form[:api_type].value) == "anthropic"}>
                  Anthropic
                </option>
                <option value="openai" selected={to_string(@form[:api_type].value) == "openai"}>
                  OpenAI
                </option>
              </select>
              <.form_error field={@form[:api_type]} />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">API URL</label>
              <input
                type="text"
                name="provider[api_url]"
                value={@form[:api_url].value}
                placeholder="https://api.anthropic.com"
                class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
              />
              <.form_error field={@form[:api_url]} />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">
                API Key
                <span :if={@editing != :new} class="text-gray-500">(leave blank to keep existing)</span>
              </label>
              <input
                type="password"
                name="provider[api_key]"
                value=""
                placeholder={if @editing != :new, do: "••••••••", else: "sk-ant-..."}
                class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
              />
              <.form_error field={@form[:api_key]} />
            </div>

            <div class="sm:col-span-2">
              <label class="block text-sm font-medium text-gray-300 mb-1">
                Models
                <span class="text-gray-500">(comma-separated)</span>
              </label>
              <input
                type="text"
                name="provider[models]"
                value={models_display(@form[:models].value)}
                placeholder="claude-sonnet-4-20250514, claude-haiku-3-20240307"
                class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
              />
              <.form_error field={@form[:models]} />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">
                RPM Limit
                <span class="text-gray-500">(optional)</span>
              </label>
              <input
                type="text"
                name="provider[rpm_limit]"
                value={@form[:rpm_limit].value}
                placeholder="60"
                class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
              />
              <.form_error field={@form[:rpm_limit]} />
            </div>

            <div class="sm:col-span-2">
              <label class="block text-sm font-medium text-gray-300 mb-1">
                Default Headers
                <span class="text-gray-500">(JSON object, optional)</span>
              </label>
              <textarea
                name="provider[default_headers]"
                rows="3"
                placeholder='{"anthropic-version": "2023-06-01"}'
                class="w-full rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white font-mono"
              >{headers_display(@form[:default_headers].value)}</textarea>
              <.form_error field={@form[:default_headers]} />
            </div>
          </div>

          <div class="flex gap-2">
            <button
              type="submit"
              class="rounded-md bg-emerald-700 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-600"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="cancel"
              class="rounded-md bg-gray-700 px-4 py-2 text-sm font-medium text-white hover:bg-gray-600"
            >
              Cancel
            </button>
          </div>
        </.form>
      </div>

      <%!-- Alias Form --%>
      <div :if={@alias_form} class="bg-gray-900 border border-gray-800 rounded-lg p-6 mb-6">
        <h2 class="text-lg font-semibold text-white mb-4">Add Model Alias</h2>
        <.form for={@alias_form} phx-submit="save_alias" class="flex items-end gap-4">
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Alias Name</label>
            <input
              type="text"
              name="model_alias[alias]"
              value={@alias_form[:alias].value}
              placeholder="fast"
              class="rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
            />
            <.form_error field={@alias_form[:alias]} />
          </div>
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Model</label>
            <select
              name="model_alias[model]"
              class="rounded-lg bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-white"
            >
              <option
                :for={model <- alias_provider_models(@providers, @alias_provider_id)}
                value={model}
                selected={to_string(@alias_form[:model].value) == model}
              >
                {model}
              </option>
            </select>
            <.form_error field={@alias_form[:model]} />
          </div>
          <div class="flex gap-2">
            <button
              type="submit"
              class="rounded-md bg-emerald-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-600"
            >
              Save
            </button>
            <button
              type="button"
              phx-click="cancel"
              class="rounded-md bg-gray-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-gray-600"
            >
              Cancel
            </button>
          </div>
        </.form>
      </div>

      <%!-- Usage Panel --%>
      <div :if={@selected_provider && @usage} class="bg-gray-900 border border-gray-800 rounded-lg p-6 mb-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold text-white">
            Usage: {@selected_provider.name}
          </h2>
          <button
            phx-click="select"
            phx-value-id={@selected_provider.id}
            class="text-xs text-gray-400 hover:text-gray-200"
          >
            Refresh
          </button>
        </div>
        <div class="grid grid-cols-2 gap-4 sm:grid-cols-4 mb-4">
          <div class="bg-gray-950 rounded-lg p-3">
            <p class="text-xs text-gray-400">Total Requests</p>
            <p class="text-lg font-bold text-white">{@usage.total_requests}</p>
          </div>
          <div class="bg-gray-950 rounded-lg p-3">
            <p class="text-xs text-gray-400">Input Tokens</p>
            <p class="text-lg font-bold text-white">{@usage.total_input_tokens}</p>
          </div>
          <div class="bg-gray-950 rounded-lg p-3">
            <p class="text-xs text-gray-400">Output Tokens</p>
            <p class="text-lg font-bold text-white">{@usage.total_output_tokens}</p>
          </div>
          <div class="bg-gray-950 rounded-lg p-3">
            <p class="text-xs text-gray-400">Avg Latency</p>
            <p class="text-lg font-bold text-white">{@usage.avg_latency_ms}ms</p>
          </div>
        </div>

        <div :if={@usage.by_model != []} class="mb-4">
          <h3 class="text-sm font-medium text-gray-300 mb-2">By Model</h3>
          <div class="space-y-1">
            <div
              :for={row <- @usage.by_model}
              class="flex items-center justify-between text-sm px-3 py-1.5 bg-gray-950 rounded"
            >
              <span class="text-gray-200 font-mono">{row.model}</span>
              <span class="text-gray-400">{row.requests} reqs</span>
            </div>
          </div>
        </div>

        <div :if={map_size(@usage.by_status) > 0}>
          <h3 class="text-sm font-medium text-gray-300 mb-2">By Status</h3>
          <div class="flex flex-wrap gap-2">
            <span
              :for={{status, count} <- @usage.by_status}
              class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium bg-gray-700 text-gray-300"
            >
              {status}: {count}
            </span>
          </div>
        </div>
      </div>

      <%!-- Provider List --%>
      <div :if={@providers == []} class="text-gray-400">
        No LLM providers configured.
      </div>

      <div class="space-y-4">
        <div
          :for={provider <- @providers}
          class="bg-gray-900 border border-gray-800 rounded-lg p-4"
        >
          <div class="flex items-start justify-between">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <button
                  phx-click="select"
                  phx-value-id={provider.id}
                  class="text-sm font-medium text-white hover:text-emerald-300"
                >
                  {provider.name}
                </button>
                <span class={[
                  "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
                  elem(api_type_badge(provider.api_type), 0)
                ]}>
                  {elem(api_type_badge(provider.api_type), 1)}
                </span>
                <span
                  class={[
                    "inline-block w-2 h-2 rounded-full",
                    health_dot(provider.id)
                  ]}
                  title={if HealthChecker.healthy?(provider.id), do: "Healthy", else: "Unhealthy"}
                >
                </span>
              </div>
              <p class="text-xs text-gray-400 mt-1 truncate">{provider.api_url}</p>
              <p class="text-xs text-gray-500 mt-0.5">
                {length(provider.models || [])} model(s)
              </p>

              <%!-- Aliases --%>
              <div :if={provider.aliases != []} class="flex flex-wrap gap-1 mt-2">
                <span
                  :for={a <- provider.aliases}
                  class="inline-flex items-center gap-1 rounded-md bg-gray-800 px-2 py-0.5 text-xs text-gray-300"
                >
                  {a.alias} → {a.model}
                  <button
                    phx-click="delete_alias"
                    phx-value-id={a.id}
                    data-confirm={"Delete alias #{a.alias}?"}
                    class="text-red-400 hover:text-red-300 ml-1"
                  >
                    ×
                  </button>
                </span>
              </div>
            </div>

            <div class="flex items-center gap-2 ml-4 flex-shrink-0">
              <button
                phx-click="toggle_enabled"
                phx-value-id={provider.id}
                class={[
                  "rounded px-2 py-1 text-xs",
                  if(provider.enabled,
                    do: "bg-amber-900 text-amber-200 hover:bg-amber-800",
                    else: "bg-emerald-900 text-emerald-200 hover:bg-emerald-800"
                  )
                ]}
              >
                {if provider.enabled, do: "Disable", else: "Enable"}
              </button>
              <button
                phx-click="new_alias"
                phx-value-provider-id={provider.id}
                class="rounded px-2 py-1 text-xs bg-gray-700 text-gray-200 hover:bg-gray-600"
              >
                + Alias
              </button>
              <button
                phx-click="edit"
                phx-value-id={provider.id}
                class="rounded px-2 py-1 text-xs bg-gray-700 text-gray-200 hover:bg-gray-600"
              >
                Edit
              </button>
              <button
                phx-click="delete"
                phx-value-id={provider.id}
                data-confirm={"Delete provider #{provider.name}? This cannot be undone."}
                class="rounded px-2 py-1 text-xs bg-red-900 text-red-200 hover:bg-red-800"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp alias_provider_models(providers, provider_id) do
    provider = Enum.find(providers, &(&1.id == provider_id))
    if provider, do: provider.models || [], else: []
  end
end
