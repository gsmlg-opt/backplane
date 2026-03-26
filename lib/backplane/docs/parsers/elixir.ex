defmodule Backplane.Docs.Parsers.Elixir do
  @moduledoc """
  Parser for Elixir .ex/.exs files.

  Extracts:
  - @moduledoc as "moduledoc" chunks
  - @doc + function signature as "function_doc" chunks
  - @typedoc + @type as "typespec" chunks
  - Handles nested modules
  """

  @behaviour Backplane.Docs.Parser

  require Logger

  @impl true
  def parse(content, source_path) do
    chunks = extract_chunks(content, source_path)
    {:ok, chunks}
  rescue
    e ->
      Logger.warning("Failed to parse #{source_path}: #{Exception.message(e)}")
      {:ok, []}
  end

  defp extract_chunks(content, source_path) do
    lines = String.split(content, "\n")

    state = %{
      module_stack: [],
      current_doc: nil,
      current_spec: nil,
      current_typedoc: nil,
      chunks: []
    }

    final_state = process_lines(lines, source_path, state)
    Enum.reverse(final_state.chunks)
  end

  defp process_lines([], _source_path, state), do: state

  defp process_lines([line | rest], source_path, state) do
    trimmed = String.trim(line)

    if trimmed == "end" and state.module_stack != [] do
      process_lines(rest, source_path, %{state | module_stack: tl(state.module_stack)})
    else
      process_line(classify_line(trimmed), trimmed, rest, source_path, state)
    end
  end

  defp process_line(:moduledoc_false, _trimmed, rest, source_path, state),
    do: process_lines(rest, source_path, %{state | current_doc: nil})

  defp process_line(:moduledoc_heredoc, _trimmed, rest, source_path, state),
    do: handle_moduledoc_heredoc(rest, source_path, state)

  defp process_line(:moduledoc_single, trimmed, rest, source_path, state),
    do: handle_moduledoc_single(trimmed, rest, source_path, state)

  defp process_line(:doc_false, _trimmed, rest, source_path, state),
    do: process_lines(rest, source_path, %{state | current_doc: nil})

  defp process_line(:doc_heredoc, _trimmed, rest, source_path, state) do
    {doc, remaining} = collect_heredoc(rest)
    process_lines(remaining, source_path, %{state | current_doc: doc})
  end

  defp process_line(:doc_single, trimmed, rest, source_path, state) do
    doc = extract_single_line_string(trimmed, "@doc ")
    process_lines(rest, source_path, %{state | current_doc: doc})
  end

  defp process_line(:typedoc_heredoc, _trimmed, rest, source_path, state) do
    {doc, remaining} = collect_heredoc(rest)
    process_lines(remaining, source_path, %{state | current_typedoc: doc})
  end

  defp process_line(:typedoc_single, trimmed, rest, source_path, state) do
    doc = extract_single_line_string(trimmed, "@typedoc ")
    process_lines(rest, source_path, %{state | current_typedoc: doc})
  end

  defp process_line(:spec, trimmed, rest, source_path, state) do
    spec = String.trim_leading(trimmed, "@spec ")
    process_lines(rest, source_path, %{state | current_spec: spec})
  end

  defp process_line(:type_definition, trimmed, rest, source_path, state),
    do: handle_type(trimmed, rest, source_path, state)

  defp process_line(:defmodule, trimmed, rest, source_path, state) do
    mod_name = match_defmodule(trimmed)
    process_lines(rest, source_path, %{state | module_stack: [mod_name | state.module_stack]})
  end

  defp process_line(:function_def, trimmed, rest, source_path, state),
    do: handle_function(trimmed, rest, source_path, state)

  defp process_line(:other, _trimmed, rest, source_path, state),
    do: process_lines(rest, source_path, state)

  defp classify_line("@moduledoc false"), do: :moduledoc_false
  defp classify_line("@moduledoc \"\"\"" <> _), do: :moduledoc_heredoc
  defp classify_line("@moduledoc \"" <> _), do: :moduledoc_single
  defp classify_line("@doc false"), do: :doc_false
  defp classify_line("@doc \"\"\"" <> _), do: :doc_heredoc
  defp classify_line("@doc \"" <> _), do: :doc_single
  defp classify_line("@typedoc \"\"\"" <> _), do: :typedoc_heredoc
  defp classify_line("@typedoc \"" <> _), do: :typedoc_single
  defp classify_line("@spec " <> _), do: :spec

  defp classify_line("@type " <> _), do: :type_definition
  defp classify_line("@typep " <> _), do: :type_definition
  defp classify_line("@opaque " <> _), do: :type_definition

  defp classify_line(line) do
    cond do
      match_defmodule(line) != nil -> :defmodule
      match_function(line) != nil -> :function_def
      true -> :other
    end
  end

  defp handle_moduledoc_heredoc(rest, source_path, state) do
    {doc, remaining} = collect_heredoc(rest)
    current_module = current_module_name(state.module_stack)

    chunk = %{
      source_path: source_path,
      module: current_module,
      function: nil,
      chunk_type: "moduledoc",
      content: doc
    }

    process_lines(remaining, source_path, %{state | chunks: [chunk | state.chunks]})
  end

  defp handle_moduledoc_single(trimmed, rest, source_path, state) do
    doc = extract_single_line_string(trimmed, "@moduledoc ")
    current_module = current_module_name(state.module_stack)

    chunk = %{
      source_path: source_path,
      module: current_module,
      function: nil,
      chunk_type: "moduledoc",
      content: doc
    }

    process_lines(rest, source_path, %{state | chunks: [chunk | state.chunks]})
  end

  defp collect_heredoc(lines) do
    collect_heredoc(lines, [])
  end

  defp collect_heredoc([], acc) do
    {acc |> Enum.reverse() |> Enum.join("\n"), []}
  end

  defp collect_heredoc([line | rest], acc) do
    if String.trim(line) == "\"\"\"" do
      {acc |> Enum.reverse() |> Enum.join("\n"), rest}
    else
      collect_heredoc(rest, [String.trim(line) | acc])
    end
  end

  defp handle_function(trimmed, rest, source_path, state) do
    func_sig = match_function(trimmed)
    current_module = current_module_name(state.module_stack)

    if state.current_doc do
      content =
        if state.current_spec do
          "@spec #{state.current_spec}\n\n#{state.current_doc}"
        else
          state.current_doc
        end

      chunk = %{
        source_path: source_path,
        module: current_module,
        function: func_sig,
        chunk_type: "function_doc",
        content: content
      }

      state = %{state | current_doc: nil, current_spec: nil, chunks: [chunk | state.chunks]}
      process_lines(rest, source_path, state)
    else
      state = %{state | current_doc: nil, current_spec: nil}
      process_lines(rest, source_path, state)
    end
  end

  defp handle_type(trimmed, rest, source_path, state) do
    current_module = current_module_name(state.module_stack)

    if state.current_typedoc do
      content = "#{trimmed}\n\n#{state.current_typedoc}"

      chunk = %{
        source_path: source_path,
        module: current_module,
        function: nil,
        chunk_type: "typespec",
        content: content
      }

      state = %{state | current_typedoc: nil, chunks: [chunk | state.chunks]}
      process_lines(rest, source_path, state)
    else
      process_lines(rest, source_path, %{state | current_typedoc: nil})
    end
  end

  defp match_defmodule(line) do
    case Regex.run(~r/^defmodule\s+([\w.]+)/, line) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp match_function(line) do
    case Regex.run(~r/^(def|defp|defmacro|defmacrop)\s+([\w?!]+)(.*)$/, line) do
      [_, _kind, name, rest] ->
        arity = extract_arity(rest)
        "#{name}/#{arity}"

      _ ->
        nil
    end
  end

  defp extract_arity(rest) do
    trimmed = String.trim(rest)

    case trimmed do
      "(" <> _ -> count_args_balanced(trimmed)
      _ -> 0
    end
  end

  defp count_args_balanced("()" <> _), do: 0

  defp count_args_balanced("(" <> rest) do
    rest
    |> String.graphemes()
    |> Enum.reduce_while({0, 0}, fn
      "(", {depth, count} -> {:cont, {depth + 1, count}}
      "[", {depth, count} -> {:cont, {depth + 1, count}}
      "{", {depth, count} -> {:cont, {depth + 1, count}}
      ")", {0, count} -> {:halt, {0, count}}
      ")", {depth, count} -> {:cont, {depth - 1, count}}
      "]", {depth, count} -> {:cont, {max(depth - 1, 0), count}}
      "}", {depth, count} -> {:cont, {max(depth - 1, 0), count}}
      ",", {0, count} -> {:cont, {0, count + 1}}
      _, acc -> {:cont, acc}
    end)
    |> elem(1)
    |> Kernel.+(1)
  end

  defp current_module_name([]), do: nil
  defp current_module_name(stack), do: stack |> Enum.reverse() |> Enum.join(".")

  defp extract_single_line_string(line, prefix) do
    line
    |> String.trim_leading(prefix)
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end
end
