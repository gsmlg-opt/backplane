defmodule Backplane.Admin.MemoryMemoriesLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_link_button: 1, memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Memories
  alias Backplane.MemorySpaces
  alias Backplane.Skills.Hosts

  alias Backplane.Memory.Operations.Inventory

  @access_capabilities [:read, :deliver, :remember, :forget]

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/memory/memories",
       page_size: @page_size,
       partition: nil,
       rows: [],
       selected: nil,
       source_summary: nil,
       source_error: nil,
       offset: 0,
       error: nil,
       detail_error: nil,
       query_params: %{},
       filters: %{},
       total_count: 0,
       access_target: nil,
       access_rows: [],
       access_hosts: [],
       access_draft: empty_access_draft(),
       access_edit_id: nil,
       access_expected_version: 0,
       access_edit_status: nil,
       access_error: nil,
       access_load_error: nil,
       access_message: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    partition = browse_scope(params)

    target =
      case params["id"] do
        nil ->
          if Enum.all?([:memory_space_id, :scope, :namespace], &Map.has_key?(partition, &1)),
            do: partition

        id ->
          case Inventory.identity(
                 :memory,
                 id,
                 Map.take(partition, [:memory_space_id, :scope, :namespace])
               ) do
            {:ok, identity} -> identity
            _ -> nil
          end
      end

    socket = if target, do: load_access(socket, target), else: reset_access(socket, nil)
    load(socket, partition, params)
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/memory/memories?#{selection_query(raw)}")}

  def handle_event("filter", %{"filters" => filters}, socket) do
    query =
      Map.merge(
        partition_query(socket.assigns.partition),
        Map.take(filters, ~w(q type session sort))
      )

    {:noreply, push_patch(socket, to: ~p"/memory/memories?#{query}")}
  end

  def handle_event("memory_access_change", %{"access" => params}, socket) do
    socket =
      if params["host_id"] != socket.assigns.access_draft["host_id"] do
        select_access(socket, params["host_id"])
      else
        assign(
          socket,
          :access_draft,
          Map.merge(socket.assigns.access_draft, access_fields(params))
        )
      end

    {:noreply, assign(socket, access_error: nil, access_message: nil)}
  end

  def handle_event("memory_access_edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.access_rows, &(&1.access_id == id)) do
      nil ->
        {:noreply,
         assign(socket, :access_error, "This access is unavailable. Refresh and try again.")}

      access ->
        {:noreply, select_access(socket, access.host_id)}
    end
  end

  def handle_event("memory_access_save", %{"access" => params}, socket) do
    # The displayed version belongs to the draft, not the periodically refreshed list.
    recipient_unchanged = params["host_id"] in [nil, socket.assigns.access_draft["host_id"]]

    socket =
      assign(
        socket,
        :access_draft,
        Map.merge(socket.assigns.access_draft, Map.delete(access_fields(params), "host_id"))
      )

    with true <- recipient_unchanged || {:error, :recipient_changed},
         :ok <- access_ready(socket),
         {:ok, attrs, reason} <- access_input(socket.assigns.access_draft, params["action"]),
         result <- mutate_access(socket, attrs, reason, params["action"]),
         {:ok, access} <- result do
      socket =
        socket
        |> load_access(socket.assigns.access_target)
        |> select_access(access.host_id)
        |> assign(access_message: "Access request completed.")

      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> load_access(socket.assigns.access_target)
         |> assign(access_error: access_error_message(reason), access_message: nil)}
    end
  rescue
    _ ->
      {:noreply,
       assign(socket,
         access_error: "Access could not be updated. Reload current access before retrying.",
         access_message: nil
       )}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:access_target, fn ->
        Map.take(assigns.partition, [:memory_space_id, :scope, :namespace])
      end)
      |> assign_new(:access_rows, fn -> [] end)
      |> assign_new(:access_hosts, fn -> [] end)
      |> assign_new(:access_draft, &empty_access_draft/0)
      |> assign_new(:access_edit_id, fn -> nil end)
      |> assign_new(:access_expected_version, fn -> 0 end)
      |> assign_new(:access_edit_status, fn -> nil end)
      |> assign_new(:access_error, fn -> nil end)
      |> assign_new(:access_load_error, fn -> "Registered host access has not been loaded." end)
      |> assign_new(:access_message, fn -> nil end)

    ~H"""
    <div id="memory-memories">
      <.memory_page_header title="Memories" subtitle="Durable memory inventory, evidence, and provenance" />
      <section :if={@access_target} id="memory-access" class="mb-6" aria-labelledby="memory-access-title">
        <.dm_card variant="bordered" padding="sm">
          <h2 id="memory-access-title" class="text-lg font-semibold">Access</h2>
          <p class="mt-2 text-sm text-on-surface-variant">Manage registered hosts independently of source-host and client provenance filters.</p>
          <dl id="memory-access-target" class="mt-3 grid grid-cols-1 gap-x-4 gap-y-1 text-sm sm:grid-cols-[max-content_minmax(0,1fr)]">
            <dt>Memory space</dt><dd class="break-all font-mono">{@access_target.memory_space_id}</dd>
            <dt>Scope</dt><dd class="break-all">{@access_target.scope}</dd>
            <dt>Namespace</dt><dd class="break-all">{@access_target.namespace}</dd>
          </dl>
          <.dm_alert id="memory-access-sharing-warning" variant="warning" title="Sharing existing content" class="mt-3">
            Granting access shares existing content in this exact partition, including private content. Remember and forget are independent write permissions; forget can delete canonical content for every authorized host. Revoke removes access without deleting the host or its data.
          </.dm_alert>
          <.dm_alert :if={@access_load_error} id="memory-access-load-error" variant="error" title="Access unavailable">{@access_load_error}</.dm_alert>
          <.dm_alert :if={@access_error} id="memory-access-error" variant="error" title="Access not changed">{@access_error}</.dm_alert>
          <.dm_alert :if={@access_message} id="memory-access-success" variant="success">{@access_message}</.dm_alert>
          <p :if={@access_rows == [] and !@access_load_error} id="memory-access-empty" class="mt-3 text-sm text-on-surface-variant">No host access registered for this exact partition.</p>
          <div class="mt-3 overflow-x-auto">
            <.dm_table :if={@access_rows != []} id="memory-access-table" data={@access_rows} compact hover zebra>
              <:col :let={access} label="Recipient host"><span class="block">{access_host_name(@access_hosts, access.host_id)}</span><span class="break-all font-mono text-xs">{access.host_id}</span></:col>
              <:col :let={access} label="Access"><span class="break-all font-mono text-xs">{access.access_id}</span></:col>
              <:col :let={access} label="Status">{access.status}<span :if={access.default_capture} class="block text-xs">Default capture</span></:col>
              <:col :let={access} label="Capabilities">{Enum.join(access.capabilities, ", ")}</:col>
              <:col :let={access} label="Lease">{access.offline_read_lease_seconds}s</:col>
              <:col :let={access} label="Version">{access.authority_version}</:col>
              <:col :let={access} label="Latest audit reason">{Map.get(access, :latest_audit_reason) || "Unavailable"}</:col>
              <:col :let={access} label="Action"><.dm_btn id={"memory-access-edit-#{access.access_id}"} type="button" variant="ghost" phx-click="memory_access_edit" phx-value-id={access.access_id}>Reload / edit current access</.dm_btn></:col>
            </.dm_table>
          </div>
          <.form for={%{}} as={:access} id="memory-access-form" phx-change="memory_access_change" phx-submit="memory_access_save" class="mt-4 space-y-3">
            <.dm_select id="memory-access-recipient" name="access[host_id]" label="Recipient host" prompt="Select a registered host" value={@access_draft["host_id"]} options={Enum.map(@access_hosts, &{&1.id, "#{&1.name} · #{&1.id}"})} disabled={not is_nil(@access_load_error)} />
            <div id="memory-access-capabilities" class="flex flex-wrap gap-4">
              <.dm_checkbox :for={capability <- [:read, :deliver, :remember, :forget]} id={"memory-access-#{capability}"} name={"access[#{capability}]"} label={String.capitalize(to_string(capability))} checked={@access_draft[to_string(capability)] == "true"} />
            </div>
            <p class="text-sm text-on-surface-variant">Deliver requires read. Remember and forget do not grant read or delivery.</p>
            <.dm_input id="memory-access-lease" name="access[offline_read_lease_seconds]" type="number" label="Offline read lease (seconds)" min="0" max="300" value={@access_draft["offline_read_lease_seconds"]} required />
            <p class="text-sm text-on-surface-variant">Default 0; maximum 300. A nonzero lease requires read and deliver. A disconnected host may retain reads until its issued lease expires.</p>
            <.dm_input id="memory-access-reason" name="access[reason]" label="Reason (required for every change)" value={@access_draft["reason"]} required />
            <input id="memory-access-version" name="access[expected_version]" type="hidden" value={@access_expected_version} />
            <p id="memory-access-editor-state" class="break-all text-sm">{if @access_edit_id, do: "Access #{@access_edit_id} · #{@access_edit_status}", else: "New access"} · Expected version {@access_expected_version}</p>
            <.dm_alert :if={Enum.any?(@access_rows, &(&1.access_id == @access_edit_id and &1.default_capture))} id="memory-access-default-warning" variant="warning" title="Default capture will stop">
              Revoking this default access stops capture until it is deliberately restored. Regranting shared access does not restore default capture.
            </.dm_alert>
            <div class="flex flex-wrap gap-3">
              <.dm_btn id="memory-access-save" native_submit type="submit" name="access[action]" value="save" variant="secondary" disabled={not is_nil(@access_load_error)}>{cond do @access_edit_status == :revoked -> "Regrant access"; @access_edit_id -> "Save access"; true -> "Grant access" end}</.dm_btn>
              <.dm_btn :if={@access_edit_status == :active} id="memory-access-revoke" native_submit type="submit" name="access[action]" value="revoke" variant="error" disabled={not is_nil(@access_load_error)}>Revoke access</.dm_btn>
            </div>
          </.form>
        </.dm_card>
      </section>
      <.form for={%{}} as={:filters} id="memories-filters" phx-submit="filter" class="mb-4 flex flex-wrap items-end gap-3">
        <.dm_input name="filters[q]" label="Search" value={@filters["q"] || ""} />
        <.dm_input name="filters[type]" label="Type" value={@filters["type"] || ""} />
        <.dm_input name="filters[session]" label="Session" value={@filters["session"] || ""} />
        <.dm_select id="memories-sort" name="filters[sort]" label="Sort" value={@filters["sort"] || "newest"} options={[{"newest", "Newest first"}, {"oldest", "Oldest first"}]} />
        <.dm_btn type="submit" variant="primary">Filter</.dm_btn>
      </.form>
      <p :if={!@error} id="memories-count" class="mb-3 text-sm text-on-surface-variant">{@total_count} matching memories</p>
      <.dm_alert :if={@error} id="memories-error" variant="error" title="Memories unavailable">The memory collection could not be loaded.</.dm_alert>
      <.dm_alert :if={@detail_error} id="memory-detail-unavailable" variant="warning" title="Memory unavailable">This memory is missing, deleted, or unavailable for the current filters.</.dm_alert>
      <.dm_card :if={@rows == [] and !@error} id="memories-empty" variant="bordered" padding="lg"><h2 class="text-lg font-semibold">No memories match</h2></.dm_card>
      <div class="overflow-x-auto">
        <.dm_table :if={@rows != []} id="memory-memories-table" data={@rows} compact hover zebra>
          <:col :let={memory} label="Memory"><.link navigate={detail_path(memory.id, @partition, @offset, @filters)} class="text-primary underline">{memory.content}</.link></:col>
          <:col :let={memory} label="Source"><.source_identity record={memory} /></:col>
          <:col :let={memory} label="Type">{memory.memory_type}</:col>
          <:col :let={memory} label="State"><.dm_badge variant={status_variant(memory.lifecycle_state)} size="sm">{memory.lifecycle_state}</.dm_badge></:col>
          <:col :let={memory} label="Applications">{memory.application_count}</:col>
          <:col :let={memory} label="Created">{format_datetime(memory.inserted_at)}</:col>
        </.dm_table>
      </div>
      <nav aria-label="Memory pagination" class="mt-4 flex justify-end gap-2">
        <.memory_link_button :if={@offset > 0} id="memories-previous" patch={page_path(@partition, max(0, @offset - @page_size), @filters)}>Previous</.memory_link_button>
        <.memory_link_button :if={@offset + length(@rows) < @total_count} id="memories-next" patch={page_path(@partition, @offset + @page_size, @filters)}>Next</.memory_link_button>
      </nav>
      <aside :if={@selected} id="memory-detail" class="mt-6">
        <.dm_card variant="bordered" padding="sm">
          <h2 class="text-lg font-semibold">Memory detail</h2>
          <div id="memory-detail-source" class="mt-3"><.source_identity record={@selected.memory} detail /></div>
          <p class="mt-3 whitespace-pre-wrap">{@selected.memory.content}</p>
          <div class="mt-4 flex flex-wrap gap-3 text-sm">
            <.link :if={@selected.memory.session_id not in [nil, ""]} navigate={~p"/memory/sessions/#{@selected.memory.session_id}?#{partition_query(record_partition(@selected.memory, @partition))}"} class="text-primary underline">Session</.link>
            <.link :if={@selected.memory.session_id not in [nil, ""]} navigate={~p"/memory/replay?#{session_query(@selected.memory, record_partition(@selected.memory, @partition))}"} class="text-primary underline">Replay</.link>
            <.link navigate={~p"/memory/audit?#{Map.merge(partition_query(record_partition(@selected.memory, @partition)), %{"target" => @selected.memory.id})}"} class="text-primary underline">Audit</.link>
          </div>
          <section id="memory-evidence" class="mt-5"><h3 class="font-semibold">Evidence</h3><p :if={@selected.evidence == []} class="mt-2 text-sm text-on-surface-variant">No durable evidence</p><ul class="mt-2 space-y-2"><li :for={evidence <- @selected.evidence}>
            <.link :if={evidence_path(evidence, @selected.memory.id, record_partition(@selected.memory, @partition))} navigate={evidence_path(evidence, @selected.memory.id, record_partition(@selected.memory, @partition))} class="text-primary underline">{evidence_label(evidence)}</.link>
            <span :if={!evidence_path(evidence, @selected.memory.id, record_partition(@selected.memory, @partition))}>{evidence.evidence_kind}</span>
            · {evidence.excerpt || "No excerpt"}
          </li></ul></section>
        </.dm_card>
        <.dm_alert :if={@source_error} id="memory-source-summary-unavailable" variant="warning" title="Summary source unavailable">
          This summary is missing or is not linked to this memory through this record’s stored source links.
        </.dm_alert>
        <section :if={@source_summary} id="memory-source-summary" class="mt-5" aria-labelledby="memory-source-summary-title">
          <.dm_card variant="bordered" padding="sm">
            <h3 id="memory-source-summary-title" class="font-semibold">Session summary source</h3>
            <dl class="mt-3 grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-[max-content_minmax(0,1fr)]">
              <dt>Summary ID</dt><dd class="break-all font-mono">{@source_summary.id}</dd>
              <dt>Status</dt><dd>{if @source_summary.superseded_at, do: "Historical", else: "Current"}</dd>
              <dt>Session</dt><dd class="break-all">{@source_summary.session_id}</dd>
              <dt>Processing version</dt><dd class="break-all">{@source_summary.processing_version}</dd>
              <dt>Input revision</dt><dd class="break-all font-mono">{@source_summary.input_revision}</dd>
              <dt>Output revision</dt><dd class="break-all font-mono">{@source_summary.output_revision}</dd>
            </dl>
            <p class="mt-3 whitespace-pre-wrap break-words">{@source_summary.content}</p>
          </.dm_card>
        </section>
      </aside>
    </div>
    """
  end

  defp load(socket, partition, params) do
    offset = page(params["offset"])
    filters = Map.take(params, ~w(q type session sort))

    opts = [
      q: filters["q"],
      type: filters["type"],
      session_id: filters["session"],
      sort: filters["sort"]
    ]

    {:ok, inventory} = Inventory.memories(partition, opts ++ [limit: @page_size, offset: offset])
    rows = inventory.entries
    total_count = inventory.total

    selected =
      case {socket.assigns.live_action, params["id"]} do
        {:show, id} ->
          with {:ok, _uuid} <- Ecto.UUID.cast(id),
               {:ok, identity} <- Inventory.identity(:memory, id, partition),
               {:ok, memory} <- Memories.get(id, identity),
               {:ok, verification} <- Memories.verify(id, identity),
               do: {:ok, %{memory: memory, evidence: verification.evidence}}

        _ ->
          nil
      end

    {selected, detail_error} =
      case selected do
        {:ok, detail} -> {detail, nil}
        nil -> {nil, nil}
        error -> {nil, error}
      end

    {source_summary, source_error} =
      load_source_summary(
        selected,
        params["source_summary"],
        if(selected, do: record_partition(selected.memory, partition), else: partition)
      )

    {:noreply,
     assign(socket,
       partition: partition,
       source_summary: source_summary,
       source_error: source_error,
       rows: rows,
       selected: selected,
       offset: offset,
       error: nil,
       detail_error: detail_error,
       query_params: params,
       filters: filters,
       total_count: total_count
     )}
  rescue
    error ->
      {:noreply,
       assign(socket,
         partition: partition,
         rows: [],
         selected: nil,
         error: error,
         detail_error: nil,
         query_params: params,
         filters: Map.take(params, ~w(q type session sort))
       )}
  end

  defp load_access(socket, partition) do
    target = Map.take(partition, [:memory_space_id, :scope, :namespace])

    socket =
      if socket.assigns.access_target == target, do: socket, else: reset_access(socket, target)

    try do
      with {:ok, rows} <- MemorySpaces.list_partition_access(target) do
        assign(socket,
          access_rows: rows,
          access_hosts: Hosts.list_hosts(),
          access_load_error: nil
        )
      else
        {:error, _} ->
          assign(socket, access_load_error: "Registered host access could not be loaded.")
      end
    rescue
      _ -> assign(socket, access_load_error: "Registered host access could not be loaded.")
    end
  end

  defp reset_access(socket, target) do
    assign(socket,
      access_target: target,
      access_rows: [],
      access_hosts: [],
      access_draft: empty_access_draft(),
      access_edit_id: nil,
      access_expected_version: 0,
      access_edit_status: nil,
      access_error: nil,
      access_load_error: nil,
      access_message: nil
    )
  end

  defp empty_access_draft do
    %{
      "host_id" => "",
      "read" => "false",
      "deliver" => "false",
      "remember" => "false",
      "forget" => "false",
      "offline_read_lease_seconds" => "0",
      "reason" => ""
    }
  end

  defp select_access(socket, host_id) do
    access = Enum.find(socket.assigns.access_rows, &(&1.host_id == host_id))
    draft = Map.put(empty_access_draft(), "host_id", host_id || "")

    draft =
      if access do
        Enum.reduce(access.capabilities, draft, &Map.put(&2, to_string(&1), "true"))
        |> Map.put("offline_read_lease_seconds", to_string(access.offline_read_lease_seconds))
      else
        draft
      end

    assign(socket,
      access_draft: draft,
      access_edit_id: access && access.access_id,
      access_expected_version: if(access, do: access.authority_version, else: 0),
      access_edit_status: access && access.status,
      access_error: nil,
      access_message: nil
    )
  end

  defp access_fields(params),
    do:
      Map.take(params, ~w(host_id read deliver remember forget offline_read_lease_seconds reason))

  defp access_ready(socket) do
    cond do
      socket.assigns.access_load_error ->
        {:error, :unavailable}

      not Enum.any?(
        socket.assigns.access_hosts,
        &(&1.id == socket.assigns.access_draft["host_id"])
      ) ->
        {:error, :unknown_host}

      true ->
        :ok
    end
  end

  defp access_input(draft, "revoke") do
    case String.trim(draft["reason"] || "") do
      "" -> {:error, :reason_required}
      reason -> {:ok, %{}, reason}
    end
  end

  defp access_input(draft, _action) do
    capabilities = Enum.filter(@access_capabilities, &(draft[to_string(&1)] == "true"))
    reason = String.trim(draft["reason"] || "")

    with true <- reason != "" || {:error, :reason_required},
         {lease, ""} when lease in 0..300 <-
           Integer.parse(draft["offline_read_lease_seconds"] || ""),
         true <-
           (:deliver not in capabilities or :read in capabilities) ||
             {:error, :deliver_requires_read},
         true <-
           (lease == 0 or (:read in capabilities and :deliver in capabilities)) ||
             {:error, :lease_requires_delivery} do
      {:ok, %{capabilities: capabilities, offline_read_lease_seconds: lease}, reason}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_lease}
    end
  end

  defp mutate_access(socket, attrs, reason, action) do
    operator = %{kind: :trusted_operator, ref: nil, request_id: Ecto.UUID.generate()}
    assigns = socket.assigns

    cond do
      action not in [nil, "save", "revoke"] or
          (action == "revoke" and is_nil(assigns.access_edit_id)) ->
        {:error, :invalid_action}

      action == "revoke" ->
        MemorySpaces.revoke_host_access(
          operator,
          assigns.access_edit_id,
          assigns.access_expected_version,
          reason
        )

      assigns.access_edit_status == :active ->
        MemorySpaces.change_host_access(
          operator,
          assigns.access_edit_id,
          assigns.access_expected_version,
          attrs,
          reason
        )

      true ->
        MemorySpaces.grant_host_access(
          operator,
          assigns.access_draft["host_id"],
          assigns.access_target,
          attrs.capabilities,
          reason: reason,
          expected_version: assigns.access_expected_version,
          offline_read_lease_seconds: attrs.offline_read_lease_seconds
        )
    end
  end

  defp access_host_name(hosts, id) do
    case Enum.find(hosts, &(&1.id == id)) do
      nil -> "Unregistered host"
      host -> host.name
    end
  end

  defp access_error_message(:version_conflict),
    do:
      "Access changed since this draft was loaded. The list shows current state; reload current access and review before retrying."

  defp access_error_message(:reason_required), do: "A reason is required."

  defp access_error_message(:recipient_changed),
    do: "Recipient changed. Select the recipient and review current access before saving."

  defp access_error_message(:unknown_host), do: "Select a known registered recipient host."
  defp access_error_message(:deliver_requires_read), do: "Deliver requires read."

  defp access_error_message(:lease_requires_delivery),
    do: "A nonzero lease requires read and deliver."

  defp access_error_message(:invalid_lease),
    do: "The lease must be a whole number from 0 to 300 seconds."

  defp access_error_message(_),
    do:
      "Access could not be updated. Reload current access and review the recipient, capabilities, lease, and reason before retrying."

  defp load_source_summary(_selected, nil, _partition), do: {nil, nil}

  defp load_source_summary(%{memory: memory}, source_id, partition) do
    case Memories.get_source_summary(memory.id, source_id, partition) do
      {:ok, summary} -> {summary, nil}
      {:error, reason} -> {nil, reason}
    end
  end

  defp load_source_summary(_selected, _source_id, _partition), do: {nil, :not_found}

  defp page_path(partition, offset, filters),
    do:
      ~p"/memory/memories?#{Map.merge(partition_query(partition), Map.put(filters, "offset", offset))}"

  defp detail_path(id, partition, offset, filters),
    do:
      ~p"/memory/memories/#{id}?#{Map.merge(partition_query(partition), Map.put(filters, "offset", offset))}"

  defp session_query(memory, partition),
    do: Map.merge(partition_query(partition), %{"session" => memory.session_id || ""})

  defp evidence_path(%{source_type: "event", source_id: id}, _memory_id, partition)
       when is_binary(id),
       do: ~p"/memory/events/#{id}?#{partition_query(partition)}"

  defp evidence_path(%{source_type: "summary", source_id: id}, memory_id, partition)
       when is_binary(id),
       do:
         ~p"/memory/memories/#{memory_id}?#{Map.put(partition_query(partition), "source_summary", id)}"

  defp evidence_path(%{source_type: "session", source_id: source_id}, _memory_id, partition)
       when is_binary(source_id) do
    case String.split(source_id, ":", parts: 2) do
      [_host, session_id] when session_id != "" ->
        ~p"/memory/sessions/#{session_id}?#{partition_query(partition)}"

      _ ->
        nil
    end
  end

  defp evidence_path(%{session_id: session_id}, _memory_id, partition)
       when is_binary(session_id) and session_id != "",
       do: ~p"/memory/replay?#{Map.put(partition_query(partition), "session", session_id)}"

  defp evidence_path(_evidence, _memory_id, _partition), do: nil

  defp evidence_label(%{source_type: "event"}), do: "Event"
  defp evidence_label(%{source_type: "summary"}), do: "Session summary"
  defp evidence_label(%{source_type: "session"}), do: "Session"
  defp evidence_label(_evidence), do: "Replay source"
end
