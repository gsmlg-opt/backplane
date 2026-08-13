defmodule Backplane.Admin.MemoryLessonsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  alias Backplane.Memory.Lessons

  @partition_params ~w(host client scope namespace)
  @statuses ~w(candidate active disputed superseded archived)
  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/memory/lessons",
       statuses: @statuses,
       partition: nil,
       filters: %{},
       page: %{entries: [], page: 1, per_page: @per_page, total: 0, total_pages: 0},
       selected: nil,
       query_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    with {:ok, partition} <- partition_from_params(params),
         {:ok, filters} <- filters_from_params(params),
         {:ok, page} <- Lessons.list_admin(partition, filter_options(filters)),
         {:ok, selected} <- load_selected(socket.assigns.live_action, params, partition) do
      canonical = canonical_query(partition, filters)

      socket =
        assign(socket,
          partition: partition,
          filters: filters,
          page: page,
          selected: selected,
          query_error: nil
        )

      {:noreply, canonicalize(socket, params, canonical)}
    else
      {:error, :partition_required} ->
        {:noreply, assign(socket, partition: nil, selected: nil, query_error: nil)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "The selected lesson was not found in this partition.")
         |> push_navigate(to: ~p"/memory/lessons")}

      {:error, reason} ->
        {:noreply, assign(socket, query_error: reason)}
    end
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket) do
    query =
      raw
      |> Map.take(@partition_params)
      |> Map.new(fn {key, value} -> {key, String.trim(value || "")} end)
      |> Map.reject(fn {_key, value} -> value == "" end)

    {:noreply, push_patch(socket, to: ~p"/memory/lessons?#{query}", replace: true)}
  end

  def handle_event("filter", %{"filters" => raw}, socket) do
    filters =
      raw
      |> Map.reject(fn {key, _value} -> String.starts_with?(key, "_unused_") end)
      |> Map.take(["status", "project"])
      |> Map.new(fn {key, value} -> {key, String.trim(value || "")} end)
      |> Map.reject(fn {_key, value} -> value == "" end)

    query = canonical_query(socket.assigns.partition, filters)
    {:noreply, push_patch(socket, to: lessons_path(socket, query), replace: true)}
  end

  def handle_event(
        "govern",
        %{"governance" => params},
        %{assigns: %{selected: selected}} = socket
      ) do
    action = params["action"]
    reason = String.trim(params["reason"] || "")

    result =
      if reason == "" do
        {:error, :reason_required}
      else
        govern(selected.lesson.memory_id, action, reason, socket.assigns.partition)
      end

    case result do
      {:ok, _lesson} ->
        {:ok, selected} = Lessons.get_admin(selected.lesson.memory_id, socket.assigns.partition)

        {:noreply,
         socket
         |> assign(selected: selected)
         |> put_flash(:info, "Lesson state updated.")}

      {:error, :reason_required} ->
        {:noreply, put_flash(socket, :error, "A reason is required for lesson governance.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The lesson state could not be updated.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-lessons">
      <.memory_page_header title="Lessons" subtitle="Procedural knowledge and governed lifecycle" />

      <.dm_alert :if={@query_error} id="lesson-query-error" variant="error" title="Lessons unavailable" compact>
        Lesson data could not be loaded. Retry after checking the database connection.
      </.dm_alert>

      <.dm_card :if={is_nil(@partition)} variant="bordered" padding="lg">
        <h2 class="text-lg font-semibold">Select an exact partition</h2>
        <p class="mt-1 text-sm text-on-surface-variant">
          Host, client, scope, and namespace are all required. Lessons are never queried across partitions.
        </p>
        <.form id="lesson-partition-form" for={%{}} as={:partition} phx-submit="select_partition" class="mt-4 grid gap-3 sm:grid-cols-2">
          <.dm_input id="lesson-host" name="partition[host]" label="Host" value="" required />
          <.dm_input id="lesson-client" name="partition[client]" label="Client" value="" required />
          <.dm_input id="lesson-scope" name="partition[scope]" label="Scope" value="" required />
          <.dm_input id="lesson-namespace" name="partition[namespace]" label="Namespace" value="" required />
          <div class="sm:col-span-2"><.dm_btn type="submit" variant="primary">Open partition</.dm_btn></div>
        </.form>
      </.dm_card>

      <div :if={@partition}>
        <.form id="lesson-filters" for={%{}} as={:filters} phx-change="filter" phx-submit="filter" class="grid gap-3 sm:grid-cols-2">
          <.dm_select id="lesson-status" name="filters[status]" label="State" value={@filters["status"]} options={[{"", "All states"} | Enum.map(@statuses, &{&1, String.capitalize(&1)})]} />
          <.dm_input id="lesson-project" name="filters[project]" label="Project" value={@filters["project"]} phx-debounce="300" />
        </.form>

        <.dm_card :if={@page.entries == []} variant="bordered" padding="lg" class="mt-4 text-center">
          <h2 class="text-lg font-semibold">No lessons match this partition</h2>
          <p class="mt-1 text-sm text-on-surface-variant">Change the state or project filter to inspect other lessons.</p>
        </.dm_card>

        <div class="mt-4 overflow-x-auto">
          <.dm_table :if={@page.entries != []} id="memory-lessons-table" data={@page.entries} compact hover zebra class="min-w-[84rem]" phx-mounted={fix_dm_table_rowgroup_roles("memory-lessons-table")}>
            <:col :let={entry} label="Rule"><.link href={lesson_detail_path(entry.lesson.memory_id, @partition, @filters)} class="font-medium text-primary underline underline-offset-2">{entry.memory.content}</.link></:col>
            <:col :let={entry} label="State"><.dm_badge variant={state_variant(entry.lesson.status)} size="sm"><span id={"lesson-row-state-#{entry.lesson.memory_id}"}>{entry.lesson.status}</span></.dm_badge></:col>
            <:col :let={entry} label="Confidence">{format_decimal(entry.memory.confidence)}</:col>
            <:col :let={entry} label="Reinforcement">{entry.lesson.reinforcement_count}</:col>
            <:col :let={entry} label="Contradictions">{entry.lesson.contradiction_count}</:col>
            <:col :let={entry} label="Scope / Project">{entry.memory.scope} / {entry.project || "—"}</:col>
            <:col :let={entry} label="Source">{entry.source}</:col>
            <:col :let={entry} label="Last use">{format_datetime(entry.lesson.last_applied_at)}</:col>
            <:col :let={entry} label="Evidence">{length(entry.evidence)}</:col>
          </.dm_table>
        </div>

        <nav :if={@page.total_pages > 1} aria-label="Lesson pagination" class="mt-4 flex items-center justify-between">
          <.memory_link_button :if={@page.page > 1} id="lessons-previous-page" patch={lessons_page_path(@partition, @filters, @page.page - 1)}>Previous</.memory_link_button>
          <span class="text-sm text-on-surface-variant">Page {@page.page} of {@page.total_pages}</span>
          <.memory_link_button :if={@page.page < @page.total_pages} id="lessons-next-page" patch={lessons_page_path(@partition, @filters, @page.page + 1)}>Next</.memory_link_button>
        </nav>

        <.lesson_detail :if={@selected} entry={@selected} partition={@partition} filters={@filters} />
      </div>
    </div>
    """
  end

  attr(:entry, :map, required: true)
  attr(:partition, :map, required: true)
  attr(:filters, :map, required: true)

  defp lesson_detail(assigns) do
    ~H"""
    <aside class="mt-6" aria-labelledby="lesson-detail-title">
      <.dm_card variant="bordered" padding="sm">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div><h2 id="lesson-detail-title" class="text-lg font-semibold">{@entry.memory.content}</h2><p class="mt-1 text-sm text-on-surface-variant">{@entry.lesson.context}</p></div>
          <.memory_link_button id="lesson-close-detail" patch={~p"/memory/lessons?#{canonical_query(@partition, @filters)}"} variant="ghost" size="sm">Close detail</.memory_link_button>
        </div>
        <dl class="mt-4 grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-[max-content_minmax(0,1fr)]">
          <.identity_value label="Lesson ID" value={@entry.lesson.memory_id} />
          <dt class="text-sm font-medium text-on-surface-variant">State</dt><dd id="lesson-state" class="font-mono text-sm">{@entry.lesson.status}</dd>
          <.identity_value label="Confidence" value={format_decimal(@entry.memory.confidence)} />
          <.identity_value label="Reinforcement" value={@entry.lesson.reinforcement_count} />
          <.identity_value label="Contradictions" value={@entry.lesson.contradiction_count} />
          <.identity_value label="Scope" value={@entry.memory.scope} />
          <.identity_value label="Project" value={@entry.project} />
          <.identity_value label="Source" value={@entry.source} />
          <.identity_value label="Last used" value={format_datetime(@entry.lesson.last_applied_at)} />
          <.identity_value label="Promoted by" value={@entry.lesson.promoted_by} />
          <.identity_value label="Promotion reason" value={@entry.lesson.promotion_reason} />
          <.identity_value label="Created" value={format_datetime(@entry.lesson.created_at)} />
          <.identity_value label="Updated" value={format_datetime(@entry.lesson.updated_at)} />
          <.identity_value label="Session" value={@entry.memory.session_id} />
        </dl>

        <section id="lesson-evidence" class="mt-5" aria-labelledby="lesson-evidence-title">
          <h3 id="lesson-evidence-title" class="font-semibold">Evidence</h3>
          <p :if={@entry.evidence == []} class="mt-2 text-sm text-on-surface-variant">No evidence is attached.</p>
          <ul :if={@entry.evidence != []} class="mt-2 space-y-2">
            <li :for={evidence <- @entry.evidence} class="rounded border border-outline-variant p-3 text-sm">
              <div class="flex flex-wrap gap-2"><.dm_badge variant={if evidence.evidence_kind == "contradicts", do: "warning", else: "info"} size="sm">{evidence.evidence_kind}</.dm_badge><span>score {format_decimal(evidence.support_score)}</span></div>
              <p class="mt-2 whitespace-pre-wrap break-words">{evidence.excerpt || "No excerpt"}</p>
              <div class="mt-2 flex flex-wrap gap-3 font-mono text-xs">
                <.link :if={evidence.source_event_id} navigate={~p"/memory/events/#{evidence.source_event_id}"} class="text-primary underline">Event {evidence.source_event_id}</.link>
                <.link :if={evidence_session_id(evidence, @entry.memory)} navigate={~p"/memory/streams?#{%{"session" => evidence_session_id(evidence, @entry.memory)}}"} class="text-primary underline">Session {evidence_session_id(evidence, @entry.memory)}</.link>
              </div>
            </li>
          </ul>
        </section>

        <.form :if={available_actions(@entry.lesson.status) != []} id="lesson-action-form" for={%{}} as={:governance} phx-submit="govern" class="mt-5 border-t border-outline-variant pt-4">
          <.dm_select id="lesson-action" name="governance[action]" label="Action" value={available_actions(@entry.lesson.status) |> hd() |> elem(0)} options={Enum.map(available_actions(@entry.lesson.status), fn {action, label} -> {action, label} end)} />
          <.dm_textarea id="lesson-action-reason" name="governance[reason]" label="Reason" value="" rows={2} required />
          <div class="mt-3 flex flex-wrap gap-2">
            <.dm_btn id={"lesson-action-#{available_actions(@entry.lesson.status) |> hd() |> elem(0)}"} type="submit" variant="primary">Apply action</.dm_btn>
          </div>
        </.form>
      </.dm_card>
    </aside>
    """
  end

  defp load_selected(:show, %{"id" => id}, partition), do: Lessons.get_admin(id, partition)
  defp load_selected(_action, _params, _partition), do: {:ok, nil}

  defp govern(id, "promote", reason, partition),
    do: Lessons.promote(id, reason, Ecto.UUID.generate(), partition, audit_context())

  defp govern(id, "dispute", reason, partition), do: transition(id, "disputed", reason, partition)
  defp govern(id, "archive", reason, partition), do: transition(id, "archived", reason, partition)

  defp govern(id, "reactivate", reason, partition),
    do: transition(id, "active", reason, partition)

  defp govern(_id, _action, _reason, _partition), do: {:error, :invalid_transition}

  defp transition(id, target, reason, partition),
    do: Lessons.transition(id, target, reason, Ecto.UUID.generate(), partition, audit_context())

  defp audit_context do
    request_id = Ecto.UUID.generate()
    %{actor: "admin_ui:backplane_admin", request_id: request_id, correlation_id: request_id}
  end

  defp partition_from_params(params) do
    values = Map.take(params, @partition_params)

    if map_size(values) == 0 do
      {:error, :partition_required}
    else
      normalized = Map.new(values, fn {key, value} -> {key, String.trim(value || "")} end)

      if Enum.all?(@partition_params, &(Map.get(normalized, &1) not in [nil, ""])),
        do:
          {:ok,
           %{
             host_id: normalized["host"],
             client_id: normalized["client"],
             scope: normalized["scope"],
             namespace: normalized["namespace"]
           }},
        else: {:error, :partition_required}
    end
  end

  defp filters_from_params(params) do
    status = blank_to_nil(params["status"])
    project = blank_to_nil(params["project"])

    with true <- is_nil(status) or status in @statuses,
         true <- is_nil(project) or byte_size(project) <= 512,
         {:ok, page} <- positive_integer(params["page"], 1),
         {:ok, per_page} <- bounded_integer(params["per_page"], @per_page, 1..100) do
      {:ok, %{"status" => status, "project" => project, "page" => page, "per_page" => per_page}}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp filter_options(filters),
    do: [
      status: filters["status"],
      project: filters["project"],
      page: filters["page"],
      per_page: filters["per_page"]
    ]

  defp canonical_query(partition, filters) do
    %{
      "host" => partition.host_id,
      "client" => partition.client_id,
      "scope" => partition.scope,
      "namespace" => partition.namespace
    }
    |> Map.merge(Map.take(filters, ["status", "project"]))
    |> maybe_put_page(filters["page"])
    |> maybe_put_per_page(filters["per_page"])
    |> Map.reject(fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp maybe_put_page(query, page) when page > 1, do: Map.put(query, "page", page)
  defp maybe_put_page(query, _page), do: query
  defp maybe_put_per_page(query, @per_page), do: query
  defp maybe_put_per_page(query, per_page), do: Map.put(query, "per_page", per_page)

  defp canonicalize(socket, params, canonical) do
    submitted = Map.drop(params, ["id"])

    if connected?(socket) and submitted != stringify_values(canonical),
      do: push_patch(socket, to: lessons_path(socket, canonical), replace: true),
      else: socket
  end

  defp stringify_values(map), do: Map.new(map, fn {key, value} -> {key, to_string(value)} end)

  defp lessons_path(%{assigns: %{live_action: :show, selected: %{lesson: lesson}}}, query),
    do: ~p"/memory/lessons/#{lesson.memory_id}?#{query}"

  defp lessons_path(_socket, query), do: ~p"/memory/lessons?#{query}"

  defp lesson_detail_path(id, partition, filters),
    do: ~p"/memory/lessons/#{id}?#{canonical_query(partition, filters)}"

  defp lessons_page_path(partition, filters, page),
    do: ~p"/memory/lessons?#{canonical_query(partition, Map.put(filters, "page", page))}"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do:
      case(String.trim(value),
        do: (
          "" -> nil
          trimmed -> trimmed
        )
      )

  defp blank_to_nil(_value), do: nil
  defp positive_integer(nil, default), do: {:ok, default}
  defp positive_integer(value, _default), do: bounded_integer(value, nil, 1..1_000_000)
  defp bounded_integer(nil, default, _range), do: {:ok, default}

  defp bounded_integer(value, _default, range) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> bounded_integer(integer, nil, range)
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp bounded_integer(value, _default, range) when is_integer(value) do
    if value in range, do: {:ok, value}, else: {:error, :invalid_arguments}
  end

  defp bounded_integer(_value, _default, _range), do: {:error, :invalid_arguments}

  defp available_actions("candidate"),
    do: [{"promote", "Promote"}, {"dispute", "Dispute"}, {"archive", "Archive"}]

  defp available_actions("active"), do: [{"dispute", "Dispute"}, {"archive", "Archive"}]
  defp available_actions("disputed"), do: [{"reactivate", "Reactivate"}, {"archive", "Archive"}]
  defp available_actions("archived"), do: [{"reactivate", "Reactivate"}, {"dispute", "Dispute"}]
  defp available_actions("superseded"), do: [{"archive", "Archive"}]
  defp available_actions(_status), do: []

  defp evidence_session_id(evidence, memory),
    do: evidence.session_id || evidence.source_session_id || memory.session_id

  defp state_variant("active"), do: "success"
  defp state_variant("candidate"), do: "info"
  defp state_variant("disputed"), do: "warning"
  defp state_variant(_status), do: "neutral"
  defp format_decimal(nil), do: "—"

  defp format_decimal(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: 2)
end
