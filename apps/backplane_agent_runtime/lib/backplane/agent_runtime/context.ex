defmodule Backplane.AgentRuntime.Context do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Versioned context ownership and composition.

  Contexts have at most one active writer. A snapshot is explicitly selected
  material only. Peer results and tool output are provenance-tagged data, never
  replacement instructions.
  """

  @type t :: map()

  @spec create(String.t(), list(), list()) :: {:ok, t()} | {:error, Error.t()}
  def create(agent_id, instructions, selected \\ [])
      when is_binary(agent_id) and is_list(instructions) and is_list(selected) do
    with {:ok, _} <- validate_instructions(instructions),
         {:ok, _} <- validate_selected(selected) do
      {:ok,
       %{
         context_id: "ctx_" <> unique_id(),
         agent_id: agent_id,
         revision: 1,
         writer: nil,
         instructions: instructions,
         selected_material: selected,
         history: [],
         summaries: [],
         resources: []
       }}
    end
  end

  @spec fork(t(), map(), map()) :: {:ok, t()} | {:error, Error.t()}
  def fork(context, child, selection)
      when is_map(context) and is_map(child) and is_list(selection) do
    if :instructions in selection do
      {:error, Error.new(:forbidden, "child instructions cannot be replaced by parent selection")}
    else
      {:ok,
       %{
         context_id: "ctx_" <> unique_id(),
         agent_id: Map.get(child, :agent_id),
         revision: 1,
         writer: nil,
         instructions: Map.get(child, :instructions),
         selected_material: Map.take(context, selection),
         history: [],
         summaries: [],
         resources: []
       }}
    end
  end

  @spec admit_result(t(), map(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def admit_result(context, result, expected_revision)
      when is_map(context) and is_map(result) and is_integer(expected_revision) do
    with {:ok, _} <- same_revision(context, expected_revision),
         {:ok, _} <- reject_instructions(result) do
      admitted = %{
        content: Map.get(result, :content),
        provenance: Map.get(result, :provenance, %{}),
        revision: expected_revision
      }

      history = context.history ++ [admitted]
      {:ok, %{context | revision: context.revision + 1, history: history}}
    end
  end

  @spec compaction(t(), map(), map(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def compaction(context, summary, usage, expected_revision)
      when is_map(context) and is_map(summary) and is_integer(expected_revision) do
    with {:ok, _} <- same_revision(context, expected_revision) do
      {:ok,
       %{
         context
         | revision: context.revision + 1,
           history: [],
           summaries: context.summaries ++ [%{summary: summary, usage: usage}]
       }}
    end
  end

  defp validate_instructions(instructions) when is_list(instructions), do: {:ok, instructions}

  defp validate_instructions(_),
    do: {:error, Error.new(:validation, "instructions must be a list")}

  defp validate_selected(selected) when is_list(selected), do: {:ok, selected}

  defp validate_selected(_),
    do: {:error, Error.new(:validation, "selected material must be a list")}

  defp same_revision(%{revision: revision} = _context, expected_revision)
       when revision == expected_revision,
       do: {:ok, expected_revision}

  defp same_revision(%{revision: revision}, expected_revision) do
    {:error,
     Error.new(:resource_conflict, "context revision conflict",
       details: %{expected: expected_revision, current: revision}
     )}
  end

  defp reject_instructions(result) do
    if Map.has_key?(result, :instructions) do
      {:error, Error.new(:forbidden, "result cannot rewrite instructions")}
    else
      {:ok, result}
    end
  end

  defp unique_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
