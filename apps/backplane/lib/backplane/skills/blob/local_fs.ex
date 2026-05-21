defmodule Backplane.Skills.Blob.LocalFS do
  @moduledoc """
  Local filesystem storage for content-addressed skill archive blobs.
  """

  alias Backplane.Settings

  @ref_regex ~r/\Asha256\/[0-9a-f]{64}\.tar\.gz\z/

  @type blob_ref :: String.t()

  @spec default_root() :: String.t()
  def default_root do
    :user_data
    |> :filename.basedir("backplane")
    |> Path.join("skills_blobs")
  end

  @spec put(binary(), keyword()) :: {:ok, blob_ref()} | {:error, term()}
  def put(bytes, opts \\ []) when is_binary(bytes) do
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    ref = "sha256/#{hash}.tar.gz"

    with {:ok, path} <- path_for_ref(ref, opts),
         :ok <- atomic_write(path, bytes, hash) do
      {:ok, ref}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec put_file(String.t(), keyword()) :: {:ok, blob_ref()} | {:error, term()}
  def put_file(source_path, opts \\ []) when is_binary(source_path) do
    with {:ok, root} <- root(opts),
         {:ok, tmp_path, hash} <- copy_to_temp(source_path, root) do
      commit_upload(tmp_path, hash, opts)
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get(blob_ref(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def get(ref, opts \\ []) do
    with {:ok, path} <- path_for_ref(ref, opts),
         true <- File.regular?(path) do
      {:ok, File.stream!(path, [], 2048)}
    else
      {:error, {:invalid_root, _root}} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @spec exists?(blob_ref(), keyword()) :: boolean()
  def exists?(ref, opts \\ []) do
    case path_for_ref(ref, opts) do
      {:ok, path} -> File.regular?(path)
      _ -> false
    end
  end

  @spec delete(blob_ref(), keyword()) :: :ok | {:error, term()}
  def delete(ref, opts \\ []) do
    case path_for_ref(ref, opts) do
      {:ok, path} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, {:invalid_root, _root}} = error ->
        error

      :error ->
        :ok
    end
  end

  defp path_for_ref(ref, opts) do
    with true <- valid_ref?(ref),
         {:ok, root} <- root(opts) do
      "sha256/" <> filename = ref
      {:ok, Path.join([root, "sha256", filename])}
    else
      false -> :error
      {:error, _} = error -> error
    end
  end

  defp atomic_write(path, bytes, hash) do
    tmp_path = Path.join(Path.dirname(path), ".#{hash}.#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp_path, bytes, [:binary]),
         :ok <- commit_temp(tmp_path, path, hash) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp copy_to_temp(source_path, root) do
    tmp_path =
      Path.join([
        root,
        "sha256",
        ".upload.#{System.unique_integer([:positive])}.tmp"
      ])

    with :ok <- File.mkdir_p(Path.dirname(tmp_path)),
         {:ok, hash} <- copy_file_with_hash(source_path, tmp_path) do
      {:ok, tmp_path, hash}
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp copy_file_with_hash(source_path, tmp_path) do
    case File.open(source_path, [:read, :binary]) do
      {:ok, source} ->
        try do
          case File.open(tmp_path, [:write, :binary]) do
            {:ok, target} ->
              try do
                copy_chunks(source, target, :crypto.hash_init(:sha256))
              after
                File.close(target)
              end

            {:error, reason} ->
              {:error, reason}
          end
        after
          File.close(source)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_chunks(source, target, hash_state) do
    case IO.binread(source, 2048) do
      :eof ->
        hash = hash_state |> :crypto.hash_final() |> Base.encode16(case: :lower)
        {:ok, hash}

      {:error, reason} ->
        {:error, reason}

      chunk ->
        case IO.binwrite(target, chunk) do
          :ok -> copy_chunks(source, target, :crypto.hash_update(hash_state, chunk))
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp commit_upload(tmp_path, hash, opts) do
    ref = "sha256/#{hash}.tar.gz"

    with {:ok, path} <- path_for_ref(ref, opts),
         :ok <- commit_temp(tmp_path, path, hash) do
      {:ok, ref}
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}

      :error ->
        File.rm(tmp_path)
        {:error, :invalid_ref}
    end
  end

  defp commit_temp(tmp_path, path, hash) do
    cond do
      File.regular?(path) and existing_hash_matches?(path, hash) ->
        File.rm(tmp_path)
        :ok

      File.regular?(path) ->
        replace_corrupt_destination(tmp_path, path)

      true ->
        File.rename(tmp_path, path)
    end
  end

  defp existing_hash_matches?(path, hash) do
    case sha256_file(path) do
      {:ok, ^hash} -> true
      _ -> false
    end
  end

  defp replace_corrupt_destination(tmp_path, path) do
    with :ok <- File.rm(path) do
      File.rename(tmp_path, path)
    end
  end

  defp sha256_file(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          hash =
            io
            |> IO.binstream(2048)
            |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
            |> :crypto.hash_final()
            |> Base.encode16(case: :lower)

          {:ok, hash}
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_ref?(ref) when is_binary(ref), do: Regex.match?(@ref_regex, ref)
  defp valid_ref?(_), do: false

  defp root(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} -> normalize_root(root)
      :error -> Settings.get("skills.blob.local_root") |> normalize_root()
    end
  end

  defp normalize_root(root) when is_binary(root) do
    if String.trim(root) == "" do
      {:ok, default_root()}
    else
      require_absolute_root(root)
    end
  end

  defp normalize_root(nil), do: {:ok, default_root()}
  defp normalize_root(root), do: {:error, {:invalid_root, root}}

  defp require_absolute_root(root) do
    case Path.type(root) do
      :absolute -> {:ok, root}
      _ -> {:error, {:invalid_root, root}}
    end
  end
end
