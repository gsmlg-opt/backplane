defmodule Backplane.Skills.Archive do
  @moduledoc "Legacy archive facade backed by the complete Skill Protocol bundle inspector."

  alias Backplane.SkillProtocol.Bundle
  alias Backplane.SkillProtocol.Error

  @default_max_files 500
  @default_max_bytes 5_000_000

  @type result :: %{
          skill_md: binary(),
          skill_entry: map(),
          meta: map(),
          files: [String.t()],
          file_count: non_neg_integer(),
          size_bytes: non_neg_integer(),
          artifact_digest: String.t()
        }

  @spec inspect(String.t() | %{path: String.t()}, keyword()) :: {:ok, result()} | {:error, term()}
  def inspect(path_or_upload, opts \\ []) do
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    shared_opts = [
      validation_profile: :legacy,
      validate_directory_name: false,
      max_entries: max_files,
      max_file_bytes: max(8 * 1024 * 1024, max_bytes)
    ]

    with {:ok, bundle} <- Bundle.inspect(path_or_upload, shared_opts),
         :ok <- validate_legacy_required_bytes(bundle, max_bytes),
         {:ok, skill_entry} <- Backplane.Skills.Loader.parse(bundle.document.raw) do
      {:ok,
       %{
         skill_md: bundle.document.raw,
         skill_entry: skill_entry,
         meta: bundle.meta,
         files: Enum.map(bundle.manifest.files, & &1.path),
         file_count: length(bundle.manifest.files),
         size_bytes: bundle.manifest.compressed_bytes,
         artifact_digest: bundle.manifest.artifact_digest
       }}
    else
      {:error, %Error{} = error} -> {:error, legacy_error(error, max_files)}
      {:error, _} = error -> error
    end
  end

  defp validate_legacy_required_bytes(bundle, max_bytes) do
    byte_count =
      byte_size(bundle.document.raw) +
        case Map.fetch(bundle.files, "meta.json") do
          {:ok, bytes} -> byte_size(bytes)
          :error -> 0
        end

    if byte_count > max_bytes,
      do: {:error, {:too_many_bytes, byte_count, max_bytes}},
      else: :ok
  end

  defp legacy_error(%Error{code: :invalid_request}, _max), do: :invalid_archive_path

  defp legacy_error(
         %Error{
           code: :invalid_bundle,
           message: "archive cannot be read",
           context: %{reason: ":enoent"}
         },
         _max
       ),
       do: :enoent

  defp legacy_error(
         %Error{code: :invalid_document, context: %{diagnostics: diagnostics}},
         _max
       ) do
    reason =
      if Enum.any?(diagnostics, &(&1.code == :missing_name)),
        do: :missing_frontmatter,
        else: :malformed_frontmatter

    {:invalid_skill_md, reason}
  end

  defp legacy_error(
         %Error{code: :invalid_bundle, message: "bundle root has no SKILL.md"},
         _max
       ),
       do: :missing_skill_md

  defp legacy_error(
         %Error{code: :invalid_bundle, message: "bundle must contain exactly one logical root"},
         _max
       ),
       do: :ambiguous_archive

  defp legacy_error(
         %Error{code: :invalid_bundle, message: "archive path is unsafe", context: %{path: path}},
         _max
       ),
       do: {:unsafe_path, path}

  defp legacy_error(
         %Error{
           code: :invalid_bundle,
           message: "archive entry type is unsupported",
           context: %{path: path, type: type}
         },
         _max
       ),
       do: {:unsupported_entry_type, path, type}

  defp legacy_error(
         %Error{code: :invalid_bundle, message: "meta.json must contain a JSON object"},
         _max
       ),
       do: :malformed_meta_json

  defp legacy_error(
         %Error{
           code: :limit_exceeded,
           context: %{budget: :archive_entries, actual: actual}
         },
         max
       ),
       do: {:too_many_files, actual, max}

  defp legacy_error(%Error{} = error, _max), do: {error.code, error.message}
end
