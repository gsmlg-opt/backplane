defmodule Backplane.AgentRuntime.Plan do
  use GenServer

  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Host-started task-scoped plan document with expected-revision replacement.
  """

  @type state :: %{
          content: map(),
          revision: non_neg_integer(),
          scope: term()
        }

  @spec start_link(term(), map()) :: {:ok, pid()} | {:error, term()}
  def start_link(scope, content \\ %{})

  def start_link(scope, content) when is_map(content) do
    GenServer.start_link(__MODULE__, %{scope: scope, content: content, revision: 1})
  end

  def start_link(_scope, _content) do
    {:error, Error.new(:validation, "plan content must be a map")}
  end

  @spec read(pid()) :: {:ok, state()} | {:error, term()}
  def read(server) do
    GenServer.call(server, :read)
  end

  @spec update(pid(), integer(), map()) :: {:ok, state()} | {:error, Error.t()}
  def update(server, expected_revision, content) do
    GenServer.call(server, {:update, expected_revision, content})
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:read, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl GenServer
  def handle_call({:update, expected_revision, content}, _from, state)
      when is_integer(expected_revision) and is_map(content) do
    if expected_revision != state.revision do
      error =
        Error.new(:resource_conflict, "plan revision conflict",
          details: %{expected_revision: expected_revision, revision: state.revision}
        )

      {:reply, {:error, error}, state}
    else
      updated = %{state | content: content, revision: state.revision + 1}
      {:reply, {:ok, updated}, updated}
    end
  end

  @impl GenServer
  def handle_call({:update, _expected_revision, _content}, _from, state) do
    {:reply, {:error, Error.new(:validation, "expected_revision and content are required")},
     state}
  end
end
