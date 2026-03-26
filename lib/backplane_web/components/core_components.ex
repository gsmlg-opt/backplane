defmodule BackplaneWeb.CoreComponents do
  @moduledoc """
  Core UI components for the Backplane admin interface.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr(:href, :string, required: true)
  attr(:current, :boolean, default: false)
  slot(:inner_block, required: true)

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "rounded-md px-3 py-2 text-sm font-medium",
        if(@current,
          do: "bg-gray-800 text-white",
          else: "text-gray-300 hover:bg-gray-800 hover:text-white"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <.flash kind={:info} flash={@flash} />
    <.flash kind={:error} flash={@flash} />
    """
  end

  attr(:kind, :atom, required: true)
  attr(:flash, :map, required: true)
  attr(:rest, :global)

  def flash(assigns) do
    assigns = assign(assigns, :message, Phoenix.Flash.get(assigns.flash, assigns.kind))

    ~H"""
    <div
      :if={@message}
      class={[
        "fixed top-4 right-4 z-50 rounded-lg p-4 text-sm shadow-lg max-w-md",
        @kind == :info && "bg-emerald-900/80 text-emerald-200 border border-emerald-700",
        @kind == :error && "bg-red-900/80 text-red-200 border border-red-700"
      ]}
      role="alert"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide()}
    >
      <p>{@message}</p>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:class, :string, default: "")

  def stat_card(assigns) do
    ~H"""
    <div class={["bg-gray-900 border border-gray-800 rounded-lg p-6", @class]}>
      <dt class="text-sm font-medium text-gray-400">{@label}</dt>
      <dd class="mt-1 text-3xl font-semibold text-white">{@value}</dd>
    </div>
    """
  end

  attr(:status, :atom, required: true)

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
      @status == :connected && "bg-emerald-900/50 text-emerald-300",
      @status == :degraded && "bg-yellow-900/50 text-yellow-300",
      @status == :disconnected && "bg-red-900/50 text-red-300",
      @status == :ok && "bg-emerald-900/50 text-emerald-300",
      @status == :error && "bg-red-900/50 text-red-300"
    ]}>
      <span class={[
        "mr-1.5 h-2 w-2 rounded-full",
        @status == :connected && "bg-emerald-400",
        @status == :degraded && "bg-yellow-400",
        @status == :disconnected && "bg-red-400",
        @status == :ok && "bg-emerald-400",
        @status == :error && "bg-red-400"
      ]}>
      </span>
      {@status |> to_string() |> String.capitalize()}
    </span>
    """
  end
end
