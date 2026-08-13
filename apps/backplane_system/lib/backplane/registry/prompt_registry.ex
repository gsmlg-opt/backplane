defmodule Backplane.Registry.PromptRegistry do
  @moduledoc "Runtime registry for managed MCP prompts."

  use GenServer

  alias Backplane.Registry.PromptCatalog

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register_managed(prefix, prompts, service)
      when is_binary(prefix) and is_list(prompts) and is_atom(service) do
    GenServer.call(__MODULE__, {:register, prefix, prompts, service})
  end

  def deregister_managed(prefix) when is_binary(prefix) do
    GenServer.call(__MODULE__, {:deregister, prefix})
  end

  def clear, do: GenServer.call(__MODULE__, :clear)

  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.name)
  end

  def lookup(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, entry}] -> entry
      [] -> nil
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    rehydrate()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, prefix, prompts, service}, _from, state) do
    entries = Enum.map(prompts, &entry(prefix, &1, service))

    case PromptCatalog.register(prefix, entries) do
      :ok ->
        rehydrate()
        {:reply, :ok, state}

      {:error, :name_reserved} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:deregister, prefix}, _from, state) do
    PromptCatalog.deregister(prefix)
    rehydrate()
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    PromptCatalog.clear()
    rehydrate()
    {:reply, :ok, state}
  end

  defp entry(prefix, descriptor, service) do
    name = descriptor[:name] || descriptor["name"]

    %{
      name: name,
      prefix: prefix,
      descriptor: descriptor,
      permission: "#{prefix}.read",
      scope_target: "#{prefix}::#{name}",
      service: service
    }
  end

  defp rehydrate do
    :ets.delete_all_objects(@table)

    PromptCatalog.entries()
    |> Enum.each(&:ets.insert(@table, {&1.name, &1}))
  end
end
