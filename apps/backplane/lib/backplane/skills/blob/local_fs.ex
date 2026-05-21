defmodule Backplane.Skills.Blob.LocalFS do
  @moduledoc """
  Local filesystem blob store for skill archives.
  """

  @behaviour Backplane.Skills.Blob

  alias Backplane.Settings

  @chunk_size 2048

  @impl true
  def put(hash, chunks) do
    with {:ok, path} <- path(hash),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      tmp_path = path <> ".tmp-#{System.unique_integer([:positive])}"

      case write_chunks(tmp_path, chunks) do
        :ok ->
          File.rename(tmp_path, path)

        {:error, reason} ->
          File.rm(tmp_path)
          {:error, reason}
      end
    end
  end

  @impl true
  def get(hash) do
    with {:ok, path} <- path(hash) do
      if File.exists?(path) do
        {:ok, File.stream!(path, [:read, :binary], @chunk_size)}
      else
        {:error, :not_found}
      end
    end
  end

  @impl true
  def exists?(hash) do
    case path(hash) do
      {:ok, path} -> File.exists?(path)
      {:error, _} -> false
    end
  end

  @impl true
  def delete(hash) do
    with {:ok, path} <- path(hash) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Resolve the configured archive path for a content hash."
  @spec path(String.t()) :: {:ok, String.t()} | {:error, :invalid_hash}
  def path(hash) do
    with {:ok, hash} <- normalize_hash(hash) do
      {:ok, Path.join([root(), "sha256", "#{hash}.tar.gz"])}
    end
  end

  defp write_chunks(path, chunks) when is_binary(chunks), do: write_chunks(path, [chunks])

  defp write_chunks(path, chunks) do
    case File.open(path, [:write, :binary], fn io ->
           Enum.each(chunks, &IO.binwrite(io, &1))
         end) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_hash("sha256/" <> rest),
    do: normalize_hash(String.trim_trailing(rest, ".tar.gz"))

  defp normalize_hash(hash) when is_binary(hash) do
    if String.match?(hash, ~r/^[a-f0-9]{64}$/) do
      {:ok, hash}
    else
      {:error, :invalid_hash}
    end
  end

  defp normalize_hash(_hash), do: {:error, :invalid_hash}

  defp root do
    Settings.get("skills.blob.local_root") ||
      :backplane
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("skills_blobs")
  end
end
