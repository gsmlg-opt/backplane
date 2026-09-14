defmodule Backplane.SkillProtocol.TemporaryStorage do
  @moduledoc false

  @directory_mode 0o700
  @file_mode 0o600

  def directory(parent, prefix, opts \\ []) do
    suffix = Keyword.get(opts, :suffix, &random_suffix/0)
    attempts = Keyword.get(opts, :attempts, 5)

    Enum.reduce_while(1..attempts, {:error, :collision}, fn _, _acc ->
      path = Path.join(parent, prefix <> "." <> suffix.())

      case File.mkdir(path) do
        :ok -> {:halt, secure_directory(path)}
        {:error, :eexist} -> {:cont, {:error, :collision}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def ensure_directory(path) do
    case File.mkdir(path) do
      :ok -> secure_directory(path)
      {:error, :eexist} -> if File.dir?(path), do: :ok, else: {:error, :eexist}
      {:error, reason} -> {:error, reason}
    end
  end

  def open_file(path) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} -> secure_file(path, file)
      {:error, reason} -> {:error, reason}
    end
  end

  def write_file(path, bytes) do
    case open_file(path) do
      {:ok, file} ->
        result = :file.write(file, bytes)
        File.close(file)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            File.rm(path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp secure_directory(path) do
    case File.chmod(path, @directory_mode) do
      :ok ->
        {:ok, path}

      {:error, reason} ->
        File.rmdir(path)
        {:error, reason}
    end
  end

  defp secure_file(path, file) do
    case File.chmod(path, @file_mode) do
      :ok ->
        {:ok, file}

      {:error, reason} ->
        File.close(file)
        File.rm(path)
        {:error, reason}
    end
  end

  defp random_suffix, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
end
