defmodule Backplane.Skills.Blob.LocalFS do
  @moduledoc """
  Local filesystem storage for content-addressed skill archive blobs.
  """

  alias Backplane.Settings

  @ref_regex ~r/\Asha256\/[0-9a-f]{64}\.tar\.gz\z/

  @type blob_ref :: String.t()

  @spec put(binary(), keyword()) :: {:ok, blob_ref()} | {:error, term()}
  def put(bytes, opts \\ []) when is_binary(bytes) do
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    ref = "sha256/#{hash}.tar.gz"
    path = path_for_ref!(ref, opts)
    tmp_path = Path.join(Path.dirname(path), ".#{hash}.#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp_path, bytes, [:binary]),
         :ok <- File.rename(tmp_path, path) do
      {:ok, ref}
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  @spec get(blob_ref(), keyword()) :: {:ok, Enumerable.t()} | {:error, :not_found}
  def get(ref, opts \\ []) do
    with {:ok, path} <- path_for_ref(ref, opts),
         true <- File.regular?(path) do
      {:ok, File.stream!(path, [], 2048)}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec exists?(blob_ref(), keyword()) :: boolean()
  def exists?(ref, opts \\ []) do
    case path_for_ref(ref, opts) do
      {:ok, path} -> File.regular?(path)
      :error -> false
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

      :error ->
        :ok
    end
  end

  defp path_for_ref(ref, opts) do
    if valid_ref?(ref) do
      {:ok, path_for_ref!(ref, opts)}
    else
      :error
    end
  end

  defp path_for_ref!(ref, opts) do
    "sha256/" <> filename = ref
    Path.join([root(opts), "sha256", filename])
  end

  defp valid_ref?(ref) when is_binary(ref), do: Regex.match?(@ref_regex, ref)
  defp valid_ref?(_), do: false

  defp root(opts) do
    Keyword.get(opts, :root) ||
      Settings.get("skills.blob.local_root") ||
      Path.join(:code.priv_dir(:backplane), "skills_blobs")
  end
end
