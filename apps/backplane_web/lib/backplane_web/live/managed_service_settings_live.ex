defmodule BackplaneWeb.ManagedServiceSettingsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Services.WebSearch
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
      module: Backplane.Services.WebFetch,
      name: "Web Fetch",
      prefix: "web",
      description: "Fetch HTTP(S) pages and convert them to Markdown"
    },
    %{
      module: Backplane.Services.WebSearch,
      name: "Web Search",
      prefix: "web_search",
      description: "Search the web with Ollama, MiniMax, Z.ai, or BigModel"
    },
    %{
      module: Backplane.Services.Math,
      name: "Math",
      prefix: "math",
      description: "Evaluate math expressions with the native math engine"
    }
  ]

  @search_backends [
    %{id: "ollama", label: "Ollama"},
    %{id: "minimax", label: "MiniMax"},
    %{id: "z_ai", label: "Z.ai"},
    %{id: "bigmodel", label: "BigModel"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/mcp/managed",
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
         |> push_navigate(to: ~p"/admin/mcp/managed")}

      service ->
        {:noreply,
         socket
         |> assign(service: service, current_path: "/admin/mcp/managed/#{prefix}")
         |> assign(active_tab: active_tab(params["tab"], service))
         |> load_settings()}
    end
  end

  @impl true
  def handle_event(
        "save",
        %{"settings" => params},
        %{assigns: %{service: %{prefix: "web_search"}}} = socket
      ) do
    case save_web_search_settings(params) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Web search settings saved")
         |> load_settings()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("debug_search", %{"debug" => params}, socket) do
    query = params["query"] |> to_string() |> String.trim()
    backend = params["backend"] || socket.assigns.default_backend

    with {:ok, backend} <- parse_search_backend(backend),
         {:ok, query} <- parse_debug_query(query),
         {:ok, result} <-
           WebSearch.handle_search(%{
             "query" => query,
             "backend" => backend,
             "max_results" => 5
           }) do
      {:noreply,
       assign(socket,
         debug_backend: backend,
         debug_query: query,
         debug_result: result,
         debug_result_text: nil,
         debug_error: nil
       )}
    else
      {:error, %{message: message}} ->
        {:noreply, assign_debug_error(socket, backend, query, message)}

      {:error, message} ->
        {:noreply, assign_debug_error(socket, backend, query, message)}
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

  defp maybe_load_web_search_settings(%{assigns: %{service: %{prefix: "web_search"}}} = socket) do
    configured_backend =
      Settings.get("services.web_search.default_backend")
      |> normalize_search_backend()

    default_backend =
      if configured_backend in search_backend_ids() do
        configured_backend
      else
        "ollama"
      end

    credentials = Credentials.list()
    credential_names = credentials |> Enum.map(& &1.name) |> MapSet.new()

    assign(socket,
      default_backend: default_backend,
      backend_options: search_backend_options(),
      debug_backend: socket.assigns[:debug_backend] || default_backend,
      backends:
        Enum.map(@search_backends, &load_search_backend(&1, credentials, credential_names))
    )
  end

  defp maybe_load_web_search_settings(socket), do: socket

  defp load_search_backend(backend, credentials, credential_names) do
    credential = configured_credential(backend.id) || ""
    exists? = credential != "" and MapSet.member?(credential_names, credential)

    backend
    |> Map.put(:configured_credential, credential)
    |> Map.put(:configured?, exists?)
    |> Map.put(:credential_options, credential_options(credentials, credential, exists?))
  end

  defp save_web_search_settings(params) do
    with {:ok, default_backend} <- parse_search_backend(params["default_backend"]),
         :ok <- Settings.set("services.web_search.default_backend", default_backend),
         :ok <- save_web_search_credentials(params["credentials"] || %{}) do
      :ok
    end
  end

  defp parse_search_backend(value) do
    backend = normalize_search_backend(value)

    if backend in search_backend_ids() do
      {:ok, backend}
    else
      {:error, "Choose a supported web search backend"}
    end
  end

  defp parse_debug_query(""), do: {:error, "Enter a search query"}
  defp parse_debug_query(query), do: {:ok, query}

  defp assign_debug_error(socket, backend, query, message) do
    assign(socket,
      debug_backend: normalize_search_backend(backend) || socket.assigns.default_backend,
      debug_query: query,
      debug_result: nil,
      debug_result_text: nil,
      debug_error: to_string(message)
    )
  end

  defp save_web_search_credentials(credentials) when is_map(credentials) do
    Enum.reduce_while(@search_backends, :ok, fn backend, :ok ->
      credential = normalize_credential(credentials[backend.id])

      cond do
        credential == "" ->
          case Settings.set("services.web_search.#{backend.id}.credential", nil) do
            :ok ->
              {:cont, :ok}

            {:error, _reason} ->
              {:halt, {:error, "Could not clear #{backend.label} credential setting"}}
          end

        Credentials.exists?(credential) ->
          case Settings.set("services.web_search.#{backend.id}.credential", credential) do
            :ok ->
              {:cont, :ok}

            {:error, _reason} ->
              {:halt, {:error, "Could not save #{backend.label} credential setting"}}
          end

        true ->
          {:halt, {:error, "#{backend.label} credential is not in the credential store"}}
      end
    end)
  end

  defp save_web_search_credentials(_credentials),
    do: {:error, "Credential settings were not submitted correctly"}

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
    |> case do
      "zai" -> "z_ai"
      "bigmodel_cn" -> "bigmodel"
      other -> other
    end
  end

  defp normalize_search_backend(_value), do: nil

  defp normalize_credential(value) when is_binary(value), do: String.trim(value)
  defp normalize_credential(_value), do: ""

  defp active_tab("settings", %{prefix: "web_search"}), do: "settings"
  defp active_tab("debug", _service), do: "debug"
  defp active_tab(_tab, %{prefix: "web_search"}), do: "settings"
  defp active_tab(_tab, _service), do: "debug"

  defp find_service(prefix), do: Enum.find(@services, &(&1.prefix == prefix))
  defp search_backend_ids, do: Enum.map(@search_backends, & &1.id)
  defp search_backend_options, do: Enum.map(@search_backends, &{&1.id, &1.label})
  defp search_results(%{"results" => results}) when is_list(results), do: results
  defp search_results(_result), do: []
  defp related_searches(%{"related_searches" => searches}) when is_list(searches), do: searches
  defp related_searches(_result), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex items-center gap-3">
        <.dm_btn variant="link" size="sm" phx-click={JS.navigate(~p"/admin/mcp/managed")}>
          &larr; Managed Services
        </.dm_btn>
        <div>
          <h1 class="text-2xl font-bold">{@service.name} Settings</h1>
          <p class="text-sm text-on-surface-variant">{@service.description}</p>
        </div>
      </div>

      <div class="tabs tabs-lifted mb-4" role="tablist">
        <.link
          :if={@service.prefix == "web_search"}
          patch={~p"/admin/mcp/managed/#{@service.prefix}?tab=settings"}
          class={["tab tab-lg", @active_tab == "settings" && "tab-active"]}
          role="tab"
          aria-selected={@active_tab == "settings"}
        >
          Settings
        </.link>
        <.link
          patch={~p"/admin/mcp/managed/#{@service.prefix}?tab=debug"}
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
        <:title>Default Backend</:title>
        <div class="max-w-md">
          <.dm_select
            id="web-search-default-backend"
            name="settings[default_backend]"
            label="Backend"
            options={@backend_options}
            value={@default_backend}
          />
        </div>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Backend Credentials</:title>
        <p class="mb-4 text-sm text-on-surface-variant">
          Add or rotate API keys in <.link
            navigate={~p"/admin/system/credentials"}
            class="text-primary underline"
          >System &gt; Credentials</.link>.
        </p>

        <div class="space-y-4">
          <div
            :for={backend <- @backends}
            class="grid grid-cols-1 gap-3 border-b border-outline-variant pb-4 last:border-b-0 last:pb-0 md:grid-cols-[minmax(0,1fr)_minmax(18rem,1fr)]"
          >
            <div>
              <div class="flex items-center gap-2">
                <h3 class="font-medium">{backend.label}</h3>
                <.dm_badge variant={if backend.configured?, do: "success", else: "ghost"}>
                  {if backend.configured?, do: "Configured", else: "No credential"}
                </.dm_badge>
              </div>
              <p class="mt-1 text-xs text-on-surface-variant">
                Current credential:
                <code>{if backend.configured_credential == "", do: "none", else: backend.configured_credential}</code>
              </p>
            </div>

            <.dm_select
              id={"web-search-credential-#{backend.id}"}
              name={"settings[credentials][#{backend.id}]"}
              label="Credential"
              options={backend.credential_options}
              value={backend.configured_credential}
            />
          </div>
        </div>
      </.dm_card>

      <div class="flex gap-2 pt-2">
        <.dm_btn type="submit" variant="primary">Save Settings</.dm_btn>
        <.link navigate={~p"/admin/mcp/managed"}>
          <.dm_btn type="button">Cancel</.dm_btn>
        </.link>
      </div>
    </form>
    """
  end

  defp render_debug_tab(%{service: %{prefix: "web_search"}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <.dm_card variant="bordered">
        <:title>Debug Search</:title>
        <form id="web-search-debug-form" phx-submit="debug_search" class="space-y-4">
          <div class="grid grid-cols-1 gap-4 md:grid-cols-[minmax(0,1fr)_14rem_auto]">
            <.dm_input
              id="web-search-debug-query"
              name="debug[query]"
              label="Query"
              value={@debug_query}
              placeholder="Search query"
              required
            />
            <.dm_select
              id="web-search-debug-backend"
              name="debug[backend]"
              label="Backend"
              options={@backend_options}
              value={@debug_backend}
            />
            <div class="flex items-end">
              <.dm_btn type="submit" variant="primary">Search</.dm_btn>
            </div>
          </div>
        </form>
      </.dm_card>

      <.render_tool_schema_docs {assigns} />
      <.render_web_search_results {assigns} />
    </div>
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

  defp render_web_search_results(assigns) do
    ~H"""
    <.dm_card :if={@debug_error} variant="bordered">
      <:title>Search Error</:title>
      <p class="text-sm text-error">{@debug_error}</p>
    </.dm_card>

    <.dm_card :if={@debug_result} variant="bordered">
      <:title>Results</:title>
      <div class="space-y-4">
        <div
          :for={result <- search_results(@debug_result)}
          class="border-b border-outline-variant pb-3 last:border-b-0 last:pb-0"
        >
          <a
            :if={result["url"] != ""}
            href={result["url"]}
            target="_blank"
            rel="noopener noreferrer"
            class="font-medium text-primary underline"
          >
            {result["title"]}
          </a>
          <h3 :if={result["url"] == ""} class="font-medium">{result["title"]}</h3>
          <p class="mt-1 text-sm text-on-surface-variant">{result["snippet"]}</p>
        </div>

        <div :if={related_searches(@debug_result) != []} class="border-t border-outline-variant pt-3">
          <h3 class="mb-2 text-sm font-medium">Related Searches</h3>
          <div class="flex flex-wrap gap-2">
            <.dm_badge :for={search <- related_searches(@debug_result)} variant="ghost">
              {search}
            </.dm_badge>
          </div>
        </div>
      </div>
    </.dm_card>
    """
  end
end
