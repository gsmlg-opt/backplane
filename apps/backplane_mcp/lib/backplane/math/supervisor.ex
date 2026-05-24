defmodule Backplane.Math.Supervisor do
  @moduledoc "Supervisor for the native Math server runtime."

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      Backplane.Math.Config,
      Backplane.Math.Sandbox
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
