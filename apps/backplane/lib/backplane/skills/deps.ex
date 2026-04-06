defmodule Backplane.Skills.Deps do
  @moduledoc """
  Dependency resolution for skills with `depends_on` frontmatter.

  Resolves transitive dependencies in topological order (depth-first).
  Detects cycles and enforces a max depth of 10.
  """

  alias Backplane.Skills.Registry

  @max_depth 10

  @doc """
  Resolve a skill and all its transitive dependencies.

  Returns `{:ok, skills}` where skills are in topological order
  (dependencies before dependents), or `{:error, reason}`.

  Options:
    - `:resolve_deps` — when false, returns just the skill (default true)
  """
  @spec resolve(String.t(), keyword()) ::
          {:ok, [map()]} | {:ok, [map()], [String.t()]} | {:error, String.t()}
  def resolve(skill_id, opts \\ []) do
    resolve_deps? = Keyword.get(opts, :resolve_deps, true)

    case Registry.fetch(skill_id) do
      {:error, :not_found} ->
        {:error, "Skill not found: #{skill_id}"}

      {:ok, skill} ->
        if resolve_deps? do
          resolve_with_deps(skill)
        else
          {:ok, [skill]}
        end
    end
  end

  defp resolve_with_deps(skill) do
    case do_resolve(skill.id, [], MapSet.new(), MapSet.new(), 0) do
      {:ok, ordered, warnings, _resolved} ->
        if warnings == [] do
          {:ok, ordered}
        else
          {:ok, ordered, warnings}
        end

      {:error, _} = err ->
        err
    end
  end

  defp do_resolve(skill_id, path, visited, resolved, depth) do
    cond do
      depth > @max_depth ->
        {:error, "Dependency chain exceeds maximum depth (#{@max_depth})"}

      MapSet.member?(visited, skill_id) and not MapSet.member?(resolved, skill_id) ->
        cycle = Enum.reverse([skill_id | path]) |> Enum.drop_while(&(&1 != skill_id))
        {:error, "Dependency cycle detected: #{Enum.join(cycle, " → ")}"}

      MapSet.member?(resolved, skill_id) ->
        {:ok, [], [], resolved}

      true ->
        case Registry.fetch(skill_id) do
          {:error, :not_found} ->
            parent = List.first(path) || "unknown"

            {:ok, [], ["Unresolved dependency: '#{skill_id}' (referenced by '#{parent}')"],
             resolved}

          {:ok, skill} ->
            dep_names = parse_depends_on(skill)
            visited = MapSet.put(visited, skill_id)

            result =
              Enum.reduce_while(dep_names, {:ok, [], [], resolved}, fn dep_name,
                                                                       {:ok, acc_skills,
                                                                        acc_warnings,
                                                                        acc_resolved} ->
                dep_id = find_skill_id_by_name(dep_name)

                case do_resolve(
                       dep_id || dep_name,
                       [skill_id | path],
                       visited,
                       acc_resolved,
                       depth + 1
                     ) do
                  {:ok, deps, warnings, new_resolved} ->
                    {:cont, {:ok, acc_skills ++ deps, acc_warnings ++ warnings, new_resolved}}

                  {:error, _} = err ->
                    {:halt, err}
                end
              end)

            case result do
              {:error, _} = err ->
                err

              {:ok, dep_skills, all_warnings, updated_resolved} ->
                {:ok, dep_skills ++ [skill], all_warnings, MapSet.put(updated_resolved, skill_id)}
            end
        end
    end
  end

  @doc "Parse `depends_on` from a skill's YAML frontmatter."
  @spec parse_depends_on(map()) :: [String.t()]
  def parse_depends_on(%{content: content}) when is_binary(content) do
    case parse_frontmatter(content) do
      {:ok, frontmatter} ->
        case frontmatter["depends_on"] do
          deps when is_list(deps) -> deps
          _ -> []
        end

      :error ->
        []
    end
  end

  def parse_depends_on(_), do: []

  defp parse_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, yaml_str] ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, parsed} -> {:ok, parsed}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp find_skill_id_by_name(name) do
    # Skills can be looked up by name — scan the registry
    Registry.list()
    |> Enum.find(fn s -> s.name == name end)
    |> case do
      %{id: id} -> id
      nil -> nil
    end
  end
end
