defmodule Backplane.AgentRuntime.Codex.ContextTools do
  @moduledoc """
  Context window operations which preserve run-owned resources and authority.
  """

  alias Backplane.AgentRuntime.Error

  @spec new_context(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def new_context(context, opts \\ %{}) when is_map(context) and is_map(opts) do
    if Map.get(context, :run_id) == nil or Map.get(context, :environment) == nil do
      {:error, Error.new(:validation, "context must include run_id and environment")}
    else
      replacement =
        Map.merge(context, %{
          context_id: "ctx_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
          revision: Map.get(context, :revision, 0) + 1,
          messages: Map.get(opts, :messages, []),
          history:
            Map.get(context, :history, []) ++
              [%{type: :context_replaced, provenance: Map.get(opts, :provenance, %{})}]
        })

      {:ok, replacement}
    end
  end

  @spec get_context_remaining(map()) :: {:ok, map()} | {:error, Error.t()}
  def get_context_remaining(context) when is_map(context) do
    case {Map.get(context, :capacity), Map.get(context, :occupancy)} do
      {capacity, occupancy}
      when is_integer(capacity) and is_integer(occupancy) and capacity >= occupancy ->
        {:ok,
         %{
           capacity: capacity,
           occupancy: occupancy,
           remaining: capacity - occupancy,
           availability: :known
         }}

      _ ->
        {:ok,
         %{
           capacity: :unknown,
           occupancy: :unknown,
           remaining: :unknown,
           availability: :unavailable
         }}
    end
  end
end
