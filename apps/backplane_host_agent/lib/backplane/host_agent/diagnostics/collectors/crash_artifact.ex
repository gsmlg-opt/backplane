defmodule Backplane.HostAgent.Diagnostics.Collectors.CrashArtifact do
  @moduledoc "Summarizes metadata for an explicitly registered crash artifact without opening its contents."

  alias Backplane.HostAgent.Diagnostics.Collectors.Probes

  def sample(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = info} ->
        reference =
          Probes.fingerprint(
            {info.major_device, info.minor_device, info.inode, info.mtime, info.size}
          )

        %{
          status: :available,
          reference: "crash-artifact:" <> reference,
          bytes: info.size,
          modified_at: info.mtime
        }

      {:error, :enoent} ->
        %{status: :absent}

      _ ->
        %{status: :unavailable}
    end
  end
end
