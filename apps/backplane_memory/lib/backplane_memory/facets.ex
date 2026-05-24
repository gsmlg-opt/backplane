defmodule BackplaneMemory.Facets do
  @moduledoc "Context for memory facet dimensions and tagging."

  import Ecto.Query
  alias BackplaneMemory.Facets.{Dimension, Facet}

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  @doc """
  Tag a memory with facets. Each facet is %{"dimension" => string, "value" => string}.
  Validates dimension exists. Returns {:error, {:unknown_dimension, name}} for unknown dims.
  """
  def tag(memory_id, facets) when is_list(facets) do
    with :ok <- validate_dimensions(facets) do
      results =
        Enum.map(facets, fn %{"dimension" => dim, "value" => val} ->
          %Facet{}
          |> Facet.changeset(%{memory_id: memory_id, dimension: dim, value: val})
          |> repo().insert(
            on_conflict: {:replace, [:value]},
            conflict_target: [:memory_id, :dimension]
          )
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))
      if errors == [], do: {:ok, length(facets)}, else: {:error, errors}
    end
  end

  @doc """
  Query memory IDs matching ALL specified facets (AND across dimensions).
  facets is a list of %{"dimension" => string, "value" => string}.
  """
  def query(facets) when is_list(facets) and facets != [] do
    sets =
      Enum.map(facets, fn %{"dimension" => dim, "value" => val} ->
        repo().all(
          from(f in Facet,
            where: f.dimension == ^dim and f.value == ^val,
            select: f.memory_id
          )
        )
        |> MapSet.new()
      end)

    [first | rest] = sets
    intersection = Enum.reduce(rest, first, &MapSet.intersection(&2, &1))
    MapSet.to_list(intersection)
  end

  def query([]), do: []

  defp validate_dimensions(facets) do
    names = Enum.map(facets, fn %{"dimension" => d} -> d end) |> Enum.uniq()

    existing =
      repo().all(from(d in Dimension, where: d.name in ^names, select: d.name)) |> MapSet.new()

    unknown = Enum.reject(names, &MapSet.member?(existing, &1))

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_dimension, hd(unknown)}}
    end
  end
end
