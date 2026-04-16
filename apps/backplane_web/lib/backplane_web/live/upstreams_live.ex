defmodule BackplaneWeb.UpstreamsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Proxy.{McpUpstream, Pool, Upstreams}
  alias Backplane.PubSubBroadcaster

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
       editing: nil,
       form: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_upstreams(socket)}
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
  def handle_event("new", _, socket) do
    changeset = Upstreams.change(%McpUpstream{}, %{transport: "http", auth_scheme: "none"})
    {:noreply, assign(socket, editing: :new, form: to_form(changeset))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    upstream = Upstreams.get!(id)
    changeset = Upstreams.change(upstream, %{})
    {:noreply, assign(socket, editing: upstream, form: to_form(changeset))}
  end

  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

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
             |> assign(editing: nil, form: nil)
             |> load_upstreams()}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end

      %McpUpstream{} = upstream ->
        case Upstreams.update(upstream, params) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Upstream updated")
             |> assign(editing: nil, form: nil)
             |> load_upstreams()}

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

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
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
      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center gap-3">
          <.dm_btn variant="link" size="sm" phx-click={JS.navigate(~p"/admin/hub")}>
            &larr; Hub
          </.dm_btn>
          <h1 class="text-2xl font-bold">Upstream MCP Servers</h1>
        </div>
        <.dm_btn :if={@editing == nil} variant="primary" size="sm" phx-click="new">
          New Upstream
        </.dm_btn>
      </div>

      <%!-- Upstream Form (create/edit) --%>
      <%= if @editing != nil do %>
        <.dm_card variant="bordered" class="mb-6">
          <:title>
            {if @editing == :new, do: "New Upstream", else: "Edit #{@editing.name}"}
          </:title>
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
                  options={[{"none", "None"}, {"bearer", "Bearer Token"}, {"x_api_key", "X-API-Key"}, {"custom_header", "Custom Header"}]}
                  value={auth_scheme_value(@form)}
                />
                <.form_error field={@form[:auth_scheme]} />
              </div>
              <div>
                <.dm_input
                  id="upstream-credential"
                  name="mcp_upstream[credential]"
                  label="Credential Name"
                  value={@form[:credential].value || ""}
                  placeholder="credential-name"
                />
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

            <div class="sm:col-span-2">
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
              <.dm_btn type="button" phx-click="cancel">Cancel</.dm_btn>
            </div>
          </.form>
        </.dm_card>
      <% end %>

      <%!-- Upstream List --%>
      <div :if={@upstreams == [] and @editing == nil} class="text-on-surface-variant">
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
                <.dm_btn size="xs" phx-click="edit" phx-value-id={upstream.id}>Edit</.dm_btn>
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
end
