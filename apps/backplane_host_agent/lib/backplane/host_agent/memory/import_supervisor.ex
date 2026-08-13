defmodule Backplane.HostAgent.Memory.ImportSupervisor do
  @moduledoc "Bounded supervisor for host-local replay imports."

  use DynamicSupervisor

  @max_concurrent_imports 2

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_concurrent_imports)
  end

  def enqueue(fun, supervisor \\ __MODULE__) when is_function(fun, 0) do
    DynamicSupervisor.start_child(supervisor, Task.child_spec(fun))
  end
end
