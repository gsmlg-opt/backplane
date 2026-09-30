defmodule Backplane.AgentRuntime.Codex.ApplyPatch do
  @moduledoc "Structured, workspace-confined application of Codex patch operations."

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.PathGuard

  @spec apply(String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def apply(root, patch) when is_binary(root) and is_binary(patch) do
    with {:ok, operations} <- parse(patch),
         {:ok, results} <- execute(root, operations) do
      {:ok, %{status: :applied, files: results}}
    end
  end

  def apply(_root, _patch), do: {:error, Error.new(:validation, "patch must be a string")}

  defp parse(patch) do
    lines = patch |> String.split("\n", trim: false) |> drop_final_empty()

    case lines do
      ["*** Begin Patch" | rest] ->
        case Enum.reverse(rest) do
          ["*** End Patch" | reversed] when reversed != [] ->
            parse_ops(Enum.reverse(reversed), [])

          _ ->
            invalid("patch must end with *** End Patch")
        end

      _ ->
        invalid("patch must start with *** Begin Patch")
    end
  end

  defp drop_final_empty(lines) do
    if List.last(lines) == "", do: List.delete_at(lines, -1), else: lines
  end

  defp parse_ops([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_ops(["*** Add File: " <> path | rest], acc) do
    {body, tail} = take_body(rest, [])

    if path != "" and body != [] and Enum.all?(body, &String.starts_with?(&1, "+")) do
      parse_ops(tail, [%{kind: :add, path: path, lines: Enum.map(body, &strip_prefix/1)} | acc])
    else
      invalid("add file requires one or more + lines")
    end
  end

  defp parse_ops(["*** Delete File: " <> path | rest], acc) do
    {body, tail} = take_body(rest, [])

    if path != "" and body == [],
      do: parse_ops(tail, [%{kind: :delete, path: path} | acc]),
      else: invalid("delete file cannot have a body")
  end

  defp parse_ops(["*** Update File: " <> path | rest], acc) do
    {destination, rest} =
      case rest do
        ["*** Move to: " <> target | tail] -> {target, tail}
        _ -> {nil, rest}
      end

    {body, tail} = take_body(rest, [])

    with true <- (path != "" and destination != "") or invalid("update path is required"),
         true <- body != [] or destination != nil or invalid("update hunk is empty"),
         {:ok, hunks} <- parse_hunks(body) do
      parse_ops(tail, [
        %{kind: :update, path: path, destination: destination, hunks: hunks} | acc
      ])
    end
  end

  # Backplane's old direct-call move form remains available to existing consumers.
  defp parse_ops(["*** Move to: " <> destination | rest], acc) do
    {body, tail} = take_body(rest, [])

    case body do
      [source] when source != "" and destination != "" ->
        parse_ops(tail, [%{kind: :move, path: source, destination: destination} | acc])

      _ ->
        invalid("move requires exactly one source path")
    end
  end

  defp parse_ops([line | _], _acc), do: invalid("invalid patch operation header", line: line)

  defp take_body([], acc), do: {Enum.reverse(acc), []}

  defp take_body(["*** End of File" | rest], acc),
    do: take_body_after_eof(rest, ["*** End of File" | acc])

  defp take_body(["*** " <> _ | _] = tail, acc), do: {Enum.reverse(acc), tail}
  defp take_body([line | rest], acc), do: take_body(rest, [line | acc])

  defp take_body_after_eof(["*** " <> _ | _] = tail, acc), do: {Enum.reverse(acc), tail}
  defp take_body_after_eof([], acc), do: {Enum.reverse(acc), []}
  defp take_body_after_eof([line | rest], acc), do: take_body_after_eof(rest, [line | acc])

  defp parse_hunks([]), do: {:ok, []}

  defp parse_hunks(lines) do
    Enum.reduce_while(
      lines,
      {:ok, [], %{anchor: nil, lines: [], eof: false, marked: false}},
      fn line, {:ok, done, current} ->
        cond do
          line == "@@" or String.starts_with?(line, "@@ ") ->
            if current.lines == [] and current.marked do
              {:halt, invalid("empty update hunk")}
            else
              anchor = if line == "@@", do: nil, else: String.replace_prefix(line, "@@ ", "")
              done = if current.lines == [], do: done, else: [current | done]
              {:cont, {:ok, done, %{anchor: anchor, lines: [], eof: false, marked: true}}}
            end

          line == "*** End of File" ->
            if current.eof or current.lines == [] do
              {:halt, invalid("EOF marker requires a preceding hunk")}
            else
              {:cont, {:ok, done, %{current | eof: true}}}
            end

          line == "" and current.eof ->
            {:cont, {:ok, done, current}}

          line == "" ->
            {:cont, {:ok, done, %{current | lines: current.lines ++ [{" ", ""}]}}}

          String.starts_with?(line, [" ", "+", "-"]) and not current.eof ->
            {:cont,
             {:ok, done,
              %{current | lines: current.lines ++ [{String.first(line), strip_prefix(line)}]}}}

          true ->
            {:halt, invalid("invalid update line", line: line)}
        end
      end
    )
    |> case do
      {:ok, done, current} ->
        if current.lines == [] and lines != [] do
          invalid("update hunk does not contain lines")
        else
          hunks = Enum.reverse(if current.lines == [], do: done, else: [current | done])

          if hunks == [] and lines != [],
            do: invalid("update has no hunk lines"),
            else: {:ok, hunks}
        end

      error ->
        error
    end
  end

  defp strip_prefix(<<_::binary-size(1), rest::binary>>), do: rest

  defp execute(root, operations) do
    Enum.reduce_while(operations, {:ok, []}, fn op, {:ok, done} ->
      case execute_one(root, op) do
        {:ok, result} ->
          {:cont, {:ok, [result | done]}}

        {:error, %Error{} = error} ->
          files = Enum.reverse(done) ++ Map.get(error.details, :files, [])
          {:halt, {:error, %{error | details: Map.put(error.details, :files, files)}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp execute_one(root, %{kind: :add, path: path, lines: lines}) do
    with {:ok, full} <- confined(root, path),
         :ok <- File.mkdir_p(Path.dirname(full)) do
      write_content(full, Enum.join(lines, "\n") <> "\n", :added)
    else
      error -> normalize_io(error, "file creation failed")
    end
  end

  defp execute_one(root, %{kind: :delete, path: path}) do
    with {:ok, full} <- confined(root, path),
         :ok <- File.rm(full) do
      {:ok, %{path: full, action: :deleted}}
    else
      error -> normalize_io(error, "file deletion failed")
    end
  end

  defp execute_one(root, %{kind: :move, path: path, destination: destination}) do
    with {:ok, source} <- confined(root, path),
         {:ok, target} <- confined(root, destination),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.rename(source, target) do
      {:ok, %{from: source, path: target, action: :moved}}
    else
      error -> normalize_io(error, "file move failed")
    end
  end

  defp execute_one(root, %{kind: :update, path: path, destination: destination, hunks: hunks}) do
    with {:ok, source} <- confined(root, path),
         {:ok, target} <- maybe_target(root, destination, source),
         {:ok, old} <- File.read(source),
         {:ok, new} <- apply_hunks(old, hunks) do
      if target == source do
        write_content(source, new, :updated)
      else
        with :ok <- File.mkdir_p(Path.dirname(target)),
             {:ok, _} <- write_content(target, new, :added) do
          case File.rm(source) do
            :ok ->
              {:ok, %{from: source, path: target, action: :moved}}

            {:error, reason} ->
              {:error,
               Error.new(:unknown_outcome, "file move failed after destination write",
                 cause: reason,
                 details: %{files: [%{path: target, action: :added}], uncertain_files: [source]}
               )}
          end
        else
          error -> normalize_io(error, "destination creation failed")
        end
      end
    else
      error -> normalize_io(error, "file update failed")
    end
  end

  defp maybe_target(_root, nil, source), do: {:ok, source}
  defp maybe_target(root, destination, _source), do: confined(root, destination)

  defp write_content(path, content, action) do
    case File.write(path, content) do
      :ok ->
        {:ok, %{path: path, action: action}}

      {:error, reason} ->
        {:error,
         Error.new(:unknown_outcome, "file write failed; contents may have changed",
           cause: reason,
           details: %{uncertain_files: [path]}
         )}
    end
  end

  defp apply_hunks(old, hunks) do
    {lines, _trailing_newline?} = split_file_lines(old)

    Enum.reduce_while(hunks, {:ok, [], 0}, fn hunk, {:ok, replacements, cursor} ->
      case locate_hunk(lines, hunk, cursor) do
        {:ok, replacement, next_cursor} ->
          {:cont, {:ok, [replacement | replacements], next_cursor}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, replacements, _} ->
        updated =
          Enum.reduce(replacements, lines, fn {index, expected, replacement}, acc ->
            Enum.take(acc, index) ++ replacement ++ Enum.drop(acc, index + expected)
          end)

        {:ok, if(updated == [], do: "", else: Enum.join(updated, "\n") <> "\n")}

      error ->
        error
    end
  end

  defp split_file_lines(""), do: {[], false}

  defp split_file_lines(text) do
    parts = String.split(text, "\n", trim: false)
    if List.last(parts) == "", do: {List.delete_at(parts, -1), true}, else: {parts, false}
  end

  defp locate_hunk(lines, hunk, cursor) do
    expected = for {prefix, text} <- hunk.lines, prefix != "+", do: text
    replacement = for {prefix, text} <- hunk.lines, prefix != "-", do: text

    with {:ok, start} <- seek_anchor(lines, hunk.anchor, cursor) do
      index =
        if expected == [] do
          length(lines)
        else
          seek_sequence(lines, expected, start, hunk.eof)
        end

      if is_integer(index) do
        {:ok, {index, length(expected), replacement}, index + length(expected)}
      else
        {:error, Error.new(:resource_conflict, "patch context did not match")}
      end
    end
  end

  defp seek_anchor(_lines, nil, cursor), do: {:ok, cursor}

  defp seek_anchor(lines, anchor, cursor) do
    case seek_sequence(lines, [anchor], cursor, false) do
      nil -> {:error, Error.new(:resource_conflict, "patch anchor did not match")}
      index -> {:ok, index + 1}
    end
  end

  defp seek_sequence(lines, pattern, start, eof) do
    if length(pattern) > length(lines) do
      nil
    else
      last = length(lines) - length(pattern)
      first = if eof, do: last, else: start

      Enum.find_value(
        [
          &(&1 == &2),
          &(String.trim_trailing(&1) == String.trim_trailing(&2)),
          &(String.trim(&1) == String.trim(&2)),
          &normalized_equal?/2
        ],
        fn compare ->
          find_match(lines, pattern, first, last, compare)
        end
      )
    end
  end

  defp find_match(_lines, _pattern, first, last, _compare) when first > last, do: nil

  defp find_match(lines, pattern, first, last, compare) do
    Enum.find(first..last, fn index ->
      Enum.zip(Enum.slice(lines, index, length(pattern)), pattern)
      |> Enum.all?(fn {actual, expected} -> compare.(actual, expected) end)
    end)
  end

  defp normalized_equal?(left, right),
    do: normalize_punctuation(left) == normalize_punctuation(right)

  defp normalize_punctuation(text) do
    text
    |> String.trim()
    |> String.replace(~r/[‐‑‒–—―−]/u, "-")
    |> String.replace(~r/[‘’‚‛]/u, "'")
    |> String.replace(~r/[“”„‟]/u, "\"")
    |> then(fn value ->
      Enum.reduce(
        [0xA0 | Enum.to_list(0x2002..0x200A)] ++ [0x202F, 0x205F, 0x3000],
        value,
        fn codepoint, acc ->
          String.replace(acc, <<codepoint::utf8>>, " ")
        end
      )
    end)
  end

  defp confined(root, path), do: PathGuard.authorize(root, path)

  defp normalize_io({:error, %Error{} = error}, _message), do: {:error, error}

  defp normalize_io({:error, reason}, message),
    do: {:error, Error.new(:resource_conflict, message, cause: reason)}

  defp invalid(message, details \\ []),
    do: {:error, Error.new(:validation, message, details: details)}
end
