defmodule Backplane.SkillProtocol.Directory.Snapshot do
  @moduledoc """
  A published directory view for one scope.

  A scope is `:warming` until each source has its first outcome, `:ready` when
  every source is ready, and `:degraded` when at least one source is stale or
  unavailable. Inspect `sources` for individual statuses and diagnostics.
  """

  alias Backplane.SkillProtocol.{Catalog, Descriptor, Diagnostic, Eligibility, Error}

  @enforce_keys [:scope]
  defstruct [:scope, :revision, status: :warming, automatic: [], explicit: [], sources: %{}]

  @type source_status :: %{
          status: :warming | :ready | :stale | :error,
          generation: String.t() | nil,
          notifications: :connecting | :online | :offline | :denied | :error | nil,
          search_categories: [String.t()],
          error: Error.t() | nil,
          diagnostics: [Diagnostic.t()]
        }

  @type t :: %__MODULE__{
          scope: term(),
          revision: pos_integer(),
          status: :warming | :ready | :degraded,
          automatic: [Descriptor.t()],
          explicit: [Descriptor.t()],
          sources: %{optional(String.t()) => source_status()}
        }

  @doc false
  def build(scope, config, indexes, previous_revision) do
    {entries, statuses} =
      Enum.reduce(config.sources, {[], %{}}, fn {{id, _source} = key, precedence},
                                                {entries, statuses} ->
        index = Map.fetch!(indexes, key)
        descriptors = Enum.map(index.descriptors, &%{&1 | precedence: precedence})

        status =
          Map.take(index, [
            :status,
            :error,
            :diagnostics,
            :generation,
            :notifications,
            :search_categories
          ])

        {descriptors ++ entries, Map.put(statuses, id, status)}
      end)

    status = aggregate_status(statuses)

    visible =
      if status == :warming do
        []
      else
        entries |> Enum.reject(&disabled?(&1, config.disabled)) |> Catalog.sort()
      end

    %__MODULE__{
      scope: scope,
      revision: previous_revision,
      status: status,
      automatic: eligible(visible, :automatic, config),
      explicit: eligible(visible, :explicit, config),
      sources: statuses
    }
  end

  defp disabled?(descriptor, disabled) do
    MapSet.member?(disabled, descriptor.name) or
      MapSet.member?(disabled, {descriptor.ref.source_id, descriptor.ref.skill_id})
  end

  defp eligible(entries, trigger, config) do
    Enum.filter(entries, fn descriptor ->
      Eligibility.evaluate(descriptor, trigger, %{allow_explicit: config.allow_explicit}) ==
        {:ok, :eligible}
    end)
  end

  defp aggregate_status(statuses) do
    statuses = Enum.map(statuses, fn {_id, source} -> source.status end)

    cond do
      :warming in statuses -> :warming
      Enum.all?(statuses, &(&1 == :ready)) -> :ready
      true -> :degraded
    end
  end
end
