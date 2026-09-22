defmodule Backplane.SkillProtocol.Source.Local do
  @moduledoc "Bounded local discovery under explicit host-approved roots."

  alias Backplane.SkillProtocol.{
    Catalog,
    Descriptor,
    Diagnostic,
    Error,
    Parser,
    PathSafety,
    SkillRef,
    Validator
  }

  @default_max_depth 16
  @default_max_entries 10_000
  @default_max_diagnostics 100

  @spec discover([map() | keyword()], keyword()) :: {:ok, [Descriptor.t()]} | {:error, Error.t()}
  def discover(roots, opts \\ []) when is_list(roots) do
    case discover_with_diagnostics(roots, opts) do
      {:ok, descriptors, _diagnostics} -> {:ok, descriptors}
      {:error, _} = error -> error
    end
  end

  @spec discover_with_diagnostics([map() | keyword()], keyword()) ::
          {:ok, [Descriptor.t()], [Diagnostic.t()]} | {:error, Error.t()}
  def discover_with_diagnostics(roots, opts \\ []) when is_list(roots) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    max_diagnostics = Keyword.get(opts, :max_diagnostics, @default_max_diagnostics)

    with :ok <- valid_limit(max_depth, :max_depth),
         :ok <- valid_limit(max_entries, :max_entries),
         :ok <- valid_diagnostic_limit(max_diagnostics) do
      Enum.reduce_while(roots, {:ok, [], [], 0}, fn root, {:ok, acc, diagnostics, count} ->
        case discover_root(
               root,
               max_depth,
               max_entries - count,
               max_diagnostics - length(diagnostics)
             ) do
          {:ok, descriptors, root_diagnostics, visited} ->
            {:cont, {:ok, descriptors ++ acc, root_diagnostics ++ diagnostics, count + visited}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, descriptors, diagnostics, _count} ->
          {:ok, Catalog.sort(descriptors), sort_diagnostics(diagnostics)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp discover_root(root, max_depth, remaining, remaining_diagnostics) do
    source_id = value(root, :source_id)
    path = value(root, :path)
    precedence = value(root, :precedence, 100)

    with true <- is_binary(source_id) and source_id != "" and is_binary(path),
         {:ok, approved_root} <- realpath(path),
         {:ok, descriptors, diagnostics, count, _seen} <-
           walk(
             path,
             approved_root,
             source_id,
             precedence,
             {0, max_depth},
             remaining,
             {MapSet.new(), [], [], remaining_diagnostics}
           ) do
      {:ok, descriptors, diagnostics, count}
    else
      false ->
        {:error, Error.new(:invalid_request, :discovery, "root requires source_id and path")}

      {:error, _} = error ->
        error
    end
  end

  defp walk(
         _path,
         _root,
         _source,
         _precedence,
         _depth_budget,
         remaining,
         _state
       )
       when remaining < 1,
       do: {:error, Error.new(:limit_exceeded, :discovery, "local scan entry limit exceeded")}

  defp walk(
         _path,
         _root,
         _source,
         _precedence,
         {depth, max_depth},
         _remaining,
         _state
       )
       when depth > max_depth,
       do: {:error, Error.new(:limit_exceeded, :discovery, "local scan depth limit exceeded")}

  defp walk(
         path,
         root,
         source,
         precedence,
         {depth, max_depth},
         remaining,
         {seen, acc, diagnostics, remaining_diagnostics}
       ) do
    with {:ok, canonical} <- realpath(path),
         :ok <- contained(canonical, root),
         false <- MapSet.member?(seen, canonical),
         {:ok, names} <- File.ls(canonical) do
      seen = MapSet.put(seen, canonical)
      names = Enum.sort(names)

      Enum.reduce_while(names, {:ok, acc, diagnostics, 1, seen}, fn name,
                                                                    {:ok, items,
                                                                     current_diagnostics, count,
                                                                     visited} ->
        child = Path.join(canonical, name)

        case inspect_child(
               child,
               root,
               source,
               precedence,
               {depth, max_depth},
               remaining - count,
               {visited, items, current_diagnostics, remaining_diagnostics}
             ) do
          {:ok, next_items, next_diagnostics, added, next_seen} ->
            {:cont, {:ok, next_items, next_diagnostics, count + added, next_seen}}

          {:skip, next_diagnostics, added} ->
            {:cont, {:ok, items, next_diagnostics, count + added, visited}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    else
      true ->
        {:ok, acc, diagnostics, 1, seen}

      {:error, %Error{}} = error ->
        error

      {:error, reason} ->
        {:error,
         Error.new(:invalid_request, :discovery, "local root cannot be read",
           context: %{reason: inspect(reason)}
         )}
    end
  end

  defp inspect_child(
         path,
         root,
         source,
         precedence,
         {depth, max_depth},
         remaining,
         {seen, acc, diagnostics, remaining_diagnostics}
       ) do
    cond do
      remaining < 1 ->
        {:error, Error.new(:limit_exceeded, :discovery, "local scan entry limit exceeded")}

      File.dir?(path) ->
        walk(
          path,
          root,
          source,
          precedence,
          {depth + 1, max_depth},
          remaining,
          {seen, acc, diagnostics, remaining_diagnostics}
        )

      Path.basename(path) == "SKILL.md" ->
        parse_descriptor(
          path,
          root,
          source,
          precedence,
          acc,
          seen,
          diagnostics,
          remaining_diagnostics
        )

      true ->
        {:skip, diagnostics, 1}
    end
  end

  defp parse_descriptor(
         path,
         root,
         source,
         precedence,
         acc,
         seen,
         diagnostics,
         remaining_diagnostics
       ) do
    with {:ok, canonical} <- realpath(path),
         :ok <- contained(canonical, root) do
      with {:ok, bytes} <- File.read(canonical),
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

        {:ok, [descriptor | acc], diagnostics, 1, seen}
      else
        {:error, %Error{} = error} ->
          {:skip, add_diagnostic(diagnostics, remaining_diagnostics, path, root, error.code), 1}

        {:error, _reason} ->
          {:skip,
           add_diagnostic(diagnostics, remaining_diagnostics, path, root, :invalid_document), 1}
      end
    else
      {:error, %Error{}} = error -> error
    end
  end

  defp add_diagnostic(diagnostics, maximum, _path, _root, _code)
       when length(diagnostics) >= maximum,
       do: diagnostics

  defp add_diagnostic(diagnostics, _remaining, path, root, code) do
    [
      Diagnostic.new(code, :discovery, :warning, "skill document skipped", %{
        path: Path.relative_to(path, root),
        code: code
      })
      | diagnostics
    ]
  end

  defp sort_diagnostics(diagnostics) do
    Enum.sort_by(diagnostics, fn diagnostic ->
      {diagnostic.context.path, diagnostic.code, diagnostic.message}
    end)
  end

  defp valid_limit(value, _name) when is_integer(value) and value >= 0, do: :ok

  defp valid_limit(_value, name),
    do:
      {:error, Error.new(:invalid_request, :discovery, "#{name} must be a non-negative integer")}

  defp valid_diagnostic_limit(value) when is_integer(value) and value >= 0, do: :ok

  defp valid_diagnostic_limit(_value),
    do:
      {:error,
       Error.new(:invalid_request, :discovery, "max_diagnostics must be a non-negative integer")}

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
