defmodule Backplane.HostAgent.Reconciler do
  @moduledoc """
  Builds a desired-vs-local manifest action plan for skill sync.
  """

  def plan(desired, %Backplane.HostAgent.Manifest{skills: local_skills}) do
    desired_by_slug = Map.new(desired, fn skill -> {skill["slug"], skill} end)
    local_by_slug = Map.new(local_skills, fn skill -> {field(skill, :slug), skill} end)

    desired_actions =
      Enum.map(desired, fn skill ->
        slug = skill["slug"]

        case Map.get(local_by_slug, slug) do
          nil -> action(:install, skill)
          local -> compare(skill, local)
        end
      end)

    removal_actions =
      local_skills
      |> Enum.reject(fn skill -> Map.has_key?(desired_by_slug, field(skill, :slug)) end)
      |> Enum.map(fn skill ->
        if field(skill, :owned, true) do
          action(:remove, skill)
        else
          action(:noop, skill)
        end
      end)

    desired_actions ++ removal_actions
  end

  defp compare(desired, local) do
    cond do
      desired["checksum"] != field(local, :checksum) ->
        action(:update, desired)

      sorted_targets(desired["targets"] || []) != sorted_targets(field(local, :targets, [])) ->
        action(:update, desired)

      true ->
        action(:noop, desired)
    end
  end

  defp sorted_targets(targets), do: Enum.sort(targets)

  defp action(kind, skill) do
    %{action: kind, slug: field(skill, :slug), skill: skill}
  end

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
