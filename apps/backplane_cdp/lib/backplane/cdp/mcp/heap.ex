defmodule Backplane.CDP.MCP.Heap do
  @moduledoc "Streams Chrome heap snapshots into bounded private artifacts."

  alias Backplane.CDP.Client
  alias Backplane.CDP.MCP.{Artifacts, Pages}

  @max_bytes 64 * 1024 * 1024
  @timeout 120_000

  def call("take_heapsnapshot", args, state) when is_map(args) do
    with :ok <- validate(args),
         {:ok, target, state} <- Pages.selected(args, state) do
      result =
        Artifacts.stream(args["filePath"], ".heapsnapshot", @max_bytes, fn writer ->
          Client.with_connection(state.port, target, &capture(&1, writer), @timeout)
        end)

      case result do
        {:ok, path, _bytes} ->
          {:ok, [%{"type" => "text", "text" => "Heap snapshot saved to #{path}"}], state}

        {:error, message} ->
          {:error, message, state}
      end
    else
      {:error, message, state} -> {:error, message, state}
      {:error, message} -> {:error, message, state}
    end
  end

  def call(_name, _args, state), do: {:error, "Unsupported heap snapshot request", state}

  defp capture(connection, writer) do
    with {:ok, _} <- Client.send_command(connection, "HeapProfiler.enable", %{}) do
      try do
        with {:ok, _} <- Client.send_command(connection, "HeapProfiler.collectGarbage", %{}),
             {:ok, _} <-
               Client.stream_command(
                 connection,
                 "HeapProfiler.takeHeapSnapshot",
                 %{"reportProgress" => false},
                 "HeapProfiler.addHeapSnapshotChunk",
                 &write_chunk(writer, &1)
               ) do
          :ok
        end
      after
        Client.send_command(connection, "HeapProfiler.disable", %{})
      end
    end
  end

  defp write_chunk(writer, %{"chunk" => chunk}) when is_binary(chunk),
    do: Artifacts.append(writer, chunk)

  defp write_chunk(_writer, _params),
    do: {:error, "Chrome returned an invalid heap snapshot chunk"}

  defp validate(args) do
    cond do
      Map.keys(args) -- ~w(pageId filePath) != [] ->
        {:error, "Unsupported heap snapshot options"}

      not is_binary(args["filePath"]) or args["filePath"] == "" ->
        {:error, "A heap snapshot filePath is required"}

      true ->
        :ok
    end
  end
end
