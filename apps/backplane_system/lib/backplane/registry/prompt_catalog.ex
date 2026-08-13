defmodule Backplane.Registry.PromptCatalog do
  @moduledoc false

  use GenServer

  @desired_state_key {__MODULE__, :desired_registrations}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register(prefix, entries), do: GenServer.call(__MODULE__, {:register, prefix, entries})

  def deregister(prefix), do: GenServer.call(__MODULE__, {:deregister, prefix})

  def clear, do: GenServer.call(__MODULE__, :clear)

  def entries, do: GenServer.call(__MODULE__, :entries)

  def cleanup, do: :persistent_term.erase(@desired_state_key)

  @impl true
  def init(_opts), do: {:ok, desired_registrations()}

  @impl true
  def handle_call({:register, prefix, entries}, _from, registrations) do
    reserved_names =
      registrations
      |> Map.delete(prefix)
      |> Map.values()
      |> List.flatten()
      |> MapSet.new(& &1.name)

    if Enum.any?(entries, &MapSet.member?(reserved_names, &1.name)) do
      {:reply, {:error, :name_reserved}, registrations}
    else
      next_registrations = Map.put(registrations, prefix, entries)
      persist(next_registrations)
      {:reply, :ok, next_registrations}
    end
  end

  def handle_call({:deregister, prefix}, _from, registrations) do
    next_registrations = Map.delete(registrations, prefix)
    persist(next_registrations)
    {:reply, :ok, next_registrations}
  end

  def handle_call(:clear, _from, _registrations) do
    persist(%{})
    {:reply, :ok, %{}}
  end

  def handle_call(:entries, _from, registrations) do
    {:reply, registrations |> Map.values() |> List.flatten(), registrations}
  end

  defp desired_registrations, do: :persistent_term.get(@desired_state_key, %{})

  defp persist(registrations), do: :persistent_term.put(@desired_state_key, registrations)
end
