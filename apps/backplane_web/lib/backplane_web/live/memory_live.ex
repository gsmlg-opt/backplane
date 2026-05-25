defmodule BackplaneWeb.MemoryLive do
  @moduledoc """
  Browse, filter, view, and soft-delete memories from the `bpm_memories` store.
  Filters are URL-driven (type, scope, agent_id, q, deleted, page).
  """

  use BackplaneWeb, :live_view

  alias BackplaneMemory.Memory

  @page_size 25
  @memory_types ~w(working episodic semantic procedural)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/memory/browse",
       memories: [],
       total: 0,
       loading: true,
       filters: empty_filters(),
       page: 1,
       expanded: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)
    page = parse_page(params)
    {:noreply, load_memories(socket, filters, page)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters =
      socket.assigns.filters
      |> Map.merge(parse_filters(params))

    {:noreply, push_patch(socket, to: build_path(filters, 1))}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/memory/browse")}
  end

  def handle_event("expand", %{"id" => id}, socket) do
    next = if socket.assigns.expanded == id, do: nil, else: id
    {:noreply, assign(socket, expanded: next)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Memory.forget(id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Memory forgotten")
         |> load_memories(socket.assigns.filters, socket.assigns.page)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Memory not found")}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp empty_filters,
    do: %{"type" => "", "scope" => "", "agent_id" => "", "q" => "", "deleted" => "false"}

  defp parse_filters(params) when is_map(params) do
    %{
      "type" => to_string(params["type"] || ""),
      "scope" => to_string(params["scope"] || ""),
      "agent_id" => to_string(params["agent_id"] || ""),
      "q" => to_string(params["q"] || ""),
      "deleted" => to_string(params["deleted"] || "false")
    }
  end

  defp parse_page(params) do
    case Integer.parse(to_string(params["page"] || "1")) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp load_memories(socket, filters, page) do
    opts = filter_opts(filters, page)

    list_opts =
      Keyword.drop(opts, [:limit, :offset]) ++
        [limit: @page_size, offset: (page - 1) * @page_size]

    memories = safe_call(fn -> Memory.list(list_opts) end, [])
    total = safe_call(fn -> Memory.count(Keyword.drop(opts, [:limit, :offset])) end, 0)

    assign(socket,
      loading: false,
      memories: memories,
      total: total,
      filters: filters,
      page: page
    )
  end

  defp filter_opts(filters, _page) do
    [
      type: filters["type"],
      scope: filters["scope"],
      agent_id: filters["agent_id"],
      q: filters["q"],
      include_deleted: filters["deleted"] == "true"
    ]
  end

  defp build_path(filters, page) do
    qp =
      filters
      |> Enum.reject(fn {_k, v} -> v == "" or v == "false" end)
      |> Enum.into(%{})
      |> Map.put("page", page)

    ~p"/admin/memory/browse?#{qp}"
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp total_pages(total) when is_integer(total) do
    max(1, div(total + @page_size - 1, @page_size))
  end

  defp truncate(nil, _len), do: ""

  defp truncate(content, len) when is_binary(content) do
    if String.length(content) > len do
      String.slice(content, 0, len) <> "…"
    else
      content
    end
  end

  defp type_badge_variant("working"), do: "info"
  defp type_badge_variant("episodic"), do: "primary"
  defp type_badge_variant("semantic"), do: "success"
  defp type_badge_variant("procedural"), do: "warning"
  defp type_badge_variant(_), do: "ghost"

  defp format_dt(nil), do: ""

  defp format_dt(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp present?(value), do: value not in [nil, ""]

  defp tag_list(tags) when is_list(tags), do: tags
  defp tag_list(_tags), do: []

  defp short_id(nil), do: ""
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp format_confidence(nil), do: "-"

  defp format_confidence(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  defp format_confidence(value), do: to_string(value)

  # ── Template ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :memory_types, @memory_types)

    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-bold">Memories</h1>
          <p class="text-sm text-on-surface-variant mt-1">
            Browse, filter, and forget agent memories. Total matching: <span class="font-medium">{@total}</span>.
          </p>
        </div>
      </div>

      <.dm_card variant="bordered" class="mb-4">
        <.form for={%{}} as={:filters} phx-change="filter" phx-submit="filter" class="space-y-3">
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-5">
            <div>
              <label class="block text-xs font-medium mb-1">Type</label>
              <select
                name="filters[type]"
                class="select select-bordered w-full"
              >
                <option value="" selected={@filters["type"] == ""}>All types</option>
                <option :for={t <- @memory_types} value={t} selected={@filters["type"] == t}>
                  {t}
                </option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium mb-1">Scope</label>
              <input
                type="text"
                name="filters[scope]"
                value={@filters["scope"]}
                placeholder="global"
                class="input input-bordered w-full"
                phx-debounce="400"
              />
            </div>
            <div>
              <label class="block text-xs font-medium mb-1">Agent ID</label>
              <input
                type="text"
                name="filters[agent_id]"
                value={@filters["agent_id"]}
                placeholder="agent-..."
                class="input input-bordered w-full"
                phx-debounce="400"
              />
            </div>
            <div class="lg:col-span-2">
              <label class="block text-xs font-medium mb-1">Search content</label>
              <input
                type="text"
                name="filters[q]"
                value={@filters["q"]}
                placeholder="substring match"
                class="input input-bordered w-full"
                phx-debounce="400"
              />
            </div>
          </div>
          <div class="flex items-center gap-3">
            <label class="inline-flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                name="filters[deleted]"
                value="true"
                checked={@filters["deleted"] == "true"}
                class="checkbox checkbox-sm"
              />
              Include soft-deleted
            </label>
            <.dm_btn type="button" size="xs" phx-click="clear-filters">Clear</.dm_btn>
          </div>
        </.form>
      </.dm_card>

      <div :if={@memories == [] and not @loading} class="text-on-surface-variant py-12 text-center">
        No memories match these filters.
      </div>

      <.dm_table :if={@memories != []} id="memories-table" data={@memories} hover zebra>
        <:col :let={mem} label="Type" class="align-top">
          <div class="space-y-1">
            <.dm_badge variant={type_badge_variant(mem.memory_type)} size="sm">
              {mem.memory_type}
            </.dm_badge>
            <div class="font-mono text-xs text-on-surface-variant">{short_id(mem.id)}</div>
            <div :if={mem.deleted_at} class="text-xs text-error">deleted</div>
          </div>
        </:col>
        <:col :let={mem} label="Content" class="align-top">
          <div class="max-w-2xl">
            <div :if={@expanded != mem.id} class="text-sm break-words">
              {truncate(mem.content, 240)}
            </div>

            <div :if={@expanded == mem.id} class="space-y-3">
              <pre class="max-h-80 overflow-auto whitespace-pre-wrap break-words rounded bg-surface-container p-3 text-xs">{mem.content}</pre>

              <div class="grid grid-cols-1 gap-2 text-xs text-on-surface-variant sm:grid-cols-2">
                <div><span class="font-medium">ID:</span> <span class="font-mono">{mem.id}</span></div>
                <div :if={present?(mem.host_id)}>
                  <span class="font-medium">Host:</span> <span class="font-mono">{mem.host_id}</span>
                </div>
                <div :if={present?(mem.client_id)}>
                  <span class="font-medium">Client:</span> <span class="font-mono">{mem.client_id}</span>
                </div>
                <div :if={present?(mem.session_id)}>
                  <span class="font-medium">Session:</span> <span class="font-mono">{mem.session_id}</span>
                </div>
                <div :if={present?(mem.embedding_model)}>
                  <span class="font-medium">Embedding model:</span> {mem.embedding_model}
                </div>
                <div :if={mem.expires_at}>
                  <span class="font-medium">Expires:</span> {format_dt(mem.expires_at)}
                </div>
              </div>

              <div :if={mem.metadata not in [nil, %{}]}>
                <div class="mb-1 text-xs font-medium text-on-surface-variant">Metadata</div>
                <pre class="overflow-x-auto rounded bg-surface-container p-2 text-xs">{Jason.encode!(mem.metadata, pretty: true)}</pre>
              </div>
            </div>
          </div>
        </:col>
        <:col :let={mem} label="Scope" class="align-top">
          <div class="space-y-1 text-xs">
            <div class="font-mono break-all">{mem.scope}</div>
            <div :if={present?(mem.namespace)} class="text-on-surface-variant">
              namespace: <span class="font-mono">{mem.namespace}</span>
            </div>
          </div>
        </:col>
        <:col :let={mem} label="Agent" class="align-top">
          <div class="space-y-1 text-xs">
            <div :if={present?(mem.agent_id)} class="font-mono break-all">{mem.agent_id}</div>
            <div :if={!present?(mem.agent_id)} class="text-on-surface-variant">-</div>
            <div :if={present?(mem.session_id)} class="text-on-surface-variant">
              session: <span class="font-mono">{short_id(mem.session_id)}</span>
            </div>
          </div>
        </:col>
        <:col :let={mem} label="Tags" class="align-top">
          <div class="flex flex-wrap gap-1">
            <.dm_badge :for={tag <- tag_list(mem.tags)} variant="ghost" size="sm">{tag}</.dm_badge>
            <span :if={tag_list(mem.tags) == []} class="text-xs text-on-surface-variant">-</span>
          </div>
        </:col>
        <:col :let={mem} label="Activity" class="align-top">
          <div class="space-y-1 text-xs">
            <div>{format_dt(mem.inserted_at)}</div>
            <div class="text-on-surface-variant">
              confidence: {format_confidence(mem.confidence)}
            </div>
            <div class="text-on-surface-variant">
              access: {mem.access_count || 0}
            </div>
            <div :if={mem.deleted_at} class="text-error">
              deleted: {format_dt(mem.deleted_at)}
            </div>
          </div>
        </:col>
        <:col :let={mem} label="Actions" class="align-top">
          <div class="flex flex-wrap gap-2">
            <.dm_btn type="button" size="xs" phx-click="expand" phx-value-id={mem.id}>
              {if @expanded == mem.id, do: "Collapse", else: "Expand"}
            </.dm_btn>
            <.dm_btn
              :if={is_nil(mem.deleted_at)}
              type="button"
              size="xs"
              variant="error"
              phx-click="delete"
              phx-value-id={mem.id}
              data-confirm="Forget this memory? It will be soft-deleted."
            >
              Forget
            </.dm_btn>
          </div>
        </:col>
      </.dm_table>

      <div :if={@total > 0} class="flex items-center justify-between mt-4 text-sm">
        <div class="text-on-surface-variant">
          Page {@page} of {total_pages(@total)}
        </div>
        <div class="flex items-center gap-2">
          <.link :if={@page > 1} patch={build_path(@filters, @page - 1)}>
            <.dm_btn size="xs">Previous</.dm_btn>
          </.link>
          <.link :if={@page < total_pages(@total)} patch={build_path(@filters, @page + 1)}>
            <.dm_btn size="xs">Next</.dm_btn>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
