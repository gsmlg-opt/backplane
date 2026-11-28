defmodule Backplane.HostAgent.Diagnostics.Collectors.Cursor do
  @moduledoc false

  alias Backplane.HostAgent.Diagnostics.Collectors.Probes

  @max_bytes 512 * 1024

  def load(path) do
    case Probes.read(path, @max_bytes) do
      {:ok, encoded} ->
        case Formata.JSON.decode(encoded) do
          {:ok, %{"targets" => targets, "sequences" => sequences} = value}
          when is_map(targets) and is_map(sequences) ->
            {:ok, value}

          _ ->
            {:error, :invalid_cursor}
        end

      {:error, :enoent} ->
        {:ok, %{"targets" => %{}, "sequences" => %{}}}

      _ ->
        {:error, :cursor_unavailable}
    end
  end

  def save(path, value) do
    payload = Formata.JSON.encode!(value)

    if byte_size(payload) <= @max_bytes do
      temporary =
        path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, file} <- File.open(temporary, [:write, :raw, :binary, :exclusive]) do
        try do
          with :ok <- File.chmod(temporary, 0o600),
               :ok <- :file.write(file, payload),
               :ok <- :file.sync(file),
               :ok <- File.close(file) do
            File.rename(temporary, path)
          end
        after
          _ = File.close(file)
          _ = File.rm(temporary)
        end
      end
    else
      {:error, :cursor_capacity}
    end
  end
end
