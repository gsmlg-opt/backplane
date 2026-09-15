defmodule Backplane.SkillProtocol.Resolver do
  @moduledoc "Deterministic source-aware Skill resolution."

  alias Backplane.SkillProtocol.{Catalog, Descriptor, Error, SkillRef}

  @spec resolve([Descriptor.t()], String.t() | SkillRef.t()) ::
          {:ok, Descriptor.t()} | {:error, Error.t()}
  def resolve(descriptors, %SkillRef{} = reference) do
    matches =
      Enum.filter(descriptors, fn descriptor ->
        descriptor.ref.source_id == reference.source_id and
          descriptor.ref.skill_id == reference.skill_id and
          (is_nil(reference.revision) or descriptor.revision == reference.revision)
      end)

    one(matches, reference)
  end

  def resolve(descriptors, name) when is_binary(name) do
    matches = descriptors |> Enum.filter(&(&1.name == name)) |> Catalog.sort()

    case matches do
      [] ->
        {:error, Error.new(:not_found, :resolve, "skill was not found", context: %{name: name})}

      [descriptor] ->
        {:ok, descriptor}

      [first | _] ->
        resolve_rank(matches, first.precedence, name)
    end
  end

  defp resolve_rank(matches, precedence, name) do
    top = Enum.take_while(matches, &(&1.precedence == precedence))

    case top do
      [descriptor] ->
        {:ok, descriptor}

      _ ->
        {:error,
         Error.new(:ambiguous_skill, :resolve, "skill name is ambiguous", context: %{name: name})}
    end
  end

  defp one([descriptor], _reference), do: {:ok, descriptor}

  defp one([], reference),
    do:
      {:error,
       Error.new(:not_found, :resolve, "qualified skill was not found",
         context: %{source_id: reference.source_id, skill_id: reference.skill_id}
       )}

  defp one(_matches, reference),
    do:
      {:error,
       Error.new(:ambiguous_skill, :resolve, "qualified skill is ambiguous",
         context: %{source_id: reference.source_id, skill_id: reference.skill_id}
       )}
end
