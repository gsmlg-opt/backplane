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
       current_path: "/llama/providers",
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
        {:noreply, put_flash(socket, :error, dgettext("errors", "Provider not found"))}

      provider ->
        case Provider.soft_delete(provider) do
          {:ok, _} ->
            Backplane.Admin.Audit.record("provider.delete", "provider", provider.id)

            {:noreply,
             socket
             |> put_flash(
               :info,
               dgettext("admin", "Provider %{name} deleted", name: provider.name)
             )
             |> load_providers()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, dgettext("errors", "Failed to delete provider"))}
        end
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    case Provider.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Provider not found"))}

      provider ->
        case Provider.update(provider, %{enabled: !provider.enabled}) do
          {:ok, _} ->
            Backplane.Admin.Audit.record("provider.toggle", "provider", provider.id)
            {:noreply, load_providers(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, dgettext("errors", "Failed to toggle provider"))}
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

  defp provider_enabled_badge(true), do: "success"
  defp provider_enabled_badge(false), do: "neutral"

  defp provider_enabled_text(true), do: dgettext("common", "Enabled")
  defp provider_enabled_text(false), do: dgettext("common", "Disabled")

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">{dgettext("admin", "Providers")}</h1>
        <.dm_btn navigate={~p"/llama/providers/new"} variant="primary" size="sm">{dgettext("admin", "Add Provider")}</.dm_btn>
      </div>

      <div :if={@providers == []} class="text-on-surface-variant">
        {dgettext("admin", "No providers configured.")}
      </div>

      <.dm_table :if={@providers != []} id="llm-providers-table" data={@providers} hover zebra>
        <:col :let={provider} label={dgettext("admin", "Provider")}>
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <.link
                navigate={~p"/llama/providers/#{provider.id}"}
                class="truncate font-medium text-primary hover:underline"
              >
                {provider.name}
              </.link>
              <.dm_badge variant={provider_enabled_badge(provider.enabled)} size="sm">
                {provider_enabled_text(provider.enabled)}
              </.dm_badge>
            </div>
          </div>
        </:col>
        <:col :let={provider} label={dgettext("admin", "Preset")}>
          {provider.preset_key || "—"}
        </:col>
        <:col :let={provider} label={dgettext("admin", "Credential")}>
          <code class="break-all">{provider.credential || "—"}</code>
        </:col>
        <:col :let={provider} label={dgettext("admin", "Base URL")}>
          <code class="break-all">{provider.base_url || "—"}</code>
        </:col>
        <:col :let={provider} label={dgettext("common", "Actions")}>
          <div class="flex items-center gap-1">
            <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "View")} position="bottom">
              <.dm_btn
                {tooltip_attrs}
                navigate={~p"/llama/providers/#{provider.id}"}
                size="xs"
                shape="circle"
                variant="outline"
                aria-label={dgettext("admin", "View %{name}", name: provider.name)}
              >
                <.dm_mdi name="eye" class="h-4 w-4" />
                <span class="sr-only">{dgettext("common", "View")}</span>
              </.dm_btn>
            </.dm_tooltip>
            <.dm_tooltip :let={tooltip_attrs} content="Configure LLM" position="bottom">
              <.dm_btn {tooltip_attrs} id={"llm-provider-#{provider.id}"} navigate={~p"/llama/llm"} size="xs" shape="circle" variant="outline" aria-label={"Configure LLM for #{provider.name}"}>
                <.dm_mdi name="message-text-outline" class="h-4 w-4" />
              </.dm_btn>
            </.dm_tooltip>
            <.dm_tooltip :let={tooltip_attrs} content={if provider.enabled, do: dgettext("common", "Disable"), else: dgettext("common", "Enable")} position="bottom">
              <.dm_btn {tooltip_attrs}
                type="button"
                variant={if provider.enabled, do: "warning", else: "success"}
                size="xs"
                shape="circle"
                aria-label={
                  if provider.enabled,
                    do: dgettext("admin", "Disable %{name}", name: provider.name),
                    else: dgettext("admin", "Enable %{name}", name: provider.name)
                }
                phx-click="toggle_enabled"
                phx-value-id={provider.id}
              >
                <.dm_mdi name={if provider.enabled, do: "pause", else: "play"} class="h-4 w-4" />
                <span class="sr-only">{if provider.enabled, do: dgettext("common", "Disable"), else: dgettext("common", "Enable")}</span>
              </.dm_btn>
            </.dm_tooltip>
            <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Delete")} position="bottom">
              <.dm_btn {tooltip_attrs}
                type="button"
                variant="error"
                size="xs"
                shape="circle"
                aria-label={dgettext("admin", "Delete %{name}", name: provider.name)}
                data-confirm={dgettext("admin", "Delete provider %{name}?", name: provider.name)}
                phx-click="delete"
                phx-value-id={provider.id}
              >
                <.dm_mdi name="delete" class="h-4 w-4" />
                <span class="sr-only">{dgettext("common", "Delete")}</span>
              </.dm_btn>
            </.dm_tooltip>
          </div>
        </:col>
      </.dm_table>
    </div>
    """
  end
end
