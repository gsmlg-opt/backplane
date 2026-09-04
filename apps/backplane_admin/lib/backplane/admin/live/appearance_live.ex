defmodule Backplane.Admin.AppearanceLive do
  use Backplane.Admin, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Appearance",
       current_path: "/system/appearance"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold tracking-tight text-on-surface">Appearance</h1>
        <p class="mt-1 text-sm text-on-surface-variant">
          Choose system theme preference: automatic, light, or dark.
        </p>
      </div>

      <div>
        <div
          id="appearance-theme-switcher"
          class="segment-control"
          role="radiogroup"
          aria-label="Theme preference"
          phx-hook="ThemeSegmentControl"
        >
          <button
            type="button"
            role="radio"
            aria-checked="false"
            class="segment-item"
            data-theme-value="default"
          >
            <.dm_bsi name="display" class="segment-icon" />
            <span>Auto</span>
          </button>
          <button
            type="button"
            role="radio"
            aria-checked="false"
            class="segment-item"
            data-theme-value="sunshine"
          >
            <.dm_bsi name="sun" class="segment-icon" />
            <span>Light</span>
          </button>
          <button
            type="button"
            role="radio"
            aria-checked="false"
            class="segment-item"
            data-theme-value="moonlight"
          >
            <.dm_bsi name="moon" class="segment-icon" />
            <span>Dark</span>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
