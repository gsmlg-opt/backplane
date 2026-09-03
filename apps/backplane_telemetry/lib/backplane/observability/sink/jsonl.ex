defmodule Backplane.Observability.Sink.JSONL do
  @moduledoc false

  require Logger

  @doc "Appends one JSON line to the configured runtime JSONL sink."
  @spec write(map(), keyword()) :: :ok | {:error, term()}
  def write(event, opts \\ []) when is_map(event) do
    path = Keyword.get(opts, :path, configured_path())

    with true <- is_binary(path),
         :ok <- ensure_dir(path),
         {:ok, json} <- Jason.encode(sanitize(event)) do
      case File.open(path, [:append, :utf8]) do
        {:ok, io} ->
          try do
            IO.write(io, json <> "\n")
            :ok
          after
            File.close(io)
          end

        {:error, reason} ->
          Logger.warning("Observability JSONL sink failed to open #{path}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      false -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp configured_path do
    Application.get_env(:backplane_telemetry, Backplane.Observability.RuntimeSink, [])
    |> Keyword.get(:log_to_file)
  end

  defp ensure_dir(path) do
    path |> Path.dirname() |> File.mkdir_p()
    :ok
  end

  defp sanitize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp sanitize(value) when is_struct(value) do
    if is_exception(value) do
      Exception.message(value)
    else
      value |> Map.from_struct() |> sanitize()
    end
  end

  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), sanitize(v)} end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)
  defp sanitize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp sanitize(value) when is_tuple(value), do: value |> Tuple.to_list() |> sanitize()
  defp sanitize(value), do: value
end
