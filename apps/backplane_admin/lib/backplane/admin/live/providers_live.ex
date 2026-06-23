defmodule Backplane.Admin.ProvidersLive do
  use Backplane.Admin, :live_view

  alias Backplane.LLM.Provider
  alias Backplane.PubSubBroadcaster

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.llm_providers_topic())
    end

    {:ok,
     assign(socket,
       current_path: "/admin/llama/providers",
       loading: true,
       providers: []
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

  @impl true
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

  defp load_providers(socket) do
    providers =
      try do
        Provider.list()
      rescue
        _ -> []
      end

    assign(socket, loading: false, providers: providers)
  end

  defp api_badge_variant(:openai), do: "info"
  defp api_badge_variant(:anthropic), do: "tertiary"
  defp api_badge_variant(_), do: "neutral"

  defp api_label(:openai), do: "OpenAI"
  defp api_label(:anthropic), do: "Anthropic"
  defp api_label(other), do: to_string(other)

  defp provider_enabled_badge(true), do: "success"
  defp provider_enabled_badge(false), do: "neutral"

  defp provider_enabled_text(true), do: "Enabled"
  defp provider_enabled_text(false), do: "Disabled"

  defp headers_count(headers) when is_map(headers), do: map_size(headers)
  defp headers_count(_), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">LLM Providers</h1>
        <.link navigate={~p"/admin/llama/providers/new"} class="no-underline">
          <.dm_btn variant="primary" size="sm">Add Provider</.dm_btn>
        </.link>
      </div>

      <div :if={@providers == []} class="text-on-surface-variant">
        No LLM providers configured.
      </div>

      <.dm_table :if={@providers != []} id="llm-providers-table" data={@providers} hover zebra>
        <:col :let={provider} label="Provider">
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <.link
                navigate={~p"/admin/llama/providers/#{provider.id}"}
                class="truncate font-medium text-primary hover:underline"
              >
                {provider.name}
              </.link>
              <.dm_badge variant={provider_enabled_badge(provider.enabled)} size="sm">
                {provider_enabled_text(provider.enabled)}
              </.dm_badge>
            </div>
            <div class="mt-1 text-xs text-on-surface-variant">
              <span :if={provider.preset_key}>Preset: {provider.preset_key}</span>
              <span :if={provider.credential}> · credential: <code>{provider.credential}</code></span>
            </div>
          </div>
        </:col>
        <:col :let={provider} label="API surfaces">
          <div class="flex flex-col gap-2">
            <div
              :for={api <- provider.apis}
              class="min-w-0 rounded-md border border-outline-variant p-2"
            >
              <div class="flex items-center gap-2">
                <.dm_badge variant={api_badge_variant(api.api_surface)} size="sm">
                  {api_label(api.api_surface)}
                </.dm_badge>
                <.dm_badge variant={provider_enabled_badge(api.enabled)} size="sm">
                  {provider_enabled_text(api.enabled)}
                </.dm_badge>
              </div>
              <div class="mt-1 truncate font-mono text-xs text-on-surface">{api.base_url}</div>
              <div class="mt-1 text-xs text-on-surface-variant">
                Discovery:
                <code>{api.model_discovery_path || "-"}</code>
                · headers: {headers_count(api.default_headers)}
              </div>
            </div>
            <span :if={provider.apis == []} class="text-sm text-on-surface-variant">
              No API surfaces configured.
            </span>
          </div>
        </:col>
        <:col :let={provider} label="Actions">
          <div class="flex items-center gap-1">
            <.dm_tooltip content="View" position="bottom">
              <.link navigate={~p"/admin/llama/providers/#{provider.id}"} class="no-underline">
                <.dm_btn
                  type="button"
                  size="xs"
                  shape="circle"
                  variant="outline"
                  aria-label={"View #{provider.name}"}
                >
                  <.dm_mdi name="eye" class="h-4 w-4" />
                  <span class="sr-only">View</span>
                </.dm_btn>
              </.link>
            </.dm_tooltip>
            <.dm_tooltip content={if provider.enabled, do: "Disable", else: "Enable"} position="bottom">
              <.dm_btn
                type="button"
                variant={if provider.enabled, do: "warning", else: "success"}
                size="xs"
                shape="circle"
                aria-label={
                  if provider.enabled, do: "Disable #{provider.name}", else: "Enable #{provider.name}"
                }
                phx-click="toggle_enabled"
                phx-value-id={provider.id}
              >
                <.dm_mdi name={if provider.enabled, do: "pause", else: "play"} class="h-4 w-4" />
                <span class="sr-only">{if provider.enabled, do: "Disable", else: "Enable"}</span>
              </.dm_btn>
            </.dm_tooltip>
            <.dm_tooltip content="Delete" position="bottom">
              <.dm_btn
                type="button"
                variant="error"
                size="xs"
                shape="circle"
                aria-label={"Delete #{provider.name}"}
                data-confirm={"Delete provider #{provider.name}?"}
                phx-click="delete"
                phx-value-id={provider.id}
              >
                <.dm_mdi name="delete" class="h-4 w-4" />
                <span class="sr-only">Delete</span>
              </.dm_btn>
            </.dm_tooltip>
          </div>
        </:col>
      </.dm_table>
    </div>
    """
  end
end
