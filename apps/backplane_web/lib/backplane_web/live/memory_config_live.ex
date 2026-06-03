defmodule BackplaneWeb.MemoryConfigLive do
  @moduledoc "Memory system configuration editor."

  use BackplaneWeb, :live_view

  alias Backplane.Embedding
  alias Backplane.LLM.ProviderModelSurface

  @settings_keys ~w(
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
    {:ok,
     socket
     |> assign(
       current_path: "/admin/memory/config",
       flash_msg: nil
     )
     |> assign_config()}
  end

  @impl true
  def handle_event("save", %{"config" => params}, socket) do
    results =
      Enum.map(params, fn {key, value} ->
        if key in @settings_keys do
          safe_call(fn -> Backplane.Settings.set(key, value) end, {:error, :unavailable})
        else
          :ok
        end
      end)

    if Enum.all?(results, &(&1 == :ok)) do
      {:noreply,
       socket
       |> put_flash(:info, "Settings saved.")
       |> assign_config()}
    else
      {:noreply, put_flash(socket, :error, "Some settings could not be saved.")}
    end
  end

  defp assign_config(socket) do
    values = load_settings()

    assign(socket,
      values: values,
      embedding_model_options: embedding_model_options(values["memory.embed_model"]),
      llm_model_options: llm_model_options(values["memory.llm_model"])
    )
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

  defp setting_control(assigns) do
    ~H"""
    <select
      :if={@key == "memory.embed_model"}
      name={"config[#{@key}]"}
      class="select select-bordered flex-1"
    >
      <option value="" selected={blank?(@value)}>(not set)</option>
      <option
        :for={{value, label} <- @embedding_model_options}
        value={value}
        selected={selected?(@value, value)}
      >
        {label}
      </option>
    </select>

    <select
      :if={@key == "memory.llm_model"}
      name={"config[#{@key}]"}
      class="select select-bordered flex-1"
    >
      <option value="" selected={blank?(@value)}>(not set)</option>
      <option
        :for={{value, label} <- @llm_model_options}
        value={value}
        selected={selected?(@value, value)}
      >
        {label}
      </option>
    </select>

    <input
      :if={text_setting?(@key)}
      type="text"
      name={"config[#{@key}]"}
      value={@value}
      placeholder="(not set)"
      class="dm-input flex-1"
    />
    """
  end

  defp embedding_model_options(current_value) do
    safe_call(
      fn ->
        Embedding.list_enabled_models()
        |> Enum.map(fn model ->
          id = Embedding.model_id(model)
          {id, model_label(model.display_name, id)}
        end)
        |> include_current_option(current_value)
      end,
      include_current_option([], current_value)
    )
  end

  defp llm_model_options(current_value) do
    safe_call(
      fn ->
        :openai
        |> ProviderModelSurface.list_enabled()
        |> Enum.map(fn surface ->
          model = surface.provider_model
          id = "#{model.provider.name}/#{model.model}"
          {id, model_label(model.display_name, id)}
        end)
        |> Enum.uniq_by(fn {id, _label} -> id end)
        |> Enum.sort_by(fn {id, _label} -> id end)
        |> include_current_option(current_value)
      end,
      include_current_option([], current_value)
    )
  end

  defp include_current_option(options, current_value) do
    current_value = current_value |> to_string() |> String.trim()

    cond do
      current_value == "" ->
        options

      Enum.any?(options, fn {value, _label} -> value == current_value end) ->
        options

      true ->
        [{current_value, "#{current_value} (unavailable)"} | options]
    end
  end

  defp model_label(display_name, id) when display_name in [nil, ""], do: id
  defp model_label(display_name, id), do: "#{display_name} (#{id})"

  defp selected?(current_value, option_value), do: to_string(current_value) == option_value
  defp blank?(value), do: value in [nil, ""]
  defp text_setting?(key), do: key not in ~w(memory.embed_model memory.llm_model)

  defp section_keys(:embedding),
    do: ~w(memory.embed_model)

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
              <.setting_control
                key={key}
                value={@values[key]}
                embedding_model_options={@embedding_model_options}
                llm_model_options={@llm_model_options}
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
