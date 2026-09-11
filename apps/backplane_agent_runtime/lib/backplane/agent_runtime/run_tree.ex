defmodule Backplane.AgentRuntime.RunTree do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Run-owned child relationships and cancellation propagation.

  Owner-bound children are cancelled with their owner. Hosted agents and
  unrelated peer work are never cancelled because of another run.
  """

  @type t :: map()

  @spec new(String.t(), map()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def new(root_run_id, policy) when is_binary(root_run_id) and is_map(policy) do
    with {:ok, max_depth} <- non_negative(policy, :max_depth) do
      {:ok,
       %{
         root_run_id: root_run_id,
         max_depth: max_depth,
         nodes: %{
           root_run_id => %{parent: nil, owner: nil, state: :running}
         }
       }}
    end
  end

  @spec add_child(t(), String.t(), map()) ::
          {:ok, t(), %{run_id: String.t(), depth: non_neg_integer()}}
          | {:error, Backplane.AgentRuntime.Error.t()}
  def add_child(tree, parent_run_id, child)
      when is_map(tree) and is_binary(parent_run_id) do
    with {:ok, child_run_id} <- validate_child(child),
         {:ok, owner} <- validate_owner(child),
         {:ok, depth} <- validate_depth(tree, parent_run_id) do
      if Map.has_key?(tree.nodes, child_run_id) do
        {:error,
         Error.new(:resource_conflict, "child run already exists",
           details: %{run_id: child_run_id}
         )}
      else
        nodes =
          Map.put(tree.nodes, child_run_id, %{
            parent: parent_run_id,
            owner: owner,
            state: :running
          })

        {:ok, %{tree | nodes: nodes}, %{run_id: child_run_id, depth: depth}}
      end
    end
  end

  @spec cancel(t(), String.t()) ::
          {:ok, t(), %{cancelled: list(), untouched: list()}} | {:error, Error.t()}
  def cancel(tree, run_id) when is_map(tree) and is_binary(run_id) do
    if Map.has_key?(tree.nodes, run_id) do
      descendants = descendants(tree, run_id)

      nodes =
        Enum.reduce(descendants, tree.nodes, fn child_run_id, nodes ->
          Map.update!(nodes, child_run_id, &%{&1 | state: :cancelled})
        end)

      nodes = Map.update!(nodes, run_id, &%{&1 | state: :cancelled})

      untouched =
        tree.nodes
        |> Map.keys()
        |> Enum.reject(&(&1 in descendants or &1 == run_id))

      {:ok, %{tree | nodes: nodes}, %{cancelled: [run_id | descendants], untouched: untouched}}
    else
      {:error, Error.new(:not_found, "run not found", details: %{run_id: run_id})}
    end
  end

  defp non_negative(policy, key) do
    value = Map.get(policy, key)

    if is_integer(value) and value >= 0 do
      {:ok, value}
    else
      {:error, Error.new(:validation, "policy #{key} must be non-negative")}
    end
  end

  defp validate_child(%{run_id: run_id}) when is_binary(run_id), do: {:ok, run_id}
  defp validate_child(_), do: {:error, Error.new(:validation, "child run_id is required")}

  defp validate_owner(%{owner: owner}) when owner in [:run, nil], do: {:ok, owner}
  defp validate_owner(_), do: {:error, Error.new(:validation, "child owner is invalid")}

  defp validate_depth(tree, parent_run_id) do
    case Map.get(tree.nodes, parent_run_id) do
      nil ->
        {:error, Error.new(:not_found, "parent run not found", details: %{parent: parent_run_id})}

      _parent ->
        depth = depth(tree.nodes, parent_run_id, 0)

        if depth + 1 > tree.max_depth do
          {:error,
           Error.new(:budget_exceeded, "run tree depth exceeded",
             details: %{depth: depth + 1, max_depth: tree.max_depth}
           )}
        else
          {:ok, depth + 1}
        end
    end
  end

  defp depth(_nodes, "root", depth), do: depth

  defp depth(nodes, run_id, current) do
    case Map.get(nodes, run_id) do
      %{parent: nil} -> current + 1
      %{parent: parent} -> depth(nodes, parent, current + 1)
      _ -> current
    end
  end

  defp descendants(tree, run_id) do
    tree.nodes
    |> Enum.filter(fn {_run_id, node} -> node.parent == run_id end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.flat_map(&[&1 | descendants(tree, &1)])
  end
end
