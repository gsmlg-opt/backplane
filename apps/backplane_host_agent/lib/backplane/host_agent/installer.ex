defmodule Backplane.HostAgent.Installer do
  @moduledoc """
  Installs validated extracted skills into configured local target roots.
  """

  alias Backplane.HostAgent.{LocalStore, SkillBundle}

  @slug_format ~r/\A[a-z0-9][a-z0-9-]*\z/

  def install_extracted(source_root, skill, targets) do
    slug = skill["slug"]

    with :ok <- validate_slug(slug),
         {:ok, _root} <- SkillBundle.validate(source_root),
         {:ok, target_plan} <- resolve_install_targets(skill, targets) do
      install_targets(source_root, slug, target_plan)
    end
  end

  defp resolve_install_targets(skill, targets) do
    skill
    |> Map.get("targets", [])
    |> Enum.reduce_while({:ok, []}, fn target_name, {:ok, target_plan} ->
      case target_for_install(targets, target_name) do
        {:error, reason} ->
          {:halt, {:error, reason}}

        :skip ->
          {:cont, {:ok, target_plan}}

        {:ok, target} ->
          case target_root_for_install(target, target_name) do
            {:ok, target_root} -> {:cont, {:ok, [{target_name, target_root} | target_plan]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, target_plan} -> {:ok, Enum.reverse(target_plan)}
      error -> error
    end
  end

  defp install_targets(source_root, slug, target_plan) do
    Enum.reduce_while(target_plan, {:ok, []}, fn {target_name, target_root}, {:ok, installed} ->
      case replace_install(source_root, target_root, slug) do
        :ok -> {:cont, {:ok, [target_name | installed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, installed} -> {:ok, Enum.reverse(installed)}
      error -> error
    end
  end

  defp target_for_install(targets, target_name) do
    case LocalStore.target_by_name(targets, target_name) do
      nil ->
        {:error, {:target_missing, target_name}}

      target ->
        if LocalStore.field(target, :enabled, true) do
          {:ok, target}
        else
          :skip
        end
    end
  end

  defp target_root_for_install(target, target_name) do
    case LocalStore.field(target, :path) do
      target_root when is_binary(target_root) ->
        if File.dir?(target_root) do
          {:ok, target_root}
        else
          {:error, {:target_missing, target_name}}
        end

      _target_root ->
        {:error, {:target_missing, target_name}}
    end
  end

  defp validate_slug(slug) when is_binary(slug) do
    if Regex.match?(@slug_format, slug) do
      :ok
    else
      {:error, {:invalid_slug, slug}}
    end
  end

  defp validate_slug(slug), do: {:error, {:invalid_slug, slug}}

  defp replace_install(source_root, target_root, slug) do
    with {:ok, paths} <- install_paths(target_root, slug),
         :ok <- File.mkdir_p(paths.tmp_root),
         {:ok, _copied} <- File.cp_r(source_root, paths.tmp_path),
         :ok <- remove_if_exists(paths.backup_path),
         :ok <- move_existing(paths.final_path, paths.backup_path),
         :ok <- rename_with_restore(paths.tmp_path, paths.final_path, paths.backup_path),
         :ok <- remove_if_exists(paths.backup_path) do
      :ok
    else
      {:error, reason, _file} ->
        cleanup_tmp(target_root, slug)
        {:error, reason}

      {:error, {:restore_failed, _reason} = reason} ->
        {:error, reason}

      {:error, reason} ->
        cleanup_tmp(target_root, slug)
        {:error, reason}
    end
  end

  defp install_paths(target_root, slug) do
    target_root = Path.expand(target_root)
    tmp_root = Path.join(target_root, ".backplane-tmp")
    tmp_path = Path.expand(Path.join(tmp_root, "#{slug}-#{unique_suffix()}"))
    final_path = Path.expand(Path.join(target_root, slug))
    backup_path = Path.expand(Path.join(tmp_root, "#{slug}-#{unique_suffix()}.backup"))

    with :ok <- validate_contained_path(target_root, tmp_path, slug),
         :ok <- validate_contained_path(target_root, final_path, slug),
         :ok <- validate_contained_path(target_root, backup_path, slug) do
      {:ok,
       %{
         backup_path: backup_path,
         final_path: final_path,
         tmp_path: tmp_path,
         tmp_root: tmp_root
       }}
    end
  end

  defp validate_contained_path(target_root, path, slug) do
    if path == target_root or String.starts_with?(path, target_root <> "/") do
      :ok
    else
      {:error, {:invalid_slug, slug}}
    end
  end

  defp move_existing(final_path, backup_path) do
    if File.exists?(final_path) do
      File.rename(final_path, backup_path)
    else
      :ok
    end
  end

  defp rename_with_restore(tmp_path, final_path, backup_path) do
    case File.rename(tmp_path, final_path) do
      :ok ->
        :ok

      {:error, reason} ->
        case restore_backup(final_path, backup_path) do
          :ok -> {:error, reason}
          {:error, {:restore_failed, _reason}} = error -> error
        end
    end
  end

  defp restore_backup(final_path, backup_path) do
    if File.exists?(backup_path) and not File.exists?(final_path) do
      case File.rename(backup_path, final_path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:restore_failed, reason}}
      end
    else
      :ok
    end
  end

  defp remove_if_exists(path) do
    if File.exists?(path) do
      case File.rm_rf(path) do
        {:ok, _removed} -> :ok
        {:error, _path, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp cleanup_tmp(target_root, slug) do
    target_root = Path.expand(target_root)
    tmp_root = Path.join(target_root, ".backplane-tmp")
    tmp_glob = Path.join(tmp_root, "#{slug}-*")

    tmp_glob
    |> Path.wildcard()
    |> Enum.each(&remove_if_exists/1)
  end

  defp unique_suffix do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
