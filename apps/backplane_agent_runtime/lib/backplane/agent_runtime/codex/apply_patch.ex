defmodule Backplane.AgentRuntime.Codex.ApplyPatch do
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.PathGuard

  @moduledoc """
  Small, strict implementation of the Codex apply_patch grammar.
  """

  @spec apply(String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def apply(root, patch) when is_binary(root) and is_binary(patch) do
    with {:ok, operations} <- parse(patch),
         {:ok, results} <- execute(root, operations) do
      {:ok, %{status: :applied, files: results}}
    end
  end

  def apply(_root, _patch), do: {:error, Error.new(:validation, "patch must be a string")}

  defp parse(patch) do
    lines = patch |> String.trim() |> String.split("\n", trim: false)

    if String.trim(List.first(lines) || "") == "*** Begin Patch" and
         String.trim(List.last(lines) || "") == "*** End Patch" and
         length(lines) > 2,
       do: parse_ops(Enum.slice(lines, 1..-2//1), []),
       else:
         {:error,
          Error.new(
            :validation,
            "patch must start with *** Begin Patch and end with *** End Patch"
          )}
  end

  defp parse_ops([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_ops([header | rest], acc) do
    {kind, path} =
      cond do
        String.starts_with?(header, "*** Add File: ") ->
          {:add, String.trim_leading(header, "*** Add File: ")}

        String.starts_with?(header, "*** Update File: ") ->
          {:update, String.trim_leading(header, "*** Update File: ")}

        String.starts_with?(header, "*** Delete File: ") ->
          {:delete, String.trim_leading(header, "*** Delete File: ")}

        String.starts_with?(header, "*** Move to: ") ->
          {:move, String.trim_leading(header, "*** Move to: ")}

        true ->
          {nil, nil}
      end

    if kind == nil do
      {:error, Error.new(:validation, "invalid patch operation header", details: %{line: header})}
    else
      case {kind, rest} do
        {:update, [move_header | move_tail]} when is_binary(move_header) ->
          if String.starts_with?(move_header, "*** Move to: ") do
            destination = String.trim_leading(move_header, "*** Move to: ")
            {body, tail} = take_until_header(move_tail, [])

            parse_ops(tail, [
              %{kind: :move, path: path, destination: destination, body: body} | acc
            ])
          else
            {body, tail} = take_until_header(rest, [])
            parse_ops(tail, [%{kind: kind, path: path, body: body} | acc])
          end

        _ ->
          {body, tail} = take_until_header(rest, [])
          parse_ops(tail, [%{kind: kind, path: path, body: body} | acc])
      end
    end
  end

  defp take_until_header([], acc), do: {Enum.reverse(acc), []}

  defp take_until_header([line | rest] = all, acc) do
    if String.starts_with?(line, "*** "),
      do: {Enum.reverse(acc), all},
      else: take_until_header(rest, [line | acc])
  end

  defp execute(root, operations) do
    Enum.reduce_while(operations, {:ok, []}, fn op, {:ok, done} ->
      case execute_one(root, op) do
        {:ok, result} -> {:cont, {:ok, [result | done]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp execute_one(root, %{kind: :move, path: source, destination: destination, body: _body}) do
    with {:ok, origin} <- confined(root, source),
         {:ok, target} <- confined(root, destination),
         :ok <- File.rename(origin, target) do
      {:ok, %{from: origin, path: target, action: :moved}}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, Error.new(:resource_conflict, "file move failed", cause: reason)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp execute_one(root, %{kind: kind, path: path, body: body}) do
    with {:ok, full} <- confined(root, path) do
      case kind do
        :add -> write_new(full, added_content(body))
        :update -> update(full, body)
        :delete -> delete(full)
        :move -> move(root, full, body)
      end
    end
  end

  defp write_new(path, content) do
    if File.exists?(path) or File.lstat(path) != {:error, :enoent} do
      {:error, Error.new(:resource_conflict, "file already exists")}
    else
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, content) do
        {:ok, %{path: path, action: :added}}
      else
        {:error, reason} ->
          {:error, Error.new(:resource_conflict, "file write failed", cause: reason)}
      end
    end
  end

  defp update(path, body) do
    with {:ok, old} <- File.read(path),
         {:ok, new} <- apply_hunks(old, body),
         :ok <- File.write(path, new),
         do: {:ok, %{path: path, action: :updated}}
  end

  defp delete(path),
    do:
      if(File.rm(path) == :ok,
        do: {:ok, %{path: path, action: :deleted}},
        else: {:error, Error.new(:resource_conflict, "file deletion failed")}
      )

  defp move(root, destination, body) do
    source = body |> List.first() |> to_string()

    with {:ok, origin} <- confined(root, source),
         :ok <- File.rename(origin, destination),
         do: {:ok, %{from: origin, path: destination, action: :moved}}
  end

  defp added_content(lines),
    do:
      lines
      |> Enum.filter(&String.starts_with?(&1, "+"))
      |> Enum.map(&String.slice(&1, 1..-1//1))
      |> Enum.join("\n")
      |> Kernel.<>("\n")

  defp apply_hunks(old, lines) do
    lines = Enum.reject(lines, &String.starts_with?(&1, "@@"))
    expected = lines |> Enum.reject(&String.starts_with?(&1, "+")) |> Enum.map(&patch_text/1)
    replacement = lines |> Enum.reject(&String.starts_with?(&1, "-")) |> Enum.map(&patch_text/1)

    cond do
      expected == [] and replacement == [] ->
        {:ok, old}

      expected == [] ->
        {:ok, old <> Enum.join(replacement, "\n") <> "\n"}

      true ->
        needle = Enum.join(expected, "\n")
        value = Enum.join(replacement, "\n")

        if String.contains?(old, needle) do
          {:ok, String.replace(old, needle, value, global: false)}
        else
          {:error, Error.new(:resource_conflict, "patch context did not match")}
        end
    end
  end

  defp patch_text(<<prefix::binary-size(1), rest::binary>>) when prefix in [" ", "+", "-"] do
    rest
  end

  defp patch_text(line), do: line

  defp confined(root, path) when is_binary(path) do
    PathGuard.authorize(root, path)
  end

  defp confined(_, _), do: {:error, Error.new(:validation, "patch path is required")}
end
