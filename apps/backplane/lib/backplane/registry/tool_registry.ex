defmodule Backplane.Registry.ToolRegistry do
  @moduledoc """
  ETS-backed tool registry with namespace support.

  All tools use `::` as the namespace separator.
  """

  use GenServer

  alias Backplane.Registry.Tool

  @table :backplane_tools
  @separator "::"

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

  @doc "Register tools from an upstream MCP server with a namespace prefix."
  @spec register_upstream(String.t(), pid(), [map()]) :: :ok
  def register_upstream(prefix, upstream_pid, tools) when is_list(tools) do
    rows =
      Enum.map(tools, fn tool ->
        namespaced = prefix <> @separator <> tool.name

        entry = %Tool{
          name: namespaced,
          description: tool.description,
          input_schema: tool.input_schema,
          origin: {:upstream, prefix},
          upstream_pid: upstream_pid,
          original_name: tool.name,
          timeout: tool.timeout
        }

        {namespaced, entry}
      end)

    # Bulk insert — atomic from readers' perspective
    :ets.insert(@table, rows)
    Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/tools/list_changed")
    :ok
  end

  @doc "Deregister all tools from a given upstream prefix."
  @spec deregister_upstream(String.t()) :: :ok
  def deregister_upstream(prefix) do
    pattern = prefix <> @separator

    # Atomic select_delete — avoids race with concurrent register_upstream
    match_spec = [
      {{:"$1", :_}, [{:==, {:binary_part, :"$1", 0, byte_size(pattern)}, pattern}], [true]}
    ]

    :ets.select_delete(@table, match_spec)
    Backplane.PubSubBroadcaster.broadcast_mcp_notification("notifications/tools/list_changed")
    :ok
  end

  @doc "List all registered tools as MCP tool definitions."
  @spec list_all() :: [Tool.t()]
  def list_all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, tool} -> tool end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Resolve a tool name to its handler."
  @spec resolve(String.t()) ::
          {:native, module(), atom() | nil}
          | {:upstream, pid(), String.t(), pos_integer()}
          | :not_found
  def resolve(name) do
    case :ets.lookup(@table, name) do
      [{^name, %{origin: :native, module: module, handler: handler}}] ->
        {:native, module, handler}

      [{^name, %{origin: {:upstream, _}, upstream_pid: pid, original_name: original} = tool}] ->
        {:upstream, pid, original, tool.timeout}

      [] ->
        :not_found
    end
  end

  @doc "Look up a tool by name, returning the full tool struct or nil."
  @spec lookup(String.t()) :: Tool.t() | nil
  def lookup(name) do
    case :ets.lookup(@table, name) do
      [{^name, tool}] -> tool
      [] -> nil
    end
  end

  @doc "Search tools by name or description substring. Name matches rank higher."
  @spec search(String.t(), keyword()) :: [Tool.t()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    query_down = String.downcase(query)

    @table
    |> :ets.tab2list()
    |> Enum.reduce([], fn {_key, tool}, acc ->
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
    :ets.info(@table, :size)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
