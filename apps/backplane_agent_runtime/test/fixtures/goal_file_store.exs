defmodule Backplane.AgentRuntime.GoalFileStore do
  use GenServer
  @behaviour Backplane.AgentRuntime.Goal.Store
  alias Backplane.AgentRuntime.{Error, Goal.State}
  def start_link(dir), do: GenServer.start_link(__MODULE__, dir)
  def load(pid, thread), do: GenServer.call(pid, {:load, thread})

  def compare_and_swap(pid, thread, revision, goal_id, next),
    do: GenServer.call(pid, {:cas, thread, revision, goal_id, next})

  def replace_on_next_cas(pid, thread, record),
    do: GenServer.call(pid, {:replace_next, thread, record})

  def delay_next_cas(pid, observer), do: GenServer.call(pid, {:delay_next, observer})

  def init(dir) do
    File.mkdir_p!(dir)
    {:ok, dir}
  end

  def handle_call({:load, thread}, _, dir), do: {:reply, {:ok, read(dir, thread)}, dir}

  def handle_call({:replace_next, thread, record}, _, dir) do
    Process.put({:replace_next, thread}, record)
    {:reply, :ok, dir}
  end

  def handle_call({:delay_next, observer}, _, dir) do
    token = make_ref()
    Process.put(:delay_next, {observer, token})
    {:reply, token, dir}
  end

  def handle_call({:cas, thread, revision, goal_id, next}, _, dir) do
    if delay = Process.delete(:delay_next) do
      {observer, token} = delay
      send(observer, {:goal_cas_waiting, self(), token})

      receive do
        {:release_goal_cas, ^token} -> :ok
      after
        4_000 -> raise "goal fixture CAS latch not released"
      end
    end

    if replacement = Process.delete({:replace_next, thread}) do
      current = read(dir, thread)

      File.write!(
        path(dir, thread),
        :erlang.term_to_binary(%{replacement | revision: current.revision + 1})
      )
    end

    current = read(dir, thread)
    current_id = if current.goal, do: current.goal.goal_id

    if current.revision == revision and current_id == goal_id do
      next = %{next | revision: revision + 1}
      file = path(dir, thread)

      with :ok <- File.write(file <> ".tmp", :erlang.term_to_binary(next)),
           :ok <- File.rename(file <> ".tmp", file) do
        {:reply, {:ok, next}, dir}
      else
        {:error, reason} ->
          {:reply, {:error, Error.new(:execution_failure, "goal write failed", cause: reason)},
           dir}
      end
    else
      {:reply, {:error, Error.new(:resource_conflict, "goal CAS conflict")}, dir}
    end
  end

  defp read(dir, thread) do
    case File.read(path(dir, thread)) do
      {:ok, data} -> :erlang.binary_to_term(data, [:safe])
      {:error, :enoent} -> elem(State.new(thread, []), 1)
    end
  end

  defp path(dir, thread), do: Path.join(dir, Base.url_encode64(thread, padding: false) <> ".term")
end
