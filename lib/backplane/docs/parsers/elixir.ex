defmodule Backplane.Docs.Parsers.Elixir do
  @moduledoc """
  Parser for Elixir .ex/.exs files.

  Uses `Code.string_to_quoted/2` for reliable AST-based extraction of:
  - @moduledoc as "moduledoc" chunks
  - @doc + function signature as "function_doc" chunks
  - @typedoc + @type as "typespec" chunks
  - Handles nested modules correctly via AST walking
  """

  @behaviour Backplane.Docs.Parser

  require Logger

  @impl true
  def parse(content, source_path) when is_binary(content) do
    case Code.string_to_quoted(content,
           columns: true,
           token_metadata: true,
           unescape: false,
           warn_on_unnecessary_quotes: false
         ) do
      {:ok, ast} ->
        chunks = walk(ast, source_path, [])
        {:ok, chunks}

      {:error, _} ->
        # Fall back to line-scanning for files with syntax errors
        chunks = fallback_extract(content, source_path)
        {:ok, chunks}
    end
  rescue
    e ->
      Logger.warning("Failed to parse #{source_path}: #{Exception.message(e)}")
      {:ok, []}
  end

  def parse(_content, source_path) do
    Logger.warning("Non-binary content for #{source_path}")
    {:ok, []}
  end

  # --- AST Walking ---

  defp walk({:defmodule, _meta, [alias_ast, [do: body]]}, source_path, module_stack) do
    mod_name = extract_module_name(alias_ast)
    new_stack = module_stack ++ [mod_name]
    walk_module_body(body, source_path, new_stack)
  end

  defp walk({:__block__, _meta, children}, source_path, module_stack) do
    walk_block(children, source_path, module_stack, nil, nil, nil)
  end

  defp walk(_ast, _source_path, _module_stack), do: []

  # Walk a module body, which may be a block or a single expression
  defp walk_module_body({:__block__, _meta, children}, source_path, module_stack) do
    walk_block(children, source_path, module_stack, nil, nil, nil)
  end

  defp walk_module_body(single_expr, source_path, module_stack) do
    walk_block([single_expr], source_path, module_stack, nil, nil, nil)
  end

  # Walk a list of expressions, tracking @moduledoc, @doc, @spec, @typedoc state
  defp walk_block([], _source_path, _module_stack, _doc, _spec, _typedoc), do: []

  defp walk_block([expr | rest], source_path, module_stack, doc, spec, typedoc) do
    # Handle nested defmodule directly to preserve source_path and module context
    case expr do
      {:defmodule, _meta, [alias_ast, [do: body]]} ->
        mod_name = extract_module_name(alias_ast)
        nested_stack = module_stack ++ [mod_name]
        nested_chunks = walk_module_body(body, source_path, nested_stack)
        nested_chunks ++ walk_block(rest, source_path, module_stack, nil, nil, nil)

      _ ->
        handle_classified(
          classify_expr(expr),
          rest,
          source_path,
          module_stack,
          doc,
          spec,
          typedoc
        )
    end
  end

  defp handle_classified(
         {:moduledoc, content},
         rest,
         source_path,
         module_stack,
         _doc,
         _spec,
         _typedoc
       ) do
    chunk = build_chunk(source_path, module_stack, nil, "moduledoc", content)
    [chunk | walk_block(rest, source_path, module_stack, nil, nil, nil)]
  end

  defp handle_classified(:moduledoc_false, rest, source_path, module_stack, _doc, _spec, _typedoc) do
    walk_block(rest, source_path, module_stack, nil, nil, nil)
  end

  defp handle_classified({:doc, content}, rest, source_path, module_stack, _doc, spec, typedoc) do
    walk_block(rest, source_path, module_stack, content, spec, typedoc)
  end

  defp handle_classified(:doc_false, rest, source_path, module_stack, _doc, _spec, typedoc) do
    walk_block(rest, source_path, module_stack, nil, nil, typedoc)
  end

  defp handle_classified({:spec, spec_text}, rest, source_path, module_stack, doc, _spec, typedoc) do
    walk_block(rest, source_path, module_stack, doc, spec_text, typedoc)
  end

  defp handle_classified(
         {:typedoc, content},
         rest,
         source_path,
         module_stack,
         doc,
         spec,
         _typedoc
       ) do
    walk_block(rest, source_path, module_stack, doc, spec, content)
  end

  defp handle_classified(
         {:type_def, type_text},
         rest,
         source_path,
         module_stack,
         doc,
         spec,
         typedoc
       ) do
    if typedoc do
      content = "#{type_text}\n\n#{typedoc}"
      chunk = build_chunk(source_path, module_stack, nil, "typespec", content)
      [chunk | walk_block(rest, source_path, module_stack, doc, spec, nil)]
    else
      walk_block(rest, source_path, module_stack, doc, spec, nil)
    end
  end

  defp handle_classified(
         {:function_def, func_sig},
         rest,
         source_path,
         module_stack,
         doc,
         spec,
         typedoc
       ) do
    if doc do
      content = if spec, do: "@spec #{spec}\n\n#{doc}", else: doc
      chunk = build_chunk(source_path, module_stack, func_sig, "function_doc", content)
      [chunk | walk_block(rest, source_path, module_stack, nil, nil, typedoc)]
    else
      walk_block(rest, source_path, module_stack, nil, nil, typedoc)
    end
  end

  defp handle_classified(:other, rest, source_path, module_stack, doc, spec, typedoc) do
    walk_block(rest, source_path, module_stack, doc, spec, typedoc)
  end

  # --- Expression Classification ---

  # @moduledoc false
  defp classify_expr({:@, _, [{:moduledoc, _, [false]}]}), do: :moduledoc_false

  # @moduledoc "..." or @moduledoc """..."""
  defp classify_expr({:@, _, [{:moduledoc, _, [content]}]}) when is_binary(content) do
    {:moduledoc, content}
  end

  # @moduledoc with sigil or other expressions — try to extract string
  defp classify_expr({:@, _, [{:moduledoc, _, [content_ast]}]}) do
    case extract_string_from_ast(content_ast) do
      nil -> :other
      content -> {:moduledoc, content}
    end
  end

  # @doc false
  defp classify_expr({:@, _, [{:doc, _, [false]}]}), do: :doc_false

  # @doc "..." or @doc """..."""
  defp classify_expr({:@, _, [{:doc, _, [content]}]}) when is_binary(content) do
    {:doc, content}
  end

  # @doc with sigil or other expressions
  defp classify_expr({:@, _, [{:doc, _, [content_ast]}]}) do
    case extract_string_from_ast(content_ast) do
      nil -> :other
      content -> {:doc, content}
    end
  end

  # @typedoc "..." or @typedoc """..."""
  defp classify_expr({:@, _, [{:typedoc, _, [content]}]}) when is_binary(content) do
    {:typedoc, content}
  end

  defp classify_expr({:@, _, [{:typedoc, _, [content_ast]}]}) do
    case extract_string_from_ast(content_ast) do
      nil -> :other
      content -> {:typedoc, content}
    end
  end

  # @spec
  defp classify_expr({:@, _, [{:spec, _, [spec_ast]}]}) do
    {:spec, Macro.to_string(spec_ast)}
  end

  # @type, @typep, @opaque
  defp classify_expr({:@, _, [{kind, _, [_type_ast]}]} = full_ast)
       when kind in [:type, :typep, :opaque] do
    {:type_def, Macro.to_string(full_ast)}
  end

  # def/defp/defmacro/defmacrop
  defp classify_expr({kind, _, _} = ast)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    {:function_def, extract_function_sig(ast)}
  end

  defp classify_expr(_), do: :other

  # --- Function Signature Extraction ---

  defp extract_function_sig({_kind, _meta, [{:when, _, [head | _guards]}, _body]}) do
    extract_name_arity(head)
  end

  defp extract_function_sig({_kind, _meta, [head | _]}) do
    extract_name_arity(head)
  end

  defp extract_name_arity({name, _meta, args}) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    "#{name}/#{arity}"
  end

  defp extract_name_arity(_), do: "unknown/0"

  # --- Module Name Extraction ---

  defp extract_module_name({:__aliases__, _, parts}) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp extract_module_name(atom) when is_atom(atom), do: to_string(atom)
  defp extract_module_name(_), do: "Unknown"

  # --- String Extraction from AST ---

  # Handle sigil_S, sigil_s, and other string-producing sigils
  defp extract_string_from_ast({:sigil_S, _, [{:<<>>, _, [content]}, _]}) when is_binary(content),
    do: content

  defp extract_string_from_ast({:sigil_s, _, [{:<<>>, _, [content]}, _]}) when is_binary(content),
    do: content

  defp extract_string_from_ast(_), do: nil

  # --- Chunk Building ---

  defp build_chunk(source_path, module_stack, function, chunk_type, content) do
    %{
      source_path: source_path,
      module: module_name(module_stack),
      function: function,
      chunk_type: chunk_type,
      content: content
    }
  end

  defp module_name([]), do: nil
  defp module_name(stack), do: Enum.join(stack, ".")

  # --- Fallback Line Scanner (for syntax errors) ---

  defp fallback_extract(content, source_path) do
    lines = String.split(content, "\n")

    state = %{
      module_stack: [],
      current_doc: nil,
      current_spec: nil,
      current_typedoc: nil,
      chunks: []
    }

    final = scan_lines(lines, source_path, state)
    Enum.reverse(final.chunks)
  end

  defp scan_lines([], _source_path, state), do: state

  defp scan_lines([line | rest], source_path, state) do
    trimmed = String.trim(line)
    classified = classify_fallback_line(trimmed, state)
    {remaining, new_state} = apply_fallback_line(classified, rest, source_path, state)
    scan_lines(remaining, source_path, new_state)
  end

  defp apply_fallback_line(:end_module, rest, _sp, state),
    do: {rest, %{state | module_stack: tl(state.module_stack)}}

  defp apply_fallback_line(:moduledoc_false, rest, _sp, state),
    do: {rest, %{state | current_doc: nil}}

  defp apply_fallback_line(:moduledoc_heredoc, rest, source_path, state) do
    {doc, remaining} = collect_heredoc_lines(rest)
    chunk = build_fallback_moduledoc(source_path, state, doc)
    {remaining, %{state | chunks: [chunk | state.chunks]}}
  end

  defp apply_fallback_line({:moduledoc_single, doc}, rest, source_path, state) do
    chunk = build_fallback_moduledoc(source_path, state, doc)
    {rest, %{state | chunks: [chunk | state.chunks]}}
  end

  defp apply_fallback_line(:doc_false, rest, _sp, state),
    do: {rest, %{state | current_doc: nil}}

  defp apply_fallback_line(:doc_heredoc, rest, _sp, state) do
    {doc, remaining} = collect_heredoc_lines(rest)
    {remaining, %{state | current_doc: doc}}
  end

  defp apply_fallback_line({:doc_single, doc}, rest, _sp, state),
    do: {rest, %{state | current_doc: doc}}

  defp apply_fallback_line({:spec, spec}, rest, _sp, state),
    do: {rest, %{state | current_spec: spec}}

  defp apply_fallback_line({:defmodule, mod_name}, rest, _sp, state),
    do: {rest, %{state | module_stack: [mod_name | state.module_stack]}}

  defp apply_fallback_line({:function_def, func_sig}, rest, source_path, state),
    do: {rest, handle_fallback_function(source_path, state, func_sig)}

  defp apply_fallback_line(:other, rest, _sp, state),
    do: {rest, state}

  defp classify_fallback_line("end", %{module_stack: [_ | _]}), do: :end_module

  defp classify_fallback_line("@moduledoc false" <> _, _state), do: :moduledoc_false
  defp classify_fallback_line("@moduledoc \"\"\"" <> _, _state), do: :moduledoc_heredoc

  defp classify_fallback_line("@moduledoc \"" <> _ = line, _state),
    do: {:moduledoc_single, extract_inline_string(line, "@moduledoc ")}

  defp classify_fallback_line("@doc false" <> _, _state), do: :doc_false
  defp classify_fallback_line("@doc \"\"\"" <> _, _state), do: :doc_heredoc

  defp classify_fallback_line("@doc \"" <> _ = line, _state),
    do: {:doc_single, extract_inline_string(line, "@doc ")}

  defp classify_fallback_line("@spec " <> spec, _state), do: {:spec, spec}

  defp classify_fallback_line(line, _state) do
    cond do
      mod = match_defmodule_line(line) -> {:defmodule, mod}
      func = match_function_line(line) -> {:function_def, func}
      true -> :other
    end
  end

  defp build_fallback_moduledoc(source_path, state, doc) do
    %{
      source_path: source_path,
      module: fallback_module_name(state.module_stack),
      function: nil,
      chunk_type: "moduledoc",
      content: doc
    }
  end

  defp handle_fallback_function(source_path, state, func_sig) do
    if state.current_doc do
      content =
        if state.current_spec,
          do: "@spec #{state.current_spec}\n\n#{state.current_doc}",
          else: state.current_doc

      chunk = %{
        source_path: source_path,
        module: fallback_module_name(state.module_stack),
        function: func_sig,
        chunk_type: "function_doc",
        content: content
      }

      %{state | current_doc: nil, current_spec: nil, chunks: [chunk | state.chunks]}
    else
      %{state | current_doc: nil, current_spec: nil}
    end
  end

  defp collect_heredoc_lines(lines), do: collect_heredoc_lines(lines, [])

  defp collect_heredoc_lines([], acc),
    do: {acc |> Enum.reverse() |> Enum.join("\n"), []}

  defp collect_heredoc_lines([line | rest], acc) do
    if String.trim(line) == "\"\"\"" do
      {acc |> Enum.reverse() |> Enum.join("\n"), rest}
    else
      collect_heredoc_lines(rest, [String.trim(line) | acc])
    end
  end

  defp extract_inline_string(line, prefix) do
    line
    |> String.trim_leading(prefix)
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp match_defmodule_line(line) do
    case Regex.run(~r/^defmodule\s+([\w.]+)/, line) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp match_function_line(line) do
    case Regex.run(~r/^(def|defp|defmacro|defmacrop)\s+([\w?!]+)(.*)$/, line) do
      [_, _kind, name, rest] ->
        arity = count_args_fallback(rest)
        "#{name}/#{arity}"

      _ ->
        nil
    end
  end

  defp count_args_fallback(rest) do
    trimmed = String.trim(rest)

    case trimmed do
      "(" <> _ -> count_balanced(trimmed)
      _ -> 0
    end
  end

  defp count_balanced("()" <> _), do: 0

  defp count_balanced("(" <> rest) do
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

  defp fallback_module_name([]), do: nil
  defp fallback_module_name(stack), do: stack |> Enum.reverse() |> Enum.join(".")
end
