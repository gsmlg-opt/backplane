defmodule Backplane.Admin.MemoryComponents do
  @moduledoc false

  use Backplane.Admin, :html

  attr(:title, :string, required: true)
  attr(:subtitle, :string, required: true)

  def memory_page_header(assigns) do
    ~H"""
    <header class="mb-6">
      <h1 class="text-2xl font-bold tracking-tight">{@title}</h1>
      <p class="mt-1 text-sm text-on-surface-variant">{@subtitle}</p>
    </header>
    """
  end

  attr(:result, :any, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  def memory_region(assigns) do
    {ok?, value} =
      case assigns.result do
        {:ok, value} -> {true, value}
        {:error, _reason} -> {false, nil}
      end

    assigns = assign(assigns, ok?: ok?, value: value)

    ~H"""
    <section aria-label={@title}>
      <div :if={@ok?}>{render_slot(@inner_block, @value)}</div>
      <.dm_alert :if={!@ok?} variant="error" title={@title} compact>
        Memory data is unavailable. Retry after checking the database connection.
      </.dm_alert>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:rollout, :map, required: true)

  def memory_empty_state(assigns) do
    # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#90
    ~H"""
    <.dm_card variant="bordered" padding="lg" class="text-center">
      <h2 class="text-lg font-semibold">{@title}</h2>
      <p class="mt-2 text-sm text-on-surface-variant">
        Pipeline is {if @rollout.pipeline.effective, do: "effective", else: "disabled"};
        Events is {if @rollout.events.effective, do: "effective", else: "disabled"}.
      </p>
      <div class="mt-4">
        <.memory_link_button
          id="memory-open-pipeline"
          navigate={~p"/memory/pipeline"}
          variant="primary"
        >
          Open Pipeline
        </.memory_link_button>
      </div>
    </.dm_card>
    """
  end

  attr(:id, :string, required: true)
  attr(:navigate, :string, default: nil)
  attr(:patch, :string, default: nil)
  attr(:replace, :boolean, default: false)
  attr(:variant, :string, default: nil, values: [nil, "primary", "ghost"])
  attr(:size, :string, default: nil, values: [nil, "sm"])
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def memory_link_button(assigns) do
    assigns =
      assign(assigns,
        button_class: [
          "btn",
          memory_link_variant_class(assigns.variant),
          memory_link_size_class(assigns.size),
          assigns.class
        ]
      )

    ~H"""
    <.link
      :if={is_binary(@navigate)}
      id={@id}
      navigate={@navigate}
      replace={@replace}
      class={@button_class}
    >
      {render_slot(@inner_block)}
    </.link>
    <.link
      :if={!is_binary(@navigate) && is_binary(@patch)}
      id={@id}
      patch={@patch}
      replace={@replace}
      class={@button_class}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr(:event_type, :string, required: true)

  def event_type_badge(assigns) do
    ~H"""
    <.dm_badge variant="info" size="sm" soft>
      <span class="font-mono">{@event_type}</span>
    </.dm_badge>
    """
  end

  attr(:status, :any, default: nil)

  def status_badge(assigns) do
    assigns = assign(assigns, :variant, status_variant(assigns.status))

    ~H"""
    <.dm_badge variant={@variant} size="sm" soft>
      {@status || "unknown"}
    </.dm_badge>
    """
  end

  attr(:gate, :map, required: true)

  def gate_state_badges(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <.dm_badge variant={if @gate.configured, do: "info", else: "neutral"} size="sm">
        {if @gate.configured, do: "Configured on", else: "Configured off"}
      </.dm_badge>
      <.dm_badge
        variant={
          cond do
            @gate.effective -> "success"
            @gate.blocked -> "warning"
            true -> "neutral"
          end
        }
        size="sm"
      >
        {cond do
          @gate.effective -> "Effective"
          @gate.blocked -> "Configured, blocked"
          true -> "Inactive"
        end}
      </.dm_badge>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)

  def identity_value(assigns) do
    ~H"""
    <dt class="text-sm font-medium text-on-surface-variant">{@label}</dt>
    <dd class="min-w-0 break-all font-mono text-sm">{@value || "—"}</dd>
    """
  end

  def format_datetime(nil), do: "—"
  def format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def format_datetime(value), do: to_string(value)

  def datetime_local_value(nil), do: ""

  def datetime_local_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:millisecond)
        |> NaiveDateTime.to_iso8601()

      _error ->
        ""
    end
  end

  def datetime_local_value(_value), do: ""

  def fix_dm_table_rowgroup_roles(table_id) do
    JS.set_attribute({"role", "rowgroup"}, to: "##{table_id} thead")
    |> JS.set_attribute({"role", "rowgroup"}, to: "##{table_id} tbody")
  end

  def format_json(payload), do: Jason.encode!(payload || %{}, pretty: true)

  def event_color(%{status: status}) when status in ["failed", "error"], do: "error"
  def event_color(%{status: status}) when status in ["completed", "success"], do: "success"
  def event_color(_event), do: "primary"

  defp memory_link_variant_class("primary"), do: "btn-primary"
  defp memory_link_variant_class("ghost"), do: "btn-ghost"
  defp memory_link_variant_class(nil), do: nil

  defp memory_link_size_class("sm"), do: "btn-sm"
  defp memory_link_size_class(nil), do: nil

  defp status_variant(status) when status in ["failed", "error"], do: "error"
  defp status_variant(status) when status in ["completed", "success"], do: "success"
  defp status_variant(nil), do: "neutral"
  defp status_variant(_status), do: "info"
end
