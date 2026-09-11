defmodule Backplane.SkillProtocol.Source.Local do
  @moduledoc "Bounded local discovery under explicit host-approved roots."

  alias Backplane.SkillProtocol.{
    Catalog,
    Descriptor,
    Error,
    Parser,
    PathSafety,
    SkillRef,
    Validator
  }

  @default_max_depth 16
  @default_max_entries 10_000

  @spec discover([map() | keyword()], keyword()) :: {:ok, [Descriptor.t()]} | {:error, Error.t()}
  def discover(roots, opts \\ []) when is_list(roots) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)

    Enum.reduce_while(roots, {:ok, [], 0}, fn root, {:ok, acc, count} ->
      case discover_root(root, max_depth, max_entries - count) do
        {:ok, descriptors, visited} -> {:cont, {:ok, descriptors ++ acc, count + visited}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, descriptors, _count} -> {:ok, Catalog.sort(descriptors)}
      {:error, _} = error -> error
    end
  end

  defp discover_root(root, max_depth, remaining) do
    source_id = value(root, :source_id)
    path = value(root, :path)
    precedence = value(root, :precedence, 100)

    with true <- is_binary(source_id) and source_id != "" and is_binary(path),
         {:ok, approved_root} <- realpath(path),
         {:ok, descriptors, count, _seen} <-
           walk(
             path,
             approved_root,
             source_id,
             precedence,
             0,
             max_depth,
             remaining,
             MapSet.new(),
             []
           ) do
      {:ok, descriptors, count}
    else
      false ->
        {:error, Error.new(:invalid_request, :discovery, "root requires source_id and path")}

      {:error, _} = error ->
        error
    end
  end

  defp walk(_path, _root, _source, _precedence, _depth, _max_depth, remaining, _seen, _acc)
       when remaining < 1,
       do: {:error, Error.new(:limit_exceeded, :discovery, "local scan entry limit exceeded")}

  defp walk(_path, _root, _source, _precedence, depth, max_depth, _remaining, _seen, _acc)
       when depth > max_depth,
       do: {:error, Error.new(:limit_exceeded, :discovery, "local scan depth limit exceeded")}

  defp walk(path, root, source, precedence, depth, max_depth, remaining, seen, acc) do
    with {:ok, canonical} <- realpath(path),
         :ok <- contained(canonical, root),
         false <- MapSet.member?(seen, canonical),
         {:ok, names} <- File.ls(canonical) do
      seen = MapSet.put(seen, canonical)
      names = Enum.sort(names)

      Enum.reduce_while(names, {:ok, acc, 1, seen}, fn name, {:ok, items, count, visited} ->
        child = Path.join(canonical, name)

        case inspect_child(
               child,
               root,
               source,
               precedence,
               depth,
               max_depth,
               remaining - count,
               visited,
               items
             ) do
          {:ok, next_items, added, next_seen} ->
            {:cont, {:ok, next_items, count + added, next_seen}}

          {:skip, added} ->
            {:cont, {:ok, items, count + added, visited}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    else
      true ->
        {:ok, acc, 1, seen}

      {:error, %Error{}} = error ->
        error

      {:error, reason} ->
        {:error,
         Error.new(:invalid_request, :discovery, "local root cannot be read",
           context: %{reason: inspect(reason)}
         )}
    end
  end

  defp inspect_child(path, root, source, precedence, depth, max_depth, remaining, seen, acc) do
    cond do
      remaining < 1 ->
        {:error, Error.new(:limit_exceeded, :discovery, "local scan entry limit exceeded")}

      File.dir?(path) ->
        walk(path, root, source, precedence, depth + 1, max_depth, remaining, seen, acc)

      Path.basename(path) == "SKILL.md" ->
        parse_descriptor(path, root, source, precedence, acc, seen)

      true ->
        {:skip, 1}
    end
  end

  defp parse_descriptor(path, root, source, precedence, acc, seen) do
    with {:ok, canonical} <- realpath(path),
         :ok <- contained(canonical, root),
         {:ok, bytes} <- File.read(canonical),
         {:ok, document} <- Parser.parse(bytes),
         {:ok, document} <- Validator.validate(document, profile: :legacy) do
      relative_dir = canonical |> Path.dirname() |> Path.relative_to(root)
      skill_id = if relative_dir == ".", do: document.name, else: relative_dir

      descriptor = %Descriptor{
        ref: %SkillRef{source_id: source, skill_id: skill_id},
        name: document.name,
        description: document.description,
        path: canonical,
        precedence: precedence,
        publication_status: :local
      }

      {:ok, [descriptor | acc], 1, seen}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_document, :discovery, "skill document cannot be read",
           context: %{reason: inspect(reason)}
         )}
    end
  end

  defp realpath(path) do
    case PathSafety.realpath(path) do
      {:ok, canonical} ->
        {:ok, canonical}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_request, :discovery, "path cannot be resolved",
           context: %{reason: inspect(reason)}
         )}
    end
  end

  defp contained(path, root) do
    if path == root or String.starts_with?(path, root <> "/") do
      :ok
    else
      {:error, Error.new(:invalid_request, :discovery, "linked path escapes approved root")}
    end
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(list, key, default) when is_list(list), do: Keyword.get(list, key, default)
end
