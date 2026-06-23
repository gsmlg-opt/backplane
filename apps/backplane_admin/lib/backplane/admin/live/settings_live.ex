defmodule Backplane.Admin.SettingsLive do
  @moduledoc "Admin pages for model aliases and credentials management."

  use Backplane.Admin, :live_view

  require Logger

  alias Backplane.LLM.AutoModel
  alias Backplane.LLM.ModelAlias
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.OpenAICodexAuth
  alias Backplane.Settings.OAuthRefresher
  alias Backplane.Settings.OAuthStateStore

  @google_antigravity_redirect_uri "https://antigravity.google/oauth-callback"
  @google_token_url "https://oauth2.googleapis.com/token"
  @google_antigravity_scopes [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/cclog",
    "https://www.googleapis.com/auth/experimentsandconfigs",
    "openid"
  ]
  @xai_grok_redirect_uri "http://127.0.0.1:56121/callback"
  @xai_authorize_url "https://auth.x.ai/oauth2/authorize"
  @xai_token_url "https://auth.x.ai/oauth2/token"
  @xai_client_id "b1a00492-073a-47ea-816f-4c329264a828"
  @xai_grok_scopes [
    "openid",
    "profile",
    "email",
    "offline_access",
    "grok-cli:access",
    "api:access"
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_mode: nil, delete_confirm_name: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {page_mode, current_path, data_key} =
      case socket.assigns.live_action do
        action
        when action in [:credentials, :credentials_new, :credentials_new_oauth, :credentials_edit] ->
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
    assign(socket, cred_form_mode: nil, delete_confirm_name: nil)
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
        "google_oauth" -> "google-antigravity"
        "xai_oauth" -> "xai-grok"
        _ -> "oauth-cred"
      end

    assign(socket,
      cred_form_mode: :device_auth,
      device_flow_vendor: vendor,
      device_flow_state: :idle,
      device_flow_cred_name: default_name,
      device_flow_user_code: nil,
      device_flow_verification_uri: nil,
      device_flow_error: nil,
      device_flow_error_detail: nil,
      device_flow_login: nil,
      device_flow_code_verifier: nil,
      device_flow_oauth_state: nil,
      device_flow_redirect_uri: nil
    )
  end

  defp apply_action(socket, :credentials_edit, %{"name" => name}) do
    cred = Enum.find(socket.assigns.credentials, &(&1.name == name))
    metadata = (cred && cred.metadata) || %{}
    auth_type = metadata["auth_type"] || "api_key"

    assign(socket,
      cred_form_mode: :edit,
      cred_editing_name: name,
      cred_name: name,
      cred_kind: (cred && cred.kind) || "llm",
      cred_secret: "",
      cred_auth_type: auth_type,
      cred_client_id: metadata["client_id"] || "",
      cred_token_url: metadata["token_url"] || "",
      cred_scope: metadata["scope"] || "",
      oauth_status: maybe_oauth_status(name, auth_type),
      device_flow_vendor: auth_type,
      device_flow_cred_name: name
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
    alias Backplane.Settings.Credentials.Vault
    Vault.reload()

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
      device_flow_error: nil,
      device_flow_error_detail: nil,
      device_flow_login: nil,
      device_flow_code_verifier: nil,
      device_flow_oauth_state: nil,
      device_flow_redirect_uri: nil,
      auth_json_modal_open: false,
      oauth_status: nil
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

  def handle_event("show_delete_confirm", %{"name" => name}, socket) do
    {:noreply, assign(socket, delete_confirm_name: name)}
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, delete_confirm_name: nil)}
  end

  def handle_event("cancel_device_auth", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/system/credentials")}
  end

  def handle_event("cancel_cred_form", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/system/credentials")}
  end

  def handle_event("retry_device_auth", _, socket) do
    {:noreply,
     assign(socket,
       device_flow_state: :idle,
       device_flow_error: nil,
       device_flow_error_detail: nil
     )}
  end

  def handle_event("start_device_auth", params, socket) do
    vendor = socket.assigns.device_flow_vendor
    name = String.trim(params["cred_name"] || "")

    start_device_auth(socket, vendor, name)
  end

  def handle_event("reconnect_oauth", _, socket) do
    start_device_auth(socket, socket.assigns.cred_auth_type, socket.assigns.cred_editing_name)
  end

  def handle_event("renew_oauth_token", _, socket) do
    name = socket.assigns.cred_editing_name

    case Credentials.refresh_oauth_token(name, force: true) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "OAuth token renewed for '#{name}'")
         |> refresh_credential_edit(name)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to renew OAuth token: #{format_oauth_error(reason)}")
         |> refresh_credential_edit(name)}
    end
  end

  def handle_event("open_auth_json_modal", _, socket) do
    {:noreply, assign(socket, auth_json_modal_open: true)}
  end

  def handle_event("close_auth_json_modal", _, socket) do
    {:noreply, assign(socket, auth_json_modal_open: false)}
  end

  def handle_event("submit_auth_code", %{"code" => code}, socket) do
    code = String.trim(code)
    vendor = socket.assigns.device_flow_vendor
    cred_name = socket.assigns.device_flow_cred_name
    verifier = socket.assigns.device_flow_code_verifier
    expected_state = socket.assigns.device_flow_oauth_state
    redirect_uri = socket.assigns.device_flow_redirect_uri

    if code == "" do
      {:noreply, put_flash(socket, :error, "Authorization code is required")}
    else
      case exchange_auth_code(vendor, code, verifier, redirect_uri, expected_state) do
        {:ok, tokens, hints} ->
          case Credentials.store_device_token(cred_name, vendor, tokens, hints) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Connected #{device_flow_label(vendor)} as '#{cred_name}'")
               |> push_patch(to: ~p"/admin/system/credentials")}

            {:error, reason} ->
              {:noreply,
               assign(socket,
                 device_flow_state: :error,
                 device_flow_error:
                   "Auth succeeded but failed to save credential: #{inspect(reason)}",
                 device_flow_error_detail: nil
               )}
          end

        {:error, reason} ->
          {:noreply,
           assign(socket,
             device_flow_state: :error,
             device_flow_error: "Code exchange failed: #{format_exchange_error(reason)}",
             device_flow_error_detail: format_exchange_error_detail(reason)
           )}
      end
    end
  end

  def handle_event("import_cli_auth", params, socket) do
    vendor = socket.assigns.device_flow_vendor
    name = String.trim(params["cred_name"] || "")
    auth_json = String.trim(params["auth_json"] || "")

    cond do
      vendor != "anthropic_oauth" ->
        {:noreply,
         put_flash(socket, :error, "CLI auth import is not available for this provider")}

      name == "" ->
        {:noreply, put_flash(socket, :error, "Credential name is required")}

      auth_json == "" ->
        {:noreply, put_flash(socket, :error, "Claude Code auth JSON is required")}

      true ->
        case import_claude_code_auth(name, auth_json) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Imported Claude Code auth as '#{name}'")
             |> push_patch(to: ~p"/admin/system/credentials")}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to import Claude Code auth JSON: #{format_cli_auth_error(reason)}"
             )}
        end
    end
  end

  def handle_event("update_cli_auth", params, socket) do
    name = socket.assigns.cred_editing_name
    auth_json = String.trim(params["auth_json"] || "")

    cond do
      socket.assigns.cred_auth_type != "anthropic_oauth" ->
        {:noreply,
         put_flash(socket, :error, "Claude Code auth JSON is only available for Claude Plan")}

      auth_json == "" ->
        {:noreply, put_flash(socket, :error, "Claude Code auth JSON is required")}

      true ->
        case import_claude_code_auth(name, auth_json) do
          {:ok, _} ->
            Credentials.invalidate_token(name)

            {:noreply,
             socket
             |> put_flash(:info, "Updated Claude Code auth JSON for '#{name}'")
             |> assign(auth_json_modal_open: false)
             |> refresh_credential_edit(name)}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to update Claude Code auth JSON: #{format_cli_auth_error(reason)}"
             )}
        end
    end
  end

  def handle_event("change_auth_type", %{"auth_type" => auth_type}, socket) do
    {:noreply, assign(socket, cred_auth_type: auth_type)}
  end

  def handle_event("change_kind", %{"kind" => kind}, socket) do
    {:noreply, assign(socket, cred_kind: kind)}
  end

  def handle_event("save_credential", params, socket) do
    case socket.assigns.cred_form_mode do
      :add -> handle_add_credential(params, socket)
      :edit -> handle_edit_credential(params, socket)
      :rotate -> handle_rotate_credential(params, socket)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("confirm_delete", _, socket) do
    name = socket.assigns.delete_confirm_name

    case Credentials.delete(name) do
      :ok ->
        {:noreply,
         socket
         |> assign(delete_confirm_name: nil)
         |> put_flash(:info, "Credential '#{name}' deleted")
         |> load_data("credentials")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(delete_confirm_name: nil)
         |> put_flash(:error, "Failed to delete credential")}
    end
  end

  @impl true
  def handle_info({:poll_openai_codex_auth, login, cred_name}, socket) do
    if socket.assigns.device_flow_state == :waiting_code and
         socket.assigns.device_flow_vendor == "openai_oauth" do
      case OpenAICodexAuth.poll_device_login(login) do
        {:ok, code_result} ->
          code_result = Map.put(code_result, :credential_name, cred_name)

          case OpenAICodexAuth.exchange_authorization_code(code_result) do
            {:ok, _state} ->
              {:noreply,
               socket
               |> put_flash(:info, "Connected OpenAI Codex as '#{cred_name}'")
               |> push_patch(to: ~p"/admin/system/credentials")}

            {:error, reason} ->
              {:noreply,
               assign(socket,
                 device_flow_state: :error,
                 device_flow_error:
                   "Auth succeeded but failed to save credential: #{inspect(reason)}",
                 device_flow_error_detail: nil
               )}
          end

        {:pending, pending_login} ->
          schedule_openai_codex_poll(pending_login, cred_name)

          {:noreply, socket}

        {:expired} ->
          {:noreply,
           assign(socket,
             device_flow_state: :error,
             device_flow_error: "Device authorization code expired. Please try again.",
             device_flow_error_detail: nil
           )}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             device_flow_state: :error,
             device_flow_error: "Authorization failed: #{format_openai_codex_error(reason)}",
             device_flow_error_detail: nil
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp start_device_auth(socket, vendor, name) do
    socket =
      assign(socket,
        cred_form_mode: :device_auth,
        device_flow_vendor: vendor,
        device_flow_cred_name: name
      )

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Credential name is required")}

      vendor == "openai_oauth" ->
        case OpenAICodexAuth.start_device_login() do
          {:ok, login} ->
            schedule_openai_codex_poll(login, name)

            {:noreply,
             assign(socket,
               device_flow_state: :waiting_code,
               device_flow_cred_name: name,
               device_flow_user_code: login.user_code,
               device_flow_verification_uri: login.verification_url,
               device_flow_login: login,
               device_flow_error: nil,
               device_flow_error_detail: nil
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               device_flow_state: :error,
               device_flow_error:
                 "Failed to request device code: #{format_openai_codex_error(reason)}",
               device_flow_error_detail: nil
             )}
        end

      vendor == "anthropic_oauth" ->
        redirect_uri = "https://platform.claude.com/oauth/code/callback"
        {verifier, challenge} = pkce_pair()
        state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        auth_url = build_auth_url("anthropic_oauth", state, challenge, redirect_uri)

        {:noreply,
         socket
         |> assign(
           device_flow_state: :waiting_code_input,
           device_flow_cred_name: name,
           device_flow_code_verifier: verifier,
           device_flow_oauth_state: state,
           device_flow_redirect_uri: redirect_uri,
           device_flow_error: nil,
           device_flow_error_detail: nil
         )
         |> push_event("open_external_oauth", %{url: auth_url})}

      vendor == "google_oauth" ->
        redirect_uri = @google_antigravity_redirect_uri
        {verifier, challenge} = pkce_pair()
        state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

        case build_auth_url("google_oauth", state, challenge, redirect_uri) do
          {:error, reason} ->
            {:noreply,
             assign(socket,
               device_flow_state: :error,
               device_flow_error: "Authorization is not configured: #{inspect(reason)}",
               device_flow_error_detail: nil
             )}

          auth_url ->
            {:noreply,
             socket
             |> assign(
               device_flow_state: :waiting_code_input,
               device_flow_cred_name: name,
               device_flow_code_verifier: verifier,
               device_flow_oauth_state: state,
               device_flow_redirect_uri: redirect_uri,
               device_flow_error: nil,
               device_flow_error_detail: nil
             )
             |> push_event("open_external_oauth", %{url: auth_url})}
        end

      vendor == "xai_oauth" ->
        redirect_uri = xai_redirect_uri()
        {verifier, challenge} = pkce_pair()
        state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

        case build_auth_url("xai_oauth", state, challenge, redirect_uri) do
          {:error, reason} ->
            {:noreply,
             assign(socket,
               device_flow_state: :error,
               device_flow_error: "Authorization is not configured: #{inspect(reason)}",
               device_flow_error_detail: nil
             )}

          auth_url ->
            {:noreply,
             socket
             |> assign(
               device_flow_state: :waiting_code_input,
               device_flow_cred_name: name,
               device_flow_code_verifier: verifier,
               device_flow_oauth_state: state,
               device_flow_redirect_uri: redirect_uri,
               device_flow_error: nil,
               device_flow_error_detail: nil
             )
             |> push_event("open_external_oauth", %{url: auth_url})}
        end

      true ->
        redirect_uri = Backplane.WebOrigins.admin_url("/admin/oauth/callback")
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
               device_flow_error: "Authorization is not configured: #{inspect(reason)}",
               device_flow_error_detail: nil
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

  defp schedule_openai_codex_poll(login, cred_name) do
    delay_ms = max(login.interval_seconds, 1) * 1000
    Process.send_after(self(), {:poll_openai_codex_auth, login, cred_name}, delay_ms)
  end

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

  defp cred_secret_label(_mode, _auth_type, "script"), do: "Script Content"
  defp cred_secret_label(:rotate, _auth_type, _kind), do: "New Secret"
  defp cred_secret_label(_mode, "oauth2_client_credentials", _kind), do: "Client Secret"
  defp cred_secret_label(_mode, _auth_type, _kind), do: "Secret"

  defp cred_secret_placeholder(:edit, _auth_type, "script"),
    do: "Leave empty to keep current script content"

  defp cred_secret_placeholder(_mode, _auth_type, "script"), do: "Enter script contents here..."

  defp cred_secret_placeholder(:edit, "oauth2_client_credentials", _kind),
    do: "Leave empty to keep current client secret"

  defp cred_secret_placeholder(:edit, _auth_type, _kind), do: "Leave empty to keep current"

  defp cred_secret_placeholder(_mode, "oauth2_client_credentials", _kind),
    do: "OAuth2 client secret"

  defp cred_secret_placeholder(_mode, _auth_type, _kind), do: "API key or token"

  defp build_metadata(params) do
    if params["kind"] == "script" do
      %{}
    else
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

  defp device_oauth_auth_type?(auth_type),
    do: auth_type in ["anthropic_oauth", "openai_oauth", "google_oauth", "xai_oauth"]

  defp maybe_oauth_status(name, auth_type) do
    if device_oauth_auth_type?(auth_type) do
      case Credentials.oauth_status(name) do
        {:ok, status} ->
          status

        {:error, reason} ->
          %{
            auth_type: auth_type,
            status: :invalid,
            expires_at: nil,
            token_created_at: nil,
            credential_updated_at: nil,
            error: reason
          }
      end
    end
  end

  defp refresh_credential_edit(socket, name) do
    socket
    |> load_data("credentials")
    |> apply_action(:credentials_edit, %{"name" => name})
  end

  defp oauth_status_label(%{status: :active}), do: "Active"
  defp oauth_status_label(%{status: :expiring_soon}), do: "Expiring Soon"
  defp oauth_status_label(%{status: :expired}), do: "Expired"
  defp oauth_status_label(%{status: :missing_refresh_token}), do: "Missing Refresh Token"
  defp oauth_status_label(%{status: :unknown}), do: "Unknown"
  defp oauth_status_label(%{status: :invalid}), do: "Invalid"
  defp oauth_status_label(_), do: "Unknown"

  defp oauth_status_variant(%{status: :active}), do: "success"
  defp oauth_status_variant(%{status: :expiring_soon}), do: "warning"
  defp oauth_status_variant(%{status: :expired}), do: "error"
  defp oauth_status_variant(%{status: :missing_refresh_token}), do: "error"
  defp oauth_status_variant(%{status: :invalid}), do: "error"
  defp oauth_status_variant(_), do: "neutral"

  defp format_oauth_datetime(nil, _id), do: "Unknown"

  defp format_oauth_datetime(datetime, id) do
    assigns = %{datetime: datetime, id: id}

    ~H"""
    <.local_time id={@id} datetime={@datetime} />
    """
  end

  defp format_oauth_error({:refresh_failed, status}), do: "refresh returned HTTP #{status}"
  defp format_oauth_error({:refresh_error, reason}), do: inspect(reason)
  defp format_oauth_error(reason), do: inspect(reason)

  @kind_options [
    {"llm", "LLM Provider"},
    {"upstream", "Upstream MCP"},
    {"service", "Service"},
    {"admin", "Admin"},
    {"script", "Script"},
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
                    Connect Google Antigravity
                  </.link>
                  <.link
                    patch={~p"/admin/system/credentials/new/xai_oauth"}
                    class="popover-menu-item"
                  >
                    Connect xAI Grok
                  </.link>
                </:content>
              </.dm_dropdown>
            </div>
          </div>



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
                          "xai_oauth",
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
                  <.local_time datetime={cred.updated_at} />
                </:col>
                <:col :let={cred} label="Actions">
                  <div class="flex items-center gap-1">
                    <.dm_tooltip content="Edit" position="bottom">
                      <.link patch={~p"/admin/system/credentials/#{cred.name}/edit"} class="no-underline">
                        <.dm_btn
                          type="button"
                          size="xs"
                          shape="circle"
                          variant="outline"
                          aria-label={"Edit #{cred.name}"}
                        >
                          <.dm_mdi name="pencil" class="h-4 w-4" />
                          <span class="sr-only">Edit</span>
                        </.dm_btn>
                      </.link>
                    </.dm_tooltip>

                    <.dm_tooltip content="Delete" position="bottom">
                      <.dm_btn
                        type="button"
                        variant="error"
                        size="xs"
                        shape="circle"
                        aria-label={"Delete #{cred.name}"}
                        phx-click="show_delete_confirm"
                        phx-value-name={cred.name}
                      >
                        <.dm_mdi name="delete" class="h-4 w-4" />
                        <span class="sr-only">Delete</span>
                      </.dm_btn>
                    </.dm_tooltip>
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

        <% :credentials_edit -> %>
          <div class="flex items-center gap-3 mb-6">
            <.link patch={~p"/admin/system/credentials"} class="text-sm text-primary hover:underline">
              &larr; Credentials
            </.link>
          </div>
          <%= cond do %>
            <% @cred_form_mode == :device_auth -> %>
              <.render_device_auth_form {assigns} />
            <% device_oauth_auth_type?(@cred_auth_type) -> %>
              <.render_oauth_cred_edit {assigns} />
            <% true -> %>
              <.render_cred_form kind_options={@kind_options} {assigns} />
          <% end %>
      <% end %>

      <div
        :if={@delete_confirm_name}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
        phx-window-keydown="cancel_delete"
        phx-key="Escape"
      >
        <div class="bg-surface-container rounded-lg shadow-xl p-6 max-w-md w-full mx-4 border border-outline-variant">
          <h3 class="text-lg font-semibold text-on-surface mb-2">Delete Credential</h3>
          <p class="text-sm text-on-surface-variant mb-6">
            Are you sure you want to delete credential
            <code class="text-error font-mono">{@delete_confirm_name}</code>?
            This cannot be undone.
          </p>
          <div class="flex justify-end gap-2">
            <.dm_btn phx-click="cancel_delete">Cancel</.dm_btn>
            <.dm_btn variant="error" phx-click="confirm_delete">Delete</.dm_btn>
          </div>
        </div>
      </div>
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
            phx-change="change_kind"
          />

          <%= if @cred_kind != "script" do %>
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
        <% end %>

        <%= if @cred_kind == "script" do %>
          <.dm_textarea
            id="cred-secret"
            name="secret"
            value={@cred_secret}
            label={cred_secret_label(@cred_form_mode, @cred_auth_type, @cred_kind)}
            placeholder={cred_secret_placeholder(@cred_form_mode, @cred_auth_type, @cred_kind)}
            rows={8}
            class="font-mono"
            {if @cred_form_mode == :add, do: [required: true], else: []}
          />
        <% else %>
          <.dm_input
            id="cred-secret"
            name="secret"
            type="password"
            value={@cred_secret}
            label={cred_secret_label(@cred_form_mode, @cred_auth_type, @cred_kind)}
            placeholder={cred_secret_placeholder(@cred_form_mode, @cred_auth_type, @cred_kind)}
            {if @cred_form_mode == :add, do: [required: true], else: []}
          />
        <% end %>
        <p :if={@cred_form_mode == :edit} class="text-xs text-on-surface-variant -mt-2">
          Leave empty to keep the current secret. Enter a new value to rotate it.
        </p>

        <div class="flex gap-2 pt-2">
          <.dm_btn type="submit" variant="primary">
            <%= case @cred_form_mode do %>
              <% :add -> %>Store Credential
              <% :edit -> %>Save Changes
            <% end %>
          </.dm_btn>
          <.dm_btn type="button" phx-click="cancel_cred_form">Cancel</.dm_btn>
        </div>
      </form>
    </.dm_card>
    """
  end

  defp render_oauth_cred_edit(assigns) do
    ~H"""
    <.dm_card variant="bordered" class="mb-6">
      <:title>OAuth Credential: {@cred_editing_name}</:title>

      <div class="space-y-5">
        <div class="flex flex-wrap items-center gap-2">
          <.dm_badge variant="info">{device_flow_label(@cred_auth_type)}</.dm_badge>
          <.dm_badge id="oauth-status-badge" variant={oauth_status_variant(@oauth_status)}>
            {oauth_status_label(@oauth_status)}
          </.dm_badge>
        </div>

        <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
          <div class="rounded-md border border-outline-variant p-3">
            <div class="mb-1 text-xs font-medium uppercase text-on-surface-variant">Token Expires</div>
            <div id="oauth-token-expires" class="text-sm text-on-surface">
              {format_oauth_datetime(
                @oauth_status && @oauth_status.expires_at,
                "oauth-token-expires-at"
              )}
            </div>
          </div>
          <div class="rounded-md border border-outline-variant p-3">
            <div class="mb-1 text-xs font-medium uppercase text-on-surface-variant">Token Created</div>
            <div id="oauth-token-created" class="text-sm text-on-surface">
              {format_oauth_datetime(
                @oauth_status && @oauth_status.token_created_at,
                "oauth-token-created-at"
              )}
            </div>
          </div>
          <div class="rounded-md border border-outline-variant p-3">
            <div class="mb-1 text-xs font-medium uppercase text-on-surface-variant">Last Updated</div>
            <div id="oauth-credential-updated" class="text-sm text-on-surface">
              {format_oauth_datetime(
                @oauth_status && @oauth_status.credential_updated_at,
                "oauth-credential-updated-at"
              )}
            </div>
          </div>
        </div>

        <div class="flex flex-wrap gap-2 pt-1">
          <.dm_btn type="button" variant="primary" phx-click="reconnect_oauth">
            Reconnect
          </.dm_btn>
          <.dm_btn type="button" variant="secondary" phx-click="renew_oauth_token">
            Renew Token
          </.dm_btn>
          <.dm_btn
            :if={@cred_auth_type == "anthropic_oauth"}
            id="open-claude-auth-json-modal"
            type="button"
            variant="outline"
            phx-click="open_auth_json_modal"
          >
            Set Auth JSON
          </.dm_btn>
          <.dm_btn type="button" phx-click="cancel_cred_form">Cancel</.dm_btn>
        </div>

        <.claude_auth_json_modal :if={@auth_json_modal_open} />
      </div>
    </.dm_card>
    """
  end

  defp claude_auth_json_modal(assigns) do
    ~H"""
    <div
      id="claude-auth-json-modal"
      class="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-black/60 px-4 py-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="claude-auth-json-modal-title"
      phx-window-keydown="close_auth_json_modal"
      phx-key="Escape"
    >
      <div class="w-full max-w-3xl rounded-lg border border-outline-variant bg-surface-container p-6 shadow-xl">
        <div class="mb-5 flex items-center justify-between gap-4">
          <h2 id="claude-auth-json-modal-title" class="text-lg font-semibold text-on-surface">
            Set Claude Plan Auth JSON
          </h2>
          <button
            type="button"
            class="rounded px-2 py-1 text-sm text-on-surface-variant hover:bg-surface-container-high hover:text-on-surface"
            phx-click="close_auth_json_modal"
            aria-label="Close"
          >
            x
          </button>
        </div>

        <form id="claude-auth-json-form" phx-submit="update_cli_auth" class="space-y-4">
          <.dm_textarea
            id="edit-claude-code-auth-json"
            name="auth_json"
            label="Auth JSON"
            value=""
            placeholder={~s({"claudeAiOauth":{"accessToken":"...","refreshToken":"...","expiresAt":1780094101489}})}
            rows={10}
            class="font-mono"
            required
          />
          <div class="flex flex-wrap justify-end gap-2 pt-2">
            <.dm_btn type="button" variant="outline" size="sm" phx-click="close_auth_json_modal">
              Cancel
            </.dm_btn>
            <.dm_btn type="submit" variant="primary" size="sm">Update Auth JSON</.dm_btn>
          </div>
        </form>
      </div>
    </div>
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
            placeholder={@device_flow_cred_name || "oauth-cred"}
            required
          />
          <div class="flex gap-2 pt-2">
            <.dm_btn type="submit" variant="primary">Connect</.dm_btn>
            <.dm_btn type="button" phx-click="cancel_device_auth">Cancel</.dm_btn>
          </div>
        </form>

        <div :if={@device_flow_vendor == "anthropic_oauth"} class="mt-6 border-t border-outline-variant pt-5">
          <h3 class="mb-3 text-sm font-semibold text-on-surface">Claude Code Auth JSON</h3>
          <form phx-submit="import_cli_auth" class="space-y-4">
            <.dm_input
              id="cli-auth-cred-name"
              name="cred_name"
              label="Credential Name"
              value={@device_flow_cred_name}
              placeholder={@device_flow_cred_name || "claude-plan"}
              required
            />
            <.dm_textarea
              id="claude-code-auth-json"
              name="auth_json"
              label="Auth JSON"
              value=""
              placeholder={~s({"claudeAiOauth":{"accessToken":"...","refreshToken":"...","expiresAt":1780094101489}})}
              rows={8}
              class="font-mono"
              required
            />
            <div class="flex gap-2 pt-2">
              <.dm_btn type="submit" variant="primary">Import JSON</.dm_btn>
              <.dm_btn type="button" phx-click="cancel_device_auth">Cancel</.dm_btn>
            </div>
          </form>
        </div>
      <% end %>

      <%= if @device_flow_state == :waiting_code_input do %>
        <div class="space-y-4">
          <p class="text-sm text-on-surface-variant">
            Complete authorization in the browser window that just opened,
            then paste the code below.
          </p>
          <form phx-submit="submit_auth_code" class="space-y-4">
            <.dm_input
              id="oauth-code-input"
              name="code"
              label="Authorization Code"
              value=""
              placeholder="Paste code#state or the callback URL"
              required
            />
            <div class="flex gap-2 pt-2">
              <.dm_btn type="submit" variant="primary">Submit Code</.dm_btn>
              <.dm_btn type="button" phx-click="cancel_device_auth">Cancel</.dm_btn>
            </div>
          </form>
        </div>
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
          <pre
            :if={@device_flow_error_detail}
            class="whitespace-pre-wrap break-words rounded-md border border-outline-variant bg-surface-container-low p-3 text-xs text-on-surface"
          ><%= @device_flow_error_detail %></pre>
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
  defp device_flow_label("google_oauth"), do: "Google Antigravity"
  defp device_flow_label("xai_oauth"), do: "xAI Grok"
  defp device_flow_label(other), do: other || "OAuth"

  defp pkce_pair do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  @anthropic_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @anthropic_token_url "https://platform.claude.com/v1/oauth/token"
  @legacy_anthropic_token_urls [
    "https://console.anthropic.com/v1/oauth/token",
    "https://api.anthropic.com/api/oauth/claude_cli/create_api_key"
  ]
  @anthropic_scope "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
  @openai_client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  defp build_auth_url("anthropic_oauth", state, challenge, redirect_uri) do
    params = [
      {"code", "true"},
      {"client_id", @anthropic_client_id},
      {"response_type", "code"},
      {"redirect_uri", redirect_uri},
      {"scope", @anthropic_scope},
      {"code_challenge", challenge},
      {"code_challenge_method", "S256"},
      {"state", state}
    ]

    "https://claude.ai/oauth/authorize?" <> URI.encode_query(params)
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
        "scope" => Enum.join(@google_antigravity_scopes, " "),
        "access_type" => "offline",
        "prompt" => "consent",
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      }

      "https://accounts.google.com/o/oauth2/auth?" <> URI.encode_query(params)
    end
  end

  defp build_auth_url("xai_oauth", state, challenge, redirect_uri) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    params = %{
      "response_type" => "code",
      "client_id" => xai_client_id(),
      "redirect_uri" => redirect_uri,
      "scope" => Enum.join(@xai_grok_scopes, " "),
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => state,
      "nonce" => nonce,
      "plan" => "generic",
      "referrer" => "backplane"
    }

    xai_authorize_url() <> "?" <> URI.encode_query(params)
  end

  defp google_client_id do
    value =
      google_oauth_value(
        :google_client_id,
        "GOOGLE_OAUTH_CLIENT_ID",
        OAuthRefresher.google_antigravity_client_id()
      )

    if value, do: {:ok, value}, else: {:error, :missing_google_oauth_client_id}
  end

  defp google_client_credentials do
    client_id =
      google_oauth_value(
        :google_client_id,
        "GOOGLE_OAUTH_CLIENT_ID",
        OAuthRefresher.google_antigravity_client_id()
      )

    client_secret =
      google_oauth_value(
        :google_client_secret,
        "GOOGLE_OAUTH_CLIENT_SECRET",
        default_google_client_secret(client_id)
      )

    if client_id,
      do: {:ok, client_id, client_secret},
      else: {:error, :missing_google_oauth_client_id}
  end

  defp google_token_url do
    google_oauth_value(:google_token_url, nil, @google_token_url)
  end

  defp default_google_client_secret(client_id) do
    if client_id == OAuthRefresher.google_antigravity_client_id() do
      OAuthRefresher.google_antigravity_client_secret()
    end
  end

  defp xai_client_id do
    xai_oauth_value(:xai_client_id, "XAI_OAUTH_CLIENT_ID", @xai_client_id)
  end

  defp xai_authorize_url do
    xai_oauth_value(:xai_authorize_url, nil, @xai_authorize_url)
  end

  defp xai_token_url do
    xai_oauth_value(:xai_token_url, nil, @xai_token_url)
  end

  defp xai_redirect_uri do
    xai_oauth_value(:xai_redirect_uri, "XAI_OAUTH_REDIRECT_URI", @xai_grok_redirect_uri)
  end

  defp google_oauth_value(key, env_key, default) do
    oauth_config_value(key, env_key, default)
  end

  defp xai_oauth_value(key, env_key, default) do
    oauth_config_value(key, env_key, default)
  end

  defp oauth_config_value(key, env_key, default) do
    [
      :backplane
      |> Application.get_env(Backplane.Settings.OAuthRefresher, [])
      |> Keyword.get(key),
      env_key && System.get_env(env_key),
      default
    ]
    |> Enum.find_value(&normalize_optional_string/1)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil

  defp import_claude_code_auth(name, auth_json) do
    with :ok <- validate_claude_code_auth_json(auth_json),
         {:ok, cred} <- Credentials.import_cli_auth(name, auth_json) do
      {:ok, cred}
    end
  end

  defp validate_claude_code_auth_json(auth_json) do
    case Jason.decode(auth_json) do
      {:ok, %{"claudeAiOauth" => %{"refreshToken" => refresh_token}}}
      when is_binary(refresh_token) and refresh_token != "" ->
        :ok

      {:ok, _} ->
        {:error, :unrecognized_format}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp format_cli_auth_error(:invalid_json), do: "invalid JSON"
  defp format_cli_auth_error(:unrecognized_format), do: "expected Claude Code auth JSON"
  defp format_cli_auth_error(reason), do: inspect(reason)

  # --- Auth Code Exchange (Claude Code CLI flow) ---

  defp exchange_auth_code(
         "anthropic_oauth",
         pasted_code,
         code_verifier,
         redirect_uri,
         expected_state
       ) do
    with {:ok, code, returned_state} <- split_anthropic_auth_code(pasted_code),
         :ok <- verify_anthropic_state(expected_state, returned_state) do
      exchange_state = token_exchange_state(expected_state, returned_state)

      body = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "state" => exchange_state,
        "redirect_uri" => redirect_uri,
        "client_id" => @anthropic_client_id,
        "code_verifier" => code_verifier
      }

      case exchange_anthropic_token(body) do
        {:ok, %{status: 200, body: resp}} ->
          access = resp["access_token"] || resp["api_key"]
          refresh = resp["refresh_token"] || ""
          expires_in = resp["expires_in"] || 3600
          expires_at = System.system_time(:millisecond) + expires_in * 1_000

          tokens = %{access_token: access, refresh_token: refresh, expires_at: expires_at}

          hints =
            %{}
            |> maybe_put_hint("subscription_type", resp["subscription_type"] || resp["plan"])
            |> maybe_put_hint("organization_uuid", resp["organization_uuid"] || resp["org_id"])

          {:ok, tokens, hints}

        {:error, {:http, status, body}} ->
          {:error, {:http, status, body}}

        {:error, {:http, status, body, request_detail}} ->
          {:error, {:http, status, body, request_detail}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp exchange_auth_code(
         "google_oauth",
         pasted_code,
         code_verifier,
         redirect_uri,
         expected_state
       ) do
    with {:ok, code, returned_state} <- split_google_auth_code(pasted_code),
         :ok <- verify_google_state(expected_state, returned_state),
         {:ok, client_id, client_secret} <- google_client_credentials() do
      body =
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client_id,
          "code_verifier" => code_verifier
        }
        |> maybe_put_form_field("client_secret", client_secret)

      token_url = google_token_url()

      req_opts =
        token_url
        |> OAuthRefresher.request_options()
        |> Keyword.merge(form: body, headers: google_token_headers(), receive_timeout: 30_000)

      case Req.post(token_url, req_opts) do
        {:ok, %{status: 200, body: %{"access_token" => access} = resp}} ->
          refresh = resp["refresh_token"] || ""

          if refresh == "" do
            {:error, :missing_refresh_token}
          else
            expires_in = resp["expires_in"] || 3600
            expires_at = System.system_time(:millisecond) + expires_in * 1_000

            tokens =
              %{
                type: "antigravity_oauth",
                access_token: access,
                refresh_token: refresh,
                expires_at: expires_at
              }
              |> maybe_put_token(:id_token, resp["id_token"])

            {:ok, tokens, %{"auth_mode" => "antigravity"}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp exchange_auth_code(
         "xai_oauth",
         pasted_code,
         code_verifier,
         redirect_uri,
         expected_state
       ) do
    with {:ok, code, returned_state} <- split_xai_auth_code(pasted_code),
         :ok <- verify_xai_state(expected_state, returned_state) do
      body = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => xai_client_id(),
        "code_verifier" => code_verifier
      }

      token_url = xai_token_url()

      req_opts =
        token_url
        |> OAuthRefresher.request_options()
        |> Keyword.merge(form: body, receive_timeout: 30_000)

      case Req.post(token_url, req_opts) do
        {:ok, %{status: 200, body: %{"access_token" => access} = resp}} ->
          refresh = resp["refresh_token"] || ""

          if refresh == "" do
            {:error, :missing_refresh_token}
          else
            expires_in = resp["expires_in"] || 3600
            expires_at = System.system_time(:millisecond) + expires_in * 1_000

            tokens =
              %{
                type: "xai_grok_oauth",
                auth_mode: "grok",
                access_token: access,
                refresh_token: refresh,
                expires_at: expires_at
              }
              |> maybe_put_token(:id_token, resp["id_token"])

            {:ok, tokens, %{"auth_mode" => "grok", "client_id" => xai_client_id()}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp google_token_headers do
    [
      {"Accept", "*/*"},
      {"User-Agent", "google-api-nodejs-client/9.15.1"}
    ]
  end

  defp exchange_anthropic_token(body) do
    token_url = anthropic_token_url()
    request_detail = anthropic_token_request_detail(token_url, body)
    log_anthropic_token_request(request_detail)

    case Req.post(token_url,
           json: body,
           headers: Backplane.Settings.OAuthRefresher.anthropic_oauth_token_headers(),
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 403, body: response_body}} ->
        log_anthropic_token_failure(403, response_body)
        {:error, {:http, 403, response_body, request_detail}}

      {:ok, %{status: status, body: response_body}} when status != 200 ->
        log_anthropic_token_failure(status, response_body)
        {:error, {:http, status, response_body, request_detail}}

      other ->
        other
    end
  end

  defp split_anthropic_auth_code(pasted_code) do
    pasted_code =
      pasted_code
      |> String.trim()
      |> String.replace(~r/\s+/, "")

    cond do
      String.starts_with?(pasted_code, "https://") ->
        split_anthropic_callback_url(pasted_code)

      true ->
        split_anthropic_code_fragment(pasted_code)
    end
  end

  defp split_google_auth_code(pasted_code) do
    pasted_code =
      pasted_code
      |> String.trim()
      |> String.replace(~r/\s+/, "")

    cond do
      String.starts_with?(pasted_code, "http://") or String.starts_with?(pasted_code, "https://") ->
        split_google_callback_url(pasted_code)

      true ->
        split_google_code_fragment(pasted_code)
    end
  end

  defp split_xai_auth_code(pasted_code) do
    pasted_code =
      pasted_code
      |> String.trim()
      |> String.replace(~r/\s+/, "")

    cond do
      String.starts_with?(pasted_code, "http://") or String.starts_with?(pasted_code, "https://") ->
        split_xai_callback_url(pasted_code)

      String.starts_with?(pasted_code, "?") ->
        split_xai_query_fragment(pasted_code)

      true ->
        split_xai_code_fragment(pasted_code)
    end
  end

  defp split_google_callback_url(callback_url) do
    uri = URI.parse(callback_url)

    with "antigravity.google" <- uri.host,
         "/oauth-callback" <- uri.path,
         query when is_binary(query) <- uri.query do
      params = URI.decode_query(query)
      code = params["code"] || ""
      state = params["state"]

      if code != "" do
        {:ok, code, state}
      else
        {:error, :invalid_google_code}
      end
    else
      _ -> {:error, :invalid_google_code}
    end
  end

  defp split_xai_callback_url(callback_url) do
    uri = URI.parse(callback_url)

    with true <- uri.host in ["127.0.0.1", "localhost"],
         "/callback" <- uri.path,
         query when is_binary(query) <- uri.query do
      split_xai_query_params(URI.decode_query(query))
    else
      _ -> {:error, :invalid_xai_code}
    end
  end

  defp split_xai_query_fragment(query_fragment) do
    query_fragment
    |> String.trim_leading("?")
    |> URI.decode_query()
    |> split_xai_query_params()
  rescue
    _ -> {:error, :invalid_xai_code}
  end

  defp split_xai_query_params(params) do
    code = params["code"] || ""
    state = params["state"]

    if code != "" do
      {:ok, code, state}
    else
      {:error, :invalid_xai_code}
    end
  end

  defp split_google_code_fragment(pasted_code) do
    case String.split(pasted_code, "#", parts: 2) do
      [code, state] when code != "" and state != "" -> {:ok, code, state}
      [code] when code != "" -> {:ok, code, nil}
      _ -> {:error, :invalid_google_code}
    end
  end

  defp split_xai_code_fragment(pasted_code) do
    case String.split(pasted_code, "#", parts: 2) do
      [code, state] when code != "" and state != "" -> {:ok, code, state}
      [code] when code != "" -> {:ok, code, nil}
      _ -> {:error, :invalid_xai_code}
    end
  end

  defp split_anthropic_callback_url(callback_url) do
    uri = URI.parse(callback_url)

    with "platform.claude.com" <- uri.host,
         "/oauth/code/callback" <- uri.path,
         query when is_binary(query) <- uri.query do
      params = URI.decode_query(query)
      code = params["code"] || ""
      state = params["state"] || ""

      if code != "" and state != "" do
        {:ok, code, state}
      else
        {:error, :invalid_anthropic_code}
      end
    else
      _ -> {:error, :invalid_anthropic_code}
    end
  end

  defp split_anthropic_code_fragment(pasted_code) do
    case String.split(pasted_code, "#", parts: 2) do
      [code, state] when code != "" and state != "" -> {:ok, code, state}
      _ -> {:error, :invalid_anthropic_code}
    end
  end

  defp verify_anthropic_state(expected_state, returned_state)
       when is_binary(expected_state) and expected_state != "" do
    if byte_size(expected_state) == byte_size(returned_state) and
         Plug.Crypto.secure_compare(expected_state, returned_state) do
      :ok
    else
      {:error, :oauth_state_mismatch}
    end
  end

  defp verify_anthropic_state(_expected_state, _returned_state), do: :ok

  defp verify_google_state(expected_state, returned_state)
       when is_binary(expected_state) and expected_state != "" and is_binary(returned_state) and
              returned_state != "" do
    if byte_size(expected_state) == byte_size(returned_state) and
         Plug.Crypto.secure_compare(expected_state, returned_state) do
      :ok
    else
      {:error, :oauth_state_mismatch}
    end
  end

  defp verify_google_state(_expected_state, _returned_state), do: :ok

  defp verify_xai_state(expected_state, returned_state)
       when is_binary(expected_state) and expected_state != "" and is_binary(returned_state) and
              returned_state != "" do
    if byte_size(expected_state) == byte_size(returned_state) and
         Plug.Crypto.secure_compare(expected_state, returned_state) do
      :ok
    else
      {:error, :oauth_state_mismatch}
    end
  end

  defp verify_xai_state(_expected_state, _returned_state), do: :ok

  defp token_exchange_state(expected_state, _returned_state)
       when is_binary(expected_state) and expected_state != "",
       do: expected_state

  defp token_exchange_state(_expected_state, returned_state), do: returned_state

  defp anthropic_token_url do
    :backplane
    |> Application.get_env(Backplane.Settings.OAuthRefresher, [])
    |> Keyword.get(:anthropic_token_url, @anthropic_token_url)
    |> normalize_anthropic_token_url()
  end

  defp normalize_anthropic_token_url(url) when url in @legacy_anthropic_token_urls,
    do: @anthropic_token_url

  defp normalize_anthropic_token_url(url), do: url || @anthropic_token_url

  defp anthropic_token_request_detail(token_url, body) do
    %{
      url: token_url,
      headers: anthropic_oauth_token_header_detail(),
      body_keys: body |> Map.keys() |> Enum.sort(),
      redirect_uri: body["redirect_uri"],
      has_expires_in: Map.has_key?(body, "expires_in"),
      code_length: binary_length(body["code"]),
      state_length: binary_length(body["state"]),
      verifier_length: binary_length(body["code_verifier"])
    }
  end

  defp anthropic_oauth_token_header_detail do
    Backplane.Settings.OAuthRefresher.anthropic_oauth_token_headers()
    |> Map.new(fn {key, value} -> {String.downcase(key), value} end)
  end

  defp log_anthropic_token_request(request_detail) do
    Logger.debug(fn ->
      "Anthropic OAuth token exchange request: #{inspect(request_detail)}"
    end)
  end

  defp log_anthropic_token_failure(status, body) do
    Logger.debug(fn ->
      fields =
        body
        |> anthropic_error_fields()
        |> Map.put(:status, status)

      "Anthropic OAuth token exchange failed: #{inspect(fields)}"
    end)
  end

  defp anthropic_error_fields(%{"error" => %{} = error}) do
    %{
      error_type: error["type"],
      error_message: error["message"]
    }
  end

  defp anthropic_error_fields(%{} = body) do
    %{
      error_type: body["type"],
      error_message: body["message"]
    }
  end

  defp anthropic_error_fields(_body), do: %{error_type: nil, error_message: nil}

  defp binary_length(value) when is_binary(value), do: byte_size(value)
  defp binary_length(_value), do: 0

  defp maybe_put_hint(map, _key, nil), do: map
  defp maybe_put_hint(map, _key, ""), do: map
  defp maybe_put_hint(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_form_field(map, _key, nil), do: map
  defp maybe_put_form_field(map, _key, ""), do: map
  defp maybe_put_form_field(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_token(map, _key, nil), do: map
  defp maybe_put_token(map, _key, ""), do: map
  defp maybe_put_token(map, key, value), do: Map.put(map, key, value)

  defp format_exchange_error(:invalid_anthropic_code),
    do: "Paste the full code in the form code#state"

  defp format_exchange_error(:invalid_google_code),
    do: "Paste the authorization code shown by Google Antigravity"

  defp format_exchange_error(:invalid_xai_code),
    do: "Paste the xAI callback URL or authorization code"

  defp format_exchange_error(:oauth_state_mismatch),
    do: "OAuth state did not match. Please restart authorization."

  defp format_exchange_error({:http, status, %{"error_description" => desc}}),
    do: "#{desc} (#{status})"

  defp format_exchange_error({:http, status, body, _request_detail}),
    do: format_exchange_error({:http, status, body})

  defp format_exchange_error({:http, status, %{"message" => message, "type" => type}}),
    do: "#{message} (#{type}, #{status})"

  defp format_exchange_error(
         {:http, status, %{"error" => %{"message" => message, "type" => type}}}
       ),
       do: "#{message} (#{type}, #{status})"

  defp format_exchange_error({:http, status, %{"error" => %{"message" => message}}}),
    do: "#{message} (#{status})"

  defp format_exchange_error({:http, status, %{"error" => err}}), do: "#{err} (#{status})"
  defp format_exchange_error({:http, status, _}), do: "HTTP #{status}"
  defp format_exchange_error(other), do: inspect(other)

  defp format_exchange_error_detail({:http, status, body, request_detail}) do
    detail = %{
      status: status,
      request: request_detail,
      response: body
    }

    inspect(detail, pretty: true, limit: :infinity, printable_limit: :infinity)
  end

  defp format_exchange_error_detail({:http, status, body}) do
    detail = %{status: status, response: body}
    inspect(detail, pretty: true, limit: :infinity, printable_limit: :infinity)
  end

  defp format_exchange_error_detail(reason), do: inspect(reason, pretty: true)

  defp format_openai_codex_error(:device_code_login_disabled),
    do: "Device-code login is not enabled for this account or server."

  defp format_openai_codex_error(:refresh_token_reused),
    do: "The refresh token was already consumed. Reconnect OpenAI Codex."

  defp format_openai_codex_error({:transport_error, %Req.TransportError{reason: :nxdomain}}),
    do: "DNS lookup failed for auth.openai.com. Check this server's DNS or proxy settings."

  defp format_openai_codex_error({:transport_error, %Req.TransportError{reason: reason}}),
    do: "Network request failed: #{inspect(reason)}"

  defp format_openai_codex_error({:missing_field, field}), do: "Missing #{field}"

  defp format_openai_codex_error({reason, status}) when is_atom(reason),
    do: "#{reason} (#{status})"

  defp format_openai_codex_error(reason), do: inspect(reason)
end
