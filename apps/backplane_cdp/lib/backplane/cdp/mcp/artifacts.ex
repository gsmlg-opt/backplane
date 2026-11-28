defmodule Backplane.CDP.MCP.Artifacts do
  @moduledoc false

  alias Backplane.CDP.Config

  def write(path, data) do
    with {:ok, destination} <- destination(path, ""), do: save(destination, data)
  end

  def destination(nil, extension) do
    name = "backplane-cdp-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    {:ok, Path.join(System.tmp_dir!(), name <> extension)}
  end

  def destination(path, extension) when is_binary(path) and path != "" do
    with {:ok, root} <- Config.artifact_dir(),
         path = Path.expand(path, root),
         true <- Path.dirname(path) == root and path != root do
      {:ok, if(String.ends_with?(path, extension), do: path, else: path <> extension)}
    else
      {:error, _message} = error ->
        error

      _ ->
        {:error,
         "Choose a file directly inside cdp.artifact_dir (host config) or BACKPLANE_CDP_ARTIFACT_DIR"}
    end
  end

  def destination(_, _), do: {:error, "Invalid artifact path"}

  # The upstream profiler and script tools replace any existing filename suffix.
  def named_destination(path, extension) do
    with {:ok, path} <- destination(path, ""), do: {:ok, Path.rootname(path) <> extension}
  end

  def save(path, data) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = with :ok <- File.chmod(path, 0o600), do: IO.binwrite(io, data)
        close = File.close(io)

        case {result, close} do
          {:ok, :ok} ->
            {:ok, path}

          _ ->
            File.rm(path)
            {:error, "Failed to write artifact"}
        end

      {:error, reason} ->
        {:error, "Cannot create artifact: #{:file.format_error(reason)}"}
    end
  end

  @doc "Streams a bounded artifact into private staging and publishes it exclusively on success."
  def stream(path, extension, max_bytes, operation)
      when is_integer(max_bytes) and max_bytes > 0 and is_function(operation, 1) do
    with {:ok, destination} <- named_destination(path, extension),
         {:ok, writer} <- Backplane.CDP.MCP.Artifacts.Writer.start(self(), destination, max_bytes) do
      try do
        case operation.(writer) do
          :ok -> GenServer.call(writer, :commit)
          {:error, _message} = error -> error
        end
      after
        if Process.alive?(writer), do: GenServer.stop(writer, :normal)
      end
    end
  end

  @doc "Writes one artifact chunk before the producer acknowledges it."
  def append(writer, data) when is_binary(data) do
    GenServer.call(writer, {:append, data})
  catch
    :exit, _reason -> {:error, "Artifact writer is unavailable"}
  end
end

defmodule Backplane.CDP.MCP.Artifacts.Writer do
  @moduledoc false
  use GenServer

  def start(owner, destination, limit) do
    case GenServer.start(__MODULE__, {owner, destination, limit}) do
      {:error, {:artifact_error, message}} -> {:error, message}
      result -> result
    end
  end

  @impl true
  def init({owner, destination, limit}) do
    name = ".backplane-cdp-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    directory = Path.join(Path.dirname(destination), name)
    source = Path.join(directory, "artifact")

    case File.mkdir(directory) do
      :ok ->
        prepare(owner, destination, directory, source, limit)

      {:error, reason} ->
        {:stop, {:artifact_error, file_error("create artifact staging", reason)}}
    end
  end

  defp prepare(owner, destination, directory, source, limit) do
    with :ok <- File.chmod(directory, 0o700),
         {:ok, io} <- open_private(source) do
      {:ok,
       %{
         owner: Process.monitor(owner),
         destination: destination,
         directory: directory,
         source: source,
         io: io,
         bytes: 0,
         limit: limit
       }}
    else
      {:error, reason} ->
        File.rm(source)
        File.rmdir(directory)
        {:stop, {:artifact_error, file_error("prepare private artifact", reason)}}
    end
  end

  defp open_private(source) do
    with {:ok, io} <- File.open(source, [:write, :binary, :exclusive]) do
      case File.chmod(source, 0o600) do
        :ok ->
          {:ok, io}

        {:error, reason} ->
          File.close(io)
          {:error, reason}
      end
    end
  end

  @impl true
  def handle_call({:append, data}, _from, state) do
    bytes = state.bytes + byte_size(data)

    if bytes <= state.limit do
      case IO.binwrite(state.io, data) do
        :ok -> {:reply, :ok, %{state | bytes: bytes}}
        {:error, reason} -> {:reply, {:error, file_error("write artifact", reason)}, state}
      end
    else
      {:reply, {:error, "Artifact exceeds the #{state.limit} byte limit"}, state}
    end
  end

  def handle_call(:commit, _from, %{bytes: 0} = state),
    do: {:reply, {:error, "Artifact stream is empty"}, state}

  def handle_call(:commit, _from, state) do
    result =
      with :ok <- File.close(state.io),
           :ok <- File.ln(state.source, state.destination) do
        {:ok, state.destination, state.bytes}
      else
        {:error, reason} -> {:error, file_error("publish artifact", reason)}
      end

    {:reply, result, %{state | io: nil}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner: monitor} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    if state.io, do: File.close(state.io)
    File.rm(state.source)
    File.rmdir(state.directory)
    :ok
  end

  defp file_error(action, reason), do: "Cannot #{action}: #{:file.format_error(reason)}"
end
