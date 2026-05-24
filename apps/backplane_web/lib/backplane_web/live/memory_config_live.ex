defmodule BackplaneWeb.MemoryConfigLive do
  @moduledoc "Memory system configuration editor."

  use BackplaneWeb, :live_view

  @settings_keys ~w(
    memory.embed_enabled
    memory.embed_model
    memory.graph_enabled
    memory.graph_min_observations
    memory.llm_model
    memory.inject_context
    memory.context_budget
    memory.tools
    memory.reflect_enabled
    memory.eviction_enabled
    memory.eviction_threshold
    memory.eviction_decay_days
    memory.circuit_breaker_enabled
    memory.circuit_breaker_max_fails
  )

  @impl true
  def mount(_params, _session, socket) do
    values = load_settings()

    {:ok,
     assign(socket,
       current_path: "/admin/memory/config",
       values: values,
       flash_msg: nil
     )}
  end

  @impl true
  def handle_event("save", %{"config" => params}, socket) do
    results =
      Enum.map(params, fn {key, value} ->
        if key in @settings_keys do
          safe_call(fn -> Backplane.Settings.put(key, value) end, {:error, :unavailable})
        else
          :ok
        end
      end)

    if Enum.all?(results, &(&1 == :ok)) do
      {:noreply,
       socket
       |> put_flash(:info, "Settings saved.")
       |> assign(values: load_settings())}
    else
      {:noreply, put_flash(socket, :error, "Some settings could not be saved.")}
    end
  end

  defp load_settings do
    Map.new(@settings_keys, fn key ->
      {key, safe_call(fn -> Backplane.Settings.get(key) end, nil)}
    end)
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp setting_label(key) do
    key
    |> String.split(".")
    |> List.last()
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp section_keys(:embedding),
    do: ~w(memory.embed_enabled memory.embed_model)

  defp section_keys(:graph),
    do: ~w(memory.graph_enabled memory.graph_min_observations)

  defp section_keys(:llm),
    do: ~w(memory.llm_model)

  defp section_keys(:context),
    do: ~w(memory.inject_context memory.context_budget)

  defp section_keys(:tools),
    do: ~w(memory.tools memory.reflect_enabled)

  defp section_keys(:eviction),
    do: ~w(memory.eviction_enabled memory.eviction_threshold memory.eviction_decay_days)

  defp section_keys(:circuit_breaker),
    do: ~w(memory.circuit_breaker_enabled memory.circuit_breaker_max_fails)

  @sections [
    {:embedding, "Embedding"},
    {:graph, "Graph"},
    {:llm, "LLM"},
    {:context, "Context Injection"},
    {:tools, "Tools & Reflection"},
    {:eviction, "Eviction"},
    {:circuit_breaker, "Circuit Breaker"}
  ]

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :sections, @sections)

    ~H"""
    <div>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Memory Config</h1>
        <p class="text-sm text-on-surface-variant mt-1">
          Configure the agent memory system settings.
        </p>
      </div>

      <.form for={%{}} as={:config} phx-submit="save" class="space-y-4">
        <.dm_card :for={{section_id, section_label} <- @sections} variant="bordered">
          <:title>{section_label}</:title>
          <div class="space-y-3">
            <div :for={key <- section_keys(section_id)} class="flex items-center gap-3">
              <label class="w-56 text-sm font-medium shrink-0">{setting_label(key)}</label>
              <input
                type="text"
                name={"config[#{key}]"}
                value={@values[key]}
                placeholder="(not set)"
                class="dm-input flex-1"
              />
            </div>
          </div>
        </.dm_card>

        <div class="flex justify-end">
          <.dm_btn type="submit">Save Settings</.dm_btn>
        </div>
      </.form>
    </div>
    """
  end
end
