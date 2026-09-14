defmodule Backplane.AgentRuntime.Tools.LocalResource do
  use GenServer

  @behaviour Backplane.AgentRuntime.Resource

  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Local workspace resource adapter with coordinated revision writes.

  Confinement is limited to the declared scope and this adapter's coordinated
  writers. Lexical scope checking is not a complete OS sandbox boundary, and
  arbitrary external writers still require a stronger transactional backend.
  """

  @max_read_bytes 1_048_576
  @max_output_entries 100

  def start_link(_state \\ %{}) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl Backplane.AgentRuntime.Resource
  def read(resource, reference, opts) do
    with {:ok, path} <- confined_path(resource.scope, Map.get(reference, :path)),
         {:ok, content} <- regular_content(path) do
      bounded = bounded_content(content, opts)

      {:ok,
       %{
         path: resource_path(resource.scope, path),
         content: bounded.content,
         partial?: bounded.partial?,
         revision: revision(resource, path)
       }}
    end
  end

  @impl Backplane.AgentRuntime.Resource
  def write(resource, reference, content, _opts) do
    with {:ok, path} <- confined_path(resource.scope, Map.get(reference, :path)),
         {:ok, expected} <- expected_revision(reference, content) do
      if Map.get(reference, :create_only?, false) and File.exists?(path) do
        {:error, Error.new(:resource_conflict, "resource already exists")}
      else
        case current_revision(resource, path) do
          ^expected -> atomic_write(resource, path, content)
          current -> revision_conflict(expected, current)
        end
      end
    end
  end

  @impl Backplane.AgentRuntime.Resource
  def list_dir(resource, reference, opts) do
    with {:ok, path} <- confined_path(resource.scope, Map.get(reference, :path)),
         {:ok, names} <- File.ls(path) do
      entries =
        names
        |> Enum.sort()
        |> Enum.take(limit(opts))
        |> Enum.map(&entry(resource, Path.join(path, &1)))

      {:ok, %{entries: entries, provenance: "local_filesystem"}}
    else
      {:error, reason} ->
        {:error, Error.new(:validation, "local resource listing failed", cause: reason)}
    end
  end

  @impl Backplane.AgentRuntime.Resource
  def glob(resource, reference, pattern, opts) do
    with {:ok, root} <- confined_path(resource.scope, Map.get(reference, :path)),
         {:ok, full_pattern} <- confined_pattern(resource.scope, root, pattern) do
      matches =
        Path.wildcard(full_pattern, unescape: true)
        |> Enum.sort()
        |> Enum.take(limit(opts))
        |> Enum.filter(&inside_scope?(resource.scope, &1))
        |> Enum.map(&entry(resource, &1))

      {:ok, %{matches: matches, provenance: "local_filesystem"}}
    end
  end

  @impl Backplane.AgentRuntime.Resource
  def grep(resource, reference, opts) do
    opts = Map.new(opts)

    with {:ok, root} <- confined_path(resource.scope, Map.get(reference, :path)),
         {:ok, pattern} <- regex(opts) do
      matches =
        root
        |> Path.join(Map.get(opts, :pattern, "*"))
        |> Path.wildcard(unescape: true)
        |> Enum.sort()
        |> Enum.take(limit(opts))
        |> Enum.flat_map(&matches(resource, &1, pattern))
        |> Enum.take(limit(opts))

      {:ok, %{matches: matches, provenance: "local_filesystem"}}
    end
  end

  @impl Backplane.AgentRuntime.Resource
  def file_edit(resource, reference, edit, _opts) do
    with {:ok, path} <- confined_path(resource.scope, Map.get(reference, :path)),
         {:ok, expected} <- expected_revision(reference, edit),
         {:ok, find} <- require_binary(edit, :find, "find"),
         {:ok, existing_content} <- regular_content(path) do
      if revision(resource, path) == expected do
        replace_all? = Map.get(edit, :replace_all, false)

        case replace_text(existing_content, find, Map.get(edit, :replace, ""), replace_all?) do
          nil ->
            {:error, Error.new(:resource_conflict, "resource text was not found")}

          updated ->
            atomic_write(resource, path, %{payload: updated, expected_revision: expected})
        end
      else
        revision_conflict(expected, revision(resource, path))
      end
    end
  end

  defp regular_content(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        File.read(path)

      {:ok, _stat} ->
        {:error, Error.new(:unsupported_capability, "unsupported resource type")}

      {:error, reason} ->
        {:error, Error.new(:resource_conflict, "local resource read failed", cause: reason)}
    end
  end

  defp atomic_write(resource, path, content) do
    with {:ok, payload} <- encode_payload(Map.get(content, :payload)),
         temp = temporary_path(path),
         :ok <- File.write(temp, payload),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(temp) do
      case File.rename(temp, path) do
        :ok ->
          bump_revision(resource, path)
          {:ok, %{written: true, revision: revision(resource, path)}}

        {:error, reason} ->
          {:error, Error.new(:resource_conflict, "local resource write failed", cause: reason)}
      end
    else
      {:error, reason} ->
        {:error, Error.new(:resource_conflict, "local resource write failed", cause: reason)}
    end
  end

  defp temporary_path(path) do
    Path.join(
      Path.dirname(path),
      ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
    )
  end

  defp encode_payload(payload) when is_binary(payload), do: {:ok, payload}

  defp encode_payload(payload), do: {:ok, JSON.encode!(payload)}

  defp replace_text(content, find, replace, replace_all?) do
    options = if replace_all?, do: [:global], else: []
    replaced = :binary.replace(content, find, replace, options)

    if replaced == content and !String.contains?(content, find), do: nil, else: replaced
  end

  defp matches(resource, path, pattern) do
    case regular_content(path) do
      {:ok, content} when byte_size(content) <= @max_read_bytes ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, number} ->
          case Regex.run(pattern, line) do
            nil -> []
            match -> [%{path: resource_path(resource.scope, path), line: number, match: match}]
          end
        end)

      _ ->
        []
    end
  end

  defp regex(opts) do
    case Map.get(opts, :query) do
      query when is_binary(query) ->
        case Regex.compile(query) do
          {:ok, pattern} ->
            {:ok, pattern}

          {:error, reason} ->
            {:error, Error.new(:validation, "invalid grep query", cause: reason)}
        end

      _ ->
        {:error, Error.new(:validation, "query is required")}
    end
  end

  defp entry(resource, path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type, size: size}} ->
        %{
          path: resource_path(resource.scope, path),
          type: type,
          size: size,
          revision: revision(resource, path)
        }

      {:error, _reason} ->
        %{path: resource_path(resource.scope, path), type: :missing}
    end
  end

  defp resource_path(scope, path), do: Path.relative_to(path, scope)

  defp bounded_content(content, opts) do
    byte_limit = min(Keyword.get(opts, :output_limit, @max_read_bytes), @max_read_bytes)
    byte_offset = max(Keyword.get(opts, :offset, 0), 0)

    if byte_offset >= byte_size(content) do
      %{content: "", partial?: false}
    else
      available = byte_size(content) - byte_offset
      taken = min(byte_limit, available)
      chunk = binary_part(content, byte_offset, taken)
      %{content: chunk, partial?: byte_offset + taken < byte_size(content)}
    end
  end

  defp expected_revision(reference, content) do
    expected = Map.get(content, :expected_revision) || Map.get(reference, :expected_revision, 0)

    if is_integer(expected) and expected >= 0,
      do: {:ok, expected},
      else: {:error, Error.new(:validation, "expected_revision is required")}
  end

  defp require_binary(input, key, label) do
    value = Map.get(input, key)

    if is_binary(value) and value != "",
      do: {:ok, value},
      else: {:error, Error.new(:validation, "#{label} is required")}
  end

  defp current_revision(resource, path) do
    if File.exists?(path), do: revision(resource, path), else: 0
  end

  defp revision_conflict(expected, current) do
    {:error,
     Error.new(:resource_conflict, "resource revision conflict",
       details: %{expected: expected, current: current}
     )}
  end

  defp revision(resource, path) do
    key = {resource.namespace, path}
    GenServer.call(__MODULE__, {:revision, key})
  end

  defp bump_revision(resource, path) do
    key = {resource.namespace, path}
    GenServer.cast(__MODULE__, {:bump_revision, key})
  end

  defp confined_path(scope, path) when is_binary(scope) do
    with {:ok, _} <- require_binary(%{path: path}, :path, "path") do
      expanded = Path.expand(path, Path.expand(scope))

      if inside_scope?(Path.expand(scope), expanded),
        do: {:ok, expanded},
        else: {:error, Error.new(:forbidden, "resource path is outside declared scope")}
    end
  end

  defp confined_path(_scope, _path), do: {:error, Error.new(:validation, "path is required")}

  defp confined_pattern(scope, root, pattern) when is_binary(pattern) do
    full_pattern = Path.expand(pattern, root)

    if inside_scope?(scope, full_pattern),
      do: {:ok, full_pattern},
      else: {:error, Error.new(:forbidden, "glob pattern is outside declared scope")}
  end

  defp confined_pattern(_scope, _root, _pattern),
    do: {:error, Error.new(:validation, "pattern is required")}

  defp inside_scope?(scope, path) do
    path == scope or String.starts_with?(path, scope <> "/")
  end

  defp limit(opts) when is_map(opts), do: max(Map.get(opts, :limit, @max_output_entries), 0)
  defp limit(opts) when is_list(opts), do: limit(Map.new(opts))

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:revision, key}, _from, state) do
    {:reply, Map.get(state, key, 0), state}
  end

  @impl GenServer
  def handle_cast({:bump_revision, key}, state) do
    {:noreply, Map.update(state, key, 1, &(&1 + 1))}
  end
end
