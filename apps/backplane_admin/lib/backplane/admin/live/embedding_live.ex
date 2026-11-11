defmodule Backplane.Admin.EmbeddingLive do
  use Backplane.Admin, :live_view

  alias Backplane.LLM.HostServices
  alias Backplane.Embedding
  alias Backplane.Settings.Credentials

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/llama/embedding",
       provider_modal_open: false,
       provider_modal_mode: :new,
       editing_model: nil,
       provider_form: to_form(provider_defaults(), as: :provider),
       provider_errors: %{},
       credential_options: [],
       host_service_options: [],
       embedding_models: []
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_embedding_models(socket)}
  end

  @impl true
  def handle_event("open_provider_modal", _params, socket) do
    {:noreply,
     assign(socket,
       provider_modal_open: true,
       provider_modal_mode: :new,
       editing_model: nil,
       provider_form: to_form(provider_defaults(), as: :provider),
       provider_errors: %{}
     )}
  end

  def handle_event("close_provider_modal", _params, socket) do
    {:noreply,
     assign(socket,
       provider_modal_open: false,
       provider_modal_mode: :new,
       editing_model: nil,
       provider_form: to_form(provider_defaults(), as: :provider),
       provider_errors: %{}
     )}
  end

  def handle_event("edit_provider", %{"id" => id}, socket) do
    case Embedding.get_model(id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Embedding provider not found"))}

      model ->
        {:noreply,
         assign(socket,
           provider_modal_open: true,
           provider_modal_mode: :edit,
           editing_model: model,
           provider_form: to_form(provider_model_params(model), as: :provider),
           provider_errors: %{}
         )}
    end
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    case Embedding.get_model(id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Embedding provider not found"))}

      model ->
        case Embedding.soft_delete_provider(model.provider) do
          {:ok, _provider} ->
            Backplane.Admin.Audit.record(
              "embedding_provider.delete",
              "embedding_provider",
              model.provider.id
            )

            {:noreply,
             socket
             |> put_flash(:info, dgettext("admin", "Embedding provider %{name} deleted", name: model.provider.name))
             |> load_embedding_models()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, dgettext("errors", "Failed to delete embedding provider"))}
        end
    end
  end

  def handle_event(
        "save_provider",
        %{"provider" => params},
        %{
          assigns: %{provider_modal_mode: :edit, editing_model: %Embedding.Model{} = model}
        } = socket
      ) do
    case Embedding.update_provider_with_model(model, params) do
      {:ok, _result} ->
        Backplane.Admin.Audit.record(
          "embedding_provider.update",
          "embedding_provider",
          model.provider.id
        )

        {:noreply,
         socket
         |> put_flash(:info, dgettext("admin", "Embedding provider updated"))
         |> assign(
           provider_modal_open: false,
           provider_modal_mode: :new,
           editing_model: nil,
           provider_form: to_form(provider_defaults(), as: :provider),
           provider_errors: %{}
         )
         |> load_embedding_models()}

      {:error, errors} ->
        {:noreply,
         assign(socket,
           provider_modal_open: true,
           provider_modal_mode: :edit,
           provider_form: to_form(params, as: :provider),
           provider_errors: errors
         )}
    end
  end

  def handle_event("save_provider", %{"provider" => params}, socket) do
    case Embedding.create_provider_with_model(params) do
      {:ok, %{provider: provider}} ->
        Backplane.Admin.Audit.record(
          "embedding_provider.create",
          "embedding_provider",
          provider.id
        )

        {:noreply,
         socket
         |> put_flash(:info, dgettext("admin", "Embedding provider added"))
         |> assign(
           provider_modal_open: false,
           provider_modal_mode: :new,
           editing_model: nil,
           provider_form: to_form(provider_defaults(), as: :provider),
           provider_errors: %{}
         )
         |> load_embedding_models()}

      {:error, errors} ->
        {:noreply,
         assign(socket,
           provider_modal_open: true,
           provider_modal_mode: :new,
           editing_model: nil,
           provider_form: to_form(params, as: :provider),
           provider_errors: errors
         )}
    end
  end

  defp load_embedding_models(socket) do
    embedding_models = list_embedding_models()

    assign(socket,
      credential_options: credential_options(),
      host_service_options: [{"", dgettext("admin", "Direct HTTP")} | HostServices.options(:openai_embeddings)],
      embedding_models: embedding_models
    )
  end

  defp list_embedding_models do
    Embedding.list_enabled_models()
  rescue
    _ -> []
  end

  defp credential_options do
    [
      {"", dgettext("admin", "Select a credential...")}
      | Credentials.list()
        |> Enum.filter(&(&1.kind == "llm"))
        |> Enum.map(fn cred -> {cred.name, "#{cred.name} (#{cred.kind})"} end)
    ]
  rescue
    _ -> [{"", dgettext("admin", "Select a credential...")}]
  end

  defp provider_defaults do
    %{
      "name" => "",
      "credential" => "",
      "host_service_id" => "",
      "base_url" => "",
      "enabled" => "true",
      "default_headers" => "{}",
      "model" => "",
      "display_name" => "",
      "model_enabled" => "true",
      "metadata" => "{}"
    }
  end

  defp provider_model_params(%Embedding.Model{provider: provider} = model) do
    %{
      "name" => provider.name,
      "credential" => provider.credential,
      "host_service_id" => provider.host_service_id || "",
      "base_url" => provider.base_url,
      "enabled" => to_string(provider.enabled),
      "default_headers" => encode_json_map(provider.default_headers),
      "model" => model.model,
      "display_name" => model.display_name || "",
      "model_enabled" => to_string(model.enabled),
      "metadata" => encode_json_map(model.metadata)
    }
  end

  defp encode_json_map(value) when is_map(value), do: Jason.encode!(value)
  defp encode_json_map(_value), do: "{}"

  defp display_name(model) do
    model.display_name || model.model
  end

  defp enabled_variant(true), do: "success"
  defp enabled_variant(false), do: "neutral"

  defp provider_status_text(true), do: dgettext("admin", "Provider Enabled")
  defp provider_status_text(false), do: dgettext("admin", "Provider Disabled")

  defp model_status_text(true), do: dgettext("admin", "Model Enabled")
  defp model_status_text(false), do: dgettext("admin", "Model Disabled")

  defp error(assigns) do
    ~H"""
    <div :if={@errors[@field]} class="mt-1 text-xs text-error">{@errors[@field]}</div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">{dgettext("admin", "Embedding Providers")}</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            {dgettext("admin", "Manage embedding-only providers and models used for vector requests.")}
          </p>
        </div>

        <.dm_btn
          id="open-embedding-provider-modal"
          type="button"
          variant="primary"
          phx-click="open_provider_modal"
        >
          <.dm_mdi name="plus" class="h-4 w-4" />
          {dgettext("admin", "Add Provider")}
        </.dm_btn>
      </div>

      <.dm_card variant="bordered">
        <:title>{dgettext("admin", "Embedding Models")}</:title>

        <div :if={@embedding_models == []} class="text-sm text-on-surface-variant">
          {dgettext("admin", "No embedding models configured.")}
        </div>

        <.dm_table
          :if={@embedding_models != []}
          id="embedding-models-table"
          data={@embedding_models}
          hover
          zebra
        >
          <:col :let={model} label={dgettext("admin", "Model")}>
            <div class="min-w-0">
              <code class="block truncate text-sm">{Embedding.model_id(model)}</code>
              <span class="mt-1 block text-sm text-on-surface-variant">{display_name(model)}</span>
            </div>
          </:col>
          <:col :let={model} label={dgettext("admin", "Provider")}>
            <span class="font-medium">{model.provider.name}</span>
          </:col>
          <:col :let={model} label={dgettext("admin", "Base URL")}>
            <code class="block max-w-sm truncate text-xs">{model.provider.base_url}</code>
          </:col>
          <:col :let={model} label={dgettext("common", "Status")}>
            <div class="flex flex-wrap gap-2">
              <.dm_badge variant={enabled_variant(model.provider.enabled)} size="sm">
                {provider_status_text(model.provider.enabled)}
              </.dm_badge>
              <.dm_badge variant={enabled_variant(model.enabled)} size="sm">
                {model_status_text(model.enabled)}
              </.dm_badge>
            </div>
          </:col>
          <:col :let={model} label={dgettext("common", "Actions")}>
            <div class="flex items-center gap-1">
              <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Edit")} position="bottom">
                <.dm_btn {tooltip_attrs}
                  id={"edit-embedding-model-#{model.id}"}
                  type="button"
                  size="xs"
                  shape="circle"
                  variant="outline"
                  aria-label={
                    dgettext("admin", "Edit embedding provider %{name}", name: model.provider.name)
                  }
                  phx-click="edit_provider"
                  phx-value-id={model.id}
                >
                  <.dm_mdi name="pencil" class="h-4 w-4" />
                  <span class="sr-only">{dgettext("common", "Edit")}</span>
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip :let={tooltip_attrs} content={dgettext("common", "Delete")} position="bottom">
                <.dm_btn {tooltip_attrs}
                  id={"delete-embedding-model-#{model.id}"}
                  type="button"
                  size="xs"
                  shape="circle"
                  variant="error"
                  aria-label={
                    dgettext("admin", "Delete embedding provider %{name}", name: model.provider.name)
                  }
                  data-confirm={
                    dgettext("admin", "Delete embedding provider %{name}?", name: model.provider.name)
                  }
                  phx-click="delete_provider"
                  phx-value-id={model.id}
                >
                  <.dm_mdi name="delete" class="h-4 w-4" />
                  <span class="sr-only">{dgettext("common", "Delete")}</span>
                </.dm_btn>
              </.dm_tooltip>
            </div>
          </:col>
        </.dm_table>
      </.dm_card>

      <.provider_modal
        :if={@provider_modal_open}
        mode={@provider_modal_mode}
        provider_form={@provider_form}
        provider_errors={@provider_errors}
        credential_options={@credential_options}
        host_service_options={@host_service_options}
      />
    </div>
    """
  end

  defp provider_modal(assigns) do
    ~H"""
    <div
      id="embedding-provider-modal"
      class="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-black/60 px-4 py-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="embedding-provider-modal-title"
      phx-window-keydown="close_provider_modal"
      phx-key="Escape"
    >
      <div class="w-full max-w-3xl rounded-lg border border-outline-variant bg-surface-container p-6 shadow-xl">
        <div class="mb-5 flex items-center justify-between gap-4">
          <div>
            <h2 id="embedding-provider-modal-title" class="text-lg font-semibold text-on-surface">
              {provider_modal_title(@mode)}
            </h2>
            <p class="mt-1 text-sm text-on-surface-variant">
              {provider_modal_description(@mode)}
            </p>
          </div>
          <button
            type="button"
            class="rounded px-2 py-1 text-sm text-on-surface-variant hover:bg-surface-container-high hover:text-on-surface"
            phx-click="close_provider_modal"
            aria-label={dgettext("common", "Close")}
          >
            x
          </button>
        </div>

        <.form
          id="embedding-provider-form"
          for={@provider_form}
          phx-submit="save_provider"
          class="space-y-5"
        >
          <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
            <div>
              <.dm_input
                id="embedding-provider-name"
                name="provider[name]"
                label={dgettext("admin", "Provider")}
                value={@provider_form[:name].value}
                placeholder="openai-embeddings"
              />
              <.error errors={@provider_errors} field="name" />
            </div>

            <div>
              <.dm_select
                id="embedding-provider-credential"
                name="provider[credential]"
                label={dgettext("admin", "Credential")}
                options={@credential_options}
                value={@provider_form[:credential].value || ""}
              />
              <.error errors={@provider_errors} field="credential" />
            </div>

            <div class="flex items-end pb-2">
              <input type="hidden" name="provider[enabled]" value="false" />
              <.dm_checkbox
                id="embedding-provider-enabled"
                name="provider[enabled]"
                label={dgettext("admin", "Enable provider")}
                value="true"
                checked={@provider_form[:enabled].value in [true, "true", "on"]}
              />
            </div>
          </div>

          <div>
            <.dm_select id="embedding-provider-host-service" name="provider[host_service_id]" label={dgettext("admin", "Host API Service")}
              options={@host_service_options} value={@provider_form[:host_service_id].value || ""} />
            <p class="mt-1 text-xs text-on-surface-variant">{dgettext("admin", "Hosted services use their configured endpoint. Credential is optional for unauthenticated host services.")}</p>
            <.error errors={@provider_errors} field="host_service_id" />
          </div>

          <div>
            <.dm_input
              id="embedding-provider-base-url"
              name="provider[base_url]"
              label={dgettext("admin", "Embedding API Base URL")}
              value={@provider_form[:base_url].value}
              placeholder="https://api.openai.com/v1"
            />
            <.error errors={@provider_errors} field="base_url" />
          </div>

          <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
            <div>
              <.dm_input
                id="embedding-provider-model"
                name="provider[model]"
                label={dgettext("admin", "Model")}
                value={@provider_form[:model].value}
                placeholder="text-embedding-3-small"
              />
              <.error errors={@provider_errors} field="model" />
            </div>

            <.dm_input
              id="embedding-provider-display-name"
              name="provider[display_name]"
              label={dgettext("admin", "Display Name")}
              value={@provider_form[:display_name].value}
            />

            <div class="flex items-end pb-2">
              <input type="hidden" name="provider[model_enabled]" value="false" />
              <.dm_checkbox
                id="embedding-provider-model-enabled"
                name="provider[model_enabled]"
                label={dgettext("admin", "Enable model")}
                value="true"
                checked={@provider_form[:model_enabled].value in [true, "true", "on"]}
              />
            </div>
          </div>

          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <.dm_textarea
              id="embedding-provider-default-headers"
              name="provider[default_headers]"
              label={dgettext("admin", "Default Headers")}
              rows={3}
              value={@provider_form[:default_headers].value}
              class="font-mono"
            />

            <.dm_textarea
              id="embedding-provider-metadata"
              name="provider[metadata]"
              label={dgettext("admin", "Model Metadata")}
              rows={3}
              value={@provider_form[:metadata].value}
              class="font-mono"
            />
          </div>

          <div class="flex flex-wrap justify-end gap-2">
            <.dm_btn type="button" variant="outline" size="sm" phx-click="close_provider_modal">
              {dgettext("common", "Cancel")}
            </.dm_btn>
            <.dm_btn type="submit" variant="primary" size="sm">
              {provider_modal_submit(@mode)}
            </.dm_btn>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp provider_modal_title(:edit), do: dgettext("admin", "Edit Embedding Provider")
  defp provider_modal_title(_mode), do: dgettext("admin", "Add Embedding Provider")

  defp provider_modal_description(:edit), do: dgettext("admin", "Update the embedding provider and model.")

  defp provider_modal_description(_mode),
    do: dgettext("admin", "Configure an embedding-only provider and its first model.")

  defp provider_modal_submit(:edit), do: dgettext("admin", "Save Provider")
  defp provider_modal_submit(_mode), do: dgettext("admin", "Add Provider")
end
