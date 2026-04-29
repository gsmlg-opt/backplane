defmodule BackplaneWeb.UpstreamsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Proxy.{McpUpstream, Pool, Upstreams}
  alias Backplane.PubSubBroadcaster
  alias Backplane.Settings.Credentials

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Backplane.PubSub, Upstreams.topic())
      PubSubBroadcaster.subscribe(PubSubBroadcaster.config_reloaded_topic())
    end

    {:ok,
     assign(socket,
       current_path: "/admin/hub/upstreams",
       loading: true,
       upstreams: [],
       runtime_status: %{},
       credential_options: [],
       editing: nil,
       form: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(editing: nil, form: nil)
    |> load_upstreams()
  end

  defp apply_action(socket, :new, _params) do
    changeset = Upstreams.change(%McpUpstream{}, %{transport: "http", auth_scheme: "none"})

    socket
    |> assign(editing: :new, form: to_form(changeset))
    |> load_credentials()
    |> load_upstreams()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case safe_call(fn -> Upstreams.get!(id) end, nil) do
      nil ->
        socket
        |> put_flash(:error, "Upstream not found")
        |> push_patch(to: ~p"/admin/hub/upstreams")

      upstream ->
        changeset = Upstreams.change(upstream, %{})

        socket
        |> assign(editing: upstream, form: to_form(changeset))
        |> load_credentials()
        |> load_upstreams()
    end
  end

  @impl true
  def handle_info({:upstream_config, _event, _upstream}, socket) do
    {:noreply, load_upstreams(socket)}
  end

  def handle_info({event, _}, socket)
      when event in [:connected, :disconnected, :degraded, :tools_refreshed, :reloaded] do
    {:noreply, load_upstreams(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"mcp_upstream" => params}, socket) do
    params = prepare_params(params)

    changeset =
      case socket.assigns.editing do
        :new -> Upstreams.change(%McpUpstream{}, params)
        %McpUpstream{} = u -> Upstreams.change(u, params)
      end

    {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("save", %{"mcp_upstream" => params}, socket) do
    params = prepare_params(params)

    case socket.assigns.editing do
      :new ->
        case Upstreams.create(params) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Upstream created")
             |> push_patch(to: ~p"/admin/hub/upstreams")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end

      %McpUpstream{} = upstream ->
        case Upstreams.update(upstream, params) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Upstream updated")
             |> push_patch(to: ~p"/admin/hub/upstreams")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    upstream = Upstreams.get!(id)

    case Upstreams.delete(upstream) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Upstream deleted") |> load_upstreams()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete upstream")}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    upstream = Upstreams.get!(id)
    enabled = !upstream.enabled

    case Upstreams.update(upstream, %{enabled: enabled}) do
      {:ok, updated} ->
        if enabled do
          stop_runtime(updated)
          start_runtime(updated)
        else
          stop_runtime(updated)
        end

        message = if enabled, do: "Upstream enabled", else: "Upstream disabled"
        {:noreply, socket |> put_flash(:info, message) |> load_upstreams()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update upstream")}
    end
  end

  def handle_event("connect", %{"id" => id}, socket) do
    upstream = Upstreams.get!(id)

    if upstream.enabled do
      stop_runtime(upstream)

      case start_runtime(upstream) do
        {:ok, _pid} ->
          {:noreply, socket |> put_flash(:info, "Connection attempt started") |> load_upstreams()}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to start connection: #{inspect(reason)}")
           |> load_upstreams()}
      end
    else
      {:noreply, put_flash(socket, :error, "Enable upstream before connecting")}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp load_upstreams(socket) do
    upstreams = safe_call(fn -> Upstreams.list() end, [])
    runtime = safe_call(fn -> Pool.list_upstreams() end, [])
    runtime_map = Map.new(runtime, fn u -> {u.name, u} end)

    assign(socket,
      loading: false,
      upstreams: upstreams,
      runtime_status: runtime_map
    )
  end

  defp load_credentials(socket) do
    creds = safe_call(fn -> Credentials.list() end, [])
    known_names = MapSet.new(creds, & &1.name)

    base_options =
      [
        {"", "Select a credential..."}
        | Enum.map(creds, fn c -> {c.name, "#{c.name} (#{c.kind})"} end)
      ]

    # Preserve current selection if it references a credential that no longer exists in the store
    options =
      case socket.assigns[:editing] do
        %McpUpstream{credential: current} when is_binary(current) and current != "" ->
          if MapSet.member?(known_names, current) do
            base_options
          else
            base_options ++ [{current, "#{current} (missing)"}]
          end

        _ ->
          base_options
      end

    assign(socket, credential_options: options)
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp start_runtime(upstream) do
    upstream
    |> runtime_config()
    |> Pool.start_upstream()
  end

  defp stop_runtime(upstream) do
    upstream.name
    |> runtime_pids_for_name()
    |> Enum.each(&Pool.stop_upstream/1)

    :ok
  end

  defp runtime_pids_for_name(name) do
    Pool.list_upstream_pids()
    |> Enum.filter(fn {_pid, status} -> status.name == name end)
    |> Enum.map(fn {pid, _status} -> pid end)
  end

  defp runtime_config(upstream) do
    %{
      name: upstream.name,
      prefix: upstream.prefix,
      transport: upstream.transport,
      url: upstream.url,
      command: upstream.command,
      args: upstream.args || [],
      timeout: upstream.timeout_ms,
      refresh_interval: upstream.refresh_interval_ms,
      headers: upstream.headers || %{},
      credential: upstream.credential,
      auth_scheme: upstream.auth_scheme || "none",
      auth_header_name: upstream.auth_header_name
    }
  end

  defp prepare_params(params) do
    params
    |> Map.put("args", parse_args(params["args"]))
    |> Map.put("headers", parse_headers(params["headers"]))
    |> then(fn p ->
      case p["timeout_ms"] do
        "" -> Map.put(p, "timeout_ms", nil)
        _ -> p
      end
    end)
    |> then(fn p ->
      case p["refresh_interval_ms"] do
        "" -> Map.put(p, "refresh_interval_ms", nil)
        _ -> p
      end
    end)
    |> then(fn p ->
      case p["credential"] do
        "" -> Map.put(p, "credential", nil)
        _ -> p
      end
    end)
    |> then(fn p ->
      case p["auth_header_name"] do
        "" -> Map.put(p, "auth_header_name", nil)
        _ -> p
      end
    end)
  end

  defp parse_args(nil), do: []
  defp parse_args(""), do: []

  defp parse_args(val) when is_binary(val) do
    val
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_args(val) when is_list(val), do: val

  defp parse_headers(nil), do: %{}
  defp parse_headers(""), do: %{}

  defp parse_headers(val) when is_binary(val) do
    case Jason.decode(val) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp parse_headers(val) when is_map(val), do: val

  defp transport_value(form) do
    Phoenix.HTML.Form.input_value(form, :transport) || "http"
  end

  defp auth_scheme_value(form) do
    Phoenix.HTML.Form.input_value(form, :auth_scheme) || "none"
  end

  defp args_display(args) when is_list(args), do: Enum.join(args, ", ")
  defp args_display(_), do: ""

  defp headers_display(headers) when is_map(headers) and map_size(headers) > 0 do
    case Jason.encode(headers, pretty: true) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp headers_display(_), do: ""

  defp runtime_badge_color(%{status: :connected}), do: "success"
  defp runtime_badge_color(%{status: :degraded}), do: "warning"
  defp runtime_badge_color(_), do: "error"

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

  # ── Template ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= case @live_action do %>
        <% :index -> %>
          {list_view(assigns)}
        <% action when action in [:new, :edit] -> %>
          {form_view(assigns)}
      <% end %>
    </div>
    """
  end

  defp list_view(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/admin/hub"} class="text-sm text-primary hover:underline">
            &larr; Hub
          </.link>
          <h1 class="text-2xl font-bold">Upstream MCP Servers</h1>
        </div>
        <.link patch={~p"/admin/hub/upstreams/new"}>
          <.dm_btn variant="primary" size="sm">New Upstream</.dm_btn>
        </.link>
      </div>

      <div :if={@upstreams == []} class="text-on-surface-variant">
        No upstream MCP servers configured. Click "New Upstream" to add one.
      </div>

      <div class="space-y-3">
        <.dm_card :for={upstream <- @upstreams} variant="bordered">
          <:title>
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class="font-medium">{upstream.name}</span>
                <span class="text-xs text-on-surface-variant font-mono">{upstream.prefix}::</span>
                <.dm_badge variant="info">{upstream.transport}</.dm_badge>
                <.dm_badge :if={!upstream.enabled} variant="ghost">disabled</.dm_badge>
              </div>
              <div class="flex items-center gap-2">
                <.dm_badge
                  :if={rs = @runtime_status[upstream.name]}
                  variant={runtime_badge_color(rs)}
                >
                  {rs.status |> to_string() |> String.capitalize()}
                </.dm_badge>
                <.dm_badge :if={rs = @runtime_status[upstream.name]} variant="ghost">
                  {rs.tool_count || 0} tools
                </.dm_badge>
                <.dm_btn
                  size="xs"
                  variant={if upstream.enabled, do: "warning", else: "primary"}
                  phx-click="toggle"
                  phx-value-id={upstream.id}
                >
                  {if upstream.enabled, do: "Disable", else: "Enable"}
                </.dm_btn>
                <.dm_btn
                  size="xs"
                  variant="primary"
                  phx-click="connect"
                  phx-value-id={upstream.id}
                >
                  Connect
                </.dm_btn>
                <.link patch={~p"/admin/hub/upstreams/#{upstream.id}/edit"}>
                  <.dm_btn size="xs">Edit</.dm_btn>
                </.link>
                <.dm_btn
                  size="xs"
                  variant="error"
                  phx-click="delete"
                  phx-value-id={upstream.id}
                  data-confirm={"Delete upstream #{upstream.name}?"}
                >
                  Delete
                </.dm_btn>
              </div>
            </div>
          </:title>
          <div class="text-sm text-on-surface-variant mt-1">
            <span :if={upstream.url}>
              URL: <span class="text-on-surface">{upstream.url}</span>
            </span>
            <span :if={upstream.command}>
              Command: <span class="text-on-surface">{upstream.command}</span>
            </span>
            <span :if={upstream.credential} class="ml-4">
              Credential: <span class="text-on-surface">{upstream.credential}</span>
              (<span class="text-on-surface">{upstream.auth_scheme}</span>)
            </span>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end

  defp form_view(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-3 mb-6">
        <.link patch={~p"/admin/hub/upstreams"} class="text-sm text-primary hover:underline">
          &larr; Upstreams
        </.link>
        <h1 class="text-2xl font-bold">
          {if @editing == :new, do: "New Upstream", else: "Edit #{@editing.name}"}
        </h1>
      </div>

      <.dm_card variant="bordered">
        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <.dm_input
                id="upstream-name"
                name="mcp_upstream[name]"
                label="Name"
                value={@form[:name].value}
                placeholder="my-upstream"
              />
              <.form_error field={@form[:name]} />
            </div>
            <div>
              <.dm_input
                id="upstream-prefix"
                name="mcp_upstream[prefix]"
                label="Prefix"
                value={@form[:prefix].value}
                placeholder="myup"
              />
              <.form_error field={@form[:prefix]} />
            </div>
          </div>

          <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <div>
              <.dm_select
                id="upstream-transport"
                name="mcp_upstream[transport]"
                label="Transport"
                options={[{"http", "HTTP"}, {"sse", "SSE (Legacy)"}, {"stdio", "Stdio"}]}
                value={transport_value(@form)}
              />
              <.form_error field={@form[:transport]} />
            </div>
            <div>
              <.dm_select
                id="upstream-auth-scheme"
                name="mcp_upstream[auth_scheme]"
                label="Auth Scheme"
                options={[
                  {"none", "None"},
                  {"bearer", "Bearer Token"},
                  {"x_api_key", "X-API-Key"},
                  {"custom_header", "Custom Header"}
                ]}
                value={auth_scheme_value(@form)}
              />
              <.form_error field={@form[:auth_scheme]} />
            </div>
            <div>
              <.dm_select
                id="upstream-credential"
                name="mcp_upstream[credential]"
                label="Credential"
                options={@credential_options}
                value={@form[:credential].value || ""}
              />
              <p class="text-xs text-on-surface-variant mt-1">
                Select from the <.link
                  navigate={~p"/admin/settings?tab=credentials"}
                  class="text-primary underline"
                >credential store</.link>.
              </p>
              <.form_error field={@form[:credential]} />
            </div>
          </div>

          <div :if={transport_value(@form) in ["http", "sse"]}>
            <.dm_input
              id="upstream-url"
              name="mcp_upstream[url]"
              label="URL"
              value={@form[:url].value || ""}
              placeholder="https://example.com/mcp"
            />
            <.form_error field={@form[:url]} />
          </div>

          <div :if={transport_value(@form) == "stdio"} class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <.dm_input
                id="upstream-command"
                name="mcp_upstream[command]"
                label="Command"
                value={@form[:command].value || ""}
                placeholder="/usr/bin/node"
              />
              <.form_error field={@form[:command]} />
            </div>
            <div>
              <.dm_input
                id="upstream-args"
                name="mcp_upstream[args]"
                label="Args (comma-separated)"
                value={args_display(@form[:args].value)}
                placeholder="server.js,--port,3000"
              />
              <.form_error field={@form[:args]} />
            </div>
          </div>

          <div :if={auth_scheme_value(@form) == "custom_header"}>
            <.dm_input
              id="upstream-auth-header-name"
              name="mcp_upstream[auth_header_name]"
              label="Auth Header Name"
              value={@form[:auth_header_name].value || ""}
              placeholder="X-Custom-Key"
            />
            <.form_error field={@form[:auth_header_name]} />
          </div>

          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <.dm_input
                id="upstream-timeout-ms"
                name="mcp_upstream[timeout_ms]"
                label="Timeout (ms)"
                type="number"
                value={@form[:timeout_ms].value}
              />
              <.form_error field={@form[:timeout_ms]} />
            </div>
            <div>
              <.dm_input
                id="upstream-refresh-interval-ms"
                name="mcp_upstream[refresh_interval_ms]"
                label="Refresh Interval (ms)"
                type="number"
                value={@form[:refresh_interval_ms].value}
              />
              <.form_error field={@form[:refresh_interval_ms]} />
            </div>
          </div>

          <div>
            <.dm_textarea
              id="upstream-headers"
              name="mcp_upstream[headers]"
              label="Headers (JSON object, optional)"
              rows={3}
              value={headers_display(@form[:headers].value)}
              placeholder={~s({"X-Custom": "value"})}
              class="font-mono"
            />
            <.form_error field={@form[:headers]} />
          </div>

          <div class="flex gap-2 pt-2">
            <.dm_btn type="submit" variant="primary">Save</.dm_btn>
            <.link patch={~p"/admin/hub/upstreams"}>
              <.dm_btn type="button">Cancel</.dm_btn>
            </.link>
          </div>
        </.form>
      </.dm_card>
    </div>
    """
  end
end
