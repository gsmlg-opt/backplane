defmodule Backplane.Skills.AgentManage.Bootstrap do
  @moduledoc false

  use GenServer

  require Logger

  alias Backplane.Skills.AgentManage

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(state) do
    {:ok, state, {:continue, :ensure_all_agents}}
  end

  @impl true
  def handle_continue(:ensure_all_agents, state) do
    case AgentManage.ensure_all_agents() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("AgentManage bootstrap failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
