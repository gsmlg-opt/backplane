defmodule Backplane.Admin.ManagedServiceSettingsLive do
  use Backplane.Admin, :live_view

  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  @services [
    %{
      module: Backplane.Services.Day,
      name: "Day",
      prefix: "day",
      description: "Date/time utilities"
    },
    %{
      module: Backplane.Services.Web,
      name: "Web",
      prefix: "web",
      description: "Fetch HTTP(S) pages, search the web, and search X"
    },
    %{
      module: Backplane.Services.Math,
      name: "Math",
      prefix: "math",
      description: "Evaluate math expressions with the native math engine"
    },
    %{
      module: Backplane.Services.Skills,
      name: "Skills",
      prefix: "skill",
      description: "Search, load, download, and publish archive-backed agent skills"
    }
  ]

  @search_backends [
    %{id: "exa", label: "Exa", default_enabled: true, base_url: "https://api.exa.ai"},
    %{id: "tavily", label: "Tavily", default_enabled: true, base_url: "https://api.tavily.com"},
    %{id: "ollama", label: "Ollama", default_enabled: false, base_url: "https://ollama.com"},
    %{
      id: "minimax",
      label: "MiniMax",
      default_enabled: false,
      base_url: "https://api.minimaxi.com"
    }
  ]
  @fetch_backends [%{id: "direct", label: "Direct"}, %{id: "firecrawl", label: "Firecrawl"}]
  @firecrawl_base_url "https://api.firecrawl.dev"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/mcp/managed",
       loading: true,
       active_tab: "debug",
       service: nil,
       tools: [],
       tool_options: [],
       debug_tool_name: nil,
       debug_arguments: "",
       debug_result_text: nil,
       debug_error: nil,
       debug_backend: nil,
       debug_query: "",
       debug_result: nil
     )}
  end

  @impl true
  def handle_params(%{"prefix" => prefix} = params, _uri, socket) do
    case find_service(prefix) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Unknown managed service: #{prefix}")
         |> push_navigate(to: ~p"/mcp/managed")}

      service ->
        {:noreply,
         socket
         |> assign(service: service, current_path: "/mcp/managed/#{prefix}")
         |> assign(active_tab: active_tab(params["tab"], service))
         |> load_settings()}
    end
  end

  @impl true
  def handle_event(
        "save",
        %{"settings" => params},
        %{assigns: %{service: %{prefix: "web"}}} = socket
      ) do
    case save_web_search_settings(params) do
      :ok ->
        Backplane.Admin.Audit.record("managed_service.update", "managed_service", "web")

        {:noreply,
         socket
         |> put_flash(:info, "Web settings saved")
         |> load_settings()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("select_debug_tool", %{"debug" => params}, socket) do
    tool_names = Enum.map(socket.assigns.tools, & &1.name)
    selected_name = selected_tool_name(params["tool_name"], tool_names)

    arguments =
      if selected_name == socket.assigns.debug_tool_name do
        params["arguments"] || socket.assigns.debug_arguments
      else
        sample_arguments(selected_name)
      end

    {:noreply,
     assign(socket,
       debug_tool_name: selected_name,
       debug_arguments: arguments
     )}
  end

  def handle_event("debug_tool", %{"debug" => params}, socket) do
    tool_name = params["tool_name"]
    arguments = params["arguments"] || "{}"

    with {:ok, tool} <- find_tool(socket.assigns.tools, tool_name),
         {:ok, decoded_arguments} <- decode_arguments(arguments),
         {:ok, result} <- call_tool(tool, decoded_arguments) do
      {:noreply,
       assign(socket,
         debug_tool_name: tool.name,
         debug_arguments: arguments,
         debug_result_text: format_value(result),
         debug_error: nil
       )}
    else
      {:error, message} ->
        {:noreply,
         assign(socket,
           debug_tool_name: tool_name,
           debug_arguments: arguments,
           debug_result_text: nil,
           debug_error: to_string(message)
         )}
    end
  end

  defp load_settings(%{assigns: %{service: service}} = socket) do
    tools = service.module.tools()
    tool_names = Enum.map(tools, & &1.name)
    debug_tool_name = selected_tool_name(socket.assigns[:debug_tool_name], tool_names)
    debug_arguments = debug_arguments_for_load(socket, debug_tool_name, tool_names)

    socket
    |> assign(
      loading: false,
      tools: tools,
      tool_options: Enum.map(tools, &{&1.name, &1.name}),
      debug_tool_name: debug_tool_name,
      debug_arguments: debug_arguments
    )
    |> maybe_load_web_search_settings()
  end

  defp maybe_load_web_search_settings(%{assigns: %{service: %{prefix: "web"}}} = socket) do
    configured_backend =
      Settings.get("services.web_search.default_backend")
      |> normalize_search_backend()

    default_backend =
      if configured_backend in search_backend_ids() do
        configured_backend
      else
        "exa"
      end

    credentials = Credentials.list()
    credential_names = credentials |> Enum.map(& &1.name) |> MapSet.new()
    x_search_credential = configured_x_search_credential() || ""
    firecrawl_credential = configured_setting("services.web_fetch.firecrawl.credential") || ""
    firecrawl_configured? = credential_exists?(firecrawl_credential, credential_names)

    x_search_configured? = credential_exists?(x_search_credential, credential_names)

    assign(socket,
      fetch_default_backend:
        configured_choice("services.web_fetch.default_backend", fetch_backend_ids(), "direct"),
      fetch_backend_options: Enum.map(@fetch_backends, &{&1.id, &1.label}),
      firecrawl_base_url:
        configured_setting("services.web_fetch.firecrawl.base_url") || @firecrawl_base_url,
      firecrawl_credential: firecrawl_credential,
      firecrawl_configured?: firecrawl_configured?,
      firecrawl_credential_options:
        credential_options(credentials, firecrawl_credential, firecrawl_configured?),
      default_backend: default_backend,
      backend_options: search_backend_options(),
      debug_backend: socket.assigns[:debug_backend] || default_backend,
      backends:
        Enum.map(@search_backends, &load_search_backend(&1, credentials, credential_names)),
      x_search_credential: x_search_credential,
      x_search_configured?: x_search_configured?,
      x_search_credential_options:
        credential_options(credentials, x_search_credential, x_search_configured?),
      x_search_model: configured_x_search_model()
    )
  end

  defp maybe_load_web_search_settings(socket), do: socket

  defp load_search_backend(backend, credentials, credential_names) do
    credential = configured_credential(backend.id) || ""
    exists? = credential_exists?(credential, credential_names)

    backend
    |> Map.put(:enabled, configured_backend_enabled?(backend))
    |> Map.put(
      :configured_base_url,
      configured_setting("services.web_search.#{backend.id}.base_url") || backend.base_url
    )
    |> Map.put(:configured_credential, credential)
    |> Map.put(:configured?, exists?)
    |> Map.put(:credential_options, credential_options(credentials, credential, exists?))
  end

  defp save_web_search_settings(params) do
    with {:ok, settings} <- validate_web_settings(params) do
      save_settings(settings)
    end
  end

  defp validate_web_settings(params) do
    with {:ok, fetch_settings} <- validate_fetch_settings(params["fetch"] || %{}),
         {:ok, default_backend} <- parse_search_backend(params["default_backend"]),
         {:ok, backend_settings} <- validate_search_backends(params["backends"] || %{}),
         :ok <- validate_default_backend_enabled(default_backend, backend_settings),
         {:ok, x_search_settings} <- validate_x_search_settings(params["x_search"] || %{}) do
      {:ok,
       fetch_settings ++
         [{"services.web_search.default_backend", default_backend}] ++
         backend_settings ++ x_search_settings}
    end
  end

  defp validate_fetch_settings(params) when is_map(params) do
    firecrawl = params["firecrawl"] || %{}

    with {:ok, default_backend} <-
           parse_choice(params["default_backend"], fetch_backend_ids(), "fetch"),
         {:ok, base_url} <- parse_base_url(firecrawl["base_url"], "Firecrawl"),
         {:ok, credential} <- parse_credential(firecrawl["credential"], "Firecrawl") do
      {:ok,
       [
         {"services.web_fetch.default_backend", default_backend},
         {"services.web_fetch.firecrawl.base_url", base_url},
         {"services.web_fetch.firecrawl.credential", credential}
       ]}
    end
  end

  defp validate_fetch_settings(_params),
    do: {:error, "Fetch settings were not submitted correctly"}

  defp parse_search_backend(value) do
    backend = normalize_search_backend(value)

    if backend in search_backend_ids() do
      {:ok, backend}
    else
      {:error, "Choose a supported web search backend"}
    end
  end

  defp validate_search_backends(params) when is_map(params) do
    Enum.reduce_while(@search_backends, {:ok, []}, fn backend, {:ok, settings} ->
      backend_params = params[backend.id] || %{}

      with {:ok, base_url} <- parse_base_url(backend_params["base_url"], backend.label),
           {:ok, credential} <- parse_credential(backend_params["credential"], backend.label) do
        backend_settings = [
          {"services.web_search.#{backend.id}.enabled", truthy?(backend_params["enabled"])},
          {"services.web_search.#{backend.id}.base_url", base_url},
          {"services.web_search.#{backend.id}.credential", credential}
        ]

        {:cont, {:ok, settings ++ backend_settings}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp validate_search_backends(_params),
    do: {:error, "Search backend settings were not submitted correctly"}

  defp validate_default_backend_enabled(default_backend, settings) do
    key = "services.web_search.#{default_backend}.enabled"

    enabled? =
      case List.keyfind(settings, key, 0) do
        {^key, value} -> value
        nil -> false
      end

    if enabled?,
      do: :ok,
      else: {:error, "The default web search backend must be enabled"}
  end

  defp validate_x_search_settings(params) when is_map(params) do
    with {:ok, credential} <- parse_credential(params["credential"], "xAI X Search") do
      model = empty_to_nil(params["model"])

      {:ok,
       [
         {"services.web_x_search.credential", credential},
         {"services.web_x_search.model", model}
       ]}
    end
  end

  defp validate_x_search_settings(_params),
    do: {:error, "X Search settings were not submitted correctly"}

  defp save_settings(settings) do
    Enum.reduce_while(settings, :ok, fn {key, value}, :ok ->
      case Settings.set(key, value) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, "Could not save web settings"}}
      end
    end)
  end

  defp parse_choice(value, choices, label) do
    normalized = normalize_search_backend(value)

    if normalized in choices,
      do: {:ok, normalized},
      else: {:error, "Choose a supported web #{label} backend"}
  end

  defp parse_base_url(value, label) do
    base_url = normalize_credential(value)

    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(base_url, "/")}

      _ ->
        {:error, "#{label} base URL must be an absolute HTTP(S) URL"}
    end
  end

  defp parse_credential(value, label) do
    credential = normalize_credential(value)

    cond do
      credential == "" -> {:ok, nil}
      Credentials.exists?(credential) -> {:ok, credential}
      true -> {:error, "#{label} credential is not in the credential store"}
    end
  end

  defp configured_choice(key, choices, fallback) do
    value = configured_setting(key)
    if value in choices, do: value, else: fallback
  end

  defp configured_setting(key) do
    case Settings.get(key) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> nil
    end
  end

  defp configured_backend_enabled?(backend) do
    case Settings.get("services.web_search.#{backend.id}.enabled") do
      nil -> backend.default_enabled
      true -> true
      _ -> false
    end
  end

  defp credential_exists?(credential, credential_names),
    do: credential != "" and MapSet.member?(credential_names, credential)

  defp truthy?(value), do: value in [true, "true", "on", "1"]

  defp empty_to_nil(value) do
    case normalize_credential(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp credential_options(credentials, selected, selected_exists?) do
    options =
      [{"", "Select a credential..."}] ++
        Enum.map(credentials, fn credential -> {credential.name, credential.name} end)

    if selected != "" and not selected_exists? do
      options ++ [{selected, "#{selected} (missing)"}]
    else
      options
    end
  end

  defp configured_credential(backend) do
    case Settings.get("services.web_search.#{backend}.credential") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp configured_x_search_credential do
    case Settings.get("services.web_x_search.credential") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp configured_x_search_model do
    case Settings.get("services.web_x_search.model") do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> "grok-4.3"
    end
  end

  defp find_tool(tools, tool_name) do
    case Enum.find(tools, &(&1.name == tool_name)) do
      nil -> {:error, "Choose a managed tool"}
      tool -> {:ok, tool}
    end
  end

  defp decode_arguments(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, "Arguments must be a JSON object"}
      {:error, error} -> {:error, "Invalid JSON arguments: #{Exception.message(error)}"}
    end
  end

  defp call_tool(%{handler: handler}, arguments) when is_function(handler, 1) do
    case handler.(arguments) do
      {:ok, result} -> {:ok, result}
      {:error, %{message: message}} -> {:error, message}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:ok, other}
    end
  end

  defp selected_tool_name(current, tool_names) do
    cond do
      current in tool_names -> current
      tool_names != [] -> List.first(tool_names)
      true -> nil
    end
  end

  defp debug_arguments_for_load(socket, debug_tool_name, tool_names) do
    if socket.assigns[:debug_tool_name] in tool_names and
         is_binary(socket.assigns[:debug_arguments]) do
      socket.assigns.debug_arguments
    else
      sample_arguments(debug_tool_name)
    end
  end

  defp selected_tool(tools, tool_name) do
    Enum.find(tools, &(&1.name == tool_name)) || List.first(tools)
  end

  defp tool_schema_text(nil), do: "{}"

  defp tool_schema_text(tool) do
    tool
    |> Map.get(:input_schema, %{})
    |> format_value()
  end

  defp sample_arguments("day::now"), do: format_value(%{"timezone" => "Etc/UTC"})

  defp sample_arguments("day::format"),
    do:
      format_value(%{
        "datetime" => "2026-05-11T00:00:00Z",
        "format" => "YYYY-MM-DD",
        "timezone" => "Etc/UTC"
      })

  defp sample_arguments("day::parse"), do: format_value(%{"input" => "2026-05-11T00:00:00Z"})

  defp sample_arguments("day::diff"),
    do:
      format_value(%{
        "from" => "2026-05-11T00:00:00Z",
        "to" => "2026-05-12T00:00:00Z",
        "unit" => "day"
      })

  defp sample_arguments("web::fetch"), do: format_value(%{"url" => "https://example.com"})

  defp sample_arguments("web::search"),
    do: format_value(%{"query" => "elixir programming language", "max_results" => 5})

  defp sample_arguments("web::x_search"),
    do: format_value(%{"query" => "What are people saying about xAI on X?"})

  defp sample_arguments("math::evaluate"), do: format_value(%{"expr" => "2 * (3 + 4)"})
  defp sample_arguments(_tool_name), do: "{}"

  defp format_value(value) do
    Jason.encode!(value, pretty: true)
  rescue
    _ -> inspect(value, pretty: true, limit: :infinity)
  end

  defp normalize_search_backend(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_search_backend(_value), do: nil

  defp normalize_credential(value) when is_binary(value), do: String.trim(value)
  defp normalize_credential(_value), do: ""

  defp active_tab("settings", %{prefix: "web"}), do: "settings"
  defp active_tab("debug", _service), do: "debug"
  defp active_tab(_tab, %{prefix: "web"}), do: "settings"
  defp active_tab(_tab, _service), do: "debug"

  defp find_service(prefix), do: Enum.find(@services, &(&1.prefix == prefix))
  defp fetch_backend_ids, do: Enum.map(@fetch_backends, & &1.id)
  defp search_backend_ids, do: Enum.map(@search_backends, & &1.id)
  defp search_backend_options, do: Enum.map(@search_backends, &{&1.id, &1.label})

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex items-center gap-3">
        <.dm_btn variant="link" size="sm" phx-click={JS.navigate(~p"/mcp/managed")}>
          &larr; Managed Services
        </.dm_btn>
        <div>
          <h1 class="text-2xl font-bold">{@service.name} Settings</h1>
          <p class="text-sm text-on-surface-variant">{@service.description}</p>
        </div>
      </div>

      <div class="tabs tabs-lifted mb-4" role="tablist">
        <.link
          :if={@service.prefix == "web"}
          patch={~p"/mcp/managed/#{@service.prefix}?tab=settings"}
          class={["tab tab-lg", @active_tab == "settings" && "tab-active"]}
          role="tab"
          aria-selected={@active_tab == "settings"}
        >
          Settings
        </.link>
        <.link
          patch={~p"/mcp/managed/#{@service.prefix}?tab=debug"}
          class={["tab tab-lg", @active_tab == "debug" && "tab-active"]}
          role="tab"
          aria-selected={@active_tab == "debug"}
        >
          Debug
        </.link>
      </div>

      <.render_web_search_settings_tab :if={@active_tab == "settings"} {assigns} />
      <.render_debug_tab :if={@active_tab == "debug"} {assigns} />
    </div>
    """
  end

  defp render_web_search_settings_tab(assigns) do
    ~H"""
    <form id="web-search-settings-form" phx-submit="save" class="space-y-4">
      <.dm_card variant="bordered">
        <:title>Fetch Backend</:title>
        <div class="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <.dm_select
            id="web-fetch-default-backend"
            name="settings[fetch][default_backend]"
            label="Default Backend"
            options={@fetch_backend_options}
            value={@fetch_default_backend}
          />
          <.dm_input
            id="web-fetch-firecrawl-base-url"
            name="settings[fetch][firecrawl][base_url]"
            label="Firecrawl Base URL"
            value={@firecrawl_base_url}
          />
          <.dm_select
            id="web-fetch-firecrawl-credential"
            name="settings[fetch][firecrawl][credential]"
            label="Firecrawl Credential"
            options={@firecrawl_credential_options}
            value={@firecrawl_credential}
          />
        </div>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Search Backends</:title>
        <p class="mb-4 text-sm text-on-surface-variant">
          Exa and Tavily provide advanced search. Ollama and MiniMax are disabled-by-default backup backends.
          Add or rotate API keys in <.link
            navigate={~p"/system/credentials"}
            class="text-primary underline"
          >System &gt; Credentials</.link>.
        </p>

        <div class="mb-4 max-w-md">
          <.dm_select
            id="web-search-default-backend"
            name="settings[default_backend]"
            label="Default Backend"
            options={@backend_options}
            value={@default_backend}
          />
        </div>

        <div class="space-y-5">
          <div
            :for={backend <- @backends}
            class="grid grid-cols-1 gap-3 border-b border-outline-variant pb-5 last:border-b-0 last:pb-0 lg:grid-cols-[12rem_minmax(16rem,1fr)_minmax(16rem,1fr)]"
          >
            <div>
              <div class="flex items-center gap-2">
                <label class="flex items-center gap-2 font-medium">
                  <input
                    type="checkbox"
                    name={"settings[backends][#{backend.id}][enabled]"}
                    value="true"
                    checked={backend.enabled}
                    class="checkbox checkbox-sm checkbox-primary"
                  />
                  {backend.label}
                </label>
                <.dm_badge variant={if backend.configured?, do: "success", else: "ghost"}>
                  {if backend.configured?, do: "Configured", else: "No credential"}
                </.dm_badge>
              </div>
            </div>

            <.dm_input
              id={"web-search-base-url-#{backend.id}"}
              name={"settings[backends][#{backend.id}][base_url]"}
              label="Base URL"
              value={backend.configured_base_url}
            />
            <.dm_select
              id={"web-search-credential-#{backend.id}"}
              name={"settings[backends][#{backend.id}][credential]"}
              label="Credential"
              options={backend.credential_options}
              value={backend.configured_credential}
            />
          </div>
        </div>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>X Search</:title>
        <p class="mb-4 text-sm text-on-surface-variant">
          Uses xAI Grok's built-in X Search tool. Select a plain xAI API key credential or a Grok OAuth credential from
          <.link navigate={~p"/system/credentials"} class="text-primary underline">
            System &gt; Credentials
          </.link>.
        </p>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <div>
            <div class="mb-2 flex items-center gap-2">
              <h3 class="font-medium">xAI Credential</h3>
              <.dm_badge variant={if @x_search_configured?, do: "success", else: "ghost"}>
                {if @x_search_configured?, do: "Configured", else: "No credential"}
              </.dm_badge>
            </div>
            <.dm_select
              id="web-x-search-credential"
              name="settings[x_search][credential]"
              label="xAI Credential"
              options={@x_search_credential_options}
              value={@x_search_credential}
            />
          </div>

          <.dm_input
            id="web-x-search-model"
            name="settings[x_search][model]"
            label="Model"
            value={@x_search_model}
            placeholder="grok-4.3"
          />
        </div>
      </.dm_card>

      <div class="flex gap-2 pt-2">
        <.dm_btn type="submit" variant="primary">Save Settings</.dm_btn>
        <.link navigate={~p"/mcp/managed"}>
          <.dm_btn type="button">Cancel</.dm_btn>
        </.link>
      </div>
    </form>
    """
  end

  defp render_debug_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <.dm_card variant="bordered">
        <:title>{@service.name} Debug</:title>
        <form
          id="managed-tool-debug-form"
          phx-change="select_debug_tool"
          phx-submit="debug_tool"
          class="space-y-4"
        >
          <div class="grid grid-cols-1 gap-4 lg:grid-cols-[minmax(16rem,22rem)_minmax(0,1fr)]">
            <.dm_select
              id="managed-tool-debug-name"
              name="debug[tool_name]"
              label="Tool"
              options={@tool_options}
              value={@debug_tool_name}
            />
            <.dm_textarea
              id="managed-tool-debug-arguments"
              name="debug[arguments]"
              label="Arguments JSON"
              rows={8}
              value={@debug_arguments}
              class="font-mono"
            />
          </div>

          <.dm_btn type="submit" variant="primary">Call Tool</.dm_btn>
        </form>
      </.dm_card>

      <.render_tool_schema_docs {assigns} />

      <.dm_card :if={@debug_error} variant="bordered">
        <:title>Tool Error</:title>
        <p class="text-sm text-error">{@debug_error}</p>
      </.dm_card>

      <.dm_card :if={@debug_result_text} variant="bordered">
        <:title>Tool Result</:title>
        <pre class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-sm"><code>{@debug_result_text}</code></pre>
      </.dm_card>
    </div>
    """
  end

  defp render_tool_schema_docs(assigns) do
    tool = selected_tool(assigns.tools, assigns.debug_tool_name)

    assigns =
      assigns
      |> assign(:schema_tool, tool)
      |> assign(:schema_text, tool_schema_text(tool))

    ~H"""
    <.dm_card :if={@schema_tool} variant="bordered">
      <:title>JSON Argument Schema</:title>
      <div class="grid grid-cols-1 gap-4 lg:grid-cols-[minmax(16rem,22rem)_minmax(0,1fr)]">
        <div>
          <h3 class="font-medium">{@schema_tool.name}</h3>
          <p class="mt-1 text-sm text-on-surface-variant">{@schema_tool.description}</p>
          <p class="mt-3 text-xs text-on-surface-variant">
            Arguments must be a JSON object matching this schema.
          </p>
        </div>
        <pre class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-sm"><code>{@schema_text}</code></pre>
      </div>
    </.dm_card>
    """
  end
end
