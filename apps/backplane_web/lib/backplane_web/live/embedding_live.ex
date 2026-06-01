defmodule BackplaneWeb.EmbeddingLive do
  use BackplaneWeb, :live_view

  alias Backplane.LLM.ProviderModelSurface
  alias Backplane.Settings

  @embedding_model_key "memory.embed_model"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/llama/embedding",
       current_model: nil,
       form: to_form(%{"model" => ""}, as: :embedding),
       model_options: [],
       model_surfaces: []
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_embedding_models(socket)}
  end

  @impl true
  def handle_event("save", %{"embedding" => %{"model" => model}}, socket) do
    model = blank_to_nil(model)

    case Settings.set(@embedding_model_key, model) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Embedding model saved")
         |> load_embedding_models()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save embedding model")}
    end
  end

  defp load_embedding_models(socket) do
    current_model = blank_to_nil(Settings.get(@embedding_model_key))
    model_surfaces = list_model_surfaces()

    assign(socket,
      current_model: current_model,
      form: to_form(%{"model" => current_model || ""}, as: :embedding),
      model_options: model_options(model_surfaces, current_model),
      model_surfaces: model_surfaces
    )
  end

  defp list_model_surfaces do
    :openai
    |> ProviderModelSurface.list_enabled()
    |> Enum.sort_by(fn surface ->
      provider = surface.provider_model.provider
      {provider.name, surface.provider_model.model}
    end)
  rescue
    _ -> []
  end

  defp model_options(model_surfaces, current_model) do
    options =
      model_surfaces
      |> Enum.map(fn surface ->
        model_id = model_id(surface)
        {model_id, model_id}
      end)

    options =
      if current_model && not Enum.any?(options, fn {value, _label} -> value == current_model end) do
        options ++ [{current_model, "#{current_model} (configured)"}]
      else
        options
      end

    [{"", "Select a provider model..."} | options]
  end

  defp model_id(surface) do
    provider = surface.provider_model.provider
    "#{provider.name}/#{surface.provider_model.model}"
  end

  defp display_name(surface) do
    surface.provider_model.display_name || surface.provider_model.model
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">Embedding Providers</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            Select the LLM provider model used for embedding requests.
          </p>
        </div>
        <div class="flex shrink-0 gap-2">
          <.link navigate={~p"/admin/llama/providers/new"} class="no-underline">
            <.dm_btn size="sm" variant="primary">Add Provider</.dm_btn>
          </.link>
          <.link navigate={~p"/admin/llama/providers"} class="no-underline">
            <.dm_btn size="sm">Manage Providers</.dm_btn>
          </.link>
        </div>
      </div>

      <.dm_card variant="bordered" class="mb-6">
        <:title>Active Embedding Model</:title>
        <.form id="embedding-model-form" for={@form} phx-submit="save" class="space-y-4">
          <.dm_select
            id="embedding-model"
            name="embedding[model]"
            label="Model"
            options={@model_options}
            value={@form[:model].value || ""}
          />

          <div class="flex items-center gap-2">
            <.dm_btn type="submit" variant="primary">Save</.dm_btn>
            <span :if={@current_model} class="text-sm text-on-surface-variant">
              Current: <code>{@current_model}</code>
            </span>
          </div>
        </.form>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Provider Models</:title>

        <div :if={@model_surfaces == []} class="text-sm text-on-surface-variant">
          No OpenAI-compatible provider models configured.
        </div>

        <div class="space-y-3">
          <div
            :for={surface <- @model_surfaces}
            class="rounded-md border border-outline-variant p-3"
          >
            <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-mono text-sm">{model_id(surface)}</span>
                  <.dm_badge variant="info" size="sm">OpenAI</.dm_badge>
                </div>
                <div class="mt-1 text-sm text-on-surface-variant">
                  {display_name(surface)}
                </div>
                <div class="mt-1 truncate font-mono text-xs text-on-surface-variant">
                  {surface.provider_api.base_url}
                </div>
              </div>

              <.link
                navigate={~p"/admin/llama/providers/#{surface.provider_model.provider.id}"}
                class="no-underline"
              >
                <.dm_btn size="xs">Manage</.dm_btn>
              </.link>
            </div>
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end
end
