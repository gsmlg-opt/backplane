defmodule Backplane.Diagnostics.Analyses.Supervisor do
  @moduledoc "Supervises periodic dispatch of durable analysis jobs."

  use Supervisor

  alias Backplane.Diagnostics.Analyses.Runner

  @tasks Backplane.Diagnostics.Analyses.Tasks

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    workers = Keyword.get(opts, :workers, 2)

    runners =
      for index <- 1..workers do
        opts = Keyword.put(opts, :task_supervisor, @tasks)
        Supervisor.child_spec({Runner, opts}, id: {Runner, index})
      end

    Supervisor.init([{Task.Supervisor, name: @tasks} | runners], strategy: :one_for_one)
  end
end
