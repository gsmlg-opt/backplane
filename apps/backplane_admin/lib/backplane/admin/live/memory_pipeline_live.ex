defmodule Backplane.Admin.MemoryPipelineLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  alias Backplane.Memory.Operations

  @memory_setting_keys [
    "memory.pipeline.enabled",
    "memory.events.enabled",
    "memory.events.dual_write"
  ]

  @gate_names %{
    "pipeline" => :pipeline,
    "events" => :events,
    "dual_write" => :dual_write
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Operations.subscribe_rollout()

    {:ok,
     assign(socket,
       current_path: "/memory/pipeline",
       rollout: Operations.rollout_state(),
       mutation_error: nil,
       pending_dual_write: false
     )}
  end

  @impl true
  def handle_event(
        "set-gate",
        %{"gate" => %{"name" => "dual_write", "value" => "true"}},
        socket
      ) do
    {:noreply, assign(socket, pending_dual_write: true, mutation_error: nil)}
  end

  def handle_event("confirm-dual-write", _params, socket) do
    mutate_gate(socket, :dual_write, true)
  end

  def handle_event("cancel-dual-write", _params, socket) do
    {:noreply, assign(socket, pending_dual_write: false)}
  end

  def handle_event(
        "set-gate",
        %{"gate" => %{"name" => name, "value" => value}},
        socket
      )
      when is_map_key(@gate_names, name) and value in ["true", "false"] do
    mutate_gate(socket, Map.fetch!(@gate_names, name), value == "true")
  end

  def handle_event("set-gate", _params, socket) do
    {:noreply, assign(socket, mutation_error: "The submitted gate value is invalid.")}
  end

  @impl true
  def handle_info({:setting_changed, key, _value}, socket)
      when key in @memory_setting_keys do
    {:noreply, assign(socket, rollout: Operations.rollout_state())}
  end

  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-pipeline">
      <.memory_page_header
        title="Pipeline"
        subtitle="Guarded Memory V2 rollout controls"
      />

      <.dm_alert
        :if={@mutation_error}
        id="pipeline-mutation-error"
        variant="error"
        title="Rollout change not saved"
        compact
      >
        {@mutation_error}
      </.dm_alert>

      <section aria-labelledby="implemented-gates-heading">
        <h2 id="implemented-gates-heading" class="mb-3 text-lg font-semibold">
          Implemented gates
        </h2>

        <div class="grid gap-4 lg:grid-cols-3">
          <.gate_control
            form_id="pipeline-gate-form"
            input_id="pipeline-gate"
            name="pipeline"
            gate={@rollout.pipeline}
            disabled={pipeline_disabled?(@rollout)}
            helper="Master gate for Memory V2. Disable Events and Dual Write before turning it off."
          />

          <.gate_control
            form_id="events-gate-form"
            input_id="events-gate"
            name="events"
            gate={@rollout.events}
            disabled={events_disabled?(@rollout)}
            helper="Requires effective Pipeline. Disable Dual Write before turning Events off."
          />

          <.gate_control
            form_id="dual-write-gate-form"
            input_id="dual-write-gate"
            name="dual_write"
            gate={@rollout.dual_write}
            disabled={dual_write_disabled?(@rollout)}
            helper="Requires effective Events. Enabling requires confirmation."
          />
        </div>
      </section>

      <.dm_alert
        :if={@pending_dual_write}
        id="dual-write-confirmation"
        variant="warning"
        title="Enable Dual Write?"
        class="mt-4"
      >
        New writes will also enter the Memory V2 event pipeline.

        <div class="mt-3 flex flex-wrap gap-2">
          <.dm_btn
            id="confirm-dual-write"
            variant="warning"
            phx-click="confirm-dual-write"
            type="button"
          >
            Confirm
          </.dm_btn>
          <.dm_btn
            id="cancel-dual-write"
            variant="ghost"
            phx-click="cancel-dual-write"
            type="button"
          >
            Cancel
          </.dm_btn>
        </div>
      </.dm_alert>

      <section
        id="later-stages"
        aria-labelledby="later-stages-heading"
        class="mt-8"
      >
        <h2 id="later-stages-heading" class="mb-3 text-lg font-semibold">
          Later stages
        </h2>

        <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
          <.dm_card
            :for={stage <- @rollout.later}
            class="later-stage"
            variant="bordered"
            padding="sm"
          >
            <div class="flex items-start justify-between gap-2">
              <h3 class="font-medium">{stage.label}</h3>
              <.dm_badge variant="neutral" size="sm">Unavailable</.dm_badge>
            </div>
            <p class="mt-2 text-sm text-on-surface-variant">
              This stage has no production consumer.
            </p>
          </.dm_card>
        </div>
      </section>
    </div>
    """
  end

  attr(:form_id, :string, required: true)
  attr(:input_id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:gate, :map, required: true)
  attr(:disabled, :boolean, required: true)
  attr(:helper, :string, required: true)

  defp gate_control(assigns) do
    ~H"""
    <.dm_card variant="bordered" padding="sm">
      <.form id={@form_id} for={%{}} phx-change="set-gate">
        <input type="hidden" name="gate[name]" value={@name} />
        <.dm_switch
          id={@input_id}
          name="gate[value]"
          checked={@gate.configured}
          label={@gate.label}
          helper={@helper}
          horizontal
          disabled={@disabled}
        />
      </.form>

      <div class="mt-3">
        <.gate_state_badges gate={@gate} />
      </div>
    </.dm_card>
    """
  end

  defp mutate_gate(socket, gate, value) do
    result = Operations.set_gate(gate, value)
    rollout = Operations.rollout_state()

    case result do
      :ok ->
        {:noreply,
         assign(socket,
           rollout: rollout,
           mutation_error: nil,
           pending_dual_write: false
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           rollout: rollout,
           mutation_error: gate_error(reason),
           pending_dual_write: false
         )}
    end
  end

  defp pipeline_disabled?(rollout) do
    rollout.events.configured or rollout.dual_write.configured
  end

  defp events_disabled?(rollout) do
    if rollout.events.configured do
      rollout.dual_write.configured
    else
      not rollout.pipeline.effective or rollout.dual_write.configured
    end
  end

  defp dual_write_disabled?(rollout) do
    not rollout.dual_write.configured and not rollout.events.effective
  end

  defp gate_error({:dependency, :pipeline, true}), do: "Enable Pipeline first."
  defp gate_error({:dependency, :events, true}), do: "Enable Events first."
  defp gate_error({:dependency, :dual_write, false}), do: "Disable Dual Write first."
  defp gate_error({:blocked_descendant, :events}), do: "Disable Events first."
  defp gate_error({:blocked_descendant, :dual_write}), do: "Disable Dual Write first."
  defp gate_error(:invalid_gate), do: "The submitted gate is invalid."
  defp gate_error(:invalid_boolean), do: "The submitted gate value is invalid."
  defp gate_error(_reason), do: "The rollout setting could not be saved."
end
