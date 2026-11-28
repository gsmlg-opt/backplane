defmodule Backplane.HostAgent.Diagnostics.Collectors.Log do
  @moduledoc "Reads bounded error counters from a configured local log using a durable cursor."

  require Record
  alias Backplane.HostAgent.Diagnostics.Collectors.Probes

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @chunk 32 * 1024
  @max_line 4_096
  @levels ~w(error critical fatal alert emergency)

  @doc "The caller commits the returned cursor only after accepting the returned evidence."
  def sample(path, rotated_path, cursor) do
    with {:ok, current} <- stat(path) do
      follow(path, current, rotated_path, checked_cursor(cursor))
    else
      _ -> %{status: :unavailable, cursor: cursor, records: []}
    end
  end

  defp follow(path, stat, _previous, nil), do: read_cursor(path, stat, fresh(stat, 0))

  defp follow(path, stat, _previous, %{"file" => file, "offset" => offset} = cursor)
       when file == stat.id do
    if stat.size >= offset do
      read_cursor(path, stat, cursor)
    else
      rotated(path, stat, cursor, "log_truncated")
    end
  end

  defp follow(path, stat, previous_path, %{"file" => file, "offset" => offset} = cursor) do
    case stat(previous_path) do
      {:ok, previous} when previous.id == file and previous.size > offset ->
        read_rotated(previous_path, previous, path, stat, cursor)

      {:ok, previous} when previous.id == file and previous.size == offset ->
        read_cursor(path, stat, fresh(stat, cursor["generation"] + 1))

      _ ->
        rotated(path, stat, cursor, "log_rotation_gap")
    end
  end

  defp read_rotated(previous_path, previous, path, stat, %{"offset" => original_offset} = cursor) do
    case read_cursor(previous_path, previous, cursor) do
      %{status: :available, cursor: %{"offset" => ^original_offset}} ->
        rotated(path, stat, cursor, "log_rotation_gap")

      result ->
        result
    end
  end

  defp rotated(path, stat, cursor, reason) do
    next = read_cursor(path, stat, fresh(stat, cursor["generation"] + 1))
    %{next | records: [record(cursor, reason, %{}) | next.records]}
  end

  defp fresh(stat, generation),
    do: %{"file" => stat.id, "offset" => 0, "generation" => generation, "skip" => false}

  defp checked_cursor(
         %{"file" => file, "offset" => offset, "generation" => generation, "skip" => skip} =
           cursor
       )
       when is_binary(file) and is_integer(offset) and offset >= 0 and is_integer(generation) and
              generation >= 0 and is_boolean(skip),
       do: cursor

  defp checked_cursor(_), do: nil

  defp read_cursor(path, stat, cursor) do
    case read_chunk(path, stat, cursor["offset"]) do
      {:ok, bytes} -> consume(bytes, cursor)
      :eof -> %{status: :available, cursor: cursor, records: []}
      _ -> %{status: :unavailable, cursor: cursor, records: []}
    end
  end

  defp read_chunk(path, stat, offset) do
    with {:ok, io} <- File.open(path, [:read, :raw, :binary]) do
      try do
        case :file.read_file_info(io, time: :posix) do
          {:ok, file_info(type: :regular, major_device: major, minor_device: minor, inode: inode)}
          when {major, minor, inode} == stat.file ->
            :file.pread(io, offset, @chunk)

          _ ->
            {:error, :rotated_during_read}
        end
      after
        File.close(io)
      end
    end
  end

  defp stat(path) when is_binary(path) do
    case File.lstat(path, time: :posix) do
      {:ok,
       %File.Stat{
         type: :regular,
         major_device: major,
         minor_device: minor,
         inode: inode,
         size: size
       }} ->
        key = {major, minor, inode}
        {:ok, %{file: key, id: Probes.fingerprint(key), size: size}}

      _ ->
        {:error, :unavailable}
    end
  end

  defp stat(_), do: {:error, :unavailable}

  defp consume(bytes, %{"skip" => true} = cursor) do
    case :binary.match(bytes, "\n") do
      {boundary, 1} ->
        count = boundary + 1

        consume(binary_part(bytes, count, byte_size(bytes) - count), %{
          move(cursor, count)
          | "skip" => false
        })

      :nomatch ->
        %{status: :available, cursor: move(cursor, byte_size(bytes)), records: []}
    end
  end

  defp consume(bytes, cursor) do
    case List.last(:binary.matches(bytes, "\n")) do
      {boundary, 1} ->
        count = boundary + 1
        lines = bytes |> binary_part(0, count) |> :binary.split("\n", [:global, :trim_all])
        errors = Enum.count(lines, &error_line?/1)
        skipped = Enum.count(lines, &(byte_size(&1) > @max_line or not String.valid?(&1)))

        records =
          [
            if(skipped > 0,
              do: record(cursor, "unparseable_log_lines", %{"skipped_lines" => skipped})
            ),
            if(errors > 0,
              do: record(cursor, "structured_log_errors", %{"error_lines" => errors})
            )
          ]
          |> Enum.reject(&is_nil/1)

        %{status: :available, cursor: move(cursor, count), records: records}

      nil when byte_size(bytes) >= @chunk ->
        %{
          status: :available,
          cursor: %{move(cursor, byte_size(bytes)) | "skip" => true},
          records: [record(cursor, "overlong_log_line", %{})]
        }

      nil ->
        %{status: :available, cursor: cursor, records: []}
    end
  end

  defp move(cursor, bytes), do: Map.update!(cursor, "offset", &(&1 + bytes))

  defp record(cursor, kind, measurements) do
    id = Probes.fingerprint({cursor["file"], cursor["generation"], cursor["offset"], kind})
    %{id: id, kind: kind, measurements: measurements}
  end

  defp error_line?(line) when byte_size(line) <= @max_line do
    if String.valid?(line) do
      line = String.trim_leading(line)

      case line do
        "{" <> _ -> json_error?(line)
        _ -> Regex.match?(~r/\A\[(error|critical|fatal|alert|emergency)\](?:\s|\z)/i, line)
      end
    else
      false
    end
  end

  defp error_line?(_), do: false

  defp json_error?(line) do
    with {:ok, %{} = body} <- Formata.JSON.decode(line),
         level when is_binary(level) and byte_size(level) <= 12 <-
           body["level"] || body["severity"] do
      String.downcase(level) in @levels
    else
      _ -> false
    end
  end
end
