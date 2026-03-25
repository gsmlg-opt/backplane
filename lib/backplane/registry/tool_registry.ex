defmodule Backplane.Registry.ToolRegistry do
  @moduledoc """
  ETS-backed tool registry with namespace support.

  All tools use `::` as the namespace separator.
  """

  use GenServer

  @table :backplane_tools
  @separator "::"

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Register a native tool module."
  def register_native(%Backplane.Registry.Tool{origin: :native} = tool) do
    :ets.insert(@table, {tool.name, tool})
    :ok
  end

  @doc "Register tools from an upstream MCP server with a namespace prefix."
  def register_upstream(prefix, upstream_pid, tools) when is_list(tools) do
    Enum.each(tools, fn tool ->
      namespaced = prefix <> @separator <> tool.name

      entry = %Backplane.Registry.Tool{
        name: namespaced,
        description: tool.description,
        input_schema: tool.input_schema,
        origin: {:upstream, prefix},
        upstream_pid: upstream_pid,
        original_name: tool.name
      }

      :ets.insert(@table, {namespaced, entry})
    end)

    :ok
  end

  @doc "Deregister all tools from a given upstream prefix."
  def deregister_upstream(prefix) do
    pattern = prefix <> @separator

    match_spec = [
      {{:"$1", :_}, [{:==, {:binary_part, :"$1", 0, byte_size(pattern)}, pattern}], [:"$1"]}
    ]

    keys = :ets.select(@table, match_spec)
    Enum.each(keys, &:ets.delete(@table, &1))
    :ok
  end

  @doc "List all registered tools as MCP tool definitions."
  def list_all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, tool} -> tool end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Resolve a tool name to its handler."
  def resolve(name) do
    case :ets.lookup(@table, name) do
      [{^name, %{origin: :native, module: module, handler: handler}}] ->
        {:native, module, handler}

      [{^name, %{origin: {:upstream, _}, upstream_pid: pid, original_name: original}}] ->
        {:upstream, pid, original}

      [] ->
        :not_found
    end
  end

  @doc "Look up a tool by name, returning the full tool struct or nil."
  def lookup(name) do
    case :ets.lookup(@table, name) do
      [{^name, tool}] -> tool
      [] -> nil
    end
  end

  @doc "Search tools by name or description substring."
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    query_down = String.downcase(query)

    list_all()
    |> Enum.filter(fn tool ->
      String.contains?(String.downcase(tool.name), query_down) or
        String.contains?(String.downcase(tool.description), query_down)
    end)
    |> Enum.take(limit)
  end

  @doc "Count registered tools."
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
