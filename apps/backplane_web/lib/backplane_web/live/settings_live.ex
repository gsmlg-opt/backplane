defmodule BackplaneWeb.SettingsLive do
  @moduledoc "Admin pages for model aliases and credentials management."

  use BackplaneWeb, :live_view

  alias Backplane.LLM.AutoModel
  alias Backplane.LLM.ModelAlias
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.OAuthStateStore

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_mode: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {page_mode, current_path, data_key} =
      case socket.assigns.live_action do
        action when action in [:credentials, :credentials_new, :credentials_new_oauth] ->
          {:credentials, "/admin/system/credentials", "credentials"}

        _ ->
          {:model_aliases, "/admin/llama/model-aliases", "settings"}
      end

    socket =
      socket
      |> assign(page_mode: page_mode, current_path: current_path)
      |> load_data(data_key)
      |> apply_action(socket.assigns.live_action, params)

    {:noreply, socket}
  end

  defp apply_action(socket, :credentials, _params) do
    assign(socket, cred_form_mode: nil)
  end

  defp apply_action(socket, :credentials_new, _params) do
    assign(socket,
      cred_form_mode: :add,
      cred_editing_name: nil,
      cred_name: "",
      cred_kind: "llm",
      cred_secret: "",
      cred_auth_type: "api_key",
      cred_client_id: "",
      cred_token_url: "",
      cred_scope: ""
    )
  end

  defp apply_action(socket, :credentials_new_oauth, %{"vendor" => vendor}) do
    default_name =
      case vendor do
        "anthropic_oauth" -> "claude-plan"
        "openai_oauth" -> "openai-codex"
        "google_oauth" -> "google-ai"
        _ -> "oauth-cred"
      end

    assign(socket,
      cred_form_mode: :device_auth,
      device_flow_vendor: vendor,
      device_flow_state: :idle,
      device_flow_cred_name: default_name,
      device_flow_user_code: nil,
      device_flow_verification_uri: nil,
      device_flow_error: nil
    )
  end

  defp apply_action(socket, _action, _params), do: socket

  # --- Data Loading ---

  defp load_data(socket, "settings") do
    assign(socket,
      auto_models: AutoModel.list_configurations(),
      custom_aliases: ModelAlias.list(),
      custom_alias_target_options: custom_alias_target_options(),
      target_model_options: target_model_options()
    )
  end

  defp load_data(socket, "credentials") do
    credentials =
      Credentials.list()
      |> Enum.map(fn cred ->
        Map.put(cred, :hint, Credentials.fetch_hint(cred.name))
      end)

    assign(socket,
      credentials: credentials,
      cred_form_mode: nil,
      cred_editing_name: nil,
      cred_name: "",
      cred_kind: "llm",
      cred_secret: "",
      cred_auth_type: "api_key",
      cred_client_id: "",
      cred_token_url: "",
      cred_scope: "",
      device_flow_vendor: nil,
      device_flow_state: :idle,
      device_flow_cred_name: "",
      device_flow_user_code: nil,
      device_flow_verification_uri: nil,
      device_flow_error: nil
    )
  end

  defp load_data(socket, _), do: socket

  # --- Settings Events ---

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    path =
      case tab do
        "credentials" -> ~p"/admin/system/credentials"
        _ -> ~p"/admin/llama/model-aliases"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("add_auto_model_target", %{"name" => name, "model" => model}, socket) do
    model = model |> to_string() |> String.trim()
    current_model_ids = AutoModel.configured_model_ids(name)

    cond do
      model == "" ->
        {:noreply, put_flash(socket, :error, "Select a target model to add")}

      model in current_model_ids ->
        {:noreply,
         socket
         |> put_flash(:info, "Model alias '#{name}' already includes #{model}")
         |> load_data("settings")}

      true ->
        configure_auto_model_targets(socket, name, current_model_ids ++ [model])
    end
  end

  def handle_event("remove_auto_model_target", %{"name" => name, "model" => model}, socket) do
    model_ids =
      name
      |> AutoModel.configured_model_ids()
      |> Enum.reject(&(&1 == model))

    configure_auto_model_targets(socket, name, model_ids)
  end

  def handle_event("save_auto_model_targets", %{"name" => name, "models" => models}, socket) do
    model_ids = parse_model_list(models)

    configure_auto_model_targets(socket, name, model_ids)
  end

  def handle_event(
        "save_custom_model_alias",
        %{"alias" => alias_name, "target" => target},
        socket
      ) do
    case ModelAlias.put(alias_name, target) do
      {:ok, model_alias} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Custom alias '#{model_alias.alias}' points to #{model_alias.target}"
         )
         |> load_data("settings")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save custom alias: #{changeset_error(changeset)}")
         |> load_data("settings")}
    end
  end

  def handle_event("remove_custom_model_alias", %{"alias" => alias_name}, socket) do
    case ModelAlias.delete(alias_name) do
      {:ok, model_alias} ->
        {:noreply,
         socket
         |> put_flash(:info, "Custom alias '#{model_alias.alias}' removed")
         |> load_data("settings")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to remove custom alias")
         |> load_data("settings")}
    end
  end

  # --- Credentials Events ---

  def handle_event("show_edit_form", %{"name" => name}, socket) do
    cred = Enum.find(socket.assigns.credentials, &(&1.name == name))
    metadata = (cred && cred.metadata) || %{}

    {:noreply,
     assign(socket,
       cred_form_mode: :edit,
       cred_editing_name: name,
       cred_name: name,
       cred_kind: (cred && cred.kind) || "llm",
       cred_secret: "",
       cred_auth_type: metadata["auth_type"] || "api_key",
       cred_client_id: metadata["client_id"] || "",
       cred_token_url: metadata["token_url"] || "",
       cred_scope: metadata["scope"] || ""
     )}
  end

  def handle_event("show_rotate_form", %{"name" => name}, socket) do
    {:noreply,
     assign(socket,
       cred_form_mode: :rotate,
       cred_editing_name: name,
       cred_name: name,
       cred_kind: "",
       cred_secret: ""
     )}
  end

  def handle_event("cancel_device_auth", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/system/credentials")}
  end

  def handle_event("cancel_cred_form", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/system/credentials")}
  end

  def handle_event("retry_device_auth", _, socket) do
    {:noreply, assign(socket, device_flow_state: :idle, device_flow_error: nil)}
  end

  def handle_event("start_device_auth", params, socket) do
    vendor = socket.assigns.device_flow_vendor
    name = String.trim(params["cred_name"] || "")

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Credential name is required")}

      vendor == "openai_oauth" ->
        case Backplane.Settings.OAuthDeviceFlow.request_device_code(:openai_oauth, []) do
          {:ok, res} ->
            Process.send_after(
              self(),
              {:poll_device_auth, :openai_oauth, res.device_code, name},
              res.interval * 1000
            )

            {:noreply,
             assign(socket,
               device_flow_state: :waiting_code,
               device_flow_user_code: res.user_code,
               device_flow_verification_uri: res.verification_uri,
               device_flow_error: nil
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               device_flow_state: :error,
               device_flow_error: "Failed to request device code: #{inspect(reason)}"
             )}
        end

      true ->
        redirect_uri = BackplaneWeb.Endpoint.url() <> "/admin/oauth/callback"
        {verifier, challenge} = pkce_pair()

        state =
          OAuthStateStore.put(%{
            "vendor" => vendor,
            "cred_name" => name,
            "code_verifier" => verifier,
            "redirect_uri" => redirect_uri
          })

        case build_auth_url(vendor, state, challenge, redirect_uri) do
          {:error, reason} ->
            {:noreply,
             assign(socket,
               device_flow_state: :error,
               device_flow_error: "Authorization is not configured: #{inspect(reason)}"
             )}

          auth_url ->
            socket =
              socket
              |> push_event("open_external_oauth", %{url: auth_url})
              |> push_patch(to: ~p"/admin/system/credentials")

            {:noreply, socket}
        end
    end
  end

  def handle_event("change_auth_type", %{"auth_type" => auth_type}, socket) do
    {:noreply, assign(socket, cred_auth_type: auth_type)}
  end

  def handle_event("save_credential", params, socket) do
    case socket.assigns.cred_form_mode do
      :add -> handle_add_credential(params, socket)
      :edit -> handle_edit_credential(params, socket)
      :rotate -> handle_rotate_credential(params, socket)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_credential", %{"name" => name}, socket) do
    case Credentials.delete(name) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Credential '#{name}' deleted")
         |> load_data("credentials")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete credential")}
    end
  end

  @impl true
  def handle_info({:poll_device_auth, :openai_oauth, device_code, cred_name}, socket) do
    if socket.assigns.device_flow_state == :waiting_code and
         socket.assigns.device_flow_vendor == "openai_oauth" do
      case Backplane.Settings.OAuthDeviceFlow.poll(:openai_oauth, device_code, []) do
        {:ok, tokens} ->
          hints = %{"account_id" => tokens["account_id"]}

          case Credentials.store_device_token(cred_name, "openai_oauth", tokens, hints) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Connected OpenAI Codex as '#{cred_name}'")
               |> push_patch(to: ~p"/admin/system/credentials")}

            {:error, reason} ->
              {:noreply,
               assign(socket,
                 device_flow_state: :error,
                 device_flow_error:
                   "Auth succeeded but failed to save credential: #{inspect(reason)}"
               )}
          end

        {:pending} ->
          Process.send_after(
            self(),
            {:poll_device_auth, :openai_oauth, device_code, cred_name},
            5000
          )

          {:noreply, socket}

        {:slow_down} ->
          Process.send_after(
            self(),
            {:poll_device_auth, :openai_oauth, device_code, cred_name},
            10000
          )

          {:noreply, socket}

        {:expired} ->
          {:noreply,
           assign(socket,
             device_flow_state: :error,
             device_flow_error: "Device authorization code expired. Please try again."
           )}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             device_flow_state: :error,
             device_flow_error: "Authorization failed: #{inspect(reason)}"
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp configure_auto_model_targets(socket, name, model_ids) do
    case AutoModel.configure_targets(name, model_ids) do
      {:ok, %{target_count: target_count}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Model alias '#{name}' updated with #{target_count} target(s)")
         |> load_data("settings")}

      {:error, {:missing_models, missing_model_ids}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "No enabled provider model found for: #{Enum.join(missing_model_ids, ", ")}"
         )
         |> load_data("settings")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update model alias")
         |> load_data("settings")}
    end
  end

  # --- Credential Form Handlers ---

  defp handle_add_credential(params, socket) do
    name = params["name"] || ""
    kind = params["kind"] || "llm"
    secret = params["secret"] || ""
    metadata = build_metadata(params)

    if name == "" or secret == "" do
      {:noreply, put_flash(socket, :error, "Name and secret are required")}
    else
      case Credentials.store(name, secret, kind, metadata) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Credential '#{name}' created")
           |> push_patch(to: ~p"/admin/system/credentials")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to store credential")}
      end
    end
  end

  defp handle_edit_credential(params, socket) do
    name = socket.assigns.cred_editing_name
    kind = params["kind"] || "llm"
    secret = params["secret"] || ""
    metadata = build_metadata(params)

    case Credentials.update(name, %{kind: kind, metadata: metadata}) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

    if secret != "" do
      case Credentials.rotate(name, secret) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Credential '#{name}' updated")
           |> push_patch(to: ~p"/admin/system/credentials")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update credential")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:info, "Credential '#{name}' updated")
       |> push_patch(to: ~p"/admin/system/credentials")}
    end
  end

  defp handle_rotate_credential(params, socket) do
    name = socket.assigns.cred_editing_name
    secret = params["secret"] || ""

    if secret == "" do
      {:noreply, put_flash(socket, :error, "New secret is required")}
    else
      case Credentials.rotate(name, secret) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Credential '#{name}' rotated")
           |> push_patch(to: ~p"/admin/system/credentials")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to rotate credential")}
      end
    end
  end

  # --- Helpers ---

  defp cred_secret_label(:rotate, _auth_type), do: "New Secret"
  defp cred_secret_label(_mode, "oauth2_client_credentials"), do: "Client Secret"
  defp cred_secret_label(_mode, _auth_type), do: "Secret"

  defp cred_secret_placeholder(:edit, "oauth2_client_credentials"),
    do: "Leave empty to keep current client secret"

  defp cred_secret_placeholder(:edit, _auth_type), do: "Leave empty to keep current"
  defp cred_secret_placeholder(_mode, "oauth2_client_credentials"), do: "OAuth2 client secret"
  defp cred_secret_placeholder(_mode, _auth_type), do: "API key or token"

  defp build_metadata(params) do
    auth_type = params["auth_type"] || "api_key"

    if auth_type == "oauth2_client_credentials" do
      %{
        "auth_type" => "oauth2_client_credentials",
        "client_id" => params["client_id"] || "",
        "token_url" => params["token_url"] || "",
        "scope" => params["scope"] || ""
      }
    else
      %{"auth_type" => "api_key"}
    end
  end

  defp parse_model_list(value) do
    value
    |> to_string()
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp auto_model_target_ids(auto_model), do: AutoModel.configured_model_ids(auto_model.name)

  defp target_model_options do
    AutoModel.list_available_target_model_ids()
    |> Enum.map(&{&1, &1})
  end

  defp custom_alias_target_options do
    built_in_options =
      AutoModel.built_in_names()
      |> Enum.map(&{&1, "#{&1} (built-in)"})

    provider_model_options =
      AutoModel.list_available_target_model_ids()
      |> Enum.reject(&(&1 in AutoModel.built_in_names()))
      |> Enum.map(&{&1, &1})

    built_in_options ++ provider_model_options
  end

  defp selectable_target_model_options(auto_model, target_model_options) do
    selected_model_ids =
      auto_model
      |> auto_model_target_ids()
      |> MapSet.new()

    Enum.reject(target_model_options, fn {model_id, _label} ->
      MapSet.member?(selected_model_ids, model_id)
    end)
  end

  defp target_model_name(target), do: target.provider_model_surface.provider_model.model

  defp route_label(:openai), do: "OpenAI"
  defp route_label(:anthropic), do: "Anthropic"
  defp route_label(other), do: to_string(other)

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{Phoenix.Naming.humanize(field)} #{&1}")
    end)
    |> List.first()
    |> Kernel.||("invalid alias")
  end

  @kind_options [
    {"llm", "LLM Provider"},
    {"upstream", "Upstream MCP"},
    {"service", "Service"},
    {"admin", "Admin"},
    {"custom", "Custom"}
  ]

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @page_mode == :model_aliases do %>
        <.render_settings_tab {assigns} />
      <% else %>
        <.render_credentials_tab {assigns} />
      <% end %>
    </div>
    """
  end

  defp render_settings_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <section>
        <h1 class="mb-6 text-2xl font-bold">Model Aliases</h1>
        <div class="space-y-4">
          <.dm_card :for={auto_model <- @auto_models} variant="bordered">
            <% target_model_ids = auto_model_target_ids(auto_model) %>
            <% selectable_options = selectable_target_model_options(auto_model, @target_model_options) %>
            <:title>
              <div class="flex w-full items-center justify-between gap-3">
                <div class="flex items-center gap-2">
                  <code>{auto_model.name}</code>
                  <.dm_badge variant={if auto_model.enabled, do: "success", else: "neutral"}>
                    {if auto_model.enabled, do: "Enabled", else: "Disabled"}
                  </.dm_badge>
                </div>
                <span class="text-xs text-on-surface-variant">
                  {length(auto_model.routes)} routes
                </span>
              </div>
            </:title>

            <form
              id={"auto-model-#{auto_model.name}-add-form"}
              phx-submit="add_auto_model_target"
              class="flex flex-col gap-3 md:flex-row md:items-end"
            >
              <input type="hidden" name="name" value={auto_model.name} />
              <div class="min-w-0 flex-1">
                <.dm_select
                  id={"auto-model-#{auto_model.name}-model"}
                  name="model"
                  label="Target models"
                  options={selectable_options}
                  prompt={if selectable_options == [], do: "No available provider models", else: "Select a model"}
                  disabled={selectable_options == []}
                />
              </div>
              <.dm_btn type="submit" variant="primary" disabled={selectable_options == []}>Add</.dm_btn>
            </form>

            <div
              id={"auto-model-#{auto_model.name}-target-list"}
              class="mt-3 flex flex-wrap items-center gap-2"
            >
              <span :if={target_model_ids == []} class="text-sm text-on-surface-variant">
                No target models selected
              </span>
              <span
                :for={model_id <- target_model_ids}
                class="inline-flex items-center gap-2 rounded-md border border-outline-variant bg-surface-container px-2 py-1 text-sm"
              >
                <code>{model_id}</code>
                <button
                  type="button"
                  phx-click="remove_auto_model_target"
                  phx-value-name={auto_model.name}
                  phx-value-model={model_id}
                  aria-label={"Remove #{model_id} from #{auto_model.name}"}
                  class="text-xs font-medium text-on-surface-variant hover:text-error"
                >
                  Remove
                </button>
              </span>
            </div>

            <div class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-2">
              <div :for={route <- auto_model.routes} class="rounded-md border border-outline-variant p-3">
                <div class="mb-2 flex items-center justify-between gap-2">
                  <span class="text-sm font-medium">{route_label(route.api_surface)}</span>
                  <.dm_badge variant={if route.enabled, do: "success", else: "neutral"} size="sm">
                    {if route.enabled, do: "Enabled", else: "Disabled"}
                  </.dm_badge>
                </div>
                <div class="flex flex-wrap gap-2">
                  <.dm_badge :for={target <- route.targets} variant="ghost">
                    {target_model_name(target)}
                  </.dm_badge>
                  <span :if={route.targets == []} class="text-sm text-on-surface-variant">
                    No targets
                  </span>
                </div>
              </div>
            </div>
          </.dm_card>
        </div>
      </section>

      <section>
        <h2 class="mb-3 text-lg font-semibold">Custom Aliases</h2>
        <.dm_card variant="bordered">
          <:title>
            <div class="flex w-full items-center justify-between gap-3">
              <span>Custom aliases</span>
              <span class="text-xs text-on-surface-variant">
                {length(@custom_aliases)} aliases
              </span>
            </div>
          </:title>

          <form
            id="custom-model-alias-form"
            phx-submit="save_custom_model_alias"
            class="flex flex-col gap-3 md:flex-row md:items-end"
          >
            <div class="min-w-0 flex-1">
              <.dm_input
                id="custom-model-alias-name"
                name="alias"
                label="Alias"
                value=""
                placeholder="coding"
                required
              />
            </div>
            <div class="min-w-0 flex-1">
              <.dm_select
                id="custom-model-alias-target"
                name="target"
                label="Target"
                options={@custom_alias_target_options}
                prompt="Select a target"
                disabled={@custom_alias_target_options == []}
              />
            </div>
            <.dm_btn type="submit" variant="primary" disabled={@custom_alias_target_options == []}>
              Save
            </.dm_btn>
          </form>

          <div
            id="custom-model-alias-list"
            class="mt-3 flex flex-wrap items-center gap-2"
          >
            <span :if={@custom_aliases == []} class="text-sm text-on-surface-variant">
              No custom aliases configured
            </span>
            <span
              :for={model_alias <- @custom_aliases}
              class="inline-flex items-center gap-2 rounded-md border border-outline-variant bg-surface-container px-2 py-1 text-sm"
            >
              <code>{model_alias.alias}</code>
              <span class="text-on-surface-variant">-&gt;</span>
              <code>{model_alias.target}</code>
              <button
                type="button"
                phx-click="remove_custom_model_alias"
                phx-value-alias={model_alias.alias}
                aria-label={"Remove custom alias #{model_alias.alias}"}
                class="text-xs font-medium text-on-surface-variant hover:text-error"
              >
                Remove
              </button>
            </span>
          </div>
        </.dm_card>
      </section>
    </div>
    """
  end

  defp render_credentials_tab(assigns) do
    assigns = assign(assigns, :kind_options, @kind_options)

    ~H"""
    <div>
      <%= case @live_action do %>
        <% :credentials -> %>
          <div class="flex items-center justify-between mb-4">
            <h1 class="text-2xl font-bold">Credential Store</h1>
            <div :if={@cred_form_mode == nil} class="flex items-center">
              <.link
                patch={~p"/admin/system/credentials/new"}
                class="btn btn-primary split-btn-left"
              >
                Add Credential
              </.link>
              <.dm_dropdown id="cred-add-dropdown" position="bottom" dropdown_class="popover-end split-btn-dropdown">
                <:trigger class="split-btn-trigger">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    viewBox="0 0 20 20"
                    fill="currentColor"
                    class="size-4"
                  >
                    <path
                      fill-rule="evenodd"
                      d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z"
                      clip-rule="evenodd"
                    />
                  </svg>
                </:trigger>
                <:content>
                  <.link
                    patch={~p"/admin/system/credentials/new/anthropic_oauth"}
                    class="popover-menu-item"
                  >
                    Connect Claude Plan
                  </.link>
                  <.link
                    patch={~p"/admin/system/credentials/new/openai_oauth"}
                    class="popover-menu-item"
                  >
                    Connect OpenAI Codex
                  </.link>
                  <.link
                    patch={~p"/admin/system/credentials/new/google_oauth"}
                    class="popover-menu-item"
                  >
                    Connect Google AI
                  </.link>
                </:content>
              </.dm_dropdown>
            </div>
          </div>

          <.render_cred_form :if={@cred_form_mode in [:edit, :rotate]} kind_options={@kind_options} {assigns} />

          <.dm_card variant="bordered">
            <div :if={@credentials == []} class="py-8 text-center text-on-surface-variant">
              No credentials stored yet. Click "Add Credential" to create one.
            </div>
            <div :if={@credentials != []}>
              <.dm_table id="credentials-table" data={@credentials} hover zebra>
                <:col :let={cred} label="Name">
                  <code>{cred.name}</code>
                </:col>
                <:col :let={cred} label="Kind">
                  <div class="flex items-center gap-1">
                    <.dm_badge variant="neutral">{cred.kind}</.dm_badge>
                    <.dm_badge
                      :if={
                        (cred.metadata || %{})["auth_type"] in [
                          "anthropic_oauth",
                          "openai_oauth",
                          "google_oauth",
                          "oauth2_client_credentials"
                        ]
                      }
                      variant="info"
                    >
                      {(cred.metadata || %{})["auth_type"]}
                    </.dm_badge>
                  </div>
                </:col>
                <:col :let={cred} label="Hint">
                  <code class="text-on-surface-variant">{cred.hint}</code>
                </:col>
                <:col :let={cred} label="Updated">
                  {Calendar.strftime(cred.updated_at, "%Y-%m-%d %H:%M")}
                </:col>
                <:col :let={cred} label="Actions">
                  <% auth_type = (cred.metadata || %{})["auth_type"] %>
                  <% is_device_oauth = auth_type in ["anthropic_oauth", "openai_oauth", "google_oauth"] %>
                  <div class="flex items-center gap-1">
                    <.dm_btn :if={!is_device_oauth} size="sm" phx-click="show_edit_form" phx-value-name={cred.name}>
                      Edit
                    </.dm_btn>
                    <.link
                      :if={is_device_oauth}
                      patch={~p"/admin/system/credentials/new/#{auth_type}"}
                    >
                      <.dm_btn
                        size="sm"
                        title="Re-connect via device code"
                      >
                        Reconnect
                      </.dm_btn>
                    </.link>
                    <.dm_btn :if={!is_device_oauth} variant="warning" size="sm" phx-click="show_rotate_form" phx-value-name={cred.name}>
                      Rotate
                    </.dm_btn>
                    <.dm_btn
                      variant="error"
                      size="sm"
                      data-confirm={"Delete credential '#{cred.name}'? This cannot be undone."}
                      phx-click="delete_credential"
                      phx-value-name={cred.name}
                    >
                      Delete
                    </.dm_btn>
                  </div>
                </:col>
              </.dm_table>
            </div>
          </.dm_card>

        <% :credentials_new -> %>
          <div class="flex items-center gap-3 mb-6">
            <.link patch={~p"/admin/system/credentials"} class="text-sm text-primary hover:underline">
              &larr; Credentials
            </.link>
          </div>
          <.render_cred_form kind_options={@kind_options} {assigns} />

        <% :credentials_new_oauth -> %>
          <div class="flex items-center gap-3 mb-6">
            <.link patch={~p"/admin/system/credentials"} class="text-sm text-primary hover:underline">
              &larr; Credentials
            </.link>
          </div>
          <.render_device_auth_form {assigns} />
      <% end %>
    </div>
    """
  end

  defp render_cred_form(assigns) do
    ~H"""
    <.dm_card variant="bordered" class="mb-6">
      <:title>
        <%= case @cred_form_mode do %>
          <% :add -> %>New Credential
          <% :edit -> %>Edit Credential: {@cred_editing_name}
          <% :rotate -> %>Rotate Secret: {@cred_editing_name}
        <% end %>
      </:title>
      <form phx-submit="save_credential" class="space-y-4">
        <%= if @cred_form_mode == :add do %>
          <.dm_input
            id="cred-name"
            name="name"
            label="Name"
            value={@cred_name}
            placeholder="e.g. anthropic-prod-key"
            required
          />
        <% end %>

        <%= if @cred_form_mode in [:add, :edit] do %>
          <.dm_select
            id="cred-kind"
            name="kind"
            label="Kind"
            options={@kind_options}
            value={@cred_kind}
          />

          <.dm_select
            id="cred-auth-type"
            name="auth_type"
            label="Auth Type"
            options={[{"api_key", "API Key"}, {"oauth2_client_credentials", "OAuth2 Client Credentials"}]}
            value={@cred_auth_type}
            phx-change="change_auth_type"
          />

          <%= if @cred_auth_type == "oauth2_client_credentials" do %>
            <.dm_input
              id="cred-client-id"
              name="client_id"
              label="Client ID"
              value={@cred_client_id}
              placeholder="OAuth2 client identifier"
              required
            />
            <.dm_input
              id="cred-token-url"
              name="token_url"
              label="Token URL"
              value={@cred_token_url}
              placeholder="https://auth.example.com/oauth/token"
              required
            />
            <.dm_input
              id="cred-scope"
              name="scope"
              label="Scope (optional)"
              value={@cred_scope}
              placeholder="e.g. read write"
            />
          <% end %>
        <% end %>

        <.dm_input
          id="cred-secret"
          name="secret"
          type="password"
          value={@cred_secret}
          label={cred_secret_label(@cred_form_mode, @cred_auth_type)}
          placeholder={cred_secret_placeholder(@cred_form_mode, @cred_auth_type)}
          {if @cred_form_mode in [:add, :rotate], do: [required: true], else: []}
        />
        <p :if={@cred_form_mode == :edit} class="text-xs text-on-surface-variant -mt-2">
          Leave empty to keep the current secret. Enter a new value to rotate it.
        </p>

        <div class="flex gap-2 pt-2">
          <.dm_btn type="submit" variant="primary">
            <%= case @cred_form_mode do %>
              <% :add -> %>Store Credential
              <% :edit -> %>Save Changes
              <% :rotate -> %>Rotate Secret
            <% end %>
          </.dm_btn>
          <.dm_btn type="button" phx-click="cancel_cred_form">Cancel</.dm_btn>
        </div>
      </form>
    </.dm_card>
    """
  end

  defp render_device_auth_form(assigns) do
    ~H"""
    <.dm_card variant="bordered" class="mb-6">
      <:title>Connect {device_flow_label(@device_flow_vendor)}</:title>

      <%= if @device_flow_state == :idle do %>
        <p class="text-sm text-on-surface-variant mb-4">
          You will be redirected to the provider's login page to authorise.
        </p>
        <form phx-submit="start_device_auth" class="space-y-4">
          <.dm_input
            id="device-cred-name"
            name="cred_name"
            label="Credential Name"
            value={@device_flow_cred_name}
            placeholder="claude-plan"
            required
          />
          <div class="flex gap-2 pt-2">
            <.dm_btn type="submit" variant="primary">Connect</.dm_btn>
            <.dm_btn type="button" phx-click="cancel_device_auth">Cancel</.dm_btn>
          </div>
        </form>
      <% end %>

      <%= if @device_flow_state == :waiting_code do %>
        <div class="space-y-6">
          <p class="text-sm text-on-surface">
            Follow these steps to sign in with ChatGPT using device code authorization:
          </p>
          <ol class="list-decimal list-inside space-y-4 text-sm text-on-surface-variant">
            <li>
              Open this link in your browser and sign in to your account
              <a href={@device_flow_verification_uri} target="_blank" class="text-primary underline ml-1 font-medium">
                {@device_flow_verification_uri}
              </a>
            </li>
            <li>
              Enter this one-time code (expires in 15 minutes)
              <span class="block mt-1 font-mono text-lg font-bold text-primary tracking-wider bg-surface-container px-3 py-1.5 rounded-md border border-outline-variant w-fit">
                {@device_flow_user_code}
              </span>
            </li>
          </ol>

          <div class="flex items-center gap-3 py-3 border-t border-outline-variant">
            <span class="loading loading-spinner text-primary"></span>
            <span class="text-sm text-on-surface-variant animate-pulse">
              Waiting for you to complete authorization...
            </span>
          </div>

          <div class="flex gap-2">
            <.dm_btn type="button" phx-click="cancel_device_auth">Cancel</.dm_btn>
          </div>
        </div>
      <% end %>

      <%= if @device_flow_state == :error do %>
        <div class="space-y-4">
          <.dm_badge variant="error">{@device_flow_error}</.dm_badge>
          <div class="flex gap-2">
            <.dm_btn
              variant="primary"
              phx-click="retry_device_auth"
            >
              Try Again
            </.dm_btn>
            <.dm_btn phx-click="cancel_device_auth">Cancel</.dm_btn>
          </div>
        </div>
      <% end %>
    </.dm_card>
    """
  end

  defp device_flow_label("anthropic_oauth"), do: "Claude Plan"
  defp device_flow_label("openai_oauth"), do: "OpenAI Codex"
  defp device_flow_label("google_oauth"), do: "Google AI"
  defp device_flow_label(other), do: other || "OAuth"

  defp pkce_pair do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  @anthropic_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @openai_client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  defp build_auth_url("anthropic_oauth", state, challenge, redirect_uri) do
    params = %{
      "response_type" => "code",
      "client_id" => @anthropic_client_id,
      "redirect_uri" => redirect_uri,
      "scope" => "user:profile user:inference",
      "state" => state,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256"
    }

    "https://platform.claude.com/oauth/authorize?" <> URI.encode_query(params)
  end

  defp build_auth_url("openai_oauth", state, challenge, redirect_uri) do
    params = %{
      "response_type" => "code",
      "client_id" => @openai_client_id,
      "redirect_uri" => redirect_uri,
      "scope" => "openid profile email offline_access api.connectors.read api.connectors.invoke",
      "state" => state,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256"
    }

    "https://auth.openai.com/authorize?" <> URI.encode_query(params)
  end

  defp build_auth_url("google_oauth", state, challenge, redirect_uri) do
    with {:ok, client_id} <- google_client_id() do
      params = %{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "scope" =>
          "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile",
        "access_type" => "offline",
        "prompt" => "consent",
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      }

      "https://accounts.google.com/o/oauth2/v2/auth?" <> URI.encode_query(params)
    end
  end

  defp google_client_id do
    value =
      :backplane
      |> Application.get_env(Backplane.Settings.OAuthRefresher, [])
      |> Keyword.get(:google_client_id)
      |> Kernel.||(System.get_env("GOOGLE_OAUTH_CLIENT_ID"))
      |> normalize_optional_string()

    if value, do: {:ok, value}, else: {:error, :missing_google_oauth_client_id}
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil
end
