defmodule Backplane.Admin.MemoryCrystalsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  alias Backplane.Memory.{Audit, Crystals, CrystalSources}

  @partition_params ~w(host client scope namespace)
  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/memory/crystals",
       partition: nil,
       query: "",
       page: %{entries: [], next_cursor: nil},
       selected: nil,
       selected_source: nil,
       query_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    with {:ok, partition} <- partition_from_params(params),
         {:ok, query} <- query_from_params(params),
         {:ok, page} <- load_page(partition, query, params["after"]),
         {:ok, selected, selected_source} <-
           load_selected(socket.assigns.live_action, params, partition) do
      {:noreply,
       assign(socket,
         partition: partition,
         query: query,
         page: page,
         selected: selected,
         selected_source: selected_source,
         query_error: nil
       )}
    else
      {:error, :partition_required} ->
        {:noreply,
         assign(socket, partition: nil, selected: nil, selected_source: nil, query_error: nil)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "The selected crystal was not found in this partition.")
         |> push_navigate(to: ~p"/memory/crystals")}

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

    {:noreply, push_patch(socket, to: ~p"/memory/crystals?#{query}", replace: true)}
  end

  def handle_event("search", %{"filters" => %{"query" => raw}}, socket) do
    query = String.trim(raw || "")
    params = partition_query(socket.assigns.partition)
    params = if query == "", do: params, else: Map.put(params, "query", query)
    {:noreply, push_patch(socket, to: ~p"/memory/crystals?#{params}", replace: true)}
  end

  def handle_event("rerun", _params, %{assigns: %{selected: detail}} = socket) do
    result = rerun(detail, socket.assigns.partition)

    case result do
      {:ok, result} ->
        audit_rerun(detail, socket.assigns.partition, rerun_result(result))

        {:noreply,
         put_flash(socket, :info, "Crystal processing was queued or confirmed idempotently.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Crystal processing could not be rerun.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-crystals">
      <.memory_page_header title="Crystals" subtitle="Structured completed-work digests with typed provenance" />

      <.dm_alert :if={@query_error} id="crystal-query-error" variant="error" title="Crystals unavailable" compact>
        Crystal data could not be loaded. Check the partition and pagination cursor.
      </.dm_alert>

      <.dm_card :if={is_nil(@partition)} variant="bordered" padding="lg">
        <h2 class="text-lg font-semibold">Select an exact partition</h2>
        <p class="mt-1 text-sm text-on-surface-variant">Host, client, scope, and namespace are required.</p>
        <.form id="crystal-partition-form" for={%{}} as={:partition} phx-submit="select_partition" class="mt-4 grid gap-3 sm:grid-cols-2">
          <.dm_input id="crystal-host" name="partition[host]" label="Host" value="" required />
          <.dm_input id="crystal-client" name="partition[client]" label="Client" value="" required />
          <.dm_input id="crystal-scope" name="partition[scope]" label="Scope" value="" required />
          <.dm_input id="crystal-namespace" name="partition[namespace]" label="Namespace" value="" required />
          <div class="sm:col-span-2"><.dm_btn type="submit" variant="primary">Open partition</.dm_btn></div>
        </.form>
      </.dm_card>

      <div :if={@partition}>
        <.form id="crystal-filters" for={%{}} as={:filters} phx-change="search" phx-submit="search" class="max-w-xl">
          <.dm_input id="crystal-query" name="filters[query]" label="Search crystals" value={@query} phx-debounce="300" />
        </.form>

        <.dm_card :if={@page.entries == []} variant="bordered" padding="lg" class="mt-4 text-center">
          <h2 class="text-lg font-semibold">No crystals match this partition</h2>
        </.dm_card>

        <div class="mt-4 overflow-x-auto">
          <.dm_table :if={@page.entries != []} id="memory-crystals-table" data={@page.entries} compact hover zebra>
            <:col :let={crystal} label="Title"><.link href={detail_path(crystal.id, @partition, @query)} class="font-medium text-primary underline underline-offset-2">{crystal.title}</.link></:col>
            <:col :let={crystal} label="Source">{crystal.source_kind}</:col>
            <:col :let={crystal} label="Project">{crystal.project || "—"}</:col>
            <:col :let={crystal} label="State"><.dm_badge variant={if crystal.status == "complete", do: "success", else: "warning"} size="sm">{crystal.status}</.dm_badge></:col>
            <:col :let={crystal} label="Model / Version">{crystal.model || "deterministic"} / {crystal.processing_version}</:col>
            <:col :let={crystal} label="Completed">{format_datetime(crystal.completed_at)}</:col>
          </.dm_table>
        </div>

        <nav :if={@page.next_cursor} aria-label="Crystal pagination" class="mt-4 flex justify-end">
          <.memory_link_button id="crystals-next-page" patch={next_path(@partition, @query, @page.next_cursor)}>Next</.memory_link_button>
        </nav>

        <.crystal_detail :if={@selected} detail={@selected} partition={@partition} query={@query} />
        <.source_detail :if={@selected_source} source={@selected_source} />
      </div>
    </div>
    """
  end

  attr(:detail, :map, required: true)
  attr(:partition, :map, required: true)
  attr(:query, :string, required: true)

  defp crystal_detail(assigns) do
    ~H"""
    <aside id="crystal-detail" class="mt-6" aria-labelledby="crystal-detail-title">
      <.dm_card variant="bordered" padding="sm">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <h2 id="crystal-detail-title" class="text-lg font-semibold">{@detail.crystal.title}</h2>
          <.memory_link_button id="crystal-close-detail" patch={~p"/memory/crystals?#{query_params(@partition, @query)}"} variant="ghost" size="sm">Close detail</.memory_link_button>
        </div>

        <dl class="mt-4 grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-[max-content_minmax(0,1fr)]">
          <.identity_value label="Crystal ID" value={@detail.crystal.id} />
          <.identity_value label="Memory ID" value={@detail.crystal.memory_id} />
          <.identity_value label="Source kind" value={@detail.crystal.source_kind} />
          <.identity_value label="State" value={@detail.crystal.status} />
          <.identity_value label="Model" value={@detail.crystal.model || "deterministic fallback"} />
          <.identity_value label="Processing version" value={@detail.crystal.processing_version} />
          <.identity_value label="Prompt version" value={@detail.crystal.prompt_version} />
          <.identity_value label="Input revision" value={@detail.crystal.input_revision} />
          <.identity_value label="Output revision" value={@detail.crystal.output_revision} />
        </dl>

        <section class="mt-5"><h3 class="font-semibold">Narrative</h3><p class="mt-2 whitespace-pre-wrap">{@detail.crystal.narrative}</p></section>
        <.string_list id="crystal-outcomes" title="Outcomes" values={@detail.crystal.key_outcomes} />
        <.string_list id="crystal-decisions" title="Decisions" values={@detail.crystal.decisions} />
        <.string_list id="crystal-files" title="Files" values={@detail.crystal.files_affected} />
        <.string_list id="crystal-unresolved" title="Unresolved items" values={@detail.crystal.unresolved_items} />

        <section id="crystal-evidence" class="mt-5">
          <h3 class="font-semibold">Evidence and links</h3>
          <div class="mt-2 flex flex-wrap gap-3 text-sm">
            <.link :if={@detail.crystal.source_kind == "session" or @detail.source_summary_ids != []} navigate={source_path(@detail.crystal.id, "sessions", @detail.crystal.source_session_id, @partition, @query)} class="text-primary underline">Session {@detail.crystal.source_session_id}</.link>
            <.link :for={id <- @detail.source_action_ids} navigate={source_path(@detail.crystal.id, "actions", id, @partition, @query)} class="font-mono text-primary underline">Action {id}</.link>
            <.link :for={id <- @detail.lesson_memory_ids} navigate={~p"/memory/lessons/#{id}?#{partition_query(@partition)}"} class="text-primary underline">Lesson {id}</.link>
            <.link :for={id <- @detail.source_event_ids} navigate={~p"/memory/events/#{id}"} class="text-primary underline">Event {id}</.link>
            <.link :for={id <- @detail.source_summary_ids} navigate={source_path(@detail.crystal.id, "summaries", id, @partition, @query)} class="font-mono text-primary underline">Summary {id}</.link>
          </div>
        </section>

        <.dm_btn id="crystal-rerun" type="button" variant="primary" phx-click="rerun" class="mt-5">Rerun crystallization</.dm_btn>
      </.dm_card>
    </aside>
    """
  end

  attr(:source, :map, required: true)

  defp source_detail(assigns) do
    ~H"""
    <section id="crystal-source-detail" class="mt-5" aria-labelledby="crystal-source-title">
      <.dm_card variant="bordered" padding="sm">
        <h3 id="crystal-source-title" class="font-semibold">Source {source_kind_label(@source.kind)}</h3>
        <dl class="mt-3 grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-[max-content_minmax(0,1fr)]">
          <.identity_value :for={{label, value} <- source_fields(@source)} label={label} value={value} />
        </dl>
        <p :if={@source[:content]} class="mt-3 whitespace-pre-wrap break-words">{@source.content}</p>
      </.dm_card>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:values, :list, required: true)

  defp string_list(assigns) do
    ~H"""
    <section id={@id} class="mt-5"><h3 class="font-semibold">{@title}</h3><p :if={@values == []} class="mt-2 text-sm text-on-surface-variant">None</p><ul :if={@values != []} class="mt-2 list-disc space-y-1 pl-5"><li :for={value <- @values}>{value}</li></ul></section>
    """
  end

  defp load_page(partition, "", cursor),
    do: Crystals.list(partition, limit: @per_page, after: cursor)

  defp load_page(partition, query, nil) do
    with {:ok, entries} <- Crystals.search(query, partition, limit: @per_page),
         do: {:ok, %{entries: entries, next_cursor: nil}}
  end

  defp load_page(_partition, _query, _cursor), do: {:error, :invalid_cursor}

  defp load_selected(:show, %{"id" => id}, partition) do
    with {:ok, detail} <- Crystals.get(id, partition), do: {:ok, detail, nil}
  end

  defp load_selected(:source_action, params, partition),
    do: load_source(params, partition, :action)

  defp load_selected(:source_summary, params, partition),
    do: load_source(params, partition, :summary)

  defp load_selected(:source_session, params, partition),
    do: load_source(params, partition, :session)

  defp load_selected(_action, _params, _partition), do: {:ok, nil, nil}

  defp load_source(%{"id" => crystal_id, "source_id" => source_id}, partition, kind) do
    with {:ok, detail} <- Crystals.get(crystal_id, partition),
         {:ok, source} <- get_source(kind, crystal_id, source_id, partition) do
      {:ok, detail, source_result(kind, source)}
    end
  end

  defp get_source(:action, crystal_id, source_id, partition),
    do: CrystalSources.get_action(crystal_id, source_id, partition)

  defp get_source(:summary, crystal_id, source_id, partition),
    do: CrystalSources.get_summary(crystal_id, source_id, partition)

  defp get_source(:session, crystal_id, source_id, partition),
    do: CrystalSources.get_session(crystal_id, source_id, partition)

  defp source_result(:action, source),
    do: %{kind: :action, source: source, content: source.description}

  defp source_result(:summary, source),
    do: %{kind: :summary, source: source, content: source.content}

  defp source_result(:session, source), do: %{kind: :session, source: source}

  defp source_kind_label(:action), do: "action"
  defp source_kind_label(:summary), do: "summary"
  defp source_kind_label(:session), do: "session"

  defp source_fields(%{kind: :action, source: source}),
    do: [
      {"Action ID", source.id},
      {"Title", source.title},
      {"Status", source.status},
      {"Project", source.project},
      {"Created by", source.created_by}
    ]

  defp source_fields(%{kind: :summary, source: source}),
    do: [
      {"Summary ID", source.id},
      {"Session", source.session_id},
      {"Project", source.project},
      {"Processing version", source.processing_version},
      {"Input revision", source.input_revision},
      {"Output revision", source.output_revision}
    ]

  defp source_fields(%{kind: :session, source: source}),
    do: [
      {"Session ID", source.session_id},
      {"Project", source.project},
      {"Agent", source.agent_id},
      {"Status", source.status},
      {"Processing version", source.processing_version},
      {"Input revision", source.input_revision}
    ]

  defp rerun(%{crystal: %{source_kind: "session", source_session_id: session_id}}, partition),
    do: Crystals.enqueue_session(session_id, partition)

  defp rerun(
         %{crystal: %{source_kind: "action_chain"}, source_action_ids: [root | _]},
         partition
       ),
       do: Crystals.build_action_chain(root, partition)

  defp rerun(_detail, _partition), do: {:error, :source_not_found}

  defp rerun_result(%{status: status}) when status in ["enqueued", "skipped"], do: status
  defp rerun_result(%Backplane.Memory.Crystals.Crystal{status: status}), do: status

  defp audit_rerun(detail, partition, result) do
    request_id = Ecto.UUID.generate()

    Audit.log(
      "crystal.crystallize",
      "admin_ui:backplane_admin",
      %{crystal_id: detail.crystal.id},
      %{
        request_id: request_id,
        correlation_id: request_id,
        host_id: partition.host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        source_kind: detail.crystal.source_kind,
        result: result
      }
    )
  end

  defp partition_from_params(params) do
    values = Map.take(params, @partition_params)

    if map_size(values) == 0 do
      {:error, :partition_required}
    else
      normalized = Map.new(values, fn {key, value} -> {key, String.trim(value || "")} end)

      if Enum.all?(@partition_params, &valid_identifier?(normalized[&1])),
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

  defp valid_identifier?(value), do: is_binary(value) and value != "" and byte_size(value) <= 512

  defp query_from_params(%{"query" => query}) when is_binary(query) do
    query = String.trim(query)
    if byte_size(query) <= 4096, do: {:ok, query}, else: {:error, :invalid_query}
  end

  defp query_from_params(_params), do: {:ok, ""}

  defp partition_query(partition),
    do: %{
      "host" => partition.host_id,
      "client" => partition.client_id,
      "scope" => partition.scope,
      "namespace" => partition.namespace
    }

  defp query_params(partition, ""), do: partition_query(partition)
  defp query_params(partition, query), do: Map.put(partition_query(partition), "query", query)

  defp detail_path(id, partition, query),
    do: ~p"/memory/crystals/#{id}?#{query_params(partition, query)}"

  defp source_path(crystal_id, kind, source_id, partition, query),
    do:
      "/memory/crystals/#{crystal_id}/sources/#{kind}/#{URI.encode(to_string(source_id))}?" <>
        URI.encode_query(query_params(partition, query))

  defp next_path(partition, query, cursor),
    do: ~p"/memory/crystals?#{Map.put(query_params(partition, query), "after", cursor)}"
end
