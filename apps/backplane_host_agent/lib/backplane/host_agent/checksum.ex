defmodule Backplane.HostAgent.Checksum do
  @moduledoc """
  Checksum verification helpers for downloaded skill archives.
  """

  @sha256_format ~r/\Asha256:[0-9a-f]{64}\z/

  def verify_file(path, "sha256:" <> _hex = checksum) do
    if Regex.match?(@sha256_format, checksum) do
      verify_sha256(path, checksum)
    else
      {:error, :unsupported_checksum}
    end
  end

  def verify_file(_path, _checksum), do: {:error, :unsupported_checksum}

  defp verify_sha256(path, "sha256:" <> expected) do
    if File.regular?(path) do
      actual =
        path
        |> File.stream!([], 2048)
        |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, context ->
          :crypto.hash_update(context, chunk)
        end)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      if actual == expected do
        :ok
      else
        {:error, :checksum_mismatch}
      end
    else
      {:error, :missing_file}
    end
  rescue
    error in File.Error -> {:error, {:file_error, error.reason}}
  end
end
