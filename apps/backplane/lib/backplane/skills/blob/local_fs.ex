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
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
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
