defmodule Backplane.HostAgent.Installer do
  @moduledoc """
  Installs validated extracted skills into configured local target roots.
  """

  alias Backplane.HostAgent.{Checksum, LocalStore, SkillBundle}

  @slug_format ~r/\A[a-z0-9][a-z0-9-]*\z/

  def install(skill, config) do
    slug = field(skill, :slug)

    with :ok <- validate_slug(slug),
         {:ok, paths} <- work_paths(config, slug) do
      result =
        with :ok <- File.mkdir_p(paths.work_root),
             {:ok, archive_path} <- download_archive(skill, config, paths.archive_path),
             :ok <-
               Checksum.verify_file(archive_path, normalized_checksum(field(skill, :checksum))),
             {:ok, bundle_root} <- extract_archive(archive_path, paths.extract_root),
             {:ok, installed} <-
               install_extracted(bundle_root, skill, field(config, :targets, [])) do
          {:ok, installed}
        else
          {:error, reason} -> {:error, reason}
          {:error, reason, _file} -> {:error, reason}
        end

      remove_if_exists(paths.work_root)
      result
    end
  end

  def remove(skill, config) do
    slug = field(skill, :slug)

    with :ok <- validate_slug(slug),
         {:ok, target_plan} <- resolve_remove_targets(skill, field(config, :targets, [])) do
      remove_targets(slug, target_plan)
    end
  end

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

  defp resolve_remove_targets(skill, targets) do
    skill
    |> field(:targets, [])
    |> Enum.reduce_while({:ok, []}, fn target_name, {:ok, target_plan} ->
      case LocalStore.target_by_name(targets, target_name) do
        nil ->
          {:halt, {:error, {:target_missing, target_name}}}

        target ->
          case LocalStore.field(target, :path) do
            target_root when is_binary(target_root) ->
              if File.dir?(target_root) do
                {:cont, {:ok, [{target_name, target_root} | target_plan]}}
              else
                {:halt, {:error, {:target_missing, target_name}}}
              end

            _target_root ->
              {:halt, {:error, {:target_missing, target_name}}}
          end
      end
    end)
    |> case do
      {:ok, target_plan} -> {:ok, Enum.reverse(target_plan)}
      error -> error
    end
  end

  defp remove_targets(slug, target_plan) do
    Enum.reduce_while(target_plan, {:ok, []}, fn {target_name, target_root}, {:ok, removed} ->
      case remove_one(target_root, slug) do
        :ok -> {:cont, {:ok, [target_name | removed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      error -> error
    end
  end

  defp remove_one(target_root, slug) do
    target_root = Path.expand(target_root)
    path = Path.expand(Path.join(target_root, slug))

    with :ok <- validate_contained_path(target_root, path, slug) do
      remove_if_exists(path)
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

  defp work_paths(config, slug) do
    case field(config, :work_dir) do
      work_dir when is_binary(work_dir) ->
        work_dir = Path.expand(work_dir)
        work_root = Path.expand(Path.join(work_dir, "#{slug}-#{unique_suffix()}"))

        with :ok <- validate_contained_path(work_dir, work_root, slug) do
          {:ok,
           %{
             archive_path: Path.join(work_root, "archive.tar.gz"),
             extract_root: Path.join(work_root, "extract"),
             work_root: work_root
           }}
        end

      _work_dir ->
        {:error, :missing_work_dir}
    end
  end

  defp download_archive(skill, config, archive_path) do
    with {:ok, url} <- download_url(skill, config),
         :ok <- File.mkdir_p(Path.dirname(archive_path)) do
      headers = download_headers(config)

      case field(config, :download_fun) do
        fun when is_function(fun, 3) ->
          case fun.(url, headers, archive_path) do
            :ok -> {:ok, archive_path}
            {:ok, _value} -> {:ok, archive_path}
            {:error, _reason} = error -> error
            other -> {:error, {:download_failed, other}}
          end

        _fun ->
          req_options =
            config
            |> field(:req_options, [])
            |> Keyword.merge(
              url: url,
              headers: headers,
              into: File.stream!(archive_path),
              retry: false
            )

          case Req.get(req_options) do
            {:ok, %{status: status}} when status in 200..299 -> {:ok, archive_path}
            {:ok, %{status: status}} -> {:error, {:download_failed, status}}
            {:error, reason} -> {:error, {:download_failed, reason}}
          end
      end
    end
  rescue
    error in File.Error -> {:error, {:file_error, error.reason}}
  end

  defp download_url(skill, config) do
    case field(skill, :download_url) do
      url when is_binary(url) ->
        uri = URI.parse(url)

        if uri.scheme do
          {:ok, url}
        else
          with hub_url when is_binary(hub_url) <- field(config, :hub_url) do
            {:ok, String.trim_trailing(hub_url, "/") <> "/" <> String.trim_leading(url, "/")}
          else
            _hub_url -> {:error, :missing_hub_url}
          end
        end

      _url ->
        {:error, :missing_download_url}
    end
  end

  defp download_headers(config) do
    case field(config, :token) do
      token when is_binary(token) -> [{"X-Backplane-Host-Token", token}]
      _token -> []
    end
  end

  defp normalized_checksum(nil), do: nil
  defp normalized_checksum("sha256:" <> _rest = checksum), do: checksum
  defp normalized_checksum(checksum) when is_binary(checksum), do: "sha256:" <> checksum
  defp normalized_checksum(checksum), do: checksum

  defp extract_archive(archive_path, extract_root) do
    with {:ok, root} <- archive_root(archive_path),
         :ok <- File.mkdir_p(extract_root),
         :ok <- extract_tar(archive_path, extract_root) do
      {:ok, Path.join(extract_root, root)}
    end
  end

  defp archive_root(archive_path) do
    with {:ok, entries} <- tar_entries(archive_path),
         {:ok, root} <- skill_root(entries),
         :ok <- validate_single_root(entries, root) do
      {:ok, root}
    end
  end

  defp tar_entries(archive_path) do
    case :erl_tar.table(String.to_charlist(archive_path), [:compressed, :verbose]) do
      {:ok, entries} ->
        normalize_tar_entries(entries)

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_tar_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, name, type} <- normalize_tar_entry(entry),
           :ok <- validate_tar_path(name),
           :ok <- validate_tar_type(name, type) do
        {:cont, {:ok, [%{name: name, type: type} | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_tar_entry({name, type, _size, _mtime, _mode, _uid, _gid}) do
    {:ok, IO.chardata_to_string(name), type}
  end

  defp normalize_tar_entry({name, _size, type}) do
    {:ok, IO.chardata_to_string(name), type}
  end

  defp normalize_tar_entry(_entry), do: {:error, :malformed_tar_entry}

  defp validate_tar_path(name) do
    cond do
      name == "" -> {:error, {:unsafe_path, name}}
      Path.type(name) == :absolute -> {:error, {:unsafe_path, name}}
      String.contains?(name, "\\") -> {:error, {:unsafe_path, name}}
      ".." in path_segments(name) -> {:error, {:unsafe_path, name}}
      windows_drive_path?(name) -> {:error, {:unsafe_path, name}}
      percent_encoded_dot_path?(name) -> {:error, {:unsafe_path, name}}
      true -> :ok
    end
  end

  defp validate_tar_type(_name, :regular), do: :ok
  defp validate_tar_type(_name, :directory), do: :ok
  defp validate_tar_type(name, type), do: {:error, {:unsupported_entry_type, name, type}}

  defp skill_root(entries) do
    file_entries = Enum.filter(entries, &(&1.type == :regular))

    case Enum.filter(file_entries, &(Path.basename(&1.name) == "SKILL.md")) do
      [%{name: skill_path}] ->
        root = Path.dirname(skill_path)

        if root in [".", ""] do
          {:error, :missing_skill_root}
        else
          {:ok, root}
        end

      [] ->
        {:error, :missing_skill_md}

      _multiple ->
        {:error, :ambiguous_skill_md}
    end
  end

  defp validate_single_root(entries, root) do
    if Enum.all?(entries, &under_root?(&1.name, root)) do
      :ok
    else
      {:error, :ambiguous_archive}
    end
  end

  defp under_root?(name, root), do: name == root or String.starts_with?(name, root <> "/")

  defp extract_tar(archive_path, extract_root) do
    case :erl_tar.extract(String.to_charlist(archive_path), [
           :compressed,
           {:cwd, String.to_charlist(extract_root)}
         ]) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp windows_drive_path?(name),
    do: Enum.any?(path_segments(name), &Regex.match?(~r/^[A-Za-z]:/, &1))

  defp percent_encoded_dot_path?(name),
    do: Enum.any?(path_segments(name), &Regex.match?(~r/%2e/i, &1))

  defp path_segments(name), do: String.split(name, "/", trim: false)

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

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
