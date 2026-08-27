defmodule Backplane.Registry.ToolRegistry do
  @moduledoc """
  ETS-backed tool registry with namespace support.

  All tools use `::` as the namespace separator.
  """

  use GenServer

  alias Backplane.Registry.{Namespace, Tool}

  @table :backplane_tools

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Register a native tool module."
  @spec register_native(Tool.t()) :: :ok
  def register_native(%Tool{origin: :native} = tool) do
    :ets.insert(@table, {tool.name, tool})
    Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/tools/list_changed")
    :ok
  end

  @doc "Deregister a native tool by name."
  @spec deregister_native(String.t()) :: :ok
  def deregister_native(name) when is_binary(name) do
    :ets.delete(@table, name)
    Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/tools/list_changed")
    :ok
  end

  @doc "Register tools from an upstream MCP server with a namespace prefix."
  @spec register_upstream(String.t(), pid(), [map()]) :: :ok
  def register_upstream(prefix, upstream_pid, tools) when is_list(tools) do
    original_prefix = prefix
    prefix = Namespace.normalize_prefix(prefix)

    catalog =
      Map.new(tools, fn tool ->
        namespaced = Namespace.prefix(prefix, tool.name)

        entry = %Tool{
          name: namespaced,
          title: Map.get(tool, :title),
          description: tool.description,
          input_schema: tool.input_schema,
          output_schema: tool.output_schema,
          annotations: tool.annotations,
          icon: tool.icon,
          icons: Map.get(tool, :icons),
          meta: Map.get(tool, :meta),
          execution: Map.get(tool, :execution),
          origin: {:upstream, prefix},
          upstream_pid: upstream_pid,
          original_name: tool.name,
          timeout: tool.timeout
        }

        {namespaced, entry}
      end)

    :ets.insert(@table, {upstream_catalog_key(prefix), {upstream_pid, catalog}})

    original_prefix
    |> upstream_prefixes_to_delete()
    |> Enum.each(&delete_upstream_prefix/1)

    Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/tools/list_changed")
    :ok
  end

  @doc "Register tools from a managed service with a namespace prefix."
  @spec register_managed(String.t(), [map()]) :: :ok
  def register_managed(prefix, tools) when is_list(tools) do
    rows =
      Enum.map(tools, fn tool ->
        entry = %Tool{
          name: tool.name,
          description: tool.description,
          input_schema: tool.input_schema,
          output_schema: Map.get(tool, :output_schema),
          annotations: Map.get(tool, :annotations),
          icon: Map.get(tool, :icon),
          origin: {:managed, prefix},
          handler: tool.handler
        }

        {tool.name, entry}
      end)

    :ets.insert(@table, rows)
    Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/tools/list_changed")
    :ok
  end

  @doc "Deregister all tools from a given managed service prefix."
  @spec deregister_managed(String.t()) :: :ok
  def deregister_managed(prefix) do
    deregister_upstream(prefix)
  end

  @doc "Deregister all tools from a given upstream prefix."
  @spec deregister_upstream(String.t()) :: :ok
  def deregister_upstream(prefix) do
    prefix
    |> upstream_prefixes_to_delete()
    |> Enum.each(&delete_upstream_prefix/1)

    prefix
    |> Namespace.normalize_prefix()
    |> upstream_catalog_key()
    |> then(&:ets.delete(@table, &1))

    Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/tools/list_changed")
    :ok
  end

  @doc "Deregister an upstream catalog only when `owner` still owns the current snapshot."
  @spec deregister_upstream(String.t(), pid()) :: :ok
  def deregister_upstream(prefix, owner) when is_pid(owner) do
    prefix = Namespace.normalize_prefix(prefix)
    direct_deleted = delete_upstream_owner_rows(prefix, owner)
    snapshot_deleted = delete_upstream_catalog(prefix, owner)

    if direct_deleted + snapshot_deleted > 0 do
      Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/tools/list_changed")
    end

    :ok
  end

  @doc "List all registered tools as MCP tool definitions."
  @spec list_all() :: [Tool.t()]
  def list_all do
    rows = :ets.tab2list(@table)
    {catalog_rows, direct_rows} = Enum.split_with(rows, &upstream_catalog_row?/1)

    snapshot_prefixes =
      MapSet.new(catalog_rows, fn {{__MODULE__, :upstream_catalog, prefix}, {_owner, _catalog}} ->
        prefix
      end)

    snapshot_rows =
      Enum.flat_map(catalog_rows, fn {_key, {_owner, catalog}} ->
        Enum.map(catalog, fn {name, tool} -> {name, tool} end)
      end)

    direct_rows = Enum.reject(direct_rows, &hidden_upstream_row?(&1, snapshot_prefixes))

    (snapshot_rows ++ direct_rows)
    |> Enum.map(&canonical_tool_row/1)
    |> Enum.sort_by(fn {name, rank, _tool} -> {name, rank} end)
    |> Enum.uniq_by(fn {name, _rank, _tool} -> name end)
    |> Enum.map(fn {_name, _rank, tool} -> tool end)
  end

  @doc "Resolve a tool name to its handler."
  @spec resolve(String.t()) ::
          {:native, module(), atom() | nil}
          | {:upstream, pid(), String.t(), pos_integer()}
          | {:managed, Tool.handler()}
          | :not_found
  def resolve(name) do
    case lookup_tool_row(name) do
      {_key, %{origin: :native, module: module, handler: handler}} ->
        {:native, module, handler}

      {_key, %{origin: {:upstream, _}, upstream_pid: pid, original_name: original} = tool} ->
        {:upstream, pid, original, tool.timeout}

      {_key, %{origin: {:managed, _}, handler: handler}} ->
        {:managed, handler}

      nil ->
        :not_found
    end
  end

  @doc "Look up a tool by name, returning the full tool struct or nil."
  @spec lookup(String.t()) :: Tool.t() | nil
  def lookup(name) do
    case lookup_tool_row(name) do
      {_key, tool} -> canonical_tool(tool)
      nil -> nil
    end
  end

  @doc "Search tools by name or description substring. Name matches rank higher."
  @spec search(String.t(), keyword()) :: [Tool.t()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    query_down = String.downcase(query)

    list_all()
    |> Enum.reduce([], fn tool, acc ->
      name_down = String.downcase(tool.name)
      desc_down = String.downcase(tool.description)
      name_match = String.contains?(name_down, query_down)
      desc_match = String.contains?(desc_down, query_down)

      cond do
        name_match -> [{0, tool} | acc]
        desc_match -> [{1, tool} | acc]
        true -> acc
      end
    end)
    |> Enum.sort_by(fn {rank, tool} -> {rank, tool.name} end)
    |> Enum.take(limit)
    |> Enum.map(fn {_rank, tool} -> tool end)
  end

  @doc "Count registered tools."
  @spec count() :: non_neg_integer()
  def count do
    length(list_all())
  end

  defp lookup_tool_row(name) do
    case lookup_upstream_catalog(name) do
      {:ok, tool} ->
        {name, tool}

      {:catalog_miss, prefix} ->
        name
        |> lookup_direct_tool_row()
        |> reject_hidden_upstream_row(prefix)

      :no_catalog ->
        lookup_direct_tool_row(name)
    end
  end

  defp lookup_direct_tool_row(name) do
    case :ets.lookup(@table, name) do
      [{^name, %Tool{} = tool}] -> {name, tool}
      _missing_or_private -> find_canonical_tool_row(name)
    end
  end

  defp find_canonical_tool_row(name) do
    @table
    |> :ets.tab2list()
    |> Enum.reject(&upstream_catalog_row?/1)
    |> Enum.find(fn {_key, tool} -> canonical_tool(tool).name == name end)
  end

  defp canonical_tool_row({key, tool}) do
    canonical_tool = canonical_tool(tool)
    rank = if key == canonical_tool.name and tool.name == canonical_tool.name, do: 0, else: 1

    {canonical_tool.name, rank, canonical_tool}
  end

  defp canonical_tool(%Tool{origin: {:upstream, prefix}} = tool) do
    prefix = Namespace.normalize_prefix(prefix)
    original_name = tool.original_name || local_tool_name(tool.name)

    %{tool | name: Namespace.prefix(prefix, original_name), origin: {:upstream, prefix}}
  end

  defp canonical_tool(tool), do: tool

  defp local_tool_name(name) when is_binary(name) do
    case String.split(name, Namespace.separator(), parts: 2) do
      [_prefix, tool_name] -> tool_name
      [tool_name] -> tool_name
    end
  end

  defp upstream_prefixes_to_delete(prefix) do
    normalized = Namespace.normalize_prefix(prefix)
    path_like = if is_binary(normalized), do: "/" <> normalized

    [prefix, normalized, path_like]
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp delete_upstream_prefix(prefix) do
    pattern = prefix <> Namespace.separator()

    # Atomic select_delete — avoids race with concurrent register_upstream
    match_spec = [
      {{:"$1", :_},
       [
         {:is_binary, :"$1"},
         {:==, {:binary_part, :"$1", 0, byte_size(pattern)}, pattern}
       ], [true]}
    ]

    :ets.select_delete(@table, match_spec)
  end

  defp lookup_upstream_catalog(name) when is_binary(name) do
    case String.split(name, Namespace.separator(), parts: 2) do
      [prefix, _tool_name] ->
        prefix = Namespace.normalize_prefix(prefix)

        case :ets.lookup(@table, upstream_catalog_key(prefix)) do
          [{_key, {_owner, catalog}}] ->
            case Map.fetch(catalog, name) do
              {:ok, tool} -> {:ok, tool}
              :error -> {:catalog_miss, prefix}
            end

          [] ->
            :no_catalog
        end

      [_unprefixed] ->
        :no_catalog
    end
  end

  defp reject_hidden_upstream_row(nil, _prefix), do: nil

  defp reject_hidden_upstream_row({_key, %Tool{origin: {:upstream, prefix}}} = row, hidden_prefix)
       when is_binary(prefix) do
    if Namespace.normalize_prefix(prefix) == hidden_prefix, do: nil, else: row
  end

  defp reject_hidden_upstream_row(row, _prefix), do: row

  defp hidden_upstream_row?({_key, %Tool{origin: {:upstream, prefix}}}, snapshot_prefixes)
       when is_binary(prefix) do
    MapSet.member?(snapshot_prefixes, Namespace.normalize_prefix(prefix))
  end

  defp hidden_upstream_row?(_row, _snapshot_prefixes), do: false

  defp upstream_catalog_row?({{__MODULE__, :upstream_catalog, prefix}, {owner, catalog}})
       when is_binary(prefix) and is_pid(owner) and is_map(catalog),
       do: true

  defp upstream_catalog_row?(_row), do: false

  defp upstream_catalog_key(prefix), do: {__MODULE__, :upstream_catalog, prefix}

  defp delete_upstream_catalog(prefix, owner) do
    key = upstream_catalog_key(prefix)
    :ets.select_delete(@table, [{{key, {owner, :_}}, [], [true]}])
  end

  defp delete_upstream_owner_rows(prefix, owner) do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(0, fn
      {key,
       %Tool{
         origin: {:upstream, row_prefix},
         upstream_pid: ^owner
       }},
      deleted
      when is_binary(key) and is_binary(row_prefix) ->
        if Namespace.normalize_prefix(row_prefix) == prefix do
          :ets.delete(@table, key)
          deleted + 1
        else
          deleted
        end

      _row, deleted ->
        deleted
    end)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
