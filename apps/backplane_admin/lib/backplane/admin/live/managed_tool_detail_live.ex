defmodule Backplane.Admin.ManagedToolDetailLive do
  @moduledoc """
  Detail page for a single managed service tool.

  Shows tool information, input schema, and a test runner to call
  the tool and display results.
  """

  use Backplane.Admin, :live_view

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
      description: "Fetch HTTP(S) pages, search the web, run live LLM web search, and search X"
    },
    %{
      module: Backplane.Services.Math,
      name: "Math",
      prefix: "math",
      description: "Evaluate math expressions with the native math engine"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/mcp/managed",
       loading: true,
       service: nil,
       tool: nil,
       schema_text: "{}",
       test_arguments: "{}",
       test_result: nil,
       test_error: nil,
       testing: false
     )}
  end

  @impl true
  def handle_params(%{"prefix" => prefix, "tool_name" => short_name}, _uri, socket) do
    full_name = "#{prefix}::#{short_name}"

    case find_service(prefix) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Unknown managed service: #{prefix}")
         |> push_navigate(to: ~p"/mcp/managed")}

      service ->
        case find_tool(service.module.tools(), full_name) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "Unknown tool: #{full_name}")
             |> push_navigate(to: ~p"/mcp/managed")}

          tool ->
            schema_text = format_value(Map.get(tool, :input_schema, %{}))

            {:noreply,
             assign(socket,
               loading: false,
               service: service,
               tool: tool,
               schema_text: schema_text,
               test_arguments: sample_arguments(full_name),
               current_path: "/mcp/managed/#{prefix}/tool/#{short_name}"
             )}
        end
    end
  end

  @impl true
  def handle_event("run_test", %{"test" => %{"arguments" => arguments}}, socket) do
    tool = socket.assigns.tool

    with {:ok, decoded} <- decode_arguments(arguments),
         {:ok, result} <- call_tool(tool, decoded) do
      {:noreply,
       assign(socket,
         test_arguments: arguments,
         test_result: format_value(result),
         test_error: nil,
         testing: false
       )}
    else
      {:error, message} ->
        {:noreply,
         assign(socket,
           test_arguments: arguments,
           test_result: nil,
           test_error: to_string(message),
           testing: false
         )}
    end
  end

  def handle_event("clear_result", _params, socket) do
    {:noreply, assign(socket, test_result: nil, test_error: nil)}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp find_service(prefix), do: Enum.find(@services, &(&1.prefix == prefix))

  defp find_tool(tools, full_name), do: Enum.find(tools, &(&1.name == full_name))

  defp decode_arguments(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, "Arguments must be a JSON object"}
      {:error, error} -> {:error, "Invalid JSON: #{Exception.message(error)}"}
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

  defp format_value(value) do
    Jason.encode!(value, pretty: true)
  rescue
    _ -> inspect(value, pretty: true, limit: :infinity)
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

  defp sample_arguments("web::live_search"),
    do: format_value(%{"query" => "latest Elixir release"})

  defp sample_arguments("web::x_search"),
    do: format_value(%{"query" => "What are people saying about xAI on X?"})

  defp sample_arguments("math::evaluate"), do: format_value(%{"expr" => "2 * (3 + 4)"})
  defp sample_arguments(_tool_name), do: "{}"

  defp schema_properties(tool) do
    tool
    |> Map.get(:input_schema, %{})
    |> Map.get("properties", %{})
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  defp schema_required(tool) do
    tool
    |> Map.get(:input_schema, %{})
    |> Map.get("required", [])
    |> MapSet.new()
  end

  defp property_type(prop) do
    type = prop["type"] || "any"

    cond do
      prop["enum"] ->
        "#{type} (#{Enum.join(prop["enum"], ", ")})"

      prop["format"] ->
        "#{type} (#{prop["format"]})"

      prop["minimum"] && prop["maximum"] ->
        "#{type} [#{prop["minimum"]}..#{prop["maximum"]}]"

      true ->
        type
    end
  end

  # ── Template ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6 flex items-center gap-3">
        <.dm_btn variant="link" size="sm" phx-click={JS.navigate(~p"/mcp/managed")}>
          &larr; Managed Services
        </.dm_btn>
        <div>
          <h1 class="text-2xl font-bold">{@tool.name}</h1>
          <p class="text-sm text-on-surface-variant">{@tool.description}</p>
        </div>
      </div>

      <div class="space-y-4">
        <%!-- Tool Info --%>
        <.dm_card variant="bordered">
          <:title>Tool Information</:title>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <h4 class="text-xs font-medium text-on-surface-variant mb-1">Full Name</h4>
              <code class="text-sm font-mono bg-surface-container-high px-2 py-1 rounded">{@tool.name}</code>
            </div>
            <div>
              <h4 class="text-xs font-medium text-on-surface-variant mb-1">Service</h4>
              <div class="flex items-center gap-2">
                <span class="text-sm">{@service.name}</span>
                <.dm_badge variant="ghost" size="sm">{@service.prefix}::</.dm_badge>
              </div>
            </div>
            <div class="md:col-span-2">
              <h4 class="text-xs font-medium text-on-surface-variant mb-1">Description</h4>
              <p class="text-sm">{@tool.description}</p>
            </div>
          </div>
        </.dm_card>

        <%!-- Input Schema --%>
        <.dm_card variant="bordered">
          <:title>Input Schema</:title>
          <div class="space-y-4">
            <%!-- Properties table --%>
            <div :if={schema_properties(@tool) != []} class="overflow-x-auto">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b border-outline-variant">
                    <th class="text-left py-2 pr-4 text-xs font-medium text-on-surface-variant">Parameter</th>
                    <th class="text-left py-2 pr-4 text-xs font-medium text-on-surface-variant">Type</th>
                    <th class="text-left py-2 pr-4 text-xs font-medium text-on-surface-variant">Required</th>
                    <th class="text-left py-2 text-xs font-medium text-on-surface-variant">Description</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={{name, prop} <- schema_properties(@tool)}
                    class="border-b border-outline-variant/40"
                  >
                    <td class="py-2 pr-4">
                      <code class="font-mono text-xs bg-surface-container-high px-1.5 py-0.5 rounded">{name}</code>
                    </td>
                    <td class="py-2 pr-4 text-xs text-on-surface-variant font-mono">{property_type(prop)}</td>
                    <td class="py-2 pr-4">
                      <.dm_badge
                        :if={MapSet.member?(schema_required(@tool), name)}
                        variant="warning"
                        size="sm"
                      >
                        required
                      </.dm_badge>
                      <span :if={not MapSet.member?(schema_required(@tool), name)} class="text-xs text-on-surface-variant">
                        optional
                      </span>
                    </td>
                    <td class="py-2 text-xs text-on-surface-variant">{prop["description"] || "—"}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Raw JSON schema --%>
            <details class="group">
              <summary class="cursor-pointer text-xs text-on-surface-variant hover:text-on-surface transition-colors">
                Raw JSON Schema ▸
              </summary>
              <pre class="mt-2 overflow-x-auto rounded-md bg-surface-container-high p-4 text-sm"><code>{@schema_text}</code></pre>
            </details>
          </div>
        </.dm_card>

        <%!-- Test Runner --%>
        <.dm_card variant="bordered">
          <:title>
            <div class="flex items-center justify-between w-full">
              <span>Test Tool</span>
              <.dm_tooltip :if={@test_result || @test_error} content="Clear results">
                <.dm_btn
                  size="xs"
                  shape="circle"
                  variant="ghost"
                  phx-click="clear_result"
                >
                  <.dm_mdi name="close" class="w-4 h-4" />
                </.dm_btn>
              </.dm_tooltip>
            </div>
          </:title>
          <form id="tool-test-form" phx-submit="run_test" class="space-y-4">
            <div>
              <label class="block text-xs font-medium text-on-surface-variant mb-1">
                Arguments (JSON)
              </label>
              <.dm_textarea
                id="tool-test-arguments"
                name="test[arguments]"
                rows={8}
                value={@test_arguments}
                class="font-mono"
              />
            </div>
            <.dm_btn type="submit" variant="primary">
              <.dm_mdi name="play" class="w-4 h-4 mr-1" /> Call Tool
            </.dm_btn>
          </form>
        </.dm_card>

        <%!-- Error Result --%>
        <.dm_card :if={@test_error} variant="bordered">
          <:title>
            <div class="flex items-center gap-2">
              <.dm_mdi name="alert-circle" class="w-5 h-5 text-error" />
              <span>Error</span>
            </div>
          </:title>
          <p class="text-sm text-error">{@test_error}</p>
        </.dm_card>

        <%!-- Success Result --%>
        <.dm_card :if={@test_result} variant="bordered">
          <:title>
            <div class="flex items-center gap-2">
              <.dm_mdi name="check-circle" class="w-5 h-5 text-success" />
              <span>Result</span>
            </div>
          </:title>
          <pre class="overflow-x-auto rounded-md bg-surface-container-high p-4 text-sm"><code>{@test_result}</code></pre>
        </.dm_card>
      </div>
    </div>
    """
  end
end
