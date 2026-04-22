defmodule Backplane.Math.Sandbox do
  @moduledoc """
  Bounded execution wrapper for Math operations.
  """

  @name __MODULE__

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task.Supervisor, :start_link, [[name: @name]]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec run((-> term()), pos_integer()) ::
          {:ok, term()} | {:error, :timeout | {:exit, term()}}
  def run(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.Supervisor.async_nolink(@name, fun)

    case Task.yield(task, timeout_ms) do
      {:ok, value} ->
        {:ok, value}

      {:exit, reason} ->
        {:error, {:exit, reason}}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
