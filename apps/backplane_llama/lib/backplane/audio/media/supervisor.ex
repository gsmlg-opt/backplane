defmodule Backplane.Audio.Media.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Backplane.Audio.Media.Admission,
      Backplane.Audio.Media.TempFiles,
      {Task.Supervisor, name: Backplane.Audio.Media.TaskSupervisor},
      {DynamicSupervisor, name: Backplane.Audio.Media.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
