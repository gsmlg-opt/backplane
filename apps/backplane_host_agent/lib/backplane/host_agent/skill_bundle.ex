defmodule Backplane.HostAgent.SkillBundle do
  @moduledoc """
  Validates extracted skill bundle shape before installation.
  """

  def validate(root) do
    skill_md = Path.join(root, "SKILL.md")

    with :ok <- validate_root(root) do
      cond do
        not File.regular?(skill_md) -> {:error, :missing_skill_md}
        true -> validate_safe_paths(root)
      end
    end
  end

  defp validate_root(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, %{type: :symlink}} -> {:error, {:unsafe_bundle_path, root}}
      {:ok, _stat} -> {:error, :missing_bundle_root}
      {:error, _reason} -> {:error, :missing_bundle_root}
    end
  end

  defp validate_safe_paths(root) do
    root_path = Path.expand(root)

    case validate_entries(root_path, root_path) do
      :ok -> {:ok, root}
      {:error, _reason} = error -> error
    end
  end

  defp validate_entries(root_path, current_path) do
    with {:ok, entries} <- File.ls(current_path) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        path = Path.join(current_path, entry)

        case validate_entry(root_path, path) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, reason} -> {:error, {:bundle_read_error, reason}}
    end
  end

  defp validate_entry(root_path, path) do
    with :ok <- validate_contained_path(root_path, path),
         {:ok, stat} <- File.lstat(path) do
      case stat.type do
        :symlink -> {:error, {:unsafe_bundle_path, path}}
        :directory -> validate_entries(root_path, path)
        _type -> :ok
      end
    else
      {:error, %File.Error{}} -> {:error, {:unsafe_bundle_path, path}}
      {:error, reason} when is_atom(reason) -> {:error, {:bundle_read_error, reason}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_contained_path(root_path, path) do
    expanded = Path.expand(path)

    if expanded == root_path or String.starts_with?(expanded, root_path <> "/") do
      :ok
    else
      {:error, {:unsafe_bundle_path, path}}
    end
  end
end
