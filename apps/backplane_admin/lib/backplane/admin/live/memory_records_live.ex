defmodule Backplane.Admin.MemoryRecordsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_blank_state: 1, memory_page_header: 1]

  alias Backplane.Memory.Records

  @kinds ~w(fact procedure worklog note)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(current_path: "/memory/records", kinds: @kinds)
     |> assign(form: %{"q" => "", "host_id" => "", "agent_id" => "", "kind" => "", "since" => ""})
     |> assign(include_inactive: false, selected: nil, records: [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  @impl true
  def handle_event("search", params, socket) do
    form = Map.take(params, ["q", "host_id", "agent_id", "kind", "since"])

    {:noreply,
     socket
     |> assign(form: Map.merge(socket.assigns.form, form))
     |> assign(include_inactive: params["include_inactive"] in ["true", "on"], selected: nil)
     |> load()}
  end

  def handle_event("select", %{"id" => id}, socket) do
    case Records.get(id) do
      {:ok, detail} -> {:noreply, assign(socket, selected: detail)}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "Record not found")}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, selected: nil)}

  def handle_event("forget", %{"record_id" => id, "reason" => reason}, socket) do
    reason = String.trim(reason)

    if reason == "" do
      {:noreply, put_flash(socket, :error, "A reason is required to forget a record")}
    else
      case Records.forget(id, reason) do
        {:ok, _record} ->
          {:noreply, socket |> put_flash(:info, "Record forgotten") |> assign(selected: nil) |> load()}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Record not found")}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, "Record could not be forgotten")}
      end
    end
  end

  defp load(socket) do
    %{"q" => q} = form = socket.assigns.form

    filters =
      form
      |> Map.take(["host_id", "agent_id", "kind", "since"])
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()
      |> Map.put("include_inactive", socket.assigns.include_inactive)
      |> Map.put("limit", 50)

    records =
      if String.trim(q) == "",
        do: Records.list(filters),
        else: Records.search(String.trim(q), filters)

    assign(socket, records: records)
  rescue
    e in ArgumentError ->
      socket |> put_flash(:error, "Invalid filter: #{Exception.message(e)}") |> assign(records: [])
  end

  defp excerpt(%{title: t}) when is_binary(t) and t != "", do: t
  defp excerpt(%{content: c}), do: String.slice(c || "", 0, 120)

  defp subjects(%{subject_keys: keys}), do: Enum.join(keys || [], ", ")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-page">
      <.memory_page_header title="Records" subtitle="Search and review the global memory record store" />

      <.form id="memory-records-search" for={%{}} phx-change="search" phx-submit="search" class="grid gap-3 md:grid-cols-6">
        <.dm_input id="memory-records-q" name="q" label="Search" value={@form["q"]} phx-debounce="300" />
        <.dm_input id="memory-records-host" name="host_id" label="Host" value={@form["host_id"]} phx-debounce="300" />
        <.dm_input id="memory-records-agent" name="agent_id" label="Agent" value={@form["agent_id"]} phx-debounce="300" />
        <.dm_input id="memory-records-since" name="since" label="Since (ISO 8601)" value={@form["since"]} phx-debounce="300" />
        <.dm_select
          id="memory-records-kind"
          name="kind"
          label="Kind"
          prompt="All"
          options={Enum.map(@kinds, &{&1, &1})}
          value={@form["kind"]}
        />
        <.dm_checkbox
          id="memory-records-inactive"
          name="include_inactive"
          label="Include inactive"
          checked={@include_inactive}
        />
      </.form>

      <.memory_blank_state
        :if={@records == []}
        id="memory-records-empty"
        title="No records"
        description="No memory records match the current filters."
      />

      <div :if={@records != []} class="min-w-0 w-full overflow-x-auto mt-4">
        <.dm_table id="memory-records-table" data={@records} hover zebra>
          <:col :let={r} label="Kind">{r.kind}</:col>
          <:col :let={r} label="Record">
            <button type="button" id={"record-#{r.id}"} phx-click="select" phx-value-id={r.id} class="text-left text-primary underline">
              {excerpt(r)}
            </button>
          </:col>
          <:col :let={r} label="Subjects">{subjects(r)}</:col>
          <:col :let={r} label="Status">{r.status}</:col>
          <:col :let={r} label="Writer">{r.writer}</:col>
          <:col :let={r} label="Host">{r.host_id}</:col>
          <:col :let={r} label="Agent">{r.agent_id}</:col>
          <:col :let={r} label="Observed"><.local_time datetime={r.observed_at} format="short" /></:col>
        </.dm_table>
      </div>

      <.dm_card :if={@selected} id="memory-record-detail" variant="bordered" padding="lg" class="mt-6">
        <div class="flex items-start justify-between gap-4">
          <h2 class="text-lg font-semibold">{@selected.record.title || @selected.record.kind}</h2>
          <.dm_btn id="memory-record-close" size="sm" phx-click="close">Close</.dm_btn>
        </div>
        <p class="mt-2 whitespace-pre-wrap break-words">{@selected.record.content}</p>
        <dl class="mt-4 grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3 gap-y-1 text-sm">
          <dt class="text-on-surface-variant">Status</dt><dd>{@selected.record.status}</dd>
          <dt class="text-on-surface-variant">Writer</dt><dd>{@selected.record.writer}</dd>
          <dt class="text-on-surface-variant">Host</dt><dd>{@selected.record.host_id || "—"}</dd>
          <dt class="text-on-surface-variant">Agent</dt><dd>{@selected.record.agent_id || "—"}</dd>
          <dt class="text-on-surface-variant">Integration</dt><dd>{@selected.record.integration || "—"}</dd>
          <dt class="text-on-surface-variant">Session</dt><dd class="break-all">{@selected.record.session_id || "—"}</dd>
          <dt class="text-on-surface-variant">Client</dt><dd class="break-all">{@selected.record.client_id || "—"}</dd>
          <dt class="text-on-surface-variant">Source events</dt><dd class="break-all">{Enum.join(@selected.record.source_event_ids, ", ")}</dd>
          <dt :if={@selected.record.forgotten_reason} class="text-on-surface-variant">Forgotten reason</dt>
          <dd :if={@selected.record.forgotten_reason}>{@selected.record.forgotten_reason}</dd>
        </dl>

        <h3 class="mt-4 font-semibold">History</h3>
        <p :if={@selected.history == []} class="text-sm text-on-surface-variant">No earlier versions.</p>
        <ul id="memory-record-history" class="list-disc pl-5 text-sm">
          <li :for={h <- @selected.history}>{h.status}: {excerpt(h)}</li>
        </ul>

        <.form :if={@selected.record.status == "active"} id="memory-record-forget" for={%{}} phx-submit="forget" class="mt-4 flex items-end gap-2">
          <input type="hidden" name="record_id" value={@selected.record.id} />
          <.dm_input id="memory-record-forget-reason" name="reason" label="Reason" value="" />
          <.dm_btn type="submit" native_submit variant="error" size="sm">Forget</.dm_btn>
        </.form>
      </.dm_card>
    </div>
    """
  end
end
