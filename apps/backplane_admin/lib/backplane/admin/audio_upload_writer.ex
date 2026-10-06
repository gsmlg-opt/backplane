defmodule Backplane.Admin.AudioUploadWriter do
  @moduledoc "Writes preview uploads only while their server-admitted preview remains alive."
  @behaviour Phoenix.LiveView.UploadWriter

  alias Phoenix.LiveView.UploadTmpFileWriter

  @impl true
  def init(opts) do
    admission = %{session: opts[:session], deadline: opts[:deadline]}

    if admitted?(admission) do
      with {:ok, file} <- UploadTmpFileWriter.init([]) do
        case File.chmod(file.path, 0o600) do
          :ok ->
            {:ok, Map.put(admission, :file, file)}

          {:error, reason} ->
            UploadTmpFileWriter.close(file, :cancel)
            File.rm(file.path)
            {:error, reason}
        end
      end
    else
      {:error, :upload_not_admitted}
    end
  end

  @impl true
  def meta(state), do: UploadTmpFileWriter.meta(state.file)

  @impl true
  def write_chunk(bytes, state) do
    if admitted?(state) do
      {:ok, file} = UploadTmpFileWriter.write_chunk(bytes, state.file)
      {:ok, %{state | file: file}}
    else
      {:error, :upload_not_admitted, state}
    end
  end

  @impl true
  def close(state, reason) do
    result = UploadTmpFileWriter.close(state.file, reason)
    expired? = reason == :done and not admitted?(state)
    if reason != :done or expired?, do: File.rm(state.file.path)

    case result do
      {:ok, _} when expired? -> {:error, :upload_not_admitted}
      {:ok, file} -> {:ok, %{state | file: file}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admitted?(%{session: session, deadline: deadline}) do
    is_pid(session) and node(session) == node() and Process.alive?(session) and
      is_integer(deadline) and System.monotonic_time(:millisecond) < deadline
  end
end
