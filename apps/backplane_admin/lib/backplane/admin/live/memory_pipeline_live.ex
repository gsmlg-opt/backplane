defmodule Backplane.Admin.MemoryPipelineLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  import Backplane.Admin.MemoryOperatorComponents,
    only: [browse_scope: 1, partition_query: 1, selection_query: 1, page: 1, record_partition: 2]

  alias Backplane.Memory.Operations
  alias Backplane.Memory.Operations.Inventory

  @memory_setting_keys [
    "memory.pipeline.enabled",
    "memory.window_summaries.enabled",
    "memory.session_summary.enabled",
    "memory.fact_extraction.enabled",
    "memory.procedure_extraction.enabled",
    "memory.llm_model"
  ]

  @gate_names %{
    "pipeline" => :pipeline
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Operations.subscribe_rollout()

    {:ok,
     assign(socket,
       current_path: "/memory/pipeline",
       rollout: Operations.rollout_state(),
       mutation_error: nil,
       partition: nil,
       stage_rows: [],
       stage_total: 0,
       stage_offset: 0,
       stage_next_offset: nil,
       stage_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case Operations.get_rollout_state() do
        rollout when is_map(rollout) -> assign(socket, rollout: rollout)
        {:error, _} -> socket
      end

    partition = browse_scope(params)
    offset = page(params["offset"])
    result = Inventory.stages(partition, limit: 50, offset: offset)

    case result do
      {:ok, page} ->
        {:noreply,
         assign(socket,
           partition: partition,
           stage_rows: page.entries,
           stage_total: page.total,
           stage_offset: offset,
           stage_next_offset: page.next_offset,
           stage_error: nil
         )}

      {:error, _} ->
        {:noreply,
         assign(socket,
           partition: partition,
           stage_rows: [],
           stage_error: "Processing states could not be loaded. Refresh will retry."
         )}
    end
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/memory/pipeline?#{selection_query(raw)}")}

  @impl true
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
    case Operations.get_rollout_state() do
      rollout when is_map(rollout) ->
        {:noreply, assign(socket, rollout: rollout)}

      {:error, _reason} ->
        {:noreply, assign(socket, mutation_error: "The processing setting could not be saved.")}
    end
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
        subtitle="Background processing and canonical memory state"
      />

      <.dm_alert
        :if={@mutation_error}
        id="pipeline-mutation-error"
        variant="error"
        title="Processing change not saved"
        compact
      >
        {@mutation_error}
      </.dm_alert>

      <section aria-labelledby="processing-controls-heading">
        <h2 id="processing-controls-heading" class="mb-3 text-lg font-semibold">
          Background processing
        </h2>
        <.gate_control
          form_id="pipeline-gate-form"
          input_id="pipeline-gate"
          name="pipeline"
          gate={@rollout.pipeline}
          disabled={false}
          helper="Pause or resume derived summaries and extraction. Memory capture and recall remain available."
        />
      </section>

      <section
        id="later-stages"
        aria-labelledby="later-stages-heading"
        class="mt-8"
      >
        <h2 id="later-stages-heading" class="mb-3 text-lg font-semibold">
          Processing stages
        </h2>

        <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <.dm_card
            :for={stage <- @rollout.later}
            id={"stage-#{stage.gate}"}
            class="later-stage"
            variant="bordered"
            padding="sm"
          >
            <div class="flex items-start justify-between gap-2">
              <h3 class="font-medium">{stage.label}</h3>
              <.dm_badge variant={if stage.effective, do: "success", else: "neutral"} size="sm">{stage_status(stage)}</.dm_badge>
            </div>
            <p class="mt-2 text-sm text-on-surface-variant">
              {stage_reason(stage)}
            </p>
          </.dm_card>
        </div>
      </section>

      <section class="mt-8" aria-label="Processing states">
        <div :if={@partition}>
          <h2 class="mb-3 text-lg font-semibold">Processing states</h2>
          <p id="pipeline-state-limit" class="mb-3 text-sm text-on-surface-variant">{@stage_total} matching processing states. Showing up to 50 per page. Open a source session to inspect artifacts and consolidate / retry.</p>
          <.dm_alert :if={@stage_error} id="pipeline-states-error" variant="error" title="Processing unavailable">{@stage_error}</.dm_alert>
          <.dm_card :if={!@stage_error && @stage_rows == []} id="pipeline-states-empty" variant="bordered" padding="lg">No processing states match.</.dm_card>
          <div :if={@stage_rows != []} class="overflow-x-auto">
            <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#91 --%>
            <.dm_table id="pipeline-states" data={@stage_rows} compact hover zebra class="min-w-[60rem]" phx-mounted={fix_dm_table_rowgroup_roles("pipeline-states")}>
              <:col :let={row} label="Stage"><span id={"pipeline-state-#{row.id}"}>{row.projector}</span></:col>
              <:col :let={row} label="Subject"><span class="block text-xs text-on-surface-variant">{row.subject_type}</span><code class="break-all text-xs">{row.subject_id}</code></:col>
              <:col :let={row} label="Status"><.status_badge status={row.status} /></:col>
              <:col :let={row} label="Source revision"><code class="break-all text-xs">{row.input_revision || "—"}</code></:col>
              <:col :let={row} label="Output revision"><code class="break-all text-xs">{row.output_revision || "—"}</code></:col>
              <:col :let={row} label="Attempts">{row.attempt_count}</:col>
              <:col :let={row} label="Reason / recovery">
                <p class="text-sm">{row.reason}</p>
                <.link :if={row.session_id} navigate={~p"/memory/sessions/#{row.session_id}?#{partition_query(record_partition(row, @partition))}"} class="text-primary underline">Inspect / retry</.link>
              </:col>
            </.dm_table>
          </div>
          <nav class="mt-3 flex gap-3" aria-label="Processing state pagination">
            <.link :if={@stage_offset > 0} patch={~p"/memory/pipeline?#{Map.put(partition_query(@partition), "offset", max(0, @stage_offset - 50))}"}>Previous</.link>
            <.link :if={@stage_next_offset} patch={~p"/memory/pipeline?#{Map.put(partition_query(@partition), "offset", @stage_next_offset)}"}>Next</.link>
          </nav>
        </div>
      </section>
    </div>
    """
  end

  defp stage_status(%{available: false}), do: "Unavailable"
  defp stage_status(%{effective: true}), do: "Enabled"
  defp stage_status(%{blocked: true}), do: "Blocked"
  defp stage_status(_stage), do: "Disabled"

  defp stage_reason(%{available: false}), do: "This capability is unavailable."
  defp stage_reason(%{reason: "pipeline_disabled"}), do: "Enable Pipeline to process new work."
  defp stage_reason(%{reason: "no_model"}), do: "Select a Memory LLM model in Config."
  defp stage_reason(%{effective: true}), do: "Configured and effective for new work."
  defp stage_reason(_stage), do: "Disabled for new work; stored results remain inspectable."

  attr(:form_id, :string, required: true)
  attr(:input_id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:gate, :map, required: true)
  attr(:disabled, :boolean, required: true)
  attr(:helper, :string, required: true)

  defp gate_control(assigns) do
    ~H"""
    <.dm_card variant="bordered" padding="sm">
      <.form
        id={@form_id}
        for={%{}}
        phx-change="set-gate"
        phx-auto-recover="ignore"
      >
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
    mutation_error =
      case Operations.set_gate(gate, value) do
        :ok ->
          Backplane.Admin.Audit.record("memory_pipeline.update", "memory_pipeline")
          nil

        {:error, reason} ->
          gate_error(reason)
      end

    case Operations.get_rollout_state() do
      rollout when is_map(rollout) ->
        {:noreply,
         assign(socket,
           rollout: rollout,
           mutation_error: mutation_error
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           mutation_error: mutation_error || "The processing setting could not be saved."
         )}
    end
  end

  defp gate_error(:invalid_gate), do: "The submitted gate is invalid."
  defp gate_error(:invalid_boolean), do: "The submitted gate value is invalid."
  defp gate_error(_reason), do: "The processing setting could not be saved."
end
